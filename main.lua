--[[
	main.lua
		Bagnon companion module for ProjectEbonhold's ExtBank ("Void Storage")
		custom bank-extension feature.

		ExtBank is not a stock container -- it rides its own opcodes and its
		own addressing scheme, exposed to Lua by ebonhold.dll as:
			ExtBankOpen()                              -> CMSG_EXTBANK_OPEN
			ExtBankMove(sBag,sSlot,dBag,dSlot,count)   -> CMSG_EXTBANK_MOVE
			ExtBankUnlock()                            -> CMSG_EXTBANK_UNLOCK
			ExtBank_OnPacket('<hex>')   <- called on SMSG_EXTBANK_UPDATE

		This file is the driver: the module declaration, the addressing
		constants, the open/close lifecycle, and the thin wrappers over the
		native calls. Everything else lives beside it:

			core/model.lua        the packet parse and the model it builds
			core/nativeHooks.lua  chaining onto ProjectEbonhold's globals,
			                      and hiding the frames it draws
			core/cursor.lua       where the carried item came from
			core/deposit.lua      right-clicking an item in your real bags

			components/bag.lua, bagFrame.lua        the bag-slot strip
			components/item.lua, itemFrame.lua      the shared item grid
			components/frame.lua, pageBar.lua       Bagnon's chrome around it
			components/frameSettings.lua,
			           savedFrameSettings.lua       this frame's settings
			components/frameOptions.lua             its Bagnon_Config panel
--]]

local Bagnon = LibStub('AceAddon-3.0'):GetAddon('Bagnon')

-- AceTimer-3.0 is here for core/deposit.lua's two delayed checks AND for this
-- file's own first-snapshot wait (ShowWindowOnceModelReady below, which schedules
-- and cancels a timer on every session's first open) -- 3.3.5 has no C_Timer.
-- Both callers matter: trimming the mixin on the strength of deposit.lua alone
-- throws `attempt to call method 'ScheduleTimer' (a nil value)` on the first open
-- of every session, from inside a handler that has already latched the native
-- window off -- no vault UI at all, /reload the only way back. A clean
-- `luac5.1 -p` does not catch it.
--
-- It's embedded and loaded by core Bagnon's own embeds.xml, so it's already
-- present by the time this file runs; nothing extra to vendor or declare in the
-- .toc.
local ExtBank = Bagnon:NewModule('ExtBank', 'AceEvent-3.0', 'AceTimer-3.0')

-- Shared with every other file in this addon -- the core/ logic files and the
-- components/ widgets alike, none of which can see a `local` here. Same
-- pattern core Bagnon itself uses for e.g. Bagnon.ItemFrame.
Bagnon.ExtBank = ExtBank


--[[ Identity ]]--
-- What the options panel prints as its header (components/frameOptions.lua).
--
-- Deliberately duplicated from the .toc's ## Version / ## X-Date rather than
-- read back out of it with GetAddOnMetadata: the client parses every .toc
-- ONCE, at launch, and serves GetAddOnMetadata out of that launch-time cache
-- forever after. Drop a newer build into Interface\AddOns and /reload -- which
-- is how most people update an addon -- and the panel would still print the
-- version the client read at login, with nothing on screen hinting the update
-- landed. Lua files ARE re-executed by a /reload, so these two are correct the
-- moment it finishes.
--
-- The .toc keeps its own copies regardless: those are what addon managers list
-- and what .github/scripts/build.sh and release.yml read to name and tag a
-- release. Nothing keeps two hand-maintained copies honest, so neither copy is
-- hand-maintained -- .github/scripts/stamp-version.sh writes both from the
-- .toc's version plus today's date, the pre-commit hook runs it, and CI
-- re-checks it. See README's "Working on this addon".
ExtBank.VERSION = '1.0.0'
ExtBank.DATE    = '18-08-2026'


--[[ Addressing ]]--
-- Mirrored from modules/extBank/extBank.lua's own header comment:
--   bag 0        = backpack, bag 1..4 = character bags (live inventory)
--   bag 19       = ext bag-slot strip (slot = bag-slot index; holds the container)
--   bag 20+b     = contents of ext bag-slot b (slot = item slot, 0..bagSize-1)
--   dstBag 0xFF  = first free ext content slot
--   dstBag 0xFE  = first free live-inventory slot
--   dstSlot 0xFF on bag 19 = first free bag slot
--
-- Module fields rather than file-locals because they're read from two files:
-- the action wrappers at the bottom of this one, and ParsePacket's own
-- bag -> bagIndex conversion in core/model.lua. Both read them at call time,
-- so this file loading first (per the .toc) costs nothing.
ExtBank.HDR_BAG      = 19   -- bag: the ext bag-slot strip itself
ExtBank.CONTENT_BASE = 20   -- bag: 20+b = contents of equipped ext-bag b
ExtBank.AUTO_INV     = 254  -- dstBag sentinel: first free live-inventory slot

