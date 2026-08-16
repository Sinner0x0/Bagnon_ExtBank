--[[
	deposit.lua
		Everything that hangs off a right-click on an item in the player's
		REAL bags while the vault is open.

		One hooksecurefunc on UseContainerItem (HookInventoryDepositWatch, at
		the bottom) arms both halves of this file:
		  - the page-aware correction, which relocates a deposit that landed
		    on some other page onto the one the player is actually looking at
		  - the stuck-item warning, which explains the orphaned client-side
		    lock left behind when the server refuses the deposit

		Both halves need a delay -- one waits for the server's answer, the
		other looks at the aftermath -- which is the only reason this module
		mixes in AceTimer-3.0 at all (see main.lua's NewModule call). 3.3.5
		has no C_Timer; AceTimer is embedded and loaded by core Bagnon's own
		embeds.xml, so it's already present by the time this file runs.
--]]

local Bagnon = LibStub('AceAddon-3.0'):GetAddon('Bagnon')
local ExtBank = Bagnon.ExtBank


--[[ Right-click deposit, scoped to the currently-displayed page ]]--
-- extBank.lua's own right-click deposit is itself a hooksecurefunc
-- post-hook on ContainerFrameItemButton_OnClick -- fires after the real
-- click already ran, no OnClick replacement, no taint -- that fires off
-- ExtBankMove(bag, slot, 0xFF, 0) -- 0xFF meaning "first free slot" -- and
-- never checks where it landed. An EARLIER version of this addon tried to
-- do better by overriding OnClick outright on core's own Bagnon.ItemSlot
-- class -- which, for the player's own real bag/bank windows, is under
-- default settings literally the same live Blizzard globals
-- (ContainerFrame1Item1 etc, see ItemSlot:GetBlizzardItemSlot in
-- Bagnon/components/item.lua) the stock UI itself uses. Replacing THEIR
-- OnClick with an addon-authored closure taints those buttons outright --
-- not just for our own redirect logic, for EVERY click on them, forever --
-- which is exactly what broke plain right-click "use" and shift-click
-- "split stack" everywhere, not just near the vault. Never do that again.
--
-- This version hooks the same safe way extBank.lua itself does
-- (hooksecurefunc, never touching any button's OnClick), but can't have
-- two independent hooks racing to send two different ExtBankMove
-- destinations for the same click -- whichever request the server
-- processes first wins, and there's no way to cancel or reorder a sibling
-- hooksecurefunc listener. So this only *observes* at click time (snapshot
-- which cells are occupied beforehand), then -- once ParsePacket confirms
-- the server's own response -- issues a SEPARATE, already-existing,
-- already-safe action (MoveWithinVault, an ExtBankMove call of our own,
-- not a Blizzard-protected function) to relocate the item onto the current
-- page, if there's room.

ExtBank.pendingDeposit = nil -- { snapshot, at } of an in-flight real-inventory deposit, or nil

-- How long an armed snapshot stays worth acting on. The correction answers
-- one specific click, so it's only meaningful while the server's response to
-- THAT click is still outstanding -- a round trip, not minutes. Past this the
-- snapshot describes a vault state that has since moved on, and diffing
-- against it would credit whatever changed next to a click that's long over.
local DEPOSIT_RESPONSE_WINDOW = 3 -- seconds

function ExtBank:ClearPendingDeposit()
	self.pendingDeposit = nil
end

-- bagIndex -> {slot=true, ...} for every occupied vault cell right now.
local function SnapshotOccupiedCells()
	local snap = {}
	for bagIndex, cellsForBag in pairs(ExtBank.cells) do
		local occupied = {}
		for slot in pairs(cellsForBag) do
			occupied[slot] = true
		end
		snap[bagIndex] = occupied
	end
	return snap
end

-- The first cell that's occupied now but wasn't in an earlier snapshot --
-- i.e. wherever a just-completed deposit actually landed.
local function FindNewlyFilledCell(before)
	for bagIndex, cellsForBag in pairs(ExtBank.cells) do
		local beforeForBag = before[bagIndex]
		for slot in pairs(cellsForBag) do
			if not (beforeForBag and beforeForBag[slot]) then
				return bagIndex, slot
			end
		end
	end
end

function ExtBank:IsBagOnCurrentPage(bagIndex)
	local itemFrame = self.window and self.window:GetItemFrame()
	if not itemFrame then return false end

	for _, b in itemFrame:GetVisibleBags() do
		if b == bagIndex then return true end
	end
	return false
end

-- The slice of ExtBank.cells that GetVisibleBags (this frame's current
-- page) actually covers, first cell with no item in it. nil if every bag
-- on the current page is completely full (or the window/page isn't known
-- yet, e.g. nothing's ever been shown this session).
function ExtBank:GetCurrentPageFreeSlot()
	local itemFrame = self.window and self.window:GetItemFrame()
	if not itemFrame then return nil end

	for _, bagIndex in itemFrame:GetVisibleBags() do
		local size = (self.bags[bagIndex] and self.bags[bagIndex].size) or 0
		local cells = self.cells[bagIndex]

		for slot = 0, size - 1 do
			if not (cells and cells[slot]) then
				return bagIndex, slot
			end
		end
	end
end

-- Called from ParsePacket (core/model.lua) once the model's caught up with
-- whatever the server just did in response to a deposit
-- HookInventoryDepositWatch below saw coming. A no-op most of the time:
-- nothing pending (no matching click since the last update), the click didn't
-- actually result in a deposit (e.g. the item wasn't vault-eligible), or it
-- already landed on the current page on its own.
function ExtBank:CorrectPendingDeposit()
	local pending = self.pendingDeposit
	self:ClearPendingDeposit()
	if not pending then return end

	-- Not every armed click results in a deposit, and one that doesn't is
	-- never answered -- so without this the arm sits here indefinitely and
	-- gets spent on whatever unrelated update happens to arrive next. Two
	-- ways that happens: UseContainerItem reaches us but not the native
	-- deposit (it hooks ContainerFrameItemButton_OnClick, we hook the API, so
	-- a /run or another addon's call arms only ours), and right-clicks the
	-- server rejects outright (vault full, no bag equipped, empty source
	-- slot, a container that still has items in it). Bounding the lifetime
	-- covers all of them without the client having to tell them apart --
	-- which it can't, since a rejection looks exactly like silence.
	if GetTime() - pending.at > DEPOSIT_RESPONSE_WINDOW then return end

	local landedBag, landedSlot = FindNewlyFilledCell(pending.snapshot)
	if not landedBag or self:IsBagOnCurrentPage(landedBag) then
		return -- nothing landed, or it's already where the player's looking
	end

	local dstBag, dstSlot = self:GetCurrentPageFreeSlot()
	if dstBag then
		self:MoveWithinVault(landedBag, landedSlot, dstBag, dstSlot)
	else
		UIErrorsFrame:AddMessage('Void Storage: current page is full -- item stored on another page', 1, 0.8, 0)
	end
end


--[[ Stuck-item warning ]]--
-- A right-click deposit the server refuses doesn't just fail quietly: it
-- leaves the item permanently greyed out in the player's bags and completely
-- untouchable -- it can't be picked up, used, sold or moved. Confirmed
-- in-game, including that it won't respond to a mouse drag at all, so this is
-- a genuinely stuck item and not just a cosmetic tint.
--
-- Why it happens, in order:
--   1. Blizzard's own ContainerFrameItemButton_OnClick runs first and calls
--      UseContainerItem. With a banker session live (the only state the vault
--      can be open in -- extBank.lua closes on BANKFRAME_CLOSED) the client
--      reads that as a bank deposit: it flags the item locked and sends
--      CMSG_AUTOSTORE_BANK_ITEM.
--   2. ebonhold.dll swallows that packet on the wire -- see extbank_client.h,
--      ExtBank_ShouldDropSend / Detour_NetSend -- so the item never lands in
--      the REAL bank. Its own comment explains why it has to: extBank.lua's
--      deposit is a hooksecurefunc post-hook, which runs too late to cancel
--      Blizzard's native deposit, so it's killed at the socket instead.
--   3. Because the packet never reaches the server, nothing ever answers it,
--      and the client's optimistic lock is never released.
--   4. Separately, extBank.lua's post-hook fires its own ExtBankMove, which
--      the server DOES receive and refuse ("No free slot accepts that item"),
--      leaving the item sitting in the bag -- still locked.
--
-- So the lock is orphaned client state. Nothing in Lua can release it: it
-- lives in the client's own item data, not the UI, which is also why
-- GetContainerItemInfo reports it and why /reload does NOT clear it -- a
-- reload restarts the Lua VM but never re-requests item data. Only a full
-- relog does, since that rebuilds every item from the server.
--
-- But releasing the lock is not the only way out, and this is what the
-- warning message tells the player to do first: make the vault able to accept
-- the item (equip a bag, or free a slot) and right-click it AGAIN. The lock
-- is still never released -- it just stops mattering, because extBank.lua's
-- post-hook fires a second ExtBankMove, the server accepts this one, and the
-- item is removed from the bag server-side. An empty slot has nothing left to
-- keep locked. Note the item ends up in the VAULT, not restored in place.
--
-- Verified dead ends, so they don't get re-tried later: ExtBankMove'ing the
-- item onto its own slot, and ExtBankMove'ing it to the first free live
-- inventory slot (dstBag 0xFE), both leave it greyed -- consistent with the
-- above, since neither one actually gets the item out of the bag. Preventing
-- the lock in the first place would mean stopping UseContainerItem from
-- running at all, i.e. replacing a Blizzard API global -- out of scope.
--
-- What's left is to make sure the player understands what happened rather
-- than being left with a dead item and no explanation.

-- How long after the click to look. Long enough that a deposit which WORKED
-- has already emptied the slot (a refusal and a success are indistinguishable
-- at click time -- both are silence from our side), short enough that the
-- message still reads as feedback for the click that caused it.
local STUCK_CHECK_DELAY = 2 -- seconds

-- How long to wait before looking a second time, when the first look found
-- the player carrying the item (see the cursor guard below). Only needs to
-- outlast the drop, not another server round trip.
local STUCK_RECHECK_DELAY = 1 -- seconds

-- Scheduled STUCK_CHECK_DELAY after every deposit click. Deliberately checks
-- the SYMPTOM rather than predicting it from "the vault had no room": that
-- catches every reason the server refuses (no bag equipped, vault full, an
-- item it won't take, a container that still has items in it) without this
-- file having to keep its own copy of the server's rules.
function ExtBank:CheckDepositStuck(bag, slot, link, rechecked)
	if not link then return end

	-- The deposit went through -- the slot is empty now, or the bags have been
	-- rearranged since and it holds something else. Nothing stuck either way.
	if GetContainerItemLink(bag, slot) ~= link then return end

	-- Still sitting there AND still flagged locked. A deposit that failed
	-- without orphaning a lock would leave the item here unlocked and
	-- perfectly usable, which needs no warning.
	if not select(3, GetContainerItemInfo(bag, slot)) then return end

	-- An item the player is merely HOLDING looks identical to a stuck one at
	-- this point: 3.3.5 leaves a picked-up item in its slot, flagged locked,
	-- until the move completes -- the same behavior GetVerifiedCursorSource
	-- (core/cursor.lua) relies on. So "locked" can't tell a carried item from
	-- an orphaned lock; cursorSrc can, because the PickupContainerItem hook
	-- records which slot the held item came out of.
	--
	-- Looked at once more rather than dropped, because the ambiguity is
	-- temporary in one direction only: a genuinely stuck item is still stuck a
	-- second later, while a carried one has almost always been put down by
	-- then. Once, not in a loop -- a player who parks an item on the cursor
	-- and walks away shouldn't leave a timer rearming itself forever, and
	-- unlike the deposit lock, "still carrying it" is a state they can see.
	local src = self.cursorSrc
	if CursorHasItem() and src and src.bag == bag and src.slot == slot then
		if not rechecked then
			self:ScheduleTimer('CheckDepositStuck', STUCK_RECHECK_DELAY, bag, slot, link, true)
		end
		return
	end

	self:ReportStuckItem(link)
end

-- One message, printed in full every time a stuck item is found. Not
-- de-duplicated: each message answers one right-click the player just made,
-- so a repeat is feedback for a repeated action rather than spam. The two
-- recovery routes are the whole point of the message -- the opening clause
-- only says something went wrong -- so withholding them from a player who is
-- evidently still stuck would be backwards.
--
-- Nothing here remembers which items it has already reported, deliberately.
-- A per-item key would have to be keyed on something (bag, slot, link) that
-- an unrelated item can legitimately come to occupy later, which turns one
-- wrong report into permanent silence for the next real one -- a worse
-- failure than saying it twice.
--
-- Sent as a single AddMessage rather than three so it lands as one block in
-- the chat frame -- three calls could be split apart by whatever else is
-- printing at that moment (loot, combat spam), which is how a warning ends up
-- read as three unrelated fragments.
function ExtBank:ReportStuckItem(link)
	-- "Make room in the vault" rather than "equip a bag", because that is the
	-- actual precondition -- the re-click works whenever the vault can accept
	-- the item, and a player stuck because it was FULL needs to free a slot,
	-- not add a bag. Equipping is parenthesised as the common case only.
	--
	-- The re-click fix doubles as the prevention advice (it is the same action
	-- either way), which is why no separate "to avoid this next time" half is
	-- needed -- that collapse is most of what keeps this short.
	DEFAULT_CHAT_FRAME:AddMessage(("|cffff5555Void Storage:|r %s is stuck -- it can't be used, moved or sold. |cffffd200Fix:|r make room in the vault (equip a bag in the strip above), then right-click it again. |cffffd200Or:|r log out and back in -- /reload won't work."):format(link))
end

-- UseContainerItem is a plain stock Blizzard global, always present --
-- unlike core/nativeHooks.lua's own targets (_G.ExtBankOpen/etc, which only
-- exist once ebonhold.dll's natives have loaded), this needs no
-- PLAYER_LOGIN/load-order gating and can hook immediately from OnEnable.
local depositWatchHooked = false

function ExtBank:HookInventoryDepositWatch()
	if depositWatchHooked then return end

	hooksecurefunc('UseContainerItem', function(bag, slot)
		if not (bag and bag >= 0 and bag <= 4) then return end -- not real live-inventory (bank, keyring, ...)
		if not Bagnon.FrameSettings:Get('extbank'):IsShown() then return end
		ExtBank.pendingDeposit = { snapshot = SnapshotOccupiedCells(), at = GetTime() }

		-- Read the link HERE, not in the check itself: by then the slot may be
		-- empty (deposit worked) or hold something else, and the check needs to
		-- know what was actually clicked to tell those apart. A locked item is
		-- still fully readable in its slot, so this works for the stuck case too.
		ExtBank:ScheduleTimer('CheckDepositStuck', STUCK_CHECK_DELAY, bag, slot, GetContainerItemLink(bag, slot))
	end)

	depositWatchHooked = true
end
