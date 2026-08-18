--[[
	frame.lua
		A specialized Bagnon frame for ExtBank: the bag-slot strip on top,
		the shared item grid below
--]]

local Bagnon = LibStub('AceAddon-3.0'):GetAddon('Bagnon')
local ExtBank = Bagnon.ExtBank
local Frame = Bagnon.Classy:New('Frame', Bagnon.Frame)
Bagnon.ExtBankFrame = Frame


--[[ Components ]]--

function Frame:CreateBagFrame()
	local f = Bagnon.ExtBankBagFrame:New(self:GetFrameID(), self)
	self.bagFrame = f
	return f
end

function Frame:CreateItemFrame()
	local f = Bagnon.ExtBankItemFrame:New(self:GetFrameID(), self)
	self.itemFrame = f
	return f
end


--[[ Pagination ]]--
-- The page bar (see components/pageBar.lua) always lives directly below
-- the item grid, centered, whether or not it currently has anything to
-- show (see PageBar:Update -- it hides itself down to zero height when
-- there's only one page). Anchored once here, at creation -- it's anchored
-- to the item frame itself (a live anchor, not a snapshot of its position
-- at this moment), so it doesn't need re-anchoring on every relayout the
-- way PlaceItemFrame's returned width/height below does.
local PAGE_BAR_GAP = 6

function Frame:GetPageBar()
	return self.pageBar
end

function Frame:CreatePageBar()
	local f = Bagnon.ExtBankPageBar:New(self:GetFrameID(), self)
	f:SetPoint('TOP', self:GetItemFrame(), 'BOTTOM', 0, -PAGE_BAR_GAP)
	self.pageBar = f
	return f
end

-- core's own PlaceItemFrame (Bagnon/components/frame.lua) sizes/positions
-- just the grid; wrapped here to fold the page bar's own footprint into
-- the height/width it hands back to Frame:Layout(), the same "w, h" every
-- other PlaceX method in that stacking sequence returns. PlaceMoneyFrame
-- (core, unmodified, runs right after this) anchors to the WINDOW's own
-- bottom edge rather than to the item frame directly -- so as long as the
-- height this returns includes the page bar's real footprint, the money
-- frame naturally ends up seated below it with no gap or overlap, with no
-- need to touch PlaceMoneyFrame itself.
local super_PlaceItemFrame = Frame.PlaceItemFrame
function Frame:PlaceItemFrame()
	local w, h = super_PlaceItemFrame(self)

	local pageBar = self:GetPageBar() or self:CreatePageBar()
	if pageBar:IsShown() then
		return math.max(w, pageBar:GetWidth()), h + PAGE_BAR_GAP + pageBar:GetHeight()
	end

	return w, h
end

-- HasBagFrame, HasBagToggle and IsBagFrameShown are all left to core here.
--
-- HasBagFrame is deliberately not overridden: nothing in this addon needs
-- the strip to be unconditionally present. Core's PlaceBagFrame,
-- PlaceItemFrame and PlaceMenuButtons each guard on HasBagFrame() and lay
-- out correctly without it, and nothing outside bagFrame.lua itself ever
-- calls GetBagFrame(). So it falls through to core's settings-backed
-- version (self:GetSettings():HasBagFrame(), defaulting true -- see
-- savedFrameSettings.lua), which keeps the value driving the layout and the
-- value the options checkbox displays as one and the same.
--
-- The matching "Enable Bag Frame" checkbox is grayed out for this frame all
-- the same (see components/frameOptions.lua), so in practice the setting
-- stays parked on that default -- exactly how core treats its own 'keys'
-- frame, which likewise has a real hasBagFrame default behind a grayed box.
--
-- HasBagToggle keeps core's own default (always true) -- that icon
-- (Bagnon.BagToggle) is created automatically by core's PlaceMenuButtons on
-- the same line as the search icon, right where it belongs, no custom button
-- of our own needed. IsBagFrameShown is likewise unoverridden -- it just
-- reads FrameSettings:IsBagFrameShown(), and components/frameSettings.lua's
-- "Bag-frame-shown persistence" section is what redirects that (frameID
-- 'extbank' only) to a real saved setting defaulting to shown, rather than
-- every other frame
-- type's session-only flag that always starts hidden. Nothing here needs to
-- know the difference -- it's still just reading IsBagFrameShown() like every
-- other frame type does.

-- Read-only gold display, same as the regular bag/bank window's -- core's
-- own Bagnon.MoneyFrame just reads the player's real GetMoney(), no
-- deposit/withdraw, so it works here unmodified. Unlike HasBagFrame above,
-- whose checkbox is grayed out, this one stays a live per-frame toggle
-- players might want off -- no override here at all, so it falls through
-- Classy's metatable to core Frame:HasMoneyFrame()
-- (self:GetSettings():HasMoneyFrame()) unchanged.

function Frame:HasPlayerSelector()
	return false
end


--[[ Native close sync ]]--
-- The native "Void Storage" toggle button (pinned to the bank window) and
-- the /extbank, /voidstorage slash commands all branch on a plain `isOpen`
-- upvalue inside extBank.lua -- `if isOpen then ExtBank_Close() else
-- ExtBank_Open() end` -- that only ever flips inside its own ExtBank_Open/
-- ExtBank_Close. Nothing about *our* window closing (the X button up in
-- core's own CreateCloseButton, Escape-to-close, ...) ever told that upvalue
-- anything, so it kept believing the vault was still open after the player
-- closed our window by any means other than a real ExtBank_Close() call.
--
-- That's what caused "click Void Storage twice to reopen it": the first
-- click saw isOpen still true and called ExtBank_Close() instead -- a
-- no-op as far as the player could see, since our window was already
-- closed -- and only the second click, with isOpen now correctly false,
-- actually reached ExtBank_Open() and showed anything.
--
-- Frame:OnHide (core, Bagnon/components/frame.lua) is the one funnel every
-- in-session close path already runs through -- including the "hidden by
-- non-Bagnon means" case it exists to catch -- so hooking it here, rather
-- than the close button specifically, covers Escape as well as the X. A
-- /reload is NOT one of those paths -- OnHide scripts do not run on a UI
-- reload -- and needs no covering: the reload restarts the Lua VM, so
-- extBank.lua is re-read from scratch and its isOpen upvalue starts false
-- again on its own. Don't rely on OnHide firing at reload time.
--
-- ExtBank_Close() is safe to call unconditionally: extBank.lua's own
-- version no-ops gracefully on an already-closed vault (see its own
-- `if frame then frame:Hide() end` and similar guards), and the
-- closingFromNative flag (see HookNativeGlobals in core/nativeHooks.lua)
-- skips this when we're already hiding *because* a real ExtBank_Close() just
-- ran, so a native-triggered close doesn't loop back into calling it a
-- second, redundant time.
--
-- Being that funnel is also why every bit of in-flight click state gets dropped
-- here (the in-vault virtual pick, any armed deposit correction, and the
-- purchase-confirm popup -- see ExtBank:ClearPick in core/cursor.lua,
-- ExtBank:ClearPendingDeposit in core/deposit.lua, and
-- BagFrame.UNLOCK_POPUP in bagFrame.lua) rather than in
-- ExtBank:OnNativeClose: a native close hides this frame, so it lands right
-- back here anyway, while the X and Escape paths never reach OnNativeClose
-- at all. Nothing about a click made against the old window should still be
-- waiting to act once that window is gone.
--
-- ClearPendingDeposit is the one of the three that is ALSO called from
-- OnNativeClose, and that duplication is deliberate -- do not drop it there as
-- redundant. "A native close hides this frame" only lands back here for a frame
-- that was actually SHOWN; deposits arm for the whole native session
-- (IsVaultSessionOpen), including the first-snapshot wait and the give-up after
-- it, where the window has never been Show()n and Hide() on it runs no OnHide
-- script at all. The pick and the popup need no such twin: both can only be
-- created by clicking inside our own window, so neither can exist in that
-- never-shown state. OnNativeClose documents its half.
--
-- The popup in particular outlives the window it was raised from unless it's
-- hidden explicitly -- StaticPopups are parented to UIParent, not to us -- so
-- an unanswered "Unlock bag slot N?" would sit on screen after the vault
-- closed and send ExtBankUnlock() outside a vault session whenever the player
-- got round to clicking Yes. extBank.lua's own ExtBank_Close hides the native
-- UI's EXTBANK_UNLOCK_CONFIRM for exactly this reason; ours is a separate
-- dialog and needs its own hide. Safe unconditionally: StaticPopup_Hide only
-- touches dialog frames currently showing that name, and hiding one runs no
-- OnCancel.
local super_OnHide = Frame.OnHide
function Frame:OnHide()
	ExtBank:ClearPick()
	ExtBank:ClearPendingDeposit()
	StaticPopup_Hide(Bagnon.ExtBankBagFrame.UNLOCK_POPUP)

	-- The drag exemption belongs to the same "in-flight click state" family as
	-- the two clears above, and for the same reason -- closing the window is the
	-- end of the gesture. It needs saying explicitly because ItemSlot:OnDragStop
	-- is its only other clearer, and closing mid-drag is exactly the case that
	-- never reaches it: hiding a slot cancels WoW's native drag outright,
	-- before OnDragStop fires (itemFrame.lua documents this for the paging
	-- case). Left set, the next open still treats that button as a live drag
	-- origin -- permanently exempt from Free(), re-parked off-screen every
	-- pass -- until some later real drag happens to overwrite it.
	local itemFrame = self:GetItemFrame()
	if itemFrame then
		itemFrame:SetDraggingSlot(nil)
	end

	if not ExtBank.closingFromNative and type(_G.ExtBank_Close) == 'function' then
		_G.ExtBank_Close()
	end
	super_OnHide(self)
end

-- Bagnon.Sorting hardcodes PickupContainerItem against real bagIDs, so it
-- can't drive ExtBankMove at all without a from-scratch rewrite -- keep it
-- off rather than show a "Clean" button that would silently do nothing
-- (or worse, error). Text search (item.lua's UpdateSearch) doesn't have
-- that problem -- it's just filtering our own already-known cell data -- so
-- that one's wired up for real and left on (see savedFrameSettings.lua).
--
-- Unlike HasBagFrame above, this one can't be handed back to the setting at
-- all -- there's no value the player could pick that would make sorting work
-- here. Its checkbox is grayed out for this frame too (see
-- components/frameOptions.lua), which is how core itself says "this
-- component doesn't apply here".
function Frame:HasSortButton()
	return false
end


--[[ Title ]]--
-- Core Bagnon's TitleFrame:GetTitleText only special-cases a fixed set of
-- hardcoded frameIDs and falls back to the regular-bags title otherwise --
-- it has no branch for ours. Wrap it instead of editing the vendored file,
-- same idea as the saved-settings monkeypatch in savedFrameSettings.lua.
-- Same "%s's <Whatever>" convention core uses for its own bags/bank titles
-- (L.TitleBags/L.TitleBank) and GuildBank uses for its own ([[%s's Guild
-- Bank]]) -- SetFormattedText fills in the %s with the current player name.
local super_GetTitleText = Bagnon.TitleFrame.GetTitleText
function Bagnon.TitleFrame:GetTitleText()
	if self:GetFrameID() == ExtBank.FRAME_ID then
		return [[%s's Void Storage]]
	end
	return super_GetTitleText(self)
end
