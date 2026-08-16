--[[
	itemFrame.lua
		The shared item grid: every bag-slot toggled on in the strip pours
		its items into one continuously-growing flowing grid here
--]]

local Bagnon = LibStub('AceAddon-3.0'):GetAddon('Bagnon')
local ExtBank = Bagnon.ExtBank
local ItemFrame = Bagnon.Classy:New('Frame')
ItemFrame:Hide()
Bagnon.ExtBankItemFrame = ItemFrame

ItemFrame.ITEM_SIZE = 39


--[[ Constructor ]]--

-- Bagnon_GuildBank's own item frame uses this exact pattern (see its
-- itemFrame.lua) for a real reason: repositioning every item slot
-- (ClearAllPoints + SetPoint) is cheap once, but EXTBANK_MODEL_UPDATED can
-- arrive several times in a burst (one packet can cover several cell
-- changes), and calling Layout() synchronously on every single one of them
-- means re-anchoring every slot's frame several times in a row -- including
-- whichever one the mouse happens to be sitting on, which was tearing its
-- tooltip down mid-hover. Collapsing any burst into a single deferred pass
-- (shown this frame, applies and hides itself the next) fixes that.
local function throttledUpdater_OnUpdate(self)
	local p = self:GetParent()
	if p:NeedsLayout() then
		p:Layout()
	end
	self:Hide()
end

function ItemFrame:New(frameID, parent)
	local f = self:Bind(CreateFrame('Frame', nil, parent))

	f.itemSlots = {}
	f.currentPage = 1
	f.throttledUpdater = CreateFrame('Frame', nil, f)
	f.throttledUpdater:SetScript('OnUpdate', throttledUpdater_OnUpdate)

	f:SetFrameID(frameID)

	-- No SetScript('OnEvent', ...) here, unlike core's own itemFrame.lua:
	-- everything this frame reacts to is a Bagnon.Callbacks message, and those
	-- never travel through the OnEvent script -- see UpdateEvents below.
	f:SetScript('OnShow', f.OnShow)
	f:SetScript('OnHide', f.OnHide)
	f:SetScript('OnSizeChanged', f.OnSizeChanged)

	-- See "Pagination" below -- lets the player flip pages by scrolling over
	-- the grid itself, same gesture Blizzard's own paginated UIs (auction
	-- house, trainer, ...) use, with the page bar's prev/next buttons as the
	-- non-mouse-wheel fallback.
	f:EnableMouseWheel(true)
	f:SetScript('OnMouseWheel', f.OnMouseWheel)

	-- We're built lazily, the first time the outer window lays itself out
	-- while ALREADY visible (PlaceItemFrame(), called from that window's own
	-- OnShow) -- so we come into existence already effectively shown, with
	-- no hidden->shown transition for our own OnShow to ever catch. Blizzard
	-- only fires OnShow on a genuine transition, so relying on it here would
	-- mean this first construction never registers EXTBANK_MODEL_UPDATED (or
	-- anything else) at all -- the window would stay empty even once the
	-- model arrives, since nothing's listening for it yet. Every later
	-- close/reopen is a real transition (we exist and get genuinely
	-- Hidden/Shown by then), so this only ever matters this one time; same
	-- reasoning as the explicit Hide()+Show() item.lua's own ItemSlot:New
	-- already uses for the same kind of frame-just-built-while-parent's-
	-- already-shown gap.
	--
	-- Call the full OnShow sequence, not just UpdateEverything() -- the
	-- event/message registration itself lives in UpdateEvents(), which only
	-- OnShow calls; UpdateEverything() alone reloads slots (finding nothing
	-- yet, hence the undersized first layout) but never subscribes us to
	-- hear about the real data once it arrives.
	f:OnShow()

	return f
end


