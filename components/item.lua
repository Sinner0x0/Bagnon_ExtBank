--[[
	item.lua
		An item cell button for one slot inside one equipped ExtBank bag
--]]

local Bagnon = LibStub('AceAddon-3.0'):GetAddon('Bagnon')
local ExtBank = Bagnon.ExtBank
local ItemSlot = Bagnon.Classy:New('Button')
ItemSlot:Hide()
Bagnon.ExtBankItemSlot = ItemSlot

local ItemSearch = LibStub('LibItemSearch-1.0')


--[[ Constructor ]]--

function ItemSlot:New(bagIndex, slot, frameID, parent)
	local item = self:Restore() or self:Create()
	item:SetParent(parent)
	item:SetFrameID(frameID)
	item:SetSlot(bagIndex, slot)

	-- Always a real hidden -> shown transition, so OnShow always fires and
	-- always runs Update(): Create() hides on the way out, and Free() hides
	-- before pooling, so neither branch into here can hand back a visible
	-- button. The `if item:IsVisible() then item:Update() end` arm this replaces
	-- was unreachable for that reason.
	item:Show()

	return item
end

function ItemSlot:Create()
	local id = self:GetNextItemSlotID()
	-- ContainerFrameItemButtonTemplate, not the plain ItemButtonTemplate --
	-- matches both core Bagnon's own (real-bag) item slots and the native
	-- vault UI's own content-cell buttons (its bag-slot strip buttons use
	-- the plain template instead, which is what our own bag.lua matches).
	local item = self:Bind(CreateFrame('Button', 'BagnonExtBankItemSlot' .. id, nil, 'ContainerFrameItemButtonTemplate'))
	item:Hide()

	item:RegisterForClicks('anyUp')
	item:RegisterForDrag('LeftButton')

	-- Same defensive strip core Bagnon's own item slots do for this
	-- template -- it wires up default event-driven behavior (cooldown
	-- swipes, lock state, etc.) tied to a real bag/slot via OnEvent; nil-ing
	-- the script neutralizes all of it at once without needing to know
	-- which events it registered.
	item:SetScript('OnEvent', nil)
	item:SetScript('OnClick', item.OnClick)
	item:SetScript('OnDragStart', item.OnDragStart)
	item:SetScript('OnDragStop', item.OnDragStop)
	item:SetScript('OnReceiveDrag', item.OnReceiveDrag)
	item:SetScript('OnEnter', item.OnEnter)
	item:SetScript('OnLeave', item.OnLeave)
	item:SetScript('OnShow', item.OnShow)

	-- The template's OnLoad sets a raw 'UpdateTooltip' field pointing at
	-- Blizzard's own default (GetContainerItemInfo on self:GetParent():
	-- GetID()/self:GetID(), a real bag/slot -- these virtual vault cells
	-- aren't one). GameTooltip_OnUpdate polls that field every ~0.2s for as
	-- long as the tooltip's shown and re-invokes it -- clearing the script
	-- and the field here matches what native's own content cells do. Nil-ing
	-- the FIELD on the instance only holds as long as nothing of that exact
	-- name exists on the class table Classy's metatable falls back to --
	-- see RefreshTooltip below (deliberately NOT named UpdateTooltip) for
	-- why that distinction matters.
	item:SetScript('OnUpdate', nil)
	item.UpdateTooltip = nil

	-- The cue for an outstanding vault pick. Same texture and blend the bag-slot
	-- strip already uses for its own "contents shown" ring (components/bag.lua's
	-- constructor), so the two read as the same visual language. Created once and
	-- toggled by UpdatePicked; starts hidden.
	local picked = item:CreateTexture(nil, 'OVERLAY')
	picked:SetTexture([[Interface\Buttons\CheckButtonHilight]])
	picked:SetBlendMode('ADD')
	picked:SetAllPoints(item)
	picked:Hide()
	item.pickedHighlight = picked

	return item
end

function ItemSlot:Restore()
	local item = ItemSlot.unused and next(ItemSlot.unused)
	if item then
		ItemSlot.unused[item] = nil
		return item
	end
end

do
	local id = 0
	function ItemSlot:GetNextItemSlotID()
		id = id + 1
		return id
	end
