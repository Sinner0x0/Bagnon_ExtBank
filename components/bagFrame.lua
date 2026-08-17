--[[
	bagFrame.lua
		The bag-slot strip (wraps at 5 columns, or more if the item grid
		below us is currently drawn wider than that -- see GetColumnCount)
		plus its purchase-next-slot button, centered above the grid. Shown/
		hidden as a whole by the standard bag-toggle icon on the menu-button
		line (see frame.lua) -- when hidden, nothing here is drawn at all;
		when shown, every slot draws, occupied and empty alike.
--]]

local Bagnon = LibStub('AceAddon-3.0'):GetAddon('Bagnon')
local ExtBank = Bagnon.ExtBank
local BagFrame = Bagnon.Classy:New('Frame')
Bagnon.ExtBankBagFrame = BagFrame

local MIN_COLUMNS = 5 -- matches the item grid's own 4-column floor closely enough to not look mismatched at minimum width
local SPACING = 2
local PURCHASE_BUTTON_HEIGHT = 22
local PURCHASE_BUTTON_WIDTH = 160
local PURCHASE_BUTTON_GAP = 6

-- Per-slot cost table and gold-icon escape string taken from ProjectEbonhold's
-- own vault UI (modules/extBank/extBank.lua), so the price shown here is the
-- same one the native window shows. Client-side only -- the server enforces and
-- charges the real cost; this table is purely for telling the player what to
-- expect before they confirm.
local SLOT_COSTS = {50, 125, 250, 500, 1250, 2500, 5000, 10000}
local GOLD_ICON = "|TInterface\\MoneyFrame\\UI-GoldIcon:14:14:2:0|t"

