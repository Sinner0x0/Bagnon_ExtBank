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
	-- Hidden BEFORE the layout runs, not after. A RequestLayout() issued from
	-- inside Layout() -- or from anything it synchronously triggers, and it
	-- triggers a good deal -- then re-shows this and gets a pass of its own next
	-- frame, instead of being swallowed by a Hide() that came afterwards.
	self:Hide()
	self:GetParent():Layout()
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

-- Not frameID-guarded, unlike everything below it: the vault model is a single
-- global thing, so ParsePacket broadcasts without one (core/model.lua).
function ItemFrame:EXTBANK_MODEL_UPDATED()
	self:UpdateEverything()
end

-- Everything that changes WHICH bags belong on this page. The set of item
-- slots that should exist can change, so these need a full reload, not just a
-- reposition of the slots already built.
--
-- SLOT_ORDER_UPDATE belongs here rather than with the relayout messages below,
-- which is a behaviour fix and not just tidying: core's GetVisibleBagSlots
-- (Bagnon/components/frameSettings.lua) returns a REVERSED iterator when that
-- setting is on, and this frame paginates by slicing that order -- so flipping
-- it moves bags between pages. Routed to RequestLayout, as it used to be, the
-- layout asked GetItemSlot() for cells belonging to bags that had just arrived
-- on this page, got nil for every one of them, and silently drew nothing until
-- some unrelated message forced a reload.
function ItemFrame:OnBagSetChanged(msg, frameID)
	if frameID == self:GetFrameID() then
		self:UpdateEverything()
	end
end

-- Everything that only moves the existing slots around.
function ItemFrame:OnLayoutSettingChanged(msg, frameID)
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
-- The search string is read once here and handed down, rather than each cell
-- fetching it for itself: this fires on every KEYSTROKE and loops every live
-- cell, so a full page was 180 Settings lookups per character typed.
-- `matches` memoizes ItemSearch:Find by itemId for the duration of this one pass.
-- The answer depends only on (itemId, search) and a page holds far fewer distinct
-- items than cells, so this collapses up to 180 Find calls -- each one ~2
-- GetItemInfo plus ~10 pattern matches down inside LibItemSearch -- to one per
-- distinct item.
--
-- Deliberately a fresh table per pass rather than a field kept across them: Find's
-- answer runs through GetItemInfo, which can start resolving mid-session, so a
-- longer-lived memo would latch a miss taken while the item was still uncached --
-- the same way a cached icon lookup would latch a question-mark placeholder. Do
-- not "optimize" this into a persistent cache.
function ItemFrame:TEXT_SEARCH_UPDATE()
	local search = Bagnon.Settings:GetTextSearch()
	local matches = {}
	for _, itemSlot in pairs(self.itemSlots) do
		itemSlot:UpdateSearch(search, matches)
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

