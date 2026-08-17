--[[
	bag.lua
		One button in the ExtBank bag-slot strip: locked (unpurchased),
		empty (equip target), or equipped (toggles its contents on/off in
		the shared item grid below)
--]]

local Bagnon = LibStub('AceAddon-3.0'):GetAddon('Bagnon')
local ExtBank = Bagnon.ExtBank
local Bag = Bagnon.Classy:New('CheckButton')
Bagnon.ExtBankBag = Bag

Bag.SIZE = 30


--[[ Constructor ]]--

do
	local nextID = 0
	function Bag:New(bagIndex, frameID, parent)
		nextID = nextID + 1

		local name = 'BagnonExtBankBag' .. nextID
		local bag = self:Bind(CreateFrame('CheckButton', name, parent, 'ItemButtonTemplate'))
		bag:SetWidth(Bag.SIZE)
		bag:SetHeight(Bag.SIZE)
		bag.bagIndex = bagIndex
		bag:SetFrameID(frameID)

		-- Looked up once. ItemButtonTemplate names this region $parentIconTexture
		-- and never replaces it, so re-deriving it inside Update -- a GetName()
		-- call, a string concat and a _G probe, on all 70 buttons on every
		-- packet -- was pure repeat work. (The old `or _G[name..'Icon']`
		-- fallback went with it: that spelling belongs to later templates, and
		-- on 3.3.5 it could only ever be nil.)
		bag.icon = _G[name .. 'IconTexture']

		-- ItemButtonTemplate has no checked texture of its own (stock bag
		-- slot buttons are never toggles) -- add one so a shown/hidden bag
		-- is visibly distinguishable.
		local checked = bag:CreateTexture(nil, 'OVERLAY')
		checked:SetTexture([[Interface\Buttons\CheckButtonHilight]])
		checked:SetBlendMode('ADD')
		checked:SetAllPoints(bag)
		bag:SetCheckedTexture(checked)

		bag:RegisterForClicks('anyUp')

		-- Deliberately NOT RegisterForDrag'd. There is no OnDragStart here
		-- (unlike the item cells, which set both OnDragStart and OnDragStop),
		-- and once the client promotes a left press-and-move into a drag the
		-- mouse-up stops producing OnClick -- so a click with a few pixels of
		-- pointer drift silently did nothing at all: no contents toggle, no
		-- right-click unequip, and no UpdateChecked, which OnClick is the only
		-- path to. Receiving a dropped bag doesn't need it either; OnReceiveDrag
		-- is delivered on mouse focus regardless.
		bag:SetScript('OnEnter', bag.OnEnter)
		bag:SetScript('OnLeave', bag.OnLeave)
		bag:SetScript('OnClick', bag.OnClick)
		bag:SetScript('OnReceiveDrag', bag.OnReceiveDrag)
		bag:SetScript('OnShow', bag.OnShow)
		bag:SetScript('OnHide', bag.OnHide)

		return bag
	end
end


--[[ Frame Events ]]--

function Bag:OnShow()
	self:RegisterMessage('EXTBANK_MODEL_UPDATED', 'Update')
	self:RegisterMessage('BAG_SLOT_SHOW', 'OnSlotShownChanged')
	self:RegisterMessage('BAG_SLOT_HIDE', 'OnSlotShownChanged')
	self:Update()
end

function Bag:OnHide()
	self:UnregisterAllMessages()
end

function Bag:OnSlotShownChanged(msg, frameID, bagIndex)
	if frameID == self:GetFrameID() and bagIndex == self.bagIndex then
		self:UpdateChecked()
	end
end

-- Left-click: drop a carried bag to equip here, or (on an equipped slot)
-- toggle its contents on/off in the shared grid. Right-click: unequip
-- (server enforces that the bag has to be empty first).
--
-- CheckButtons on 'anyUp': the client flips the checked state before this
-- runs, so every path has to reach the UpdateChecked() below or the slot is
-- left glowing as "contents shown" when it isn't. Core Bagnon's own
-- Bag:OnClick ends the same way, with UpdateShown().
function Bag:OnClick(button)
	if not self:IsLocked() and not self:DropCarriedBag() then
		if button == 'RightButton' then
			if self:IsEquipped() then
				ExtBank:UnequipBag(self.bagIndex)
			end
		elseif self:IsEquipped() then
			self:GetSettings():ToggleBagSlot(self.bagIndex)
		end
	end

	self:UpdateChecked()
end

function Bag:OnReceiveDrag()
	if self:IsLocked() then return end
	self:DropCarriedBag()
end