local function NextSlotCost()
	return SLOT_COSTS[math.min(ExtBank.unlockedBags + 1, #SLOT_COSTS)]
end

local function FormatGold(n)
	local s = tostring(n):reverse():gsub('(%d%d%d)', '%1,'):reverse()
	return (s:gsub('^,', ''))
end

-- Named on the class rather than kept file-local: components/frame.lua's
-- OnHide hides this popup when the window closes (see its "Native close sync"
-- section), and one shared constant is what keeps that call and the
-- StaticPopup_Show below from drifting apart. Ours is a separate dialog from
-- the native UI's own EXTBANK_UNLOCK_CONFIRM, so extBank.lua's ExtBank_Close
-- hiding that one does nothing for this one.
BagFrame.UNLOCK_POPUP = 'BAGNON_EXTBANK_UNLOCK_CONFIRM'

StaticPopupDialogs[BagFrame.UNLOCK_POPUP] = {
	text = 'Unlock bag slot %s for %s?',
	button1 = YES,
	button2 = NO,
	OnAccept = function() Bagnon.ExtBank:Unlock() end,
	timeout = 0,
	whileDead = 1,
	hideOnEscape = 1,
}


--[[ Constructor ]]--

function BagFrame:New(frameID, parent)
	local f = self:Bind(CreateFrame('Frame', nil, parent))
	f:Hide()

	f:SetScript('OnShow', f.OnShow)
	f:SetScript('OnHide', f.OnHide)

	f:SetFrameID(frameID)
	f:CreateBagSlots()
	f:CreatePurchaseButton()
	f:UpdateEvents()

	-- Deliberately does NOT show itself here, the same as core's own
	-- BagFrame:New -- core's PlaceBagFrame (Bagnon/components/frame.lua)
	-- Show()s or Hide()s us to match IsBagFrameShown() a few lines after this
	-- returns, in the same layout pass. Showing from in here instead recurses
	-- forever: OnShow sends BAG_FRAME_UPDATE_SHOWN, Ears dispatches it
	-- synchronously, core's Frame handler calls Frame:Layout() (no
	-- re-entrancy guard) -> PlaceBagFrame -> `GetBagFrame() or
	-- CreateBagFrame()`, and GetBagFrame() is still nil because
	-- Frame:CreateBagFrame only assigns self.bagFrame AFTER we return -- so it
	-- builds another BagFrame, which shows itself, and so on. That was the
	-- instant client freeze on opening the window.
	return f
end

function BagFrame:CreateBagSlots()
	local bags = {}
	for i = 1, ExtBank.MAX_BAGS do
		bags[i] = Bagnon.ExtBankBag:New(i - 1, self:GetFrameID(), self)
	end
	self.bags = bags
end

function BagFrame:CreatePurchaseButton()
	local b = CreateFrame('Button', nil, self, 'UIPanelButtonTemplate')
	-- Fixed size, not stretched to the strip's (now variable) width -- a
	-- button stretched narrower than its own text wraps the label onto a
	-- second line, which pushes its actual rendered height past whatever
	-- SetHeight() says and the bag-slot grid below ends up drawn on top of
	-- the overflow. Centering (see Layout, below) means it doesn't need to
	-- span the full strip width to look intentional anyway.
	b:SetHeight(PURCHASE_BUTTON_HEIGHT)
	b:SetWidth(PURCHASE_BUTTON_WIDTH)
	b:SetScript('OnClick', function()
		if ExtBank.unlockedBags >= ExtBank.MAX_BAGS then return end
		StaticPopup_Show(BagFrame.UNLOCK_POPUP,
			tostring(ExtBank.unlockedBags + 1),
			FormatGold(NextSlotCost()) .. ' ' .. GOLD_ICON)
	end)
	self.purchaseButton = b
	return b
end


--[[ Messages ]]--
-- Mirrors core Bagnon's own BagFrame exactly (components/bagFrame.lua):
-- registered unconditionally (not gated to OnShow/OnHide like everything
-- else in this addon) so this frame reacts to the toggle click even while
-- WoW-hidden, and reacts directly instead of waiting for a full outer-frame
-- relayout to notice -- nothing else would ever trigger one, since core's
-- own Frame only relays out in response to BAG_FRAME_UPDATE_SHOWN (sent
-- below), not the raw BAG_FRAME_SHOW/HIDE the toggle button fires.

-- One handler for both: UpdateShown reads IsBagFrameShown() for itself, so
-- which of the two messages arrived tells it nothing it doesn't already ask.
function BagFrame:OnBagFrameToggled(msg, frameID)
	if frameID == self:GetFrameID() then
		self:UpdateShown()
	end
end

function BagFrame:UpdateEvents()
	self:UnregisterAllMessages()
	self:RegisterMessage('BAG_FRAME_SHOW', 'OnBagFrameToggled')
	self:RegisterMessage('BAG_FRAME_HIDE', 'OnBagFrameToggled')
end


--[[ Frame Events ]]--

-- Lay ourselves out, then tell the outer Frame our footprint may have moved so
-- it re-places the item grid below us (up into the gap, or back down) -- same
-- nudge core's own BagFrame sends on every show/hide. The two go together
-- everywhere they appear, which is why they're named once here rather than
-- repeated at each of the three call sites.
function BagFrame:Relayout()
	self:Layout()
	self:SendMessage('BAG_FRAME_UPDATE_SHOWN', self:GetFrameID())
end

function BagFrame:OnShow()
	self:RegisterMessage('EXTBANK_MODEL_UPDATED', 'OnModelUpdated')
	self:RegisterMessage('ITEM_FRAME_SIZE_CHANGE', 'OnItemFrameSizeChange')
	self:UpdatePurchaseButton()
	self:Relayout()
end

function BagFrame:OnHide()
	self:UnregisterMessage('EXTBANK_MODEL_UPDATED')
	self:UnregisterMessage('ITEM_FRAME_SIZE_CHANGE')
	self:SendMessage('BAG_FRAME_UPDATE_SHOWN', self:GetFrameID())
end

function BagFrame:OnModelUpdated()
	-- Unlike a plain price/count text change, the purchase button's own
	-- visibility can now change here too (see UpdatePurchaseButton -- it's
	-- hidden outright, not just disabled, once every slot's unlocked), and
	-- that changes how much vertical space the strip needs above its
	-- bag-slot grid -- so this needs a real Layout() pass (reclaiming that
	-- space, or making room for it again on a fresh model with fewer
	-- unlocked slots than last session), plus the same BAG_FRAME_UPDATE_SHOWN
	-- nudge OnShow/OnHide/OnItemFrameSizeChange already send so the outer
	-- Frame catches up to our new size.
	self:UpdatePurchaseButton()
	self:Relayout()
end

-- The item grid below us (see itemFrame.lua) only actually settles on its
-- real width sometime after we've already drawn ourselves once -- its own
-- Layout() is deferred/throttled and runs a frame later, and on the very
-- first-ever open it doesn't exist yet at all when we first lay out (see
-- GetColumnCount above). This is what lets our own width catch up once that
-- happens, and on every later column-count/content change after.
function BagFrame:OnItemFrameSizeChange(msg, frameID)
	if frameID == self:GetFrameID() then
		self:Relayout()
	end
end


--[[ Update Methods ]]--

function BagFrame:UpdateShown()
	if self:IsBagFrameShown() then
		self:Show()
	else
		self:Hide()
	end
end

function BagFrame:IsBagFrameShown()
	return self:GetSettings():IsBagFrameShown()
end

-- Hidden outright at MAX_BAGS, not merely disabled-and-relabeled -- a
-- deliberate divergence from the native vault UI, which keeps the button in
-- place and swaps its text to "All bag slots unlocked" instead (see the
-- purchase-button branch in extBank.lua's own redraw). Nothing ever un-maxes
-- bag slots, so that control is dead for good once it's reached; here it
-- sits above a strip whose height Layout() (below) recomputes from scratch
-- every pass, so hiding it hands the space back permanently rather than
-- reserving a row forever for a button that can never do anything again.
function BagFrame:UpdatePurchaseButton()
	local b = self.purchaseButton
	if ExtBank.unlockedBags >= ExtBank.MAX_BAGS then
		b:Hide()
	else
		b:SetText(('Purchase %s %s'):format(FormatGold(NextSlotCost()), GOLD_ICON))
		b:Enable()
		b:Show()
	end
end


--[[ Layout ]]--

-- MIN_COLUMNS unless the item grid below us is currently rendering wider
-- than that -- then widen to match it, so a player who's bumped up the item
-- grid's column count (or just has a lot of bags equipped) doesn't end up
-- with empty window width to the right of a strip stuck at its original
-- size. Never narrower than MIN_COLUMNS, since the item grid can render
-- narrower than its own column setting when there simply aren't enough
-- items yet to fill a row.
function BagFrame:GetColumnCount()
	local itemFrame = self:GetParent() and self:GetParent():GetItemFrame()
	local itemFrameWidth = itemFrame and itemFrame:GetWidth()

	if itemFrameWidth and itemFrameWidth > 0 then
		local span = Bagnon.ExtBankBag.SIZE + SPACING
		local fitted = math.floor((itemFrameWidth + SPACING) / span)
		return math.max(MIN_COLUMNS, fitted)
	end

	return MIN_COLUMNS
end

-- Every slot always draws when this frame's shown -- equipped ("present"),
-- unlocked-but-empty, and locked alike -- since the frame's own Show/Hide
-- (driven by the standard bag-toggle icon, see frame.lua) is what decides
-- whether the strip is on screen at all. The purchase button sits above the
-- grid (not below it) and stays horizontally centered regardless of how
-- wide the grid currently is.
function BagFrame:Layout()
	local size = Bagnon.ExtBankBag.SIZE
	local columns = self:GetColumnCount()

	-- Shown/hidden by UpdatePurchaseButton above, not here -- this only
	-- reads its current state to decide whether to reserve room for it.
	local button = self.purchaseButton
	local topOffset = 0

	if button:IsShown() then
		button:ClearAllPoints()
		button:SetPoint('TOP', self, 'TOP', 0, 0)
		topOffset = button:GetHeight() + PURCHASE_BUTTON_GAP
	end

	for i, bag in ipairs(self.bags) do
		local col = (i - 1) % columns
		local row = math.floor((i - 1) / columns)
		bag:ClearAllPoints()
		bag:SetPoint('TOPLEFT', self, 'TOPLEFT', col * (size + SPACING), -(topOffset + row * (size + SPACING)))
	end

	local rows = math.ceil(#self.bags / columns)
	local gridWidth = columns * (size + SPACING) - SPACING
	local stripHeight = rows * (size + SPACING) - SPACING

	self:SetWidth(math.max(gridWidth, button:IsShown() and button:GetWidth() or 0))
	self:SetHeight(topOffset + stripHeight)
end


--[[ Properties ]]--

-- SetFrameID/GetFrameID/GetSettings come from Bagnon.ExtBankWidget
-- (components/widget.lua).
Bagnon.ExtBankWidget:Apply(BagFrame)