end


--[[ Destructor ]]--

-- ClearAllPoints matters here in a way it doesn't for core Bagnon's otherwise
-- identical Free(): core's Layout() is synchronous, ours is deferred by a frame
-- (see itemFrame.lua's throttled updater). Pooling a button with its old
-- SetPoint intact meant a Restore()d cell was Shown and bound to its NEW
-- (bagIndex, slot) while still anchored at the PREVIOUS one's grid coordinates
-- until the next OnUpdate -- drawn on top of a live cell, already
-- mouse-enabled, so a click landing in that window acted on a cell the player
-- was not looking at.
function ItemSlot:Free()
	self:Hide()
	self:ClearAllPoints()
	self:SetParent(nil)

	-- Unlike the texture and count, the pick highlight is dropped on the way into
	-- the pool. Those two are re-resolved by Update against the new binding, so
	-- carrying them over is harmless (and is what lets the cache survive pooling);
	-- the highlight is not, because a button restored onto some other cell while
	-- still showing it would mark the wrong cell as picked until the next arm or
	-- clear happened to come along.
	if self.pickedHighlight then
		self.pickedHighlight:Hide()
	end

	ItemSlot.unused = ItemSlot.unused or {}
	ItemSlot.unused[self] = true
end


--[[ Frame Events ]]--

function ItemSlot:OnShow()
	self:Update()
	self:UpdatePicked()
end

-- Kept off Update()'s path on purpose. Update caches on the resolved item state,
-- and pick state is not item state -- folding it into that key would widen it for
-- something unrelated and make every arm and clear look like a content change.
-- Reading ExtBank.pickSrc directly instead means this is always self-consistent
-- whenever it runs, whether that is from OnShow (so a freshly built or pooled
-- button adopts the current state) or from itemFrame.lua's EXTBANK_PICK_CHANGED
-- handler.
function ItemSlot:UpdatePicked()
	local highlight = self.pickedHighlight
	if not highlight then return end

	local src = ExtBank.pickSrc
	if src and src.bagIndex == self.bagIndex and src.slot == self.slot then
		highlight:Show()
	else
		highlight:Hide()
	end
end

-- Left-click with nothing carried: picks the item up (virtually -- see
-- ExtBank.pickSrc in core/cursor.lua). Right-click or shift-click: withdraws it
-- straight to inventory, no pickup step needed.
--
-- The withdraw test comes FIRST, ahead of DropCarriedItem, and that ordering is a
-- fix rather than a tidy-up. A pick puts nothing on the real cursor, so a player
-- who left-clicked a cell a minute ago has no way to know one is still armed --
-- and DropCarriedItem running first meant their next right-click, plainly meant as
-- "withdraw this", was instead spent completing the forgotten move: the pick was
-- consumed, the occupied-cell check refused it, and they were answered with
-- "Void Storage: that slot is taken -- drop it on an empty one", describing a drop
-- they never made, while the withdrawal simply did not happen. A right-click is
-- unambiguous, so it now supersedes any outstanding pick instead of being eaten by
-- it. Confirmed as the same hazard OnDragStop's own comment describes for the drag
-- route, which was fixed there and not here.
--
-- Only LeftButton arms a pick. The button is RegisterForClicks('anyUp'), so the
-- old catch-all `else` armed one on middle-click and on mouse buttons 4 and 5 too
-- -- invisible state from a gesture nobody would associate with picking an item up.
function ItemSlot:OnClick(button)
	if button == 'RightButton' or IsShiftKeyDown() then
		ExtBank:ClearPick()

		if self:GetCellData() then
			ExtBank:WithdrawToInventory(self.bagIndex, self.slot)
		end
		return
	end

	if self:DropCarriedItem() then
		return
	end

	if button == 'LeftButton' and self:GetCellData() then
		ExtBank:SetPick(self.bagIndex, self.slot)
	end
end

-- Marks this slot as the item frame's active drag (see itemFrame.lua's own
-- SetDraggingSlot) -- confirmed necessary, not just cautious: freeing this
-- exact button (Hide() + reparent) mid-drag, which paging away from its
-- bag would otherwise do, cancels WoW's native drag outright before
-- OnDragStop below ever gets a chance to fire. See itemFrame.lua's own
-- ReloadAllItemSlots for how it stays alive (parked off-screen, not just
-- faded) without either canceling the drag or blocking clicks on whatever
-- real cell the new page renders in its old spot.
function ItemSlot:OnDragStart()
	if not self:GetCellData() then return end

	ExtBank:SetPick(self.bagIndex, self.slot)

	local itemFrame = self:GetParent()
	if itemFrame and itemFrame.SetDraggingSlot then
		itemFrame:SetDraggingSlot(self)
	end