-- Hard cap on bag-slots, mirrored from the native UI (it stops offering
-- purchases past this point). The bag-slot strip widget needs this to know
-- how many buttons to build.
ExtBank.MAX_BAGS = 70

-- The Bagnon frameID this whole module is keyed on. Every settings default,
-- every monkeypatch guard over vendored Bagnon, and every FrameSettings:Get
-- call in this addon uses it.
--
-- A constant rather than eleven copies of the literal because of how a typo
-- fails here: none of those sites would error. Each one is a
-- `if frameID == 'extbank'` guard in a wrap around a core method, so a
-- misspelling silently takes the fall-through branch instead -- core's bag
-- defaults rather than our 70-slot availableBags, the generic bags title
-- rather than "%s's Void Storage", core's session-only bag-strip flag rather
-- than the persisted one. The window still opens; it is just quietly the
-- wrong window, and nothing points at the cause.
ExtBank.FRAME_ID = 'extbank'


--[[ Lifecycle ]]--

function ExtBank:OnEnable()
	-- Built once, up front, and left hidden until the native window opens --
	-- same as how Bagnon_GuildBank builds its frame unconditionally in
	-- OnEnable rather than waiting for the first open. The reference is kept
	-- on the module because core/deposit.lua's GetCurrentPageFreeSlot and
	-- IsBagOnCurrentPage need a way to reach the live item grid's current
	-- page from outside the widget hierarchy -- everywhere else that needs it
	-- is itself a widget descended from this frame and just calls
	-- self:GetParent() up the chain (see components/pageBar.lua), which isn't
	-- an option for this module.
	self.window = Bagnon.ExtBankFrame:New(self.FRAME_ID)

	-- Published where core looks, as well as kept here. Bagnon keeps its own list
	-- and answers Bagnon:GetFrame(frameID) out of it; building ours directly left
	-- that returning nil for 'extbank', which is a licence rather than a nuisance --
	-- Bagnon:ShowFrame and :ToggleFrame both do `if not GetFrame(id) then
	-- CreateFrame(id) end`, and core's CreateFrame instantiates the PLAIN Bagnon.Frame.
	-- That would be a second frame for this frameID: same BagnonFrameextbank global
	-- name, a second UISpecialFrames entry, and a core ItemFrame querying our 0..69
	-- ExtBank bag indices as though they were real bagIDs, with nothing pointing at
	-- it. The only thing standing in the way today is that enabledFrames has no
	-- 'extbank' key, so IsFrameEnabled returns false -- an unrelated settings default,
	-- not a guard. Registering makes core's create-on-demand path a no-op by
	-- construction. Safe: Bagnon/main.lua touches self.frames only in GetFrame and
	-- CreateFrame, so nothing else iterates it.
	table.insert(Bagnon.frames, self.window)

	-- Safe to hook immediately, no PLAYER_LOGIN gating -- see the comment
	-- above it in core/deposit.lua.
	self:HookInventoryDepositWatch()

	-- Here rather than in OnNativeOpen, for the same reason and by the same test:
	-- PickupContainerItem and SplitContainerItem are stock Blizzard globals, always
	-- present, so there is nothing to wait for. Armed lazily at the first open, they
	-- missed any pickup made BEFORE it -- so a player already carrying a stack when
	-- they opened the vault for the first time that session had no recorded source,
	-- and dropping it on a cell was refused with "pick it up from your bags to
	-- deposit it", which is exactly what they had just done. It self-healed only if
	-- they put the item down and picked it up again.
	self:HookCursorTracking()

	-- The ProjectEbonhold-owned globals are the opposite case and have to
	-- wait for load order to settle -- see core/nativeHooks.lua.
	self:RegisterEvent('PLAYER_LOGIN', 'HookNativeGlobals')

	-- And again on every world entry, which is the retry. ebonhold.dll can register
	-- its natives slightly after PLAYER_LOGIN -- the repo's own probe warns about
	-- exactly that state and ships a manual rehook for it -- and HookNativeGlobals
	-- bailing out is silent: no packet chain, no window, no error, the addon simply
	-- absent for the session with /reload the only way back. PLAYER_ENTERING_WORLD
	-- fires on login and on every zone and instance change, so a late DLL gets
	-- picked up on the next loading screen instead of never. Both registrations are
	-- dropped once the hooks are in (see HookNativeGlobals).
	self:RegisterEvent('PLAYER_ENTERING_WORLD', 'HookNativeGlobals')

	-- PLAYER_LOGIN only ever fires once, at the very start of the session --
	-- if this module enabled after that already happened, the registration
	-- above will never fire. Cover that case directly.
	if IsLoggedIn() then
		self:HookNativeGlobals()
	end