--[[ Messages ]]--
-- Every handler below is a Bagnon.Callbacks (Ears) message handler, reached by
-- RegisterMessage in UpdateEvents. Ears resolves the handler at registration
-- time -- `action = obj[method]`, method defaulting to the message name -- and
-- then calls it directly (utility/ears.lua), so the method name matching the
-- message name is the whole binding. It looks exactly like core itemFrame.lua's
-- OnEvent name-dispatch (`local action = self[event]`) and that resemblance is
-- what made copying core's OnEvent alongside these handlers seem necessary, but
-- the two are unrelated lanes: OnEvent only ever carries real Blizzard events
-- delivered to a frame that called RegisterEvent. Core registers several
-- (ITEM_LOCK_CHANGED for real container-slot locking, QUEST_ACCEPTED /
-- UNIT_QUEST_LOG_CHANGED for quest-item highlighting); none apply to these
-- virtual vault cells -- they aren't real container slots to lock, and these
-- cells don't draw a quest overlay. Vault data arrives only as
-- EXTBANK_MODEL_UPDATED, sent at the end of ParsePacket (core/model.lua),
-- which core/nativeHooks.lua's ExtBank_OnPacket hook feeds. So there is no
-- event lane here, and no OnEvent dispatcher to go with it.

function ItemFrame:EXTBANK_MODEL_UPDATED()
	self:UpdateEverything()
end

function ItemFrame:BAG_SLOT_SHOW(msg, frameID, bagIndex)
	if frameID == self:GetFrameID() then
		self:UpdateEverything()
	end
end

function ItemFrame:BAG_SLOT_HIDE(msg, frameID, bagIndex)
	if frameID == self:GetFrameID() then
		self:UpdateEverything()
	end
end

function ItemFrame:ITEM_FRAME_SPACING_UPDATE(msg, frameID)
	if frameID == self:GetFrameID() then
		self:RequestLayout()
	end
end

function ItemFrame:ITEM_FRAME_COLUMNS_UPDATE(msg, frameID)
	if frameID == self:GetFrameID() then
		self:RequestLayout()
	end
end

function ItemFrame:SLOT_ORDER_UPDATE(msg, frameID)
	if frameID == self:GetFrameID() then
		self:RequestLayout()
	end
end

function ItemFrame:ITEM_FRAME_BAG_BREAK_UPDATE(msg, frameID)
	if frameID == self:GetFrameID() then
		self:RequestLayout()
	end
end

-- Unlike columns/spacing/bag-break above, changing the per-page bag count
-- shifts which bags fall on which page -- a plain RequestLayout (just
-- repositioning already-built item slots) isn't enough, the set of item
-- slots that should even exist can change. Reset to page 1 rather than try
-- to preserve "roughly the same bags" across a page-size change -- keeps
-- the result predictable instead of doing arithmetic nobody would notice
-- was trying to be clever.
function ItemFrame:ITEM_FRAME_BAGS_PER_PAGE_UPDATE(msg, frameID)
	if frameID == self:GetFrameID() then
		self.currentPage = 1
		self:UpdateEverything()
	end
end

-- Text search is a single addon-wide filter shared by every Bagnon window,
-- not scoped to a frameID -- same as core Bagnon's own item slots.
function ItemFrame:TEXT_SEARCH_UPDATE()
	for _, itemSlot in pairs(self.itemSlots) do
		itemSlot:UpdateSearch()
	end
end

-- Likewise addon-wide, not per-frame: General options > "Display a background
-- for empty item slots" (Bagnon.Settings:SetShowEmptyItemSlotTexture).
-- item.lua's GetEmptyItemTexture already reads the live value every time a
-- cell draws, so the setting was never actually being ignored -- what was
-- missing is something to make the cells redraw at the moment it changes.
-- Without this the new value only landed on the next reload the grid happened
-- to do for some other reason -- in practice the next OnShow -- so the player
-- had to close and reopen Void Storage to see a change their bag, bank and
-- guild bank windows all picked up instantly.
--
-- Full Update() per cell rather than just re-setting the texture, matching
-- what core Bagnon's and Bagnon_GuildBank's own item slots do for this same
-- message -- the empty/occupied branch that picks the texture is inside
-- Update(), so there's nothing narrower to call that would still be correct.
function ItemFrame:SHOW_EMPTY_ITEM_SLOT_TEXTURE_UPDATE()
	for _, itemSlot in pairs(self.itemSlots) do
		itemSlot:Update()
	end
end


--[[ Frame Events ]]--

function ItemFrame:OnShow()
	self:UpdateEvents()
	self:UpdateEverything()
end

function ItemFrame:OnHide()
	self:UnregisterAllMessages()
end