end

-- Fires on the ORIGIN slot once the mouse button that started the drag is
-- released, regardless of what's under the cursor at that point -- the one
-- point guaranteed to run no matter how the drag ends, so it's what clears
-- the SetDraggingSlot exemption above (letting a since-paged-away origin
-- finally get Free()'d for real, via the forced reload SetDraggingSlot(nil)
-- triggers).
--
-- It's also the reliable place to actually finish an intra-vault drag:
-- OnReceiveDrag (below) is Blizzard's own "something was dropped on me"
-- handler, but it only ever fires for a REAL cursor payload
-- (CursorHasItem()/CursorHasSpell()/...) -- our own vault-to-vault pick
-- deliberately never puts one there (see main.lua's own Addressing section:
-- bag 20+ isn't a real container PickupContainerItem/CursorHasItem
-- recognize), so nothing guarantees it fires for a drag that started on
-- one of our own cells. GetMouseFocus() at drag-stop time -- whatever
-- frame is actually under the cursor right now -- sidesteps that
-- uncertainty entirely. Harmless if OnReceiveDrag also fires too: pickSrc
-- is cleared by whichever of the two gets there first, so the second call
-- is just a no-op (see DropCarriedItem below).
--
-- The self-drop guard compares pickSrc's coordinates against the target's
-- own GetSlot() rather than `target ~= self` -- functionally the same
-- while the origin stays exempted above, but this is the more direct
-- statement of what's actually being guarded against ("don't move it onto
-- the cell it already occupies"), not an assumption about which widget
-- happens to still represent that cell.
--
-- Leaving pickSrc set on that path (rather than clearing it, as the
-- can't-drop-here return above does) is deliberate: releasing over the origin
-- gives that same button the mouse-up, so OnClick follows and its own
-- DropCarriedItem spends the pick on a no-op move and clears it. Clearing
-- here instead would just let OnClick fall through and RE-ARM it. Verified
-- in-game -- pickSrc reads back clear after a drop-back-on-origin.
--
-- Reading GetMouseFocus() only AFTER SetDraggingSlot(nil) looks unsafe, since
-- that runs a full UpdateEverything and item slots are pooled and recycled
-- (see item.lua's own Free/Restore) -- a button re-bound to different
-- coordinates mid-handler would make target:GetSlot() name a cell the player
-- never dropped on, and WoW doesn't recompute mouse focus mid-frame after
-- re-anchoring. It's safe anyway, for a reason worth writing down since the
-- ordering keeps looking wrong otherwise: every other source of grid
-- invalidation (model update, bag show/hide, bags-per-page, page change)
-- already calls UpdateEverything synchronously the moment it happens, so by
-- the time this one runs the only thing left un-reconciled is the parked
-- origin slot itemFrame.lua exempted from Free() for the duration of the
-- drag. Releasing it is a pure Free(): ReloadAllItemSlots' second loop finds
-- every current-page slot already present, so AddItemSlot -- and with it
-- Restore() -- never fires, and nothing gets re-bound. The parked slot is
-- also the one button the cursor provably ISN'T over (it sits at
-- DRAG_PARK_OFFSET, far outside the viewport).
--
-- Resolving target before SetDraggingSlot(nil) wouldn't buy anything either:
-- a reload that DOES recycle buttons (a model update landing mid-drag) has
-- already run by then, well before this handler is entered. Confirmed in-game
-- by forcing exactly that -- reshuffling the whole grid under a held drag,
-- then releasing without moving the mouse -- the item lands on the cell the
-- cursor is actually over. And moving it would put the unconditional
-- un-parking behind the two early returns below, which is a real bug traded
-- for one that can't happen.
function ItemSlot:OnDragStop()
	local itemFrame = self:GetParent()
	if itemFrame and itemFrame.SetDraggingSlot then
		itemFrame:SetDraggingSlot(nil)
	end

	-- Nothing under the cursor that can take the drop: a real bag slot, the
	-- bag strip, another frame, the open world. The gesture is over, and a
	-- pick puts nothing on the real cursor, so the player has no way to tell
	-- one is still armed -- cancel it rather than leave it to complete itself
	-- on whatever cell gets clicked next. Unlike the origin-cell case below,
	-- no OnClick follows to consume it: the mouse-up landed on a different
	-- frame entirely, so this handler is the last word. Confirmed in-game --
	-- drag a vault item out onto your bags (which does nothing by itself,
	-- withdrawal being right-click only) and without this clear the next
	-- click on any cell moves the dragged item instead of doing what was
	-- asked, including a right-click meant to withdraw (DropCarriedItem runs
	-- ahead of the button check in OnClick above).
	local target = GetMouseFocus()
	if not (target and target.DropCarriedItem) then
		ExtBank:ClearPick()
		return
	end

	local src = ExtBank.pickSrc
	local dstBag, dstSlot = target:GetSlot()
	if src and src.bagIndex == dstBag and src.slot == dstSlot then
		return -- dropped back on the exact cell it was picked from
	end

	target:DropCarriedItem()
end

function ItemSlot:OnReceiveDrag()
	self:DropCarriedItem()
end

-- The server refuses any move whose destination cell is already occupied. It
-- does not swap the two items and it does not merge two stacks of the same one;
-- it answers with a UI error and sends no SMSG_EXTBANK_UPDATE, so from this
-- addon's side the move simply never happens and nothing marks it as failed.
-- Probed against the live server with all three shapes -- a partial stack onto
-- the same item, a whole stack onto the same item, and a different item
-- entirely -- and all three were refused identically.
--
-- Caught here rather than left to the server because this is where the target
-- cell's contents are known, so the answer costs nothing and arrives before the
-- gesture is over. The native UI does not do this (extBank.lua's DropIntoCell
-- calls DepositToSlot and then ClearCursor() unconditionally, whatever the cell
-- holds) -- a deliberate divergence from the mirror, and a safe one: it changes
-- only what this addon declines to send.
--
-- Returns true if the drop was refused, in which case the caller must stop.
function ItemSlot:RefuseIfOccupied()
	if not self:GetCellData() then
		return false
	end

	UIErrorsFrame:AddMessage('Void Storage: that slot is taken -- drop it on an empty one', 1, 0.3, 0.3)
	return true
end

-- Drops whatever's being carried onto this cell: a real inventory item on
-- the cursor deposits into this exact slot; a virtual pick from elsewhere
-- in the vault moves here instead. Returns true if it handled anything.
function ItemSlot:DropCarriedItem()
	if CursorHasItem() then
		-- A real carried item supersedes any virtual pick -- nobody is holding
		-- two things at once, and what came off a bag onto the cursor is
		-- plainly what this drop is about. Cleared up front rather than
		-- alongside the deposit below, so it goes on the refusal path too:
		-- either way the interaction has moved on, and a pick armed before the
		-- cursor was ever loaded must not sit through the whole deposit and
		-- then complete itself on the next cell clicked, long after the player
		-- has forgotten making it. Confirmed in-game.
		ExtBank:ClearPick()

		if self:RefuseIfOccupied() then
			return true
		end

		-- A refusal (see GetVerifiedCursorSource in core/cursor.lua -- unknown or
		-- mismatched source) deliberately leaves the item ON the cursor rather
		-- than ClearCursor()-ing it: the drop didn't happen, so the player
		-- should still be holding it and free to put it back where they want.
		-- Still returns true either way -- the drop was handled and explained,
		-- and OnClick must not fall through into starting a vault pick while
		-- something's being carried.
		local src = ExtBank:GetVerifiedCursorSource()
		if src then
			-- src.count is nil for a whole-stack pickup and the carried amount for
			-- a shift-drag split, so this sends the 0 ("everything") sentinel
			-- exactly where it always did.
			-- Only let go of the cursor if the request actually went out. If the
			-- client is not answering, DepositToSlot says so and returns false, and
			-- ClearCursor()ing anyway would drop the item back into the bag as
			-- though the deposit had been accepted.
			if ExtBank:DepositToSlot(src.bag, src.slot, self.bagIndex, self.slot, src.count) then
				ClearCursor()
				ExtBank.cursorSrc = nil
			end
		end
		return true
	elseif ExtBank.pickSrc then
		local src = ExtBank.pickSrc

		-- Spent before the occupied check, not after. Unlike the cursor above, a
		-- pick has NO visual cue (see core/cursor.lua), so leaving one armed
		-- through a refusal is the dangerous option: the player gets a message,
		-- reasonably reads it as "that didn't happen", and the next click on any
		-- cell silently completes the old move instead of picking up what was
		-- clicked. The gesture ends here either way.
		ExtBank:ClearPick()

		-- Dropped back on the cell it came from. Silent, and checked BEFORE the
		-- occupied test, which would otherwise fire on it -- the origin is
		-- occupied by definition, by the very item being carried. Nothing moved
		-- and nothing failed, so there is nothing to say; this used to send a
		-- self-to-self move to the server instead, which is what OnDragStop's
		-- own origin-cell comment above refers to.
		if src.bagIndex == self.bagIndex and src.slot == self.slot then
			return true
		end

		if self:RefuseIfOccupied() then
			return true
		end

		ExtBank:MoveWithinVault(src.bagIndex, src.slot, self.bagIndex, self.slot)
		return true
	end

	return false
end

function ItemSlot:OnEnter()
	self:AnchorTooltip()
	self:RefreshTooltip()
end

-- OnLeave, AnchorTooltip and RefreshTooltipIfOwned all come from
-- Bagnon.ExtBankWidget (components/widget.lua), shared with bag.lua. Note
-- OnLeave there is guarded on GameTooltip:IsOwned(self); the unconditional
-- Hide() this used to do could blank a tooltip another frame had already
-- taken ownership of.


--[[ Update Methods ]]--

-- Shown when the client has no cached item data for an itemId yet -- a cold
-- login, mostly. See docs/non-issues.md §5: this server does not answer bulk item
-- queries, so it is a real and unfixable-from-Lua state rather than a transient
-- one, and the icon may resolve at any point afterwards or never. Hovering the
-- cell is what resolves it when anything does -- SetTooltipItem's single-item
-- query (components/widget.lua) repaints icon and tooltip when it answers.
local UNKNOWN_ITEM_TEXTURE = [[Interface\Icons\INV_Misc_QuestionMark]]

-- ReloadAllItemSlots calls this for every already-built cell on the page -- up to
-- GetBagsPerPage() x 36, 180 by default -- on every EXTBANK_MODEL_UPDATED, while a
-- delta packet typically touches one or two cells. So all but a couple of those
-- calls were rewriting byte-identical state: a texture, a count, a search re-run
-- and a GameTooltip:IsOwned probe each. components/bag.lua's Bag:Update has cached
-- against exactly this for the strip; this is the higher-volume path.
--
-- The cache is keyed on the RESOLVED values about to be written, not on the cell's
-- own fields, and that distinction is the whole reason it is safe:
--
--   * GetItemIcon reads the client's item cache, so for one itemId it can answer
--     nil now (-> UNKNOWN_ITEM_TEXTURE) and the real path later. Keyed on itemId,
--     this would pin the question mark for the rest of the session.
--   * GetEmptyItemTexture reads a live addon-wide setting, and
--     SHOW_EMPTY_ITEM_SLOT_TEXTURE_UPDATE (components/itemFrame.lua) applies a
--     change to it by calling plain Update() on every cell -- there is nothing
--     narrower for it to call. Keyed on cell data, that handler would become a
--     no-op and the setting would silently stop taking effect until the window was
--     reopened, which is the bug it was added to fix.
--
-- Keyed on the output, both of those are ordinary cache misses and need no special
-- case. itemId/enchant/randomProp ride along because RefreshTooltip's text is a
-- function of them and not of the icon: two different items can share an icon, and
-- an in-place enchant change would not move it.
--
-- UpdateSearch is inside the guard too. Its other input is the search string,
-- which has its own message (TEXT_SEARCH_UPDATE) calling UpdateSearch directly and
-- bypassing this cache -- and when late item data does arrive, the texture change
-- lands us here anyway, so the search filter re-evaluates with it.
--
-- Pooling needs no invalidation hook, which is worth stating because the opposite
-- looks obviously necessary. These five fields are only ever assigned immediately
-- before the two writes below, and those two lines are the only thing in the addon
-- that paints an item button (the template's own OnEvent/OnUpdate are nil'd in
-- Create). So the cache describes THIS BUTTON'S PIXELS, not the cell it is bound
-- to, and Free/Restore/SetSlot repaint nothing -- a rebound button either resolves
-- to something different (a miss, so it is redrawn) or to exactly what it is
-- already showing (a skip, which is correct). Clearing the cache in SetSlot would
-- be defending against nothing.
function ItemSlot:Update()
	if not self:IsVisible() then return end

	local data = self:GetCellData()
	local texture, count, itemId, enchant, randomProp
	if data then
		itemId, count = data.itemId, data.count
		enchant, randomProp = data.enchant, data.randomProp
		texture = GetItemIcon(itemId) or UNKNOWN_ITEM_TEXTURE
	else
		count = 0
		texture = self:GetEmptyItemTexture()
	end

	if self.shownCount == count and self.shownTexture == texture
		and self.shownItemId == itemId and self.shownEnchant == enchant
		and self.shownRandomProp == randomProp then
		return
	end

	self.shownCount, self.shownTexture = count, texture
	self.shownItemId, self.shownEnchant, self.shownRandomProp = itemId, enchant, randomProp

	SetItemButtonTexture(self, texture)
	SetItemButtonCount(self, count)

	self:UpdateSearch()
	self:RefreshTooltipIfOwned()
end

-- Same empty-slot background core Bagnon/Bagnon_GuildBank use, and honors
-- the same addon-wide "Show Empty Item Slot Background" setting they share.
local EMPTY_SLOT_TEXTURE = [[Interface\PaperDoll\UI-Backpack-EmptySlot]]
function ItemSlot:GetEmptyItemTexture()
	if Bagnon.Settings:ShowingEmptyItemSlotTextures() then
		return EMPTY_SLOT_TEXTURE
	end
	return nil
end

-- Dims (rather than hides) cells that don't match the addon-wide text
-- search, same as core Bagnon/Bagnon_GuildBank's own item slots.
-- `search` is passed in by ItemFrame:TEXT_SEARCH_UPDATE, which reads it once for
-- the whole grid; omitted (the Update() path) it's looked up here.
--
-- `matches` is that same caller's per-pass itemId -> boolean memo (see its comment
-- for why it must not outlive one pass). Optional: the Update() path passes none
-- and computes directly, which is fine now that Update only reaches here when the
-- cell actually changed. Stored as a real boolean either way, so `nil` keeps
-- meaning "not computed yet" and a genuine non-match still memoizes.
function ItemSlot:UpdateSearch(search, matches)
	if search == nil then
		search = Bagnon.Settings:GetTextSearch()
	end

	local shouldFade = false
	if search ~= nil and search ~= '' then
		local data = self:GetCellData()
		local itemId = data and data.itemId
		local match = matches and itemId and matches[itemId]

		if match == nil then
			local link = self:GetSearchLink()
			match = (link and ItemSearch:Find(link, search)) and true or false
			if matches and itemId then
				matches[itemId] = match
			end
		end

		shouldFade = not match
	end

	self:SetAlpha(shouldFade and 0.4 or 1)