end

-- Fires whenever the player opens the native ExtBank window (the existing
-- "Void Storage" button, or /extbank) -- our own window replaces the native
-- one on screen (see HideNativeWindow in core/nativeHooks.lua) rather than
-- showing alongside it; this is purely our side reacting to the same click.
--
-- previousOpen() (the real native ExtBank_Open, already called by the time
-- our hook runs) has just fired off ExtBankOpen() to request a fresh
-- snapshot, but nothing's arrived yet -- on this session's very first open
-- there's no earlier data to fall back on either, so showing right away
-- means an empty, undersized window that jumps to its real size and
-- contents a moment later once the response lands (see components/
-- itemFrame.lua's own first-open fix). Once we've received a snapshot at
-- least once, later opens already have a correctly-sized, correctly-
-- populated window to show immediately -- the fresh snapshot each open
-- after that just updates it quietly in place, no visible jump -- so only
-- this session's first open needs to wait.
-- Lifecycle state for the whole open..close sequence below.
--
-- Declared HERE, above the first function that reads them, rather than further
-- down beside the wait they belong to: Lua 5.1 resolves upvalues lexically at
-- compile time, so a `local` written after OnNativeOpen is simply invisible to it
-- -- the name would silently read a nil GLOBAL of the same name instead, with no
-- error at load and no error at call. The old placement got away with it only
-- because nothing above it touched them directly.
--
-- nativeSessionOpen: true from the moment ProjectEbonhold's ExtBank_Open ran
-- until its ExtBank_Close does. Deliberately NOT the same question as "is our
-- window shown" -- see IsVaultSessionOpen below.
local nativeSessionOpen = false

-- The session's first-snapshot wait: whether one is running, its timeout handle,
-- and whether this open has already spent its one retry.
local waitingForModel = false
local pendingShowTimer = nil
local retriedFirstSnapshot = false

function ExtBank:OnNativeOpen()
	-- First, and before HideNativeWindow can latch anything: from here on the
	-- native side believes the vault is open and its own right-click deposit is
	-- live, so core/deposit.lua's watch has to be armed for every click made
	-- between now and the close -- including the ones made while nothing of ours
	-- is on screen, which after the changes below is a state that can last for
	-- the whole of an open.
	nativeSessionOpen = true

	self:HideNativeWindow()

	if self.hasModel then
		self:ShowWindow()
	else
		self:ShowWindowOnceModelReady()
	end
end

-- Reached on EVERY close path, not only a native one: the X button and Escape
-- hide our frame, components/frame.lua's OnHide calls _G.ExtBank_Close(), and
-- core/nativeHooks.lua's wrapper on that global lands right back here. That makes
-- this the one funnel which does not require our window to have ever been SHOWN
-- -- which is why the deposit clear below lives here as well as in Frame:OnHide.
function ExtBank:OnNativeClose()
	nativeSessionOpen = false
	self:CancelPendingShow()

	-- Deliberately duplicated with components/frame.lua's OnHide rather than moved
	-- out of it. OnHide is the funnel for a frame that is actually shown; while the
	-- first-snapshot wait below is running -- or after it has given up -- the window
	-- has never been Show()n this session, so Hide() on it runs no OnHide script at
	-- all and every arm survives the close. core/deposit.lua arms in exactly that
	-- gap by design, so without this those arms outlive the window they were raised
	-- for: any packet landing inside DEPOSIT_RESPONSE_WINDOW then runs
	-- CorrectPendingDeposit against a closed vault, which is either a UIErrorsFrame
	-- line printed for a window that is not on screen or an unrequested
	-- MoveWithinVault reshuffling a vault nobody is looking at.
	--
	-- Only the deposit arms, though -- not the pick or the purchase popup that
	-- OnHide also clears. Both of those can only be created by clicking something
	-- inside our own window, so neither can exist in the never-shown state this is
	-- here to cover.
	self:ClearPendingDeposit()

	Bagnon.FrameSettings:Get(self.FRAME_ID):Hide()
end

function ExtBank:ShowWindow()
	Bagnon.FrameSettings:Get(self.FRAME_ID):Show()
end

-- Read by core/deposit.lua: the deposit watch has to arm for the whole native
-- session, not just for the part of it our window happens to be on screen for.
--
-- Replaces an `IsWaitingForModel() or FrameSettings:IsShown()` pair that reached
-- for this question through two proxies -- "a first-show wait is running" and
-- "our window is up" -- on the reasoning that between them they spanned the
-- session. They still do, but now only because GiveUpOnFirstShow below remembers
-- to call _G.ExtBank_Close(): drop that call, or let it fall through its type()
-- guard on a client where the global is missing, and the give-up leaves a session
-- the native side still considers open with neither proxy true. The watch would
-- then be disarmed for the rest of that open -- taking the stuck-item warning
-- with it, in precisely the state where the server is least healthy and a refused
-- deposit is most likely. Asking the real question costs one flag and stops the
-- answer being something two files have to keep agreeing about.
--
-- Nothing is lost by dropping the IsShown() arm: ShowWindow is only ever reached
-- from inside a session, so a shown window already implies this flag.
function ExtBank:IsVaultSessionOpen()
	return nativeSessionOpen
end

-- How long to wait for the session's first snapshot before acting on its absence.
-- Comfortably past the ~100ms a snapshot actually takes (measured, see
-- docs/non-issues.md §10) -- this is a backstop for a snapshot that is never
-- coming, not a race against a slow one. Spent twice per open: once before the
-- retry, once before giving up.
local FIRST_SHOW_TIMEOUT = 3 -- seconds

-- Deliberately not an open-ended wait -- and deliberately not a "show it anyway"
-- backstop either. HideNativeWindow (core/nativeHooks.lua) has already hooked the
-- native frames' Show straight to Hide and latched for the session by the time we
-- get here, so if the snapshot never lands there is no vault UI left at all: ours
-- never shows, theirs can no longer show. Any of a dropped ExtBankOpen, a throw
-- inside ProjectEbonhold's own packet handler, a recv handler stranded on a
-- reconnected NetClient, or a plain server hiccup gets there.
--
-- This USED to show the window regardless, reasoning that "an ugly window the
-- player can close beats no window at all". That is sound about the APPEARANCE of
-- the window and wrong about what sits behind it. With no snapshot the model is
-- not merely empty, it is WRONG, and subsystems downstream read it as
-- authoritative: unlockedBags is 0, so the strip renders all 70 slots locked and
-- the purchase button quotes 50g for "bag slot 1" -- a real price attached to a
-- real CMSG_EXTBANK_UNLOCK, which the server then prices from its own count. A
-- player who owns 6 slots reads 50g as a bargain and is charged 5000. That is the
-- one failure here that costs real currency, and it lived on the one code path
-- that exists precisely BECAUSE the model is known to be missing.
--
-- So the timeout re-asks the server instead (RequestSnapshot), and if that goes
-- unanswered too it gives up in a way the player can see and act on
-- (GiveUpOnFirstShow) rather than painting a window backed by zeros.
function ExtBank:ShowWindowOnceModelReady()
	if waitingForModel then return end
	waitingForModel = true
	retriedFirstSnapshot = false
	Bagnon.Callbacks:Listen(self, 'EXTBANK_MODEL_UPDATED', 'OnModelReadyForFirstShow')
	pendingShowTimer = self:ScheduleTimer('OnFirstShowTimeout', FIRST_SHOW_TIMEOUT)
end

-- Also called from OnNativeClose -- covers closing again before any
-- response ever arrived, so a snapshot that lands after the player already
-- left doesn't pop the window open on them unasked.
function ExtBank:CancelPendingShow()
	if waitingForModel then
		waitingForModel = false
		Bagnon.Callbacks:Ignore(self, 'EXTBANK_MODEL_UPDATED')
	end

	-- Outside the flag's guard: the timer is what clears the flag on the timeout
	-- path, so by the time OnFirstShowTimeout calls through here the flag is
	-- already false while the handle still needs dropping.
	if pendingShowTimer then
		self:CancelTimer(pendingShowTimer)
		pendingShowTimer = nil
	end
end

function ExtBank:OnModelReadyForFirstShow()
	self:CancelPendingShow()
	self:ShowWindow()
end

-- Two stages, one timer: the first expiry re-asks the server, the second gives up
-- on this open. Both are reached only while a wait is still live -- a snapshot
-- landing or the player closing in between cancels the timer and clears the flag.
--
-- A retry that could not be sent at all (no native) falls straight through to the
-- give-up rather than burning the second three seconds waiting for an answer to a
-- question that was never asked.
function ExtBank:OnFirstShowTimeout()
	pendingShowTimer = nil
	if not waitingForModel then return end

	if not retriedFirstSnapshot then
		retriedFirstSnapshot = true
		if self:RequestSnapshot() then
			pendingShowTimer = self:ScheduleTimer('OnFirstShowTimeout', FIRST_SHOW_TIMEOUT)
			return
		end
	end

	self:CancelPendingShow()
	self:GiveUpOnFirstShow()
end

-- Re-send CMSG_EXTBANK_OPEN, once, when the first one went unanswered.
--
-- _G.ExtBankOpen -- the ebonhold.dll native -- and NOT _G.ExtBank_Open, which is
-- extBank.lua's own UI function and one we have chained (core/nativeHooks.lua).
-- Calling that one re-enters our own wrapper: previousOpen re-anchors and
-- re-Show()s both native frames, calls HideBankPanel() a second time, and then
-- comes back through OnNativeOpen to arm a fresh wait on top of the one that is
-- already running. The native is the request and nothing else.
--
-- This is worth more than a hopeful re-send, which is the whole reason it is here
-- rather than a straight give-up at 3s. Lua_ExtBankOpen
-- (ebonhold-reference/ebonhold-utils/extbank_client.h) does EnsureHandler()
-- BEFORE it sends, which re-registers the SMSG_EXTBANK_UPDATE handler on the LIVE
-- NetClient -- the header documents that call as idempotent, "safe to call
-- often", and specifically as the repair for a NetClient object recreated by a
-- reconnect. A recv handler stranded on a stale NetClient is one of the concrete
-- ways the first snapshot goes missing, and it is one this call actually fixes.
-- Its SendMsg also no-ops with "NetClient not ready" when not connected, another
-- transient a second attempt covers.
--
-- ONCE, though, and never on a timer of its own. A server that is not answering
-- will not start because we asked a third time, and nothing on this side can see
-- what the packets cost.
--
-- Returns whether the request actually went out, matching the convention every
-- other native call in this file follows.
function ExtBank:RequestSnapshot()
	if type(_G.ExtBankOpen) ~= 'function' then return false end

	_G.ExtBankOpen()
	UIErrorsFrame:AddMessage('Void Storage: no response yet -- asking the server again', 1, 0.8, 0)
	return true
end

-- Give up on this open: no window of ours, and the native's stays suppressed.
-- What is left is a message and a vault session that has to be closed properly.
--
-- Closing it is not tidiness, it is the difference between one click and two.
-- extBank.lua's toggle button and both its slash commands branch on its own
-- isOpen upvalue -- `if isOpen then ExtBank_Close() else ExtBank_Open() end` --
-- which is still true here, and the only thing that ever tells it otherwise is a
-- real ExtBank_Close(). Normally components/frame.lua's OnHide makes that call
-- when our window closes; on this path there is no window and never was, so
-- nothing would. The player's next click on Void Storage would take the
-- ExtBank_Close() branch and read as a dead button, and only the click after it
-- would retry -- exactly the "click Void Storage twice to reopen it" bug
-- frame.lua's own header documents, reinstated by the give-up. Calling it here is
-- what keeps the advice in the message below honest.
--
-- It also runs extBank.lua's own ExtBankSetActive(0), which matters away from a
-- banker: there is no BANKFRAME_CLOSED coming to clean up after us there, and the
-- DLL's native-bank deposit suppression would otherwise stay armed with no vault
-- to deposit into.
--
-- Safe to call unconditionally, and non-recursive: core/nativeHooks.lua's wrapper
-- on the global sets closingFromNative for the duration, and OnNativeClose does
-- not call back into ExtBank_Close.
--
-- DEFAULT_CHAT_FRAME rather than UIErrorsFrame, unlike the retry line above: this
-- is the one message in the sequence the player needs to still be able to read a
-- few seconds later, which is the same reason core/deposit.lua's stuck-item
-- warning prints there. Same shape as it, too -- red prefix, one |cffffd200Fix:|r
-- clause -- so the two read as one voice rather than two addons.
function ExtBank:GiveUpOnFirstShow()
	if type(_G.ExtBank_Close) == 'function' then
		_G.ExtBank_Close()
	end

	DEFAULT_CHAT_FRAME:AddMessage('|cffff5555Void Storage:|r the server did not answer -- no window was opened, rather than an empty one. |cffffd200Fix:|r click Void Storage again to retry.')
end


--[[ Actions (thin wrappers over the native calls) ]]--
-- No mechanic is reimplemented here -- these just call the same natives
-- extBank.lua itself uses, with the same addressing convention.
--
-- ExtBankOpen is deliberately not among them: opening is never something we
-- initiate, only something we react to, and the native has already sent the
-- request by the time our hook runs (see OnNativeOpen above) -- so a wrapper here
-- would only ever be a way to double-send it. RequestSnapshot above is the single
-- exception, and it stays up there with the wait rather than moving down into
-- this group, because it is not an action any part of the UI can reach: it
-- re-asks a question the native already asked on this same open and never got an
-- answer to, once, from the timeout path only.

-- Every one of these returns whether the request actually went out, and callers
-- are expected to check.
--
-- They used to return nothing and swallow a missing native silently, which made
-- this the one path in the addon that failed mute -- and the failure was worse
-- than mute. components/item.lua ran ClearCursor() and dropped cursorSrc on the
-- strength of the call having "worked", components/bag.lua did the same for a bag
-- equip, and core/deposit.lua spent an arm and claimed a destination cell. So the
-- item snapped back into the bag with no message and no way to tell it from a
-- server refusal, and the correction that would have retried was already gone.
-- Everywhere else this addon explains a refusal (core/cursor.lua's three messages,
-- item.lua's occupied-cell one); the mirrored original does too, printing
-- "client (ebonhold.dll) not loaded." from its own CanSend and returning false so
-- its callers stop.
--
-- Worth knowing why the global is re-read on every call rather than cached: the
-- DLL re-registers ExtBankMove as a fresh function object on every packet, so a
-- cached reference goes stale within ~100ms of the window opening. See
-- docs/non-issues.md §10 -- that is measured, not defensive.
local function ReportNoClient()
	UIErrorsFrame:AddMessage('Void Storage: the ProjectEbonhold client is not responding -- nothing was moved', 1, 0.3, 0.3)
end

function ExtBank:Unlock()
	if type(_G.ExtBankUnlock) ~= 'function' then
		ReportNoClient()
		return false
	end

	_G.ExtBankUnlock()
	return true
end

function ExtBank:Move(srcBag, srcSlot, dstBag, dstSlot, count)
	if type(_G.ExtBankMove) ~= 'function' then
		ReportNoClient()
		return false
	end

	_G.ExtBankMove(srcBag, srcSlot, dstBag, dstSlot, count or 0)
	return true
end

function ExtBank:WithdrawToInventory(bagIndex, slot)
	return self:Move(self.CONTENT_BASE + bagIndex, slot, self.AUTO_INV, 0)
end

function ExtBank:UnequipBag(bagIndex)
	return self:Move(self.HDR_BAG, bagIndex, self.AUTO_INV, 0)
end

-- Targeted variants used by drag & drop onto a specific slot/cell, as
-- opposed to the "first free slot anywhere" wrappers above.
--
-- Every one of these needs its destination to be EMPTY. The server rejects a
-- move into an occupied cell outright -- it does not swap, and it does not merge
-- two stacks of the same item. It answers with a UI error and sends no
-- SMSG_EXTBANK_UPDATE at all, so nothing here ever hears about it and the
-- interaction just appears to have worked. Probed against the live server with
-- all three shapes (partial stack, whole stack of the same item, a different
-- item), and all three were refused identically.
--
-- components/item.lua is where that is caught, before the packet goes out --
-- it is the caller that knows what the target cell holds.

function ExtBank:EquipBagToSlot(bag, slot, bagIndex)
	return self:Move(bag, slot, self.HDR_BAG, bagIndex)
end

-- `count` is the number of items to move, nil/0 meaning the whole stack. The
-- server honours it (probed -- see core/cursor.lua's GetVerifiedCursorSource),
-- and only the split-drag path passes one; every other caller omits it and
-- keeps sending the sentinel.
function ExtBank:DepositToSlot(bag, slot, bagIndex, cellSlot, count)
	return self:Move(bag, slot, self.CONTENT_BASE + bagIndex, cellSlot, count)
end

function ExtBank:MoveWithinVault(srcBagIndex, srcSlot, dstBagIndex, dstSlot)
	return self:Move(self.CONTENT_BASE + srcBagIndex, srcSlot, self.CONTENT_BASE + dstBagIndex, dstSlot)
end
