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

	if item:IsVisible() then
		item:Update()
	else
		item:Show()
	end

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

function ItemSlot:Free()
	self:Hide()
	self:SetParent(nil)

	ItemSlot.unused = ItemSlot.unused or {}
	ItemSlot.unused[self] = true
end


--[[ Frame Events ]]--

function ItemSlot:OnShow()
	self:Update()
end

-- Left-click with an empty cursor and hand holding nothing: picks the item
-- up (virtually -- see ExtBank.pickSrc in core/cursor.lua). Right-click or
-- shift-click: withdraws it straight to inventory, no pickup step needed.
-- Either way, dropping something already carried takes priority.
function ItemSlot:OnClick(button)
	if self:DropCarriedItem() then
		return
	end

	local data = self:GetCellData()
	if not data then
		return
	end

	if button == 'RightButton' or IsShiftKeyDown() then
		ExtBank:WithdrawToInventory(self.bagIndex, self.slot)
	else
		ExtBank.pickSrc = { bagIndex = self.bagIndex, slot = self.slot }
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

	ExtBank.pickSrc = { bagIndex = self.bagIndex, slot = self.slot }

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

		-- A refusal (see GetVerifiedCursorSource in core/cursor.lua -- unknown or
		-- mismatched source) deliberately leaves the item ON the cursor rather
		-- than ClearCursor()-ing it: the drop didn't happen, so the player
		-- should still be holding it and free to put it back where they want.
		-- Still returns true either way -- the drop was handled and explained,
		-- and OnClick must not fall through into starting a vault pick while
		-- something's being carried.
		local src = ExtBank:GetVerifiedCursorSource()
		if src then
			ExtBank:DepositToSlot(src.bag, src.slot, self.bagIndex, self.slot)
			ClearCursor()
			ExtBank.cursorSrc = nil
		end
		return true
	elseif ExtBank.pickSrc then
		local src = ExtBank.pickSrc
		ExtBank:MoveWithinVault(src.bagIndex, src.slot, self.bagIndex, self.slot)
		ExtBank:ClearPick()
		return true
	end

	return false
end

function ItemSlot:OnEnter()
	self:AnchorTooltip()
	self:RefreshTooltip()
end

function ItemSlot:OnLeave()
	GameTooltip:Hide()
end


--[[ Update Methods ]]--

function ItemSlot:Update()
	if not self:IsVisible() then return end

	local data = self:GetCellData()
	if data then
		SetItemButtonTexture(self, GetItemIcon(data.itemId) or [[Interface\Icons\INV_Misc_QuestionMark]])
		SetItemButtonCount(self, data.count)
	else
		SetItemButtonTexture(self, self:GetEmptyItemTexture())
		SetItemButtonCount(self, 0)
	end

	self:UpdateSearch()

	if GameTooltip:IsOwned(self) then
		self:RefreshTooltip()
	end
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
function ItemSlot:UpdateSearch()
	local search = Bagnon.Settings:GetTextSearch()
	local shouldFade = false

	if search and search ~= '' then
		local data = self:GetCellData()
		shouldFade = not (data and ItemSearch:Find(('item:%d'):format(data.itemId), search))
	end

	if shouldFade then
		self:SetAlpha(0.4)
	else
		self:SetAlpha(1)
	end
end

function ItemSlot:AnchorTooltip()
	if self:GetRight() > (GetScreenWidth() / 2) then
		GameTooltip:SetOwner(self, 'ANCHOR_LEFT')
	else
		GameTooltip:SetOwner(self, 'ANCHOR_RIGHT')
	end
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
	GameTooltip:SetHyperlink(('item:%d:%d:0:0:0:0:%d:0:0'):format(
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

function ItemSlot:SetFrameID(frameID)
	self.frameID = frameID
end

function ItemSlot:GetFrameID()
	return self.frameID
end