-- An in-vault pick was armed or spent (core/cursor.lua's SetPick/ClearPick).
-- Repaints the cue rather than the contents: UpdatePicked is deliberately not part
-- of Update, so this cannot disturb the item cache.
--
-- Every cell, not just the two that changed. Finding which button previously held
-- the highlight would mean tracking it, and the loop is a table index and at most
-- one texture toggle per cell against a message sent only on a real arm or clear --
-- far cheaper than the state it would take to avoid.
function ItemFrame:EXTBANK_PICK_CHANGED()
	for _, itemSlot in pairs(self.itemSlots) do
		itemSlot:UpdatePicked()
	end
end


--[[ Frame Events ]]--

function ItemFrame:OnShow()
	self:UpdateEvents()
	self:UpdateEverything()
end

-- Every message this frame answers is therefore missed for as long as the window
-- is closed, and the addon-wide ones -- TEXT_SEARCH_UPDATE above especially --
-- keep changing while it is. Nothing re-plays them on the way back in, so
-- anything a handler here paints has to be re-derived on show rather than assumed
-- to have survived: ItemSlot:OnShow (components/item.lua) is where the search
-- fade does that, and its comment records what closing over a live search used to
-- leave behind.
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
-- money frame. The outer Frame class already listens for ITEM_FRAME_SIZE_CHANGE
-- (it's core's, inherited unchanged), it just never had anything telling it to
-- fire for us.
--
-- ApplySize below is what sends that message, and is the only writer of this
-- frame's size -- so this handler is a NET, not the live bridge, and its guard is
-- true every single time it runs. Core Bagnon's own itemFrame.lua wires the plain
-- OnSizeChanged->message version and so did we, until the bug in the paragraph
-- below moved the send into ApplySize; what is left here is kept deliberately, as
-- the one thing that would notice a size write arriving by some route other than
-- ApplySize -- a two-anchor placement, a core change to PlaceItemFrame. That
-- failure is silent (a window measured for a grid it no longer holds, no error
-- anywhere), which is what the net is worth two table lookups per resize for.
-- Do NOT read the always-taken early return as proof this is dead and delete
-- ApplySize's SendMessage as its duplicate: that one is the live sender.
--
-- RequestLayout rather than the message directly, and that is the whole reason the
-- flag exists. WoW fires OnSizeChanged synchronously from SetWidth, so a plain
-- SetWidth-then-SetHeight pair sent this message with the width already updated and
-- the height still holding the PREVIOUS pass's value -- and this message is not
-- cheap to answer: it reaches BagFrame:OnItemFrameSizeChange, which re-anchors all
-- 70 strip buttons and then sends BAG_FRAME_UPDATE_SHOWN, driving a full
-- outer-window Frame:Layout() through PlaceItemFrame. So every layout pass paid for
-- two complete window relayouts, the first of them sized from a half-written grid,
-- and on a row count change that intermediate one is briefly on screen. Deferring
-- to the next OnUpdate means both dimensions have landed before anything reacts,
-- and Layout then re-derives the size this frame actually wants (see "Fixed grid
-- width" below -- an outside size write is not something to honour) and leaves the
-- single message to ApplySize. A net that brought the double relayout back with it
-- would be a poor one.
--
-- Safe against its own dependency by construction: New creates throttledUpdater
-- before it registers this script, so RequestLayout can never fire first.
function ItemFrame:OnSizeChanged()
	if self.applyingSize then return end
	self:RequestLayout()
end

-- delta is 1 for wheel-up, -1 for wheel-down -- same "up/back, down/forward"
-- convention as the page bar's own prev/next buttons (see pageBar.lua),
-- wheel-up meaning "earlier page" the way scrolling up means "earlier
-- content" everywhere else in the client.
--
-- Paging deliberately does NOT cancel an outstanding pick, here or in
-- PageBar:ChangePage, and both used to -- which silently removed the reason the
-- pick and the paging exist together. Pick up an item on page 1, page to page 3,
-- click an empty cell: that cross-page move is the mechanic, and clearing on the
-- page step made the second click re-arm a fresh pick instead of completing the
-- move. Within one page the player can see both cells at once and drag.
--
-- The reasoning the clear carried -- "the grid re-flows, so the pick would
-- complete itself onto whatever cell now occupies that spot" -- confuses a screen
-- position with a vault address. pickSrc is { bagIndex, slot }, absolute
-- coordinates the server understands; paging changes only which cells are
-- rendered, never what those coordinates name. And the destination is not the
-- spot the origin used to sit in, it is whatever cell the player actually clicks,
-- read off that cell's own bagIndex/slot in DropCarriedItem. So there was no
-- re-flow hazard to fix.
--
-- What paging does cost is the cue: ItemSlot:UpdatePicked highlights the ORIGIN
-- cell, which is off-screen once you page away, so a pick abandoned mid-move is
-- invisible again until you page back. That is the real half of the concern, and
-- it is not worth paying for with the feature -- Frame:OnHide still clears on
-- every close path, so the state cannot outlive the window. See non-issues.md §13.
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

		self:RegisterMessage('BAG_SLOT_SHOW', 'OnBagSetChanged')
		self:RegisterMessage('BAG_SLOT_HIDE', 'OnBagSetChanged')
		self:RegisterMessage('SLOT_ORDER_UPDATE', 'OnBagSetChanged')

		self:RegisterMessage('ITEM_FRAME_SPACING_UPDATE', 'OnLayoutSettingChanged')
		self:RegisterMessage('ITEM_FRAME_COLUMNS_UPDATE', 'OnLayoutSettingChanged')
		self:RegisterMessage('ITEM_FRAME_BAG_BREAK_UPDATE', 'OnLayoutSettingChanged')

		self:RegisterMessage('ITEM_FRAME_BAGS_PER_PAGE_UPDATE')
		self:RegisterMessage('TEXT_SEARCH_UPDATE')
		self:RegisterMessage('SHOW_EMPTY_ITEM_SLOT_TEXTURE_UPDATE')
		self:RegisterMessage('EXTBANK_PICK_CHANGED')
	end
end


--[[ Item Slot Management ]]--

function ItemFrame:UpdateEverything()
	-- The single invalidation point for the two cached bag lists below, and the
	-- reason caching them is safe at all: every path that can change which bags
	-- are visible or which page they fall on routes through here -- the model
	-- update, the bag show/hide/reorder messages, the bags-per-page change,
	-- SetCurrentPage, and the drag release. Ahead of the IsVisible() check, so a
	-- change arriving while the window is hidden can't leave a stale list behind
	-- for the next open.
	self:InvalidateVisibleBags()

	if not self:IsVisible() then return end

	-- The set of bags on the current page can shrink out from under the
	-- player (unequipping one, or a model update that drops the total
	-- below what the old page needed) -- clamp before reloading so
	-- ReloadAllItemSlots/Layout below see a page that actually exists.
	self:ClampCurrentPage()

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

-- 256, not 100. core/model.lua reads a bag's `size` straight off the wire as an
-- unsigned byte and nothing clamps it to 36, so a server-side bag of more than
-- 99 slots would collide: bag 3 slot 100 and bag 4 slot 0 both key to 400, and
-- ReloadAllItemSlots' `if not itemSlot` check would then treat bag 4's cell as
-- already built and leave a button still bound to bag 3 sitting in it --
-- rendering one item and moving a different one on click. A full byte of
-- headroom retires the assumption rather than restating it.
local SLOT_INDEX_STRIDE = 256

function ItemFrame:GetSlotIndex(bagIndex, slot)
	return bagIndex * SLOT_INDEX_STRIDE + slot
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
-- The `needsLayout` flag this used to set alongside the Show() was a second
-- copy of throttledUpdater:IsShown(), and the guard reading it could never be
-- false: the flag was set on the line before the only Show() in the addon, and
-- cleared only inside the two Layout_ bodies, which nothing but that one
-- OnUpdate ever reaches.
function ItemFrame:RequestLayout()
	self.throttledUpdater:Show()
end

-- Writes both dimensions before letting anyone hear about either, then sends
-- the one message -- see OnSizeChanged above for what that message costs.
-- Sends nothing when neither dimension actually moved, matching what
-- OnSizeChanged did on its own (WoW does not fire it for a no-op write).
function ItemFrame:ApplySize(width, height)
	width, height = math.max(width, 1), math.max(height, 1)
	if width == self:GetWidth() and height == self:GetHeight() then return end

	self.applyingSize = true
	self:SetWidth(width)
	self:SetHeight(height)
	self.applyingSize = nil

	self:SendMessage('ITEM_FRAME_SIZE_CHANGE', self:GetFrameID())
end

--[[ Fixed grid width ]]--
-- Layout below sizes to the full column count rather than to how many cells
-- actually got placed.
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

-- Places every cell on the current page, in one of the two modes the "Bag
-- Break" setting selects -- the same switch core Bagnon's own itemFrame.lua
-- makes, though core keeps a separate function per mode:
--
--   off  one continuous flowing grid across every visible bag, the same
--        "single huge bag" feel as core's merged bank/bag view. A bag
--        boundary never starts a new row by itself; slots just keep filling
--        left-to-right, wrapping at the column count, regardless of which
--        bag they belong to.
--   on   each bag always starts its own fresh row -- a bag with slots left
--        over at the end of a row pads out to the next one instead of
--        letting the following bag's items share it.
--
-- Kept as one function because the two modes differ in exactly one statement
-- (the per-bag break at the bottom of the outer loop). As two nearly-
-- identical functions they had already drifted apart in how each counted
-- rows for the final height -- one from a running cell count via
-- math.ceil(i / columns), the other from the row cursor directly -- which is
-- the kind of divergence that turns into a real off-by-one the next time
-- only one of them gets edited.
--
-- Column/row counting is 0-based throughout, matching GetSlotIndex and
-- AddItemSlot's own 0-based bag and slot numbering, unlike core's 1-based
-- bag-break layout.
function ItemFrame:Layout()
	local bagBreak = self:IsBagBreakEnabled()
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

		-- Force the next bag onto a fresh row, unless this one happened to
		-- end exactly on a column boundary already. Skipped entirely in
		-- flowing mode, which is the one and only difference between the
		-- two modes this function covers.
		if bagBreak and col > 0 then
			col = 0
			row = row + 1
		end
	end

	-- `row` counts COMPLETED rows only, so a part-filled last one still needs
	-- to be added on. In bag-break mode the loop above has always already
	-- closed it (col is back to 0 once the last bag is done), so `row` alone
	-- used to be enough for that mode; in flowing mode this reproduces the
	-- same number its separate math.ceil(cells / columns) used to.
	local rows = row + (col > 0 and 1 or 0)

	-- Always the full column count wide, even with a part-filled last row or
	-- nothing to show at all -- see "Fixed grid width" above.
	local width = effItemSize * math.max(columns, 1) - spacing
	local height = effItemSize * math.max(rows, 1) - spacing
	self:ApplySize(width, height)
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
-- Cached, and dropped by InvalidateVisibleBags from UpdateEverything.
--
-- Worth caching because of how often one update asks for it: UpdateEverything
-- reaches it through GetPageCount, then again through ReloadAllItemSlots ->
-- GetCurrentPageBags, then a frame later through Layout -> GetVisibleBags ->
-- GetCurrentPageBags, then once more via the ITEM_FRAME_PAGE_UPDATE it sends ->
-- PageBar:UpdateShown -> GetPageCount. core/deposit.lua adds two more per
-- correction. Each of those was a fresh list plus a full walk of all 70
-- settings bag slots, and EXTBANK_MODEL_UPDATED arrives in bursts.
function ItemFrame:InvalidateVisibleBags()
	self.visibleBags = nil
	self.pageBags = nil
end

function ItemFrame:GetAllVisibleBags()
	local list = self.visibleBags
	if not list then
		list = {}
		for _, bagIndex in self:GetSettings():GetVisibleBagSlots() do
			if self:GetBagSize(bagIndex) > 0 then
				list[#list + 1] = bagIndex
			end
		end
		self.visibleBags = list
	end
	return list
end

-- What Layout/ReloadAllItemSlots actually draw -- just the slice of
-- GetAllVisibleBags that falls on the current page.
function ItemFrame:GetVisibleBags()
	return ipairs(self:GetCurrentPageBags())
end


--[[ Pagination ]]--
-- ExtBank's bag count can run up to 70 bags of up to 36 slots each (2520
-- possible cells) -- showing every equipped bag in one continuously-
-- growing grid, the way Layout above does for every other Bagnon frame,
-- would make an unusably huge window well before a player got anywhere
-- near that. Paginate by BAG, never splitting one
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

-- Pulls currentPage back into range without any of SetCurrentPage's side effects
-- -- no reload, no ITEM_FRAME_PAGE_UPDATE. UpdateEverything calls it before
-- rebuilding, and core/deposit.lua's correction calls it after dropping the cached
-- page lists, because that runs from inside ParsePacket where a synchronous
-- UpdateEverything would be both redundant and re-entrant.
function ItemFrame:ClampCurrentPage()
	local pageCount = self:GetPageCount()
	if self:GetCurrentPage() > pageCount then
		self.currentPage = pageCount
	end
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
	local list = self.pageBags
	if not list then
		local all = self:GetAllVisibleBags()
		local perPage = self:GetBagsPerPage()
		local startIdx = (self:GetCurrentPage() - 1) * perPage + 1
		local endIdx = math.min(startIdx + perPage - 1, #all)

		list = {}
		for i = startIdx, endIdx do
			list[#list + 1] = all[i]
		end
		self.pageBags = list
	end
	return list
end


--[[ Frame Properties ]]--

-- SetFrameID/GetFrameID/GetSettings come from Bagnon.ExtBankWidget
-- (components/widget.lua) -- see the Apply call at the bottom of this file.

function ItemFrame:NumColumns()
	return self:GetSettings():GetItemFrameColumns()
end

function ItemFrame:GetSpacing()
	return self:GetSettings():GetItemFrameSpacing()
end

function ItemFrame:IsBagBreakEnabled()
	return self:GetSettings():IsBagBreakEnabled()
end


Bagnon.ExtBankWidget:Apply(ItemFrame)