end

-- Rebuilt only when this cell's item actually changes. It used to be formatted
-- fresh inside UpdateSearch, which runs once per cell per keystroke, so a full
-- page threw away 180 strings per character typed.
--
-- Keyed on itemId rather than cleared in SetSlot because the pool rebinds
-- buttons freely: comparing against the CURRENT cell's itemId is correct
-- whichever cell this button was serving a moment ago, and when the id happens
-- to match, the cached link was already the right one.
function ItemSlot:GetSearchLink()
	local data = self:GetCellData()
	if not data then
		return nil
	end

	if self.searchLinkId ~= data.itemId then
		self.searchLinkId = data.itemId
		self.searchLink = ('item:%d'):format(data.itemId)
	end
	return self.searchLink
end

-- Deliberately NOT named UpdateTooltip. Classy gives every instance a live
-- metatable __index back to the class table (utility/classy.lua:
-- `class.mt = {__index = class}`), so a method defined here under that exact
-- name would still be reachable as `item.UpdateTooltip` even after Create()
-- sets the instance field to nil -- nil-ing an instance field doesn't shadow
-- a class method of the same name, it just means "nothing here", and the
-- lookup falls through to the class same as before.
--
-- That matters because Blizzard's GameTooltip_OnUpdate polls
-- `if owner.UpdateTooltip then owner:UpdateTooltip() end` every ~0.2s for as
-- long as the tooltip's shown. With a class method literally named
-- UpdateTooltip, that poll finds ours through the metatable fallback and
-- re-invokes it uninvited -- and a second, unrequested SetHyperlink() call
-- with our hand-built, non-real-item-instance link on an already-shown
-- tooltip is what was tearing it down a moment after every hover. Native's
-- own content cells never hit this: they're plain CreateFrame buttons with
-- inline anonymous OnEnter functions, no class and no metatable, so nil-ing
-- their `.UpdateTooltip` field is a genuine block. Giving our own method a
-- name Blizzard's poll never looks for gets the same guarantee here.
function ItemSlot:RefreshTooltip()
	local data = self:GetCellData()
	if not data then
		GameTooltip:Hide()
		return
	end

	-- Full item link (with enchant/random suffix) rather than just the base
	-- item, so those show up correctly in the tooltip -- hand-built since
	-- there's no real bag 20+ container to pull a genuine link from here.
	-- All 9 colon-fields (itemID:enchant:gem1-4:suffix:uniqueID:linkLevel),
	-- not just the first 7 the native vault UI truncates to -- belt and
	-- suspenders alongside the ContainerFrameItemButtonTemplate/self.slot
	-- fixes above.
	--
	-- Through SetTooltipItem (components/widget.lua), not a bare SetHyperlink:
	-- on a first hover the client's item cache may not have this id yet, and
	-- SetHyperlink then renders an empty or name-only tooltip nothing ever
	-- refreshes. SetTooltipItem shows a "Retrieving item information"
	-- placeholder instead and rebuilds this tooltip when the server's answer
	-- lands. The stack line below appends either way -- the count comes from
	-- the packet, not the item cache.
	self:SetTooltipItem(data.itemId, ('item:%d:%d:0:0:0:0:%d:0:0'):format(
		data.itemId, data.enchant or 0, data.randomProp or 0))

	if data.count and data.count > 1 then
		GameTooltip:AddLine('Stack: ' .. data.count, 0.7, 0.7, 0.7)
	end

	GameTooltip:Show()
end


--[[ Accessors ]]--

-- A plain field, not SetID() -- confirmed against the native vault UI's own
-- content cells (they use a plain 'btn.slot' field too, never SetID). This
-- matters specifically because of the ContainerFrameItemButtonTemplate
-- switch above: self:GetID() plus self:GetParent():GetID() is exactly the
-- (bag, slot) pair Blizzard's own default tooltip/update logic reads to
-- look up a REAL container slot. Routing our own virtual slot number
-- through SetID() was handing that default machinery a real, valid-looking
-- backpack slot to (mis)query every refresh -- keeping it a separate field
-- means GetID() stays unset/harmless.
function ItemSlot:SetSlot(bagIndex, slot)
	self.bagIndex = bagIndex
	self.slot = slot
end

function ItemSlot:GetSlot()
	return self.bagIndex, self.slot
end

function ItemSlot:GetCellData()
	local page = ExtBank.cells[self.bagIndex]
	return page and page[self.slot]
end


-- SetFrameID/GetFrameID/GetSettings, plus the tooltip methods -- this class hovers,
-- so it opts into the second half.
Bagnon.ExtBankWidget:Apply(ItemSlot)
Bagnon.ExtBankWidget:ApplyTooltip(ItemSlot)