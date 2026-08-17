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
function ExtBank:ClearPick()
	self.pickSrc = nil
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

-- cursorSrc is only ever WRITTEN by the hook above, so what it really holds is
-- "where the last item picked up OUT OF A CONTAINER came from" -- which is not
-- the same thing as "where the item on the cursor right now came from".
-- Nothing erases it when the cursor is emptied by another route (ClearCursor,
-- equipping, mailing, trading), and nothing corrects it when the cursor is
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
-- Returns the verified source, or nil having told the player why not. The
-- first two messages mirror the ones extBank.lua's own DropIntoCell gives,
-- so a refused drop explains itself instead of silently bouncing the item
-- back.
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