-- The outer Frame (inherited from core, see frame.lua) sizes/positions
-- itself and the money frame below us by reading our GetWidth()/GetHeight()
-- during its OWN synchronous Layout() -- but ours only actually changes size
-- later, whenever the throttled updater above finally applies a deferred
-- Layout(). Without telling the outer Frame when that happens, it never
-- re-runs its own Layout() to catch up, so it's stuck sized for whatever we
-- measured at (last session's size on a reopen, 0x0 with nothing cached
-- yet), and cells drawn at our new size spill past its border and behind the
-- money frame. Core Bagnon's own itemFrame.lua wires this exact
-- OnSizeChanged->message bridge for the same reason; the outer Frame class
-- already listens for ITEM_FRAME_SIZE_CHANGE (it's core's, inherited
-- unchanged), it just never had anything telling it to fire for us.
function ItemFrame:OnSizeChanged()
	self:SendMessage('ITEM_FRAME_SIZE_CHANGE', self:GetFrameID())
end

-- delta is 1 for wheel-up, -1 for wheel-down -- same "up/back, down/forward"
-- convention as the page bar's own prev/next buttons (see pageBar.lua),
-- wheel-up meaning "earlier page" the way scrolling up means "earlier
-- content" everywhere else in the client.
function ItemFrame:OnMouseWheel(delta)
	if delta > 0 then
		self:SetCurrentPage(self:GetCurrentPage() - 1)
	else
		self:SetCurrentPage(self:GetCurrentPage() + 1)
	end
end

function ItemFrame:UpdateEvents()
	self:UnregisterAllMessages()

	if self:IsVisible() then
		self:RegisterMessage('EXTBANK_MODEL_UPDATED')
		self:RegisterMessage('BAG_SLOT_SHOW')
		self:RegisterMessage('BAG_SLOT_HIDE')
		self:RegisterMessage('ITEM_FRAME_SPACING_UPDATE')
		self:RegisterMessage('ITEM_FRAME_COLUMNS_UPDATE')
		self:RegisterMessage('SLOT_ORDER_UPDATE')
		self:RegisterMessage('ITEM_FRAME_BAG_BREAK_UPDATE')
		self:RegisterMessage('ITEM_FRAME_BAGS_PER_PAGE_UPDATE')
		self:RegisterMessage('TEXT_SEARCH_UPDATE')
		self:RegisterMessage('SHOW_EMPTY_ITEM_SLOT_TEXTURE_UPDATE')
	end
end


--[[ Item Slot Management ]]--

function ItemFrame:UpdateEverything()
	if not self:IsVisible() then return end

	-- The set of bags on the current page can shrink out from under the
	-- player (unequipping one, or a model update that drops the total
	-- below what the old page needed) -- clamp before reloading so
	-- ReloadAllItemSlots/Layout below see a page that actually exists.
	local pageCount = self:GetPageCount()
	if self:GetCurrentPage() > pageCount then
		self.currentPage = pageCount
	end

	self:ReloadAllItemSlots()
	self:RequestLayout()

	-- Cheap even when nothing pagination-related actually changed (a plain
	-- FontString update plus a couple of button Enable/Disable calls) --
	-- see pageBar.lua's own ITEM_FRAME_PAGE_UPDATE handler -- so it's sent
	-- unconditionally here rather than tracked for an exact "did the page
	-- count change" diff.
	self:SendMessage('ITEM_FRAME_PAGE_UPDATE', self:GetFrameID())
end

function ItemFrame:AddItemSlot(bagIndex, slot)
	local itemSlot = Bagnon.ExtBankItemSlot:New(bagIndex, slot, self:GetFrameID(), self)
	self.itemSlots[self:GetSlotIndex(bagIndex, slot)] = itemSlot
end

function ItemFrame:GetItemSlot(bagIndex, slot)
	return self.itemSlots[self:GetSlotIndex(bagIndex, slot)]
end

function ItemFrame:GetSlotIndex(bagIndex, slot)
	return bagIndex * 100 + slot
end

