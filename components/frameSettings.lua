--[[
	frameSettings.lua
		The live per-frame settings layer for the 'extbank' frame -- the
		FrameSettings half of what savedFrameSettings.lua persists.

		Same split core Bagnon itself makes (Bagnon/components/
		frameSettings.lua vs savedFrameSettings.lua): the saved half is a
		plain GetDB() accessor pair, this half is what the widgets talk to
		and what fires the message bus when a value actually changes.

		Position within the addon is free -- nothing here is read at file
		scope. Every caller reaches these through a method at runtime
		(itemFrame.lua via GetSettings(), frameOptions.lua's slider from a
		click handler), and the super_ captures below read core Bagnon's own
		methods, which RequiredDeps: Bagnon guarantees are already present.
--]]

local Bagnon = LibStub('AceAddon-3.0'):GetAddon('Bagnon')


--[[ Pagination ]]--
-- Bags-per-page isn't a core Bagnon concept -- no other frame type ever has
-- enough bags equipped to need paging the shared item grid (see
-- components/itemFrame.lua's own header comment: up to 70 bags of up to 36
-- slots each, 2520 possible cells). FrameSettings/SavedFrameSettings
-- (Bagnon/components/frameSettings.lua / savedFrameSettings.lua) have no
-- field or accessors for it, so these are additions, not wraps -- same
-- GetDB()-plus-message-bus shape every other per-frame setting already uses
-- (see SetBagBreak/IsBagBreakEnabled in core for the pattern mirrored here).

-- The setter is gated to this frame, the getter deliberately is NOT.
--
-- These two are additions to a class every Bagnon frame shares, not wraps of
-- existing core methods, so there is no super_ to fall through to -- a guarded
-- getter could only return nil, and nil is the whole hazard (GetPageCount does
-- math.ceil(total / n) with it). Leaving the getter open means every frame gets
-- the same safe default out of savedFrameSettings.lua, which costs nothing and
-- cannot throw. The setter is worth gating: nothing but this frame has any use
-- for the value, and an unguarded one would write a dead `bagsPerPage` key into
-- an unrelated frame's saved settings.
--
-- No payload on the message: core's FrameSettings:SendMessage prepends
-- self:GetID(), so the count previously passed here landed in a third argument
-- that ITEM_FRAME_BAGS_PER_PAGE_UPDATE's handler (components/itemFrame.lua)
-- never reads -- it takes (msg, frameID) like every other handler in the addon.
function Bagnon.FrameSettings:SetBagsPerPage(count)
	if self:GetID() ~= Bagnon.ExtBank.FRAME_ID then return end

	if self:GetBagsPerPage() ~= count then
		self:GetDB():SetBagsPerPage(count)
		self:SendMessage('ITEM_FRAME_BAGS_PER_PAGE_UPDATE')
	end
end

function Bagnon.FrameSettings:GetBagsPerPage()
	return self:GetDB():GetBagsPerPage()
end


--[[ Bag-frame-shown persistence (extbank-only override) ]]--
-- Core's own IsBagFrameShown/ShowBagFrame/HideBagFrame (FrameSettings,
-- shared by every frame type) back onto a plain `self.showBagFrame` field
-- that's never saved -- session-only, always starts false, only flips on
-- once the player clicks the bag-toggle icon (see bagToggle.lua), for the
-- rest of that session. That default (hidden until asked for) is right for
-- a regular bag/bank window, where the item grid is the main event and the
-- bag-slot row is optional extra chrome -- but for Void Storage the
-- bag-slot strip IS the reason to open the window; starting every single
-- session with it hidden defeats the point. It still has to be a real,
-- persisted per-player choice though, not just a different hardcoded
-- default -- a player who deliberately hides it shouldn't see it pop back
-- open on their very next /reload.
--
-- Same shape as SetBagsPerPage/GetBagsPerPage just above (a per-frame
-- setting via GetDB()-plus-message-bus), just wrapping three EXISTING core
-- methods instead of only adding new ones, since IsBagFrameShown/
-- ShowBagFrame/HideBagFrame already exist and are read from several other
-- places (BagToggle, core Frame's own layout, GuildBank's TabFrame) that
-- all need to keep seeing ONE consistent answer -- so this redirects them
-- ALL to a genuine saved setting (bagFrameShown, defaulting true) rather
-- than just adding a second, competing source of truth. Guarded to
-- self:GetID() == 'extbank' only; every other frame type falls through to
-- super_X unchanged. ToggleBagFrame needs no wrap of its own: its
-- unwrapped body already calls self:IsBagFrameShown()/self:ShowBagFrame()/
-- self:HideBagFrame() through self, which resolve dynamically via the
-- class metatable to the wrapped versions below regardless of where
-- ToggleBagFrame itself was defined.
--
-- Safe on its own, but only because BagFrame:New never shows itself: this
-- override makes IsBagFrameShown() start true, and a BagFrame that Show()s
-- from inside its own constructor recurses into unbounded CreateBagFrame
-- calls -- an instant client freeze. Neither half does it alone. See
-- bagFrame.lua's BagFrame:New for the mechanism, and don't reintroduce that
-- Show().

local super_IsBagFrameShown = Bagnon.FrameSettings.IsBagFrameShown
function Bagnon.FrameSettings:IsBagFrameShown()
	if self:GetID() == Bagnon.ExtBank.FRAME_ID then
		return self:GetDB():GetBagFrameShown()
	end
	return super_IsBagFrameShown(self)
end

local super_ShowBagFrame = Bagnon.FrameSettings.ShowBagFrame
function Bagnon.FrameSettings:ShowBagFrame()
	if self:GetID() == Bagnon.ExtBank.FRAME_ID then
		if not self:IsBagFrameShown() then
			self:GetDB():SetBagFrameShown(true)
			self:SendMessage('BAG_FRAME_SHOW')
		end
		return
	end
	super_ShowBagFrame(self)
end

local super_HideBagFrame = Bagnon.FrameSettings.HideBagFrame
function Bagnon.FrameSettings:HideBagFrame()
	if self:GetID() == Bagnon.ExtBank.FRAME_ID then
		if self:IsBagFrameShown() then
			self:GetDB():SetBagFrameShown(false)
			self:SendMessage('BAG_FRAME_HIDE')
		end
		return
	end
	super_HideBagFrame(self)
end
