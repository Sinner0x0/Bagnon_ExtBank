--[[
	pageBar.lua
		Page navigation for the shared item grid: "< Page X / Y >", centered
		below the grid. Only shown once there's more than one page -- with
		GetBagsPerPage() bags equipped or fewer, there's nothing to page
		through and the bar stays hidden.
--]]

local Bagnon = LibStub('AceAddon-3.0'):GetAddon('Bagnon')
local PageBar = Bagnon.Classy:New('Frame')
Bagnon.ExtBankPageBar = PageBar

local BUTTON_WIDTH = 24
local BUTTON_HEIGHT = 20
local GAP = 8


--[[ Constructor ]]--

function PageBar:New(frameID, parent)
	local f = self:Bind(CreateFrame('Frame', nil, parent))
	f:SetHeight(BUTTON_HEIGHT)
	f:SetFrameID(frameID)
	f:Hide()

	f:CreatePrevButton()
	f:CreateNextButton()
	f:CreateText()

	-- Registered unconditionally here, not gated to OnShow/OnHide -- same
	-- reasoning as bagFrame.lua's own always-on BAG_FRAME_SHOW/HIDE
	-- registration. UpdateShown() is the only thing that ever Shows this bar
	-- (it starts Hidden, above), so if listening stopped the moment it Hid
	-- itself for having just one page, nothing would ever notice a later
	-- change -- equipping another bag, say -- push the count back above
	-- one, and it would stay hidden forever after its first single-page
	-- open.
	f:RegisterMessage('ITEM_FRAME_PAGE_UPDATE')

	-- UpdateShown(), not the full Update() every later pass uses -- the
	-- relayout nudge Update() sends must not fire from in here, for exactly
	-- the reason bagFrame.lua's own constructor comment spells out: we're
	-- built from inside Frame:CreatePageBar, which doesn't assign
	-- self.pageBar until we return, so a BAG_FRAME_UPDATE_SHOWN sent now
	-- would reach core Frame:Layout() -> our PlaceItemFrame ->
	-- `GetPageBar() or CreatePageBar()` with GetPageBar() still nil, and
	-- build another PageBar, which does the same, without bound.
	--
	-- Nothing is lost by staying quiet: whoever is building us is
	-- PlaceItemFrame itself, mid-layout, and it reads our IsShown() the
	-- moment CreatePageBar returns -- in that same pass.
	--
	-- Which is also why UpdateShown()'s own Show() is fine here, and why the
	-- rule is specifically "send no message", not "never Show()": PlaceItemFrame
	-- reads IsShown() to decide how much height to hand back, so a bar that
	-- stayed hidden through its own construction would have its footprint left
	-- out of the very layout pass that built it.
	--
	-- That safety rests on one thing: this class sets NO OnShow script. Show()
	-- therefore fires nothing on the Ears bus and cannot re-enter anything.
	-- Giving PageBar an OnShow -- the natural place to put Update() -- arms the
	-- loop this comment exists to prevent, because Update() DOES send
	-- BAG_FRAME_UPDATE_SHOWN. Contrast bagFrame.lua:64, which does set one, and
	-- correspondingly must not Show() from its constructor at all.
	f:UpdateShown()

	return f
end

function PageBar:CreateText()
	local text = self:CreateFontString(nil, 'ARTWORK', 'GameFontHighlightSmall')
	self.text = text
	return text
end

function PageBar:CreatePrevButton()
	local b = CreateFrame('Button', nil, self, 'UIPanelButtonTemplate')
	b:SetWidth(BUTTON_WIDTH)
	b:SetHeight(BUTTON_HEIGHT)
	b:SetText('<')

	local bar = self
	b:SetScript('OnClick', function()
		bar:ChangePage(-1)
	end)

	self.prevButton = b
	return b
end

function PageBar:CreateNextButton()
	local b = CreateFrame('Button', nil, self, 'UIPanelButtonTemplate')
	b:SetWidth(BUTTON_WIDTH)
	b:SetHeight(BUTTON_HEIGHT)
	b:SetText('>')

	local bar = self
	b:SetScript('OnClick', function()
		bar:ChangePage(1)
	end)

	self.nextButton = b
	return b
end


--[[ Messages ]]--

function PageBar:ITEM_FRAME_PAGE_UPDATE(msg, frameID)
	if frameID == self:GetFrameID() then
		self:Update()
	end
end


--[[ Actions ]]--
-- The buttons' own non-mouse-wheel fallback for exactly the same page
-- change ItemFrame:OnMouseWheel drives (see itemFrame.lua) -- both end up
-- at the same ItemFrame:SetCurrentPage, which clamps and no-ops at either
-- end, so there's no separate bounds-checking needed here.