-- Same verification the item cells do (see GetVerifiedCursorSource in
-- core/cursor.lua) -- this reads the exact same remembered coordinates and so had the
-- exact same exposure to them naming something other than what's being
-- carried, which here would equip the wrong container into the strip. A
-- refusal leaves the item on the cursor rather than dropping it.
function Bag:DropCarriedBag()
	if not CursorHasItem() then return false end

	local src = ExtBank:GetVerifiedCursorSource()
	if src then
		ExtBank:EquipBagToSlot(src.bag, src.slot, self.bagIndex)
		ClearCursor()
		ExtBank.cursorSrc = nil
	end
	return true
end

function Bag:OnEnter()
	self:AnchorTooltip()
	self:RefreshTooltip()
end

-- OnLeave, AnchorTooltip and RefreshTooltipIfOwned all come from
-- Bagnon.ExtBankWidget (components/widget.lua), shared with item.lua.


--[[ Update Methods ]]--

local EMPTY_BAG_TEXTURE = [[Interface\PaperDoll\UI-PaperDoll-Slot-Bag]]

function Bag:Update()
	local locked = self:IsLocked()
	local data = (not locked) and self:GetBagData() or nil
	local itemId = data and data.itemId or nil

	-- The checked ring is driven on its own, outside the cache below, because
	-- OnClick and OnSlotShownChanged both reach UpdateChecked directly --
	-- folding it into the cached state would let those two paths desync it.
	if locked then
		self:SetChecked(false)
	else
		self:UpdateChecked()
	end

	-- Everything past here is the icon and alpha work, and that is what
	-- actually costs something: all 70 buttons run this on every
	-- EXTBANK_MODEL_UPDATED, and for a typical player the 62-70 LOCKED ones
	-- were rewriting the same constant texture, the same desaturation and the
	-- same alpha every single packet. The tooltip refresh belongs on this side
	-- of the check too -- its text is a function of exactly these two values.
	if self.shownLocked == locked and self.shownItemId == itemId then
		return
	end
	self.shownLocked, self.shownItemId = locked, itemId

	local icon = self.icon
	if icon then
		if locked then
			icon:SetTexture(EMPTY_BAG_TEXTURE)
			icon:SetDesaturated(true)
		else
			icon:SetTexture(itemId and (GetItemIcon(itemId) or [[Interface\Icons\INV_Misc_QuestionMark]]) or EMPTY_BAG_TEXTURE)
			icon:SetDesaturated(false)
		end
	end

	self:SetAlpha(locked and 0.55 or 1)
	self:RefreshTooltipIfOwned()
end

function Bag:UpdateChecked()
	self:SetChecked(self:IsEquipped() and self:GetSettings():IsBagSlotShown(self.bagIndex))
end

-- Deliberately NOT named UpdateTooltip, for the same reason item.lua's cell
-- tooltip isn't (see the long note above ItemSlot:RefreshTooltip): Classy's
-- `class.mt = {__index = class}` keeps every class method reachable on the
-- instance, so a method under that exact name gets picked up by Blizzard's
-- GameTooltip_OnUpdate poll (`if owner.UpdateTooltip then owner:UpdateTooltip()
-- end`, ~5x/sec while shown) and re-invoked uninvited -- re-running the whole
-- SetHyperlink/SetText + AddLine + Show sequence on an already-shown tooltip,
-- which is exactly what was tearing the cell tooltips down mid-hover. A name
-- that poll never looks for is the whole fix. AnchorTooltip's SetOwner is what
-- makes us the owner it polls, so this applies to bag slots as much as cells.
function Bag:RefreshTooltip()
	if self:IsLocked() then
		-- Matches the native vault UI's own locked-slot tooltip text exactly
		-- (extBank.lua's bag-slot OnEnter) -- including "above", not
		-- "below": its own purchase button sits above its bag-slot strip
		-- too, same as ours (see bagFrame.lua's Layout).
		GameTooltip:SetText('Locked bag slot')
		GameTooltip:AddLine('Use the Purchase button above to unlock more bag slots.', 0.6, 0.6, 0.6, true)
		GameTooltip:Show()
		return
	end

	local data = self:GetBagData()
	if data then
		GameTooltip:SetHyperlink('item:' .. data.itemId)
		GameTooltip:AddLine('Click to show/hide its contents below', 0.6, 0.6, 0.6)
		GameTooltip:AddLine('Right-click to unequip (must be empty)', 0.6, 0.6, 0.6)
	else
		GameTooltip:SetText('Empty bag slot')
		GameTooltip:AddLine('Drag a bag here to equip it', 0.6, 0.6, 0.6, true)
	end

	GameTooltip:Show()
end


--[[ Accessors ]]--

function Bag:GetBagData()
	return ExtBank.bags[self.bagIndex]
end

function Bag:IsEquipped()
	return self:GetBagData() ~= nil
end

function Bag:IsLocked()
	return (self.bagIndex + 1) > ExtBank.unlockedBags
end


-- SetFrameID/GetFrameID/GetSettings, plus the tooltip trio above.
Bagnon.ExtBankWidget:Apply(Bag)