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
-- (server enforces that the bag has to be empty first). Every other button
-- does nothing -- see the note in the body.
--
-- CheckButtons on 'anyUp': the client flips the checked state before this
-- runs, so every path has to reach the UpdateChecked() below or the slot is
-- left glowing as "contents shown" when it isn't. Core Bagnon's own
-- Bag:OnClick ends the same way, with UpdateShown().
function Bag:OnClick(button)
	-- Clicking the strip ends any outstanding in-vault pick. Toggling a bag's
	-- contents re-flows the grid, and unequipping one removes cells outright, so a
	-- pick armed before this click would complete itself onto a cell the player
	-- never aimed at -- with no cue that it was still armed. The strip used to
	-- ignore pickSrc entirely, which is what made an accidental left-click on a cell
	-- survive arbitrarily long.
	ExtBank:ClearPick()

	-- The button is tested BEFORE the drop, and every branch names its button
	-- explicitly. Both halves of that are load-bearing, and the shape this
	-- replaced got both wrong:
	--
	--   if not self:IsLocked() and not self:DropCarriedBag() then
	--
	-- DropCarriedBag answers "was the cursor loaded?", not "did I handle this
	-- click" -- it returns true on CursorHasItem() alone, whatever the button
	-- was and whether the equip went out or GetVerifiedCursorSource refused it.
	-- So ANY click made while carrying something short-circuited the entire body
	-- away, the button test included, and was treated as a drop: what went out
	-- was EquipBagToSlot for the carried item aimed at the clicked slot, with
	-- ClearCursor() already run.
	--
	-- Right-click was the one exception, and only by accident -- see
	-- docs/non-issues.md §17. The client cancels a loaded cursor on
	-- right-button-down and consumes the press, so OnClick never ran for that
	-- case at all and never can; the strip cannot override it, and
	-- components/item.lua's ItemSlot:OnClick bows to the same rule (its
	-- right-click withdraw is guarded on `not CursorHasItem()`). That left
	-- MiddleButton and Button4/5 as the live route into the bogus equip.
	--
	-- The old second branch was a bare `elseif self:IsEquipped()`, and this
	-- button is RegisterForClicks('anyUp') above -- so those same three buttons
	-- also reached ToggleBagSlot with an empty cursor, making a bag's contents
	-- disappear from the grid on a click that was never given a meaning.
	-- components/item.lua's ItemSlot:OnClick closed exactly this on the cell
	-- side; the strip was not brought along.
	--
	-- So RightButton here is reachable only with an empty cursor. Testing it
	-- anyway rather than leaning on that: the guarantee is the client's, not
	-- ours, and a bare `else` is what this branch is being fixed for.
	if not self:IsLocked() then
		if button == 'LeftButton' then
			if not self:DropCarriedBag() and self:IsEquipped() then
				self:GetSettings():ToggleBagSlot(self.bagIndex)
			end
		elseif button == 'RightButton' and self:IsEquipped() then
			ExtBank:UnequipBag(self.bagIndex)
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
--
-- The return means "the cursor was loaded, so this was a drop attempt" -- NOT
-- "the equip succeeded", and not "I handled this click". A verification refusal
-- still answers true, because the click was still spent on a drop the player
-- made. Only OnClick's LeftButton branch and OnReceiveDrag may read it; reading
-- it as a general "was this click consumed" test is what swallowed the
-- right-click unequip, and OnClick's body says so at length.
function Bag:DropCarriedBag()
	if not CursorHasItem() then return false end

	local src = ExtBank:GetVerifiedCursorSource()
	if src and ExtBank:EquipBagToSlot(src.bag, src.slot, self.bagIndex) then
		-- Same rule as the content cells' own drop (components/item.lua): the cursor
		-- is only released once the request has actually gone out, so a client that
		-- is not answering leaves the bag in hand rather than silently dropping it
		-- back as though it had been equipped.
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

-- Drawn when the client has no cached item data for the equipped container yet, the
-- same placeholder components/item.lua uses for content cells. See
-- docs/non-issues.md §5: this server does not answer bulk item queries, so it is a
-- real state that can resolve later or never -- hovering the slot is what asks for
-- the one id and repaints it (SetTooltipItem, components/widget.lua).
local UNKNOWN_ITEM_TEXTURE = [[Interface\Icons\INV_Misc_QuestionMark]]