function PageBar:ChangePage(delta)
	local itemFrame = self:GetItemFrame()
	if itemFrame then
		itemFrame:SetCurrentPage(itemFrame:GetCurrentPage() + delta)
	end
end

-- This bar is always parented directly to the outer ExtBank Frame (see
-- frame.lua's CreatePageBar), which has its own GetItemFrame() inherited
-- unchanged from core.
function PageBar:GetItemFrame()
	local parent = self:GetParent()
	return parent and parent:GetItemFrame()
end


--[[ Update ]]--

-- Whether this bar is on screen is part of the outer window's vertical
-- budget (see frame.lua's PlaceItemFrame, which folds our footprint into the
-- height it hands back), but PlaceItemFrame only ever re-reads IsShown()
-- during an outer Frame:Layout() -- and nothing about us showing or hiding
-- triggers one by itself. The item grid's own size change is the usual thing
-- that does, and it can't be relied on here: the grid is a fixed width by
-- design (see itemFrame.lua's "Fixed grid width"), and its height only tracks
-- the CURRENT page's slots -- so gaining or losing a bag that lands on some
-- other page leaves the grid writing byte-identical dimensions, firing no
-- OnSizeChanged and no ITEM_FRAME_SIZE_CHANGE. Crossing 1 <-> 2 pages that way
-- (equipping a bag with GetBagsPerPage() already equipped, say) would show the
-- bar inside a window that never made the 26px of room for it -- drawn down
-- into the money row and the backdrop's bottom border -- or, unhiding, leave
-- that much dead space behind.
--
-- So say so ourselves. BAG_FRAME_UPDATE_SHOWN is core Frame's generic "my
-- contents changed size, lay yourself out again" message (Bagnon/components/
-- frame.lua), not something specific to the bag strip -- bagFrame.lua sends
-- the same one for the same reason. Safe to send from here: the Layout() it
-- triggers reads our IsShown() without ever calling back into Update(), so
-- there's no recursion of the kind bagFrame.lua's constructor comment warns
-- about.
--
-- Only on an actual transition, not on every page flip: page 3 -> 4 changes
-- the label text but not the footprint, and the outer window is a fixed
-- width wider than this bar at every column count (the grid's own 4-column
-- floor is already wider than the bar's ~124px), so PlaceItemFrame's
-- math.max(w, pageBar:GetWidth()) can't change either.
function PageBar:Update()
	local wasShown = self:IsShown()
	self:UpdateShown()

	if self:IsShown() ~= wasShown then
		self:SendMessage('BAG_FRAME_UPDATE_SHOWN', self:GetFrameID())
	end
end

function PageBar:UpdateShown()
	local itemFrame = self:GetItemFrame()
	local count = itemFrame and itemFrame:GetPageCount() or 1

	if count <= 1 then
		self:Hide()
		return
	end

	local page = itemFrame:GetCurrentPage()
	self.text:SetText(('Page %d / %d'):format(page, count))

	if page <= 1 then
		self.prevButton:Disable()
	else
		self.prevButton:Enable()
	end

	if page >= count then
		self.nextButton:Disable()
	else
		self.nextButton:Enable()
	end

	self:Layout()
	self:Show()
end

-- Sized to exactly wrap its three children (rather than stretched to fill
-- some fixed width) so that anchoring this bar's own TOP to the item
-- grid's BOTTOM (see frame.lua's CreatePageBar) centers the buttons+text
-- as a group under the grid, not just this frame's bounds under it.
function PageBar:Layout()
	self.prevButton:ClearAllPoints()
	self.prevButton:SetPoint('LEFT', self, 'LEFT', 0, 0)

	self.text:ClearAllPoints()
	self.text:SetPoint('LEFT', self.prevButton, 'RIGHT', GAP, 0)

	self.nextButton:ClearAllPoints()
	self.nextButton:SetPoint('LEFT', self.text, 'RIGHT', GAP, 0)

	local width = self.prevButton:GetWidth() + GAP + self.text:GetStringWidth() + GAP + self.nextButton:GetWidth()
	self:SetWidth(width)
end


--[[ Properties ]]--

-- SetFrameID/GetFrameID come from Bagnon.ExtBankWidget
-- (components/widget.lua). GetSettings comes with them and is unused here --
-- harmless, and cheaper than carving the mixin up per class.
Bagnon.ExtBankWidget:Apply(PageBar)