-- Confirmed empirically (not just theorized): Free()'ing a drag's origin
-- slot mid-drag -- Hide() plus SetParent(nil) -- cancels the native WoW
-- drag outright, before OnDragStop/OnReceiveDrag ever get a chance to
-- fire, so the move never happens (pickSrc is left set, recoverable only
-- via a later plain click on a valid destination). So the origin slot has
-- to stay alive -- Shown and parented -- for exactly as long as the drag
-- is active, which is what DRAG_PARK_OFFSET below is for.
local DRAG_PARK_OFFSET = -100000 -- far enough off the actual viewport to never render or overlap anything real

-- Removes any item slot no longer valid (its bag was unequipped, hidden,
-- shrank, unlocked-then-relocked, or paged away from), adds any newly-
-- needed ones, and updates the rest in place.
--
-- The slot currently being click-and-held-dragged (see SetDraggingSlot
-- below) is exempted from Free() even if its own bag just paged out from
-- under it -- see DRAG_PARK_OFFSET above for why. Left fully alive and
-- shown, but parked far off-screen rather than left at its last on-grid
-- position: a stale, still-visible, still-mouse-interactive button sitting
-- exactly where the new page happens to render a real cell would either
-- look like a rendering glitch (if merely faded) or actively intercept
-- clicks meant for that real cell underneath it -- parking it somewhere no
-- cursor will ever be avoids both. Restored to the grid the moment its bag
-- is part of the current page again by the normal Layout pass below, same
-- as any other current-page slot; OnDragStop's own forced reload (see
-- SetDraggingSlot) actually frees it for real once the drag ends and it's
-- still off-page.
function ItemFrame:ReloadAllItemSlots()
	local itemSlots = self.itemSlots
	local draggingSlot = self:GetDraggingSlot()

	-- Worked out once for the whole pass, not per slot. Answering "is this
	-- bag on the current page?" from scratch means a full scan of all 70
	-- settings bag slots plus two throwaway lists (GetCurrentPageBags ->
	-- GetAllVisibleBags), and both loops below run over every cell on the
	-- page -- up to GetBagsPerPage() x 36 of them. Asked per cell, on every
	-- EXTBANK_MODEL_UPDATED (which arrive in bursts, see the throttled
	-- updater up in the constructor), that would be hundreds of table
	-- allocations and tens of thousands of iterations for a single reload.
	--
	-- Membership in this set is the entire visibility test on its own:
	-- GetCurrentPageBags slices GetAllVisibleBags, which only ever yields
	-- bags that are toggled on (GetVisibleBagSlots) and still equipped
	-- (GetBagSize > 0), so a bag reaching here has already passed both --
	-- see "Pagination" below for why paging drops a bag from this set
	-- rather than just visually hiding its cells.
	local pageBags = self:GetCurrentPageBags()
	local onPage = {}
	for _, bagIndex in ipairs(pageBags) do
		onPage[bagIndex] = true
	end

	for i, itemSlot in pairs(itemSlots) do
		local bagIndex, slot = itemSlot:GetSlot()
		local stillValid = onPage[bagIndex] and slot < self:GetBagSize(bagIndex)

		if itemSlot == draggingSlot then
			if not stillValid then
				itemSlot:ClearAllPoints()
				itemSlot:SetPoint('CENTER', UIParent, 'CENTER', 0, DRAG_PARK_OFFSET)
			end
		elseif not stillValid then
			itemSlot:Free()
			itemSlots[i] = nil
		end
	end

	for _, bagIndex in ipairs(pageBags) do
		for slot = 0, self:GetBagSize(bagIndex) - 1 do
			local itemSlot = self:GetItemSlot(bagIndex, slot)
			if not itemSlot then
				self:AddItemSlot(bagIndex, slot)
			else
				itemSlot:Update()
			end
		end
	end
end

-- Set by ItemSlot:OnDragStart/OnDragStop (item.lua) for exactly the
-- duration of a real click-and-hold drag -- see ReloadAllItemSlots above
-- for why paging needs to know this. Clearing it (OnDragStop, drag ended
-- one way or another) immediately re-syncs the item slots to whatever page
-- is actually current now, since the exemption above may have left a
-- since-paged-away slot parked off-screen that a normal reload never got a
-- chance to actually Free() while the drag was protecting it.
function ItemFrame:SetDraggingSlot(itemSlot)
	self.draggingSlot = itemSlot
	if not itemSlot then
		self:UpdateEverything()
	end
end

function ItemFrame:GetDraggingSlot()
	return self.draggingSlot
end


--[[ Layout ]]--

-- Request a (possibly-deferred) layout pass -- see throttledUpdater_OnUpdate
-- up in the constructor section for why this doesn't just call Layout()
-- directly.
function ItemFrame:RequestLayout()
	self.needsLayout = true
	self.throttledUpdater:Show()
end

function ItemFrame:NeedsLayout()
	return self.needsLayout
end

-- Dispatches to whichever of the two layouts below the "Bag Break Layout"
-- setting asks for -- same switch core Bagnon's own itemFrame.lua makes.
function ItemFrame:Layout()
	if self:IsBagBreakEnabled() then
		self:Layout_BagBreak()
	else
		self:Layout_Default()
	end
end

-- One continuous flowing grid across every visible bag -- the same "single
-- huge bag" feel as core Bagnon's own merged bank/bag view (Layout_Default),
-- not a row-per-bag break. A bag boundary never starts a new row by itself;
-- slots just keep filling left-to-right, wrapping at the column count,
-- regardless of which bag they belong to.
function ItemFrame:Layout_Default()
	self.needsLayout = nil

	local columns = self:NumColumns()
	local spacing = self:GetSpacing()
	local effItemSize = self.ITEM_SIZE + spacing

	local i = 0
	for _, bagIndex in self:GetVisibleBags() do
		for slot = 0, self:GetBagSize(bagIndex) - 1 do
			local itemSlot = self:GetItemSlot(bagIndex, slot)
			if itemSlot then
				local row = math.floor(i / columns)
				local col = i % columns
				itemSlot:ClearAllPoints()
				itemSlot:SetPoint('TOPLEFT', self, 'TOPLEFT', effItemSize * col, -effItemSize * row)
				i = i + 1
			end
		end
	end

	-- Always the full column count wide, even with a part-filled last row or
	-- nothing to show at all -- see "Fixed grid width" below.
	local width = effItemSize * math.max(columns, 1) - spacing
	local height = effItemSize * math.max(math.ceil(i / columns), 1) - spacing
	self:SetWidth(math.max(width, 1))
	self:SetHeight(math.max(height, 1))
end

