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

-- AceTimer-3.0 is here for core/deposit.lua's two delayed checks -- 3.3.5 has
-- no C_Timer. It's embedded and loaded by core Bagnon's own embeds.xml, so
-- it's already present by the time this file runs; nothing extra to vendor or
-- declare in the .toc.
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
ExtBank.VERSION = '1.0.1'
ExtBank.DATE    = '17-08-2026'


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

	-- Safe to hook immediately, no PLAYER_LOGIN gating -- see the comment
	-- above it in core/deposit.lua.
	self:HookInventoryDepositWatch()

	-- The ProjectEbonhold-owned globals are the opposite case and have to
	-- wait for load order to settle -- see core/nativeHooks.lua.
	self:RegisterEvent('PLAYER_LOGIN', 'HookNativeGlobals')

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
function ExtBank:OnNativeOpen()
	self:HookCursorTracking()
	self:HideNativeWindow()

	if self.hasModel then
		self:ShowWindow()
	else
		self:ShowWindowOnceModelReady()
	end
end

function ExtBank:OnNativeClose()
	self:CancelPendingShow()
	Bagnon.FrameSettings:Get(self.FRAME_ID):Hide()
end

function ExtBank:ShowWindow()
	Bagnon.FrameSettings:Get(self.FRAME_ID):Show()
end

local waitingForModel = false

function ExtBank:ShowWindowOnceModelReady()
	if waitingForModel then return end
	waitingForModel = true
	Bagnon.Callbacks:Listen(self, 'EXTBANK_MODEL_UPDATED', 'OnModelReadyForFirstShow')
end

-- Also called from OnNativeClose -- covers closing again before any
-- response ever arrived, so a snapshot that lands after the player already
-- left doesn't pop the window open on them unasked.
function ExtBank:CancelPendingShow()
	if waitingForModel then
		waitingForModel = false
		Bagnon.Callbacks:Ignore(self, 'EXTBANK_MODEL_UPDATED')
	end
end

function ExtBank:OnModelReadyForFirstShow()
	self:CancelPendingShow()
	self:ShowWindow()
end


--[[ Actions (thin wrappers over the native calls) ]]--
-- No mechanic is reimplemented here -- these just call the same natives
-- extBank.lua itself uses, with the same addressing convention. There's
-- deliberately no ExtBankOpen wrapper: opening is never something we
-- initiate, only something we react to, and the native has already sent the
-- request by the time our hook runs (see OnNativeOpen above) -- so a wrapper
-- here would only ever be a way to double-send it.

function ExtBank:Unlock()
	if type(_G.ExtBankUnlock) == 'function' then
		_G.ExtBankUnlock()
	end
end

function ExtBank:Move(srcBag, srcSlot, dstBag, dstSlot, count)
	if type(_G.ExtBankMove) == 'function' then
		_G.ExtBankMove(srcBag, srcSlot, dstBag, dstSlot, count or 0)
	end
end

function ExtBank:WithdrawToInventory(bagIndex, slot)
	self:Move(self.CONTENT_BASE + bagIndex, slot, self.AUTO_INV, 0)
end

function ExtBank:UnequipBag(bagIndex)
	self:Move(self.HDR_BAG, bagIndex, self.AUTO_INV, 0)
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
	self:Move(bag, slot, self.HDR_BAG, bagIndex)
end

-- `count` is the number of items to move, nil/0 meaning the whole stack. The
-- server honours it (probed -- see core/cursor.lua's GetVerifiedCursorSource),
-- and only the split-drag path passes one; every other caller omits it and
-- keeps sending the sentinel.
function ExtBank:DepositToSlot(bag, slot, bagIndex, cellSlot, count)
	self:Move(bag, slot, self.CONTENT_BASE + bagIndex, cellSlot, count)
end

function ExtBank:MoveWithinVault(srcBagIndex, srcSlot, dstBagIndex, dstSlot)
	self:Move(self.CONTENT_BASE + srcBagIndex, srcSlot, self.CONTENT_BASE + dstBagIndex, dstSlot)
end