function Bag:Update()
	local locked = self:IsLocked()
	local data = (not locked) and self:GetBagData() or nil
	local itemId = data and data.itemId or nil

	-- The checked ring is driven on its own, outside the cache below, because
	-- OnClick and OnSlotShownChanged both reach UpdateChecked directly --
	-- folding it into the cached state would let those two paths desync it.
	self:UpdateChecked()

	-- Everything past here is the icon and alpha work, and that is what
	-- actually costs something: all 70 buttons run this on every
	-- EXTBANK_MODEL_UPDATED, and for a typical player the 62-70 LOCKED ones
	-- were rewriting the same constant texture, the same desaturation and the
	-- same alpha every single packet. The tooltip refresh belongs on this side
	-- of the check too -- its text is a function of exactly these two values.
	--
	-- The RESOLVED texture is part of the key, not just (locked, itemId), and that
	-- is what keeps the cache honest. GetItemIcon reads the client's item cache,
	-- which on a cold login answers nil for an item it has not seen -- the button
	-- draws the question mark, and seconds later the same itemId would answer with
	-- the real path. Keyed on itemId alone the early-out swallowed that: the `?`
	-- was pinned for the rest of the session, un-fixable by toggling the strip
	-- (OnHide does not clear this) or by reopening the window, only by /reload.
	-- Meanwhile the content grid re-resolved on every packet and drew correctly, so
	-- the player got permanent `?` bag icons above a correct grid. Keyed on what is
	-- about to be written, late item data is just a cache miss.
	local texture, desaturated
	if locked then
		texture, desaturated = EMPTY_BAG_TEXTURE, true
	else
		texture = itemId and (GetItemIcon(itemId) or UNKNOWN_ITEM_TEXTURE) or EMPTY_BAG_TEXTURE
		desaturated = false
	end

	if self.shownLocked == locked and self.shownItemId == itemId
		and self.shownTexture == texture then
		return
	end
	self.shownLocked, self.shownItemId, self.shownTexture = locked, itemId, texture

	local icon = self.icon
	if icon then
		icon:SetTexture(texture)
		icon:SetDesaturated(desaturated)
	end

	self:SetAlpha(locked and 0.55 or 1)
	self:RefreshTooltipIfOwned()
end

-- `not IsBagSlotHidden`, not `IsBagSlotShown`, because the two are equivalent
-- here and only one of them is O(1). Core's IsBagSlotShown
-- (Bagnon/components/frameSettings.lua) answers by walking GetVisibleBagSlots(),
-- whose iterator re-fetches GetDB():GetBags() and calls IsBagSlotHidden again on
-- every step -- so it means "in GetBags() AND not hidden". IsBagSlotHidden is
-- just `not GetDB():IsBagShown(slot)`: three calls and one table index.
--
-- Core pays the scan over <= 12 bag slots. This frame seeds availableBags with
-- all 70 (components/savedFrameSettings.lua), so finding index k cost k+1
-- iterator steps and a HIDDEN bag cost a full 70-step scan that never matched --
-- times 70 buttons, on every packet, and deliberately outside Update's own
-- shownLocked/shownItemId cache below since OnClick and OnSlotShownChanged reach
-- here directly.
--
-- The two predicates differ only for a slot outside GetBags(), and this frame has
-- none: GetDefaultExtBankSettings fills availableBags with every index
-- 0..MAX_BAGS-1, and BagFrame:CreateBagSlots only ever builds buttons for that
-- same range. That is the invariant this line depends on -- if availableBags ever
-- becomes a proper subset of the buttons built, they stop agreeing. (Reverse Slot
-- Order is safe either way: it flips the iterator's direction, not its
-- membership.)
-- The locked test lives HERE rather than in Update, so all three callers agree.
-- Update used to branch on it itself (`if locked then SetChecked(false) else
-- UpdateChecked() end`) while OnClick and OnSlotShownChanged called straight in --
-- and IsEquipped reads GetBagData raw, unlike Update which nils the data when
-- locked. So for any bagIndex a packet reported a container in while unlockedBags
-- still excluded it, a BAG_SLOT_SHOW for that index painted the "contents shown"
-- ring onto a greyed, desaturated locked slot.
function Bag:UpdateChecked()
	self:SetChecked(not self:IsLocked()
		and self:IsEquipped()
		and not self:GetSettings():IsBagSlotHidden(self.bagIndex))
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
		-- Through SetTooltipItem (components/widget.lua), not a bare
		-- SetHyperlink -- same first-hover cache miss as the content cells;
		-- see ItemSlot:RefreshTooltip. The two hint lines come from the
		-- model, not the item cache, so they hold under the placeholder too.
		self:SetTooltipItem(data.itemId, 'item:' .. data.itemId)
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


-- SetFrameID/GetFrameID/GetSettings, plus the tooltip methods -- this class hovers,
-- so it opts into the second half.
Bagnon.ExtBankWidget:Apply(Bag)
Bagnon.ExtBankWidget:ApplyTooltip(Bag)