--[[ Fixed grid width ]]--
-- Both layouts here -- Layout_Default above and Layout_BagBreak below --
-- size to the full column count rather than to how many cells actually got
-- placed.
--
-- Height still tracks content -- an empty vault shouldn't reserve a
-- screenful of blank rows -- but the width has to be stable, because the
-- bag-slot strip above us derives its OWN column count from our rendered
-- width (bagFrame.lua's GetColumnCount) and falls back to MIN_COLUMNS when
-- we report nothing. A content-derived width collapses the grid to a cell
-- or two whenever the vault is near-empty -- no bags equipped yet, one bag
-- holding a couple of items -- which drops the strip to its 5-column floor,
-- wrapping all 70 bag slots into 14 rows of icons above an almost-empty
-- grid, then snaps back to full width the moment enough items arrive to
-- fill a row. Pinning the width makes both the window and the strip hold
-- the size the "Columns" slider asks for, whatever is in the vault at the
-- time.

-- Same idea, but each bag always starts its own fresh row -- a bag with
-- slots left over at the end of a row pads out to the next one instead of
-- letting the following bag's items share it. Column/row counting here is
-- 0-based throughout (to match GetSlotIndex/AddItemSlot's own 0-based bag
-- and slot numbering), unlike core Bagnon's 1-based Layout_BagBreak.
function ItemFrame:Layout_BagBreak()
	self.needsLayout = nil

	local columns = self:NumColumns()
	local spacing = self:GetSpacing()
	local effItemSize = self.ITEM_SIZE + spacing

	local row, col = 0, 0

	for _, bagIndex in self:GetVisibleBags() do
		for slot = 0, self:GetBagSize(bagIndex) - 1 do
			local itemSlot = self:GetItemSlot(bagIndex, slot)
			if itemSlot then
				itemSlot:ClearAllPoints()
				itemSlot:SetPoint('TOPLEFT', self, 'TOPLEFT', effItemSize * col, -effItemSize * row)

				col = col + 1
				if col >= columns then
					col = 0
					row = row + 1
				end
			end
		end

		-- force the next bag onto a fresh row, unless this one happened to
		-- end exactly on a column boundary already
		if col > 0 then
			col = 0
			row = row + 1
		end
	end

	local width = effItemSize * math.max(columns, 1) - spacing
	local height = effItemSize * math.max(row, 1) - spacing
	self:SetWidth(math.max(width, 1))
	self:SetHeight(math.max(height, 1))
end


--[[ Bag Info ]]--

function ItemFrame:GetBagSize(bagIndex)
	local bag = ExtBank.bags[bagIndex]
	return bag and bag.size or 0
end

-- Every toggled-on, still-equipped bag (a toggle can outlive its bag being
-- unequipped, hence the size check), in strip order, regardless of
-- pagination -- the full set GetPageCount/GetCurrentPageBags slice pages
-- out of. Not itself paginated: NumColumns/the bag-slot strip and anything
-- else that needs "is there anything to show at all" reads this, only the
-- item grid's own layout/reload needs the paged-down subset.
function ItemFrame:GetAllVisibleBags()
	local list = {}
	for _, bagIndex in self:GetSettings():GetVisibleBagSlots() do
		if self:GetBagSize(bagIndex) > 0 then
			table.insert(list, bagIndex)
		end
	end
	return list
end

-- What Layout_Default/Layout_BagBreak/ReloadAllItemSlots actually draw --
-- just the slice of GetAllVisibleBags that falls on the current page.
function ItemFrame:GetVisibleBags()
	return ipairs(self:GetCurrentPageBags())
end


--[[ Pagination ]]--
-- ExtBank's bag count can run up to 70 bags of up to 36 slots each (2520
-- possible cells) -- showing every equipped bag in one continuously-
-- growing grid, the way Layout_Default/Layout_BagBreak above do for every
-- other Bagnon frame, would make an unusably huge window well before a
-- player got anywhere near that. Paginate by BAG, never splitting one
-- bag's cells across two pages -- each page shows up to GetBagsPerPage()
-- whole bags, with pageBar.lua's page bar (created by frame.lua, below the
-- grid) to navigate between pages, plus this frame's own OnMouseWheel
-- above.
--
-- currentPage itself is deliberately NOT saved -- it's the kind of state
-- (like scroll position in most UIs) that's more surprising to reopen on
-- than to reset, and every settings default in savedFrameSettings.lua's
-- extBankDefaults is a per-frame preference, not per-session position.

function ItemFrame:GetBagsPerPage()
	return self:GetSettings():GetBagsPerPage()
end

function ItemFrame:GetPageCount()
	local total = #self:GetAllVisibleBags()
	return math.max(math.ceil(total / self:GetBagsPerPage()), 1)
end

function ItemFrame:GetCurrentPage()
	return self.currentPage or 1
end

-- Clamped to the valid range -- callers (the page bar's prev/next buttons,
-- this frame's own OnMouseWheel) don't need to know or check the current
-- page count themselves, they can just always ask for one page further in
-- either direction.
function ItemFrame:SetCurrentPage(page)
	page = math.max(1, math.min(page, self:GetPageCount()))
	if page == self:GetCurrentPage() then return end

	self.currentPage = page
	self:UpdateEverything()
end

-- The slice of GetAllVisibleBags that belongs on the current page.
function ItemFrame:GetCurrentPageBags()
	local all = self:GetAllVisibleBags()
	local perPage = self:GetBagsPerPage()
	local startIdx = (self:GetCurrentPage() - 1) * perPage + 1
	local endIdx = math.min(startIdx + perPage - 1, #all)

	local list = {}
	for i = startIdx, endIdx do
		table.insert(list, all[i])
	end
	return list
end


--[[ Frame Properties ]]--

function ItemFrame:SetFrameID(frameID)
	self.frameID = frameID
end

function ItemFrame:GetFrameID()
	return self.frameID
end

function ItemFrame:GetSettings()
	return Bagnon.FrameSettings:Get(self:GetFrameID())
end

function ItemFrame:NumColumns()
	return self:GetSettings():GetItemFrameColumns()
end

function ItemFrame:GetSpacing()
	return self:GetSettings():GetItemFrameSpacing()
end

function ItemFrame:IsBagBreakEnabled()
	return self:GetSettings():IsBagBreakEnabled()
end