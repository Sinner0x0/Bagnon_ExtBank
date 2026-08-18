--[[
	cursor.lua
		Knowing where the thing being carried came from.

		ExtBankMove takes its source coordinates up front, so unlike a stock
		container move our own drop targets (components/item.lua's cells,
		components/bag.lua's bag-slot strip) have to name the source
		themselves at drop time. This file is what lets them.
--]]

local Bagnon = LibStub('AceAddon-3.0'):GetAddon('Bagnon')
local ExtBank = Bagnon.ExtBank


--[[ Cursor-source tracking ]]--
-- WoW 3.3.5 gives no API to read which bag/slot the item on the cursor came
-- from. Stock container moves don't need that -- the client remembers the
-- picked-up item internally, and Lua only ever supplies the *destination*.
-- ExtBankMove isn't like that: it's one call carrying both source and
-- destination up front, so our own item slots need to know the source of
-- whatever's on the cursor at drop time. The native UI solves this with a
-- secure post-hook on PickupContainerItem, and does so with its own
-- separate hook (hooksecurefunc allows any number of independent listeners
-- on the same function, unlike the bare-global functions in
-- core/nativeHooks.lua) -- so this is safe to add alongside it rather than
-- instead of it.
ExtBank.cursorSrc = nil  -- { bag, slot } of the real-inventory item on the cursor, or nil

-- Virtual pick for moves that start *inside* the vault: bag 20+ isn't a
-- real container ID the client API recognizes, so there's no equivalent of
-- PickupContainerItem to hook for that case -- our own item slots set this
-- directly when clicked/dragged instead (see components/item.lua).
ExtBank.pickSrc = nil  -- { bagIndex, slot } picked from within the vault, or nil

-- A pick deliberately puts nothing on the real cursor (bag 20+ isn't a
-- container the client API knows about), so there's no visual cue at all that
-- one is outstanding -- which makes a leftover pick actively dangerous rather
-- than merely untidy: the next left-click on any cell hits DropCarriedItem's
-- `elseif ExtBank.pickSrc` branch first and silently completes the OLD move
-- onto the just-clicked cell, instead of picking up what was clicked. So it
-- must not survive the window closing. extBank.lua clears exactly this in its
-- own ExtBank_Close -- but that clears `_G.ExtBank.pickSrc`, a completely
-- separate table from this module's (that global carries only the native UI's
-- own drag state), so hooking ExtBank_Close does NOT carry the clear over to
-- us. Called from components/frame.lua's OnHide, the one funnel every close
-- path already runs through.
-- The only two writers of pickSrc, so that "a pick was armed or spent" is a single
-- observable event rather than four scattered assignments. Both announce it on
-- Bagnon.Callbacks; components/itemFrame.lua listens and repaints, which is what
-- gives the pick the visual cue the comment above says it lacks.
--
-- EXTBANK_PICK_CHANGED deliberately carries no frameID: like the model itself
-- there is exactly one vault and one outstanding pick at a time.
function ExtBank:SetPick(bagIndex, slot)
	self.pickSrc = { bagIndex = bagIndex, slot = slot }
	Bagnon.Callbacks:SendMessage('EXTBANK_PICK_CHANGED')
end

-- Early return rather than an unconditional nil-and-broadcast: this is called on
-- every drop path, both DropCarriedItem branches, OnDragStop and Frame:OnHide, and
-- most of those calls have nothing to clear. Without the guard each one would send
-- a message that walks every cell on the page to repaint nothing.
function ExtBank:ClearPick()
	if not self.pickSrc then return end

	self.pickSrc = nil
	Bagnon.Callbacks:SendMessage('EXTBANK_PICK_CHANGED')
end

local cursorHooked = false

function ExtBank:HookCursorTracking()
	if cursorHooked then return end

	hooksecurefunc('PickupContainerItem', function(bag, slot)
		if CursorHasItem() then
			ExtBank.cursorSrc = { bag = bag, slot = slot }  -- no count: the whole stack
		else
			ExtBank.cursorSrc = nil  -- this call put the item back down
		end
	end)

	-- The shift-drag split, which the comment below already named as a way the
	-- cursor gets loaded behind this file's back. Recording `count` is what
	-- makes a partial deposit possible at all: it is the only place the carried
	-- amount is observable, and it rides on cursorSrc all the way to the
	-- ExtBankMove call. Absent for a whole-stack pickup, which is what keeps
	-- that case sending the 0 ("everything") sentinel.
	hooksecurefunc('SplitContainerItem', function(bag, slot, count)
		if CursorHasItem() then
			ExtBank.cursorSrc = { bag = bag, slot = slot, count = count }
		else
			ExtBank.cursorSrc = nil
		end
	end)

	cursorHooked = true
end

-- Letting go of a real carried item: put it down, then forget where it came from.
--
-- The two statements have to travel together, and the field cannot be left to the
-- hooks above to clear -- ClearCursor() is not PickupContainerItem and fires no hook
-- of ours at all, so a bare ClearCursor() leaves the coordinates behind, still
-- naming a slot the player is no longer carrying anything out of. That is precisely
-- the stale memory the long note below exists to survive, and a drop path should not
-- be creating it on its way out.
--
-- Which makes this and the hooks above the only writers of cursorSrc, the same
-- property SetPick/ClearPick give pickSrc: "the carried item was recorded or
-- released" is one observable event rather than an assignment copied into every drop
-- path. Both paths that release a verified cursor call this -- the content cells'
-- deposit (components/item.lua) and the bag strip's equip (components/bag.lua) --
-- and neither touches the field itself.
--
-- No broadcast on the way out, unlike ClearPick: a real carried item is visible on
-- the cursor, so nothing has to be repainted for the player to see it is gone.
function ExtBank:ReleaseCursor()
	ClearCursor()
	self.cursorSrc = nil
end

-- Which containers the server accepts as a MOVE source: 0 = backpack,
-- 1..4 = equipped bags. Confirmed by probing the live server rather than
-- assumed from extBank.lua's own choice of the same range -- ExtBankMove sent
-- with a bank-bag source (bag 5, an item confirmed present in that slot) and
-- with an equipment source (bag 255 slot 15/16, the internal main-hand
-- positions) both moved nothing at all. So gear can't be dragged straight in
-- and bank contents can't be deposited directly; both have to go through the
-- player's bags first.
local function IsAcceptedSource(bag)
	return bag >= 0 and bag <= 4
end

-- cursorSrc is only ever WRITTEN by the two hooks above and by ReleaseCursor, so
-- what it really holds is "where the last item picked up OUT OF A CONTAINER came
-- from" -- which is not the same thing as "where the item on the cursor right now
-- came from". Nothing erases it when the cursor is emptied by any route this file
-- does not own (equipping, mailing, trading, a bare ClearCursor somewhere else in
-- the UI), and nothing corrects it when the cursor is
-- LOADED by another route -- PickupInventoryItem when you drag gear off the
-- character pane, SplitContainerItem on a shift-drag, PickupMerchantItem at a
-- vendor. Either way the remembered coordinates can end up naming a completely
-- different item than the one being carried, and because ExtBankMove takes its
-- source up front, acting on that stale memory deposits the WRONG item while
-- ClearCursor drops the real one back where it came from. Confirmed in-game:
-- pick an item up out of a bag, ClearCursor (which leaves the coordinates
-- behind), then drag a weapon off the character pane onto a cell -- the bag
-- item is what lands in the vault.
--
-- Rather than chase every pickup API with a hook of its own (there is no
-- complete list, and any one missed reopens the hole), verify at drop time:
-- whatever is on the cursor has to still be what the remembered slot reports.
-- Also confirmed in-game: a picked-up item stays readable in its container
-- slot -- flagged locked, not removed -- until the move actually completes, so
-- the legitimate case still matches. Two identical items can of course match
-- each other, but then either one is an equally valid thing to deposit.
--
-- The silent half of the check below: "is the item on the cursor right now really
-- the one those remembered coordinates name?", with no player-facing message and
-- no accepted-source range test.
--
-- Separate from GetVerifiedCursorSource because the two answer for different
-- callers. That one is answering a DROP the player just made, so each way of
-- failing earns its own explanation. This one is answering "is the player merely
-- holding this?" while deciding whether to warn about a stuck item
-- (core/deposit.lua's CheckDepositStuck) -- nobody asked it a question, so a
-- refusal there must say nothing at all.
function ExtBank:GetCarriedInventorySource()
	local src = self.cursorSrc
	if not src or not CursorHasItem() then return nil end

	local cursorType, _, cursorLink = GetCursorInfo()
	if cursorType ~= 'item' or not cursorLink then return nil end
	if cursorLink ~= GetContainerItemLink(src.bag, src.slot) then return nil end

	return src
end

-- Returns the verified source, or nil having told the player why not. The
-- first two messages mirror the ones extBank.lua's own DropIntoCell gives,
-- so a refused drop explains itself instead of silently bouncing the item
-- back. Staged rather than delegating to GetCarriedInventorySource above,
-- because which stage fails is exactly what picks the message.
function ExtBank:GetVerifiedCursorSource()
	local src = self.cursorSrc

	if not src then
		UIErrorsFrame:AddMessage("Void Storage: held item's source unknown -- pick it up from your bags to deposit it", 1, 0.3, 0.3)
		return nil
	end

	if not IsAcceptedSource(src.bag) then
		UIErrorsFrame:AddMessage('Void Storage: items can only be deposited from your bags -- move it to your inventory first', 1, 0.3, 0.3)
		return nil
	end

	local cursorType, _, cursorLink = GetCursorInfo()
	if cursorType ~= 'item' or not cursorLink or cursorLink ~= GetContainerItemLink(src.bag, src.slot) then
		UIErrorsFrame:AddMessage("Void Storage: can't tell where that item came from -- pick it up from your bags to deposit it", 1, 0.3, 0.3)
		return nil
	end

	-- No partial-stack check here, and that is a deliberate reversal of what this
	-- function used to do.
	--
	-- A split is invisible to the link check above: a shift-drag leaves the
	-- REMAINDER in the source slot reporting a byte-identical link, so "what's on
	-- the cursor still matches what that slot says" is true even while the player
	-- carries 5 of an 18-stack. This used to refuse that drop outright, because
	-- callers reached ExtBank:Move without a count, which sends
	-- ExtBankMove(..., 0) -- and 0 means the whole stack, so asking to deposit 5
	-- silently moved all 18.
	--
	-- The refusal was a placeholder for a fact nobody had: whether the server
	-- honours a non-zero count. Nothing in the shipped game ever sends one (all
	-- seven of extBank.lua's move wrappers hardcode 0), so it could only be
	-- settled by sending one. It was, against the live server, to the same
	-- standard as the accepted source-bag range above:
	--
	--   SPLIT SplitContainerItem(0, 2, 5)         -- 5 taken off an 18 stack
	--   MOVE  src= player bag 0 slot 2  dst= extbag 0 slot 13  count=5
	--   PKT   NEW extbag 0 slot 13  47556 (Crusader Orb) x5    -- 13 left in the bag
	--
	-- Count is honoured exactly. So the count now travels with the source
	-- (components/item.lua passes it to DepositToSlot) and partial deposits work.
	-- `count` stays nil for a whole-stack pickup, which keeps every other caller
	-- sending the 0 sentinel unchanged.
	return src
end
