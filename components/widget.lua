--[[
	widget.lua
		The three things every widget class in this addon needs, in one place:
		which frame it belongs to, that frame's settings, and the tooltip
		anchor/refresh pair.

		Every one of these was previously copy-pasted per class -- SetFrameID/
		GetFrameID in five of them, GetSettings in three, AnchorTooltip
		byte-for-byte in two. Thirteen method bodies for three behaviours, and
		they had already started to drift: bag.lua guarded its OnLeave on
		GameTooltip:IsOwned(self) while item.lua's called GameTooltip:Hide()
		unconditionally, which tears down a tooltip some other frame owns.
--]]

local Bagnon = LibStub('AceAddon-3.0'):GetAddon('Bagnon')

local Widget = {}
Bagnon.ExtBankWidget = Widget


--[[ Mixing in ]]--
-- Copied onto each class rather than passed as Classy's parentClass argument.
-- Classy does support inheritance -- components/frame.lua:9 uses it, as
-- `Classy:New('Frame', Bagnon.Frame)` -- but every use of it in this addon and
-- in core Bagnon inherits a class of the SAME frame type. The five classes here
-- are a Frame, a Button and a CheckButton, and nothing establishes that one
-- parent table is safe across mixed types. Copying is exactly as good for what
-- this needs (no super_ calls, no overriding, no polymorphism) and depends on
-- nothing unverified.
--
-- rawget, not a plain `class[name] == nil`: a Classy class carries a live
-- metatable, so a plain index would fall through to any inherited method and
-- silently skip copying. rawget asks only about the class's own table, which is
-- the question actually being asked -- "did this class define its own?".
--
-- Call this at the END of a widget file, after the class has defined whatever
-- it means to keep for itself. Anything it defines wins; everything else comes
-- from here.
function Widget:Apply(class)
	for name, method in pairs(Widget) do
		if name ~= 'Apply' and name ~= 'tooltip' and name ~= 'ApplyTooltip'
			and rawget(class, name) == nil then
			class[name] = method
		end
	end
end

-- The tooltip trio is opt-in, unlike the identity methods above, because it is not
-- inert on a class that does not want it. RefreshTooltipIfOwned calls
-- self:RefreshTooltip(), which only the two hovering widget classes define -- so
-- applying it to ItemFrame, BagFrame and PageBar planted a method that could only
-- ever raise "attempt to call method 'RefreshTooltip' (a nil value)". Nothing calls
-- it on them today, so it was latent rather than broken, but a handler wired by name
-- (the way Bag:OnShow wires 'Update') is one line away from reaching it.
--
-- Note this is a different case from the unused GetSettings that pageBar.lua's own
-- comment weighs up: an extra accessor nobody calls costs a table slot, while a
-- method that cannot run is a trap. Only the second is worth splitting for.
function Widget:ApplyTooltip(class)
	for name, method in pairs(Widget.tooltip) do
		if rawget(class, name) == nil then
			class[name] = method
		end
	end
end


--[[ Identity ]]--

function Widget:SetFrameID(frameID)
	self.frameID = frameID
end

function Widget:GetFrameID()
	return self.frameID
end

function Widget:GetSettings()
	return Bagnon.FrameSettings:Get(self:GetFrameID())
end


--[[ Tooltip ]]--
-- Applied only via ApplyTooltip, i.e. only to the two classes that actually hover
-- (components/item.lua's cells and components/bag.lua's strip slots).

Widget.tooltip = {}

-- Flip the tooltip to the inside edge once this widget is past the middle of
-- the screen, so it never runs off the side.
--
-- Two corrections over the copies this replaces, both of which could throw or
-- misplace:
--
-- GetRight() returns nil -- not 0 -- for a frame whose rect isn't resolved yet,
-- and `nil > number` is an error, not false. Item cells are genuinely in that
-- state for a frame at a time: ItemSlot:New Show()s a pooled button
-- immediately, but the SetPoint that gives it a rect only lands on the next
-- OnUpdate via itemFrame.lua's deferred RequestLayout(). An OnEnter arriving in
-- that window (the mouse is already sitting where a new cell just appeared --
-- a page flip, a bag toggle) hit exactly that.
--
-- And GetRight() is measured in this frame's own coordinate space while
-- GetScreenWidth() is in UIParent's, so comparing them directly is only correct
-- at scale 1. This frame ships a live Scale slider (savedFrameSettings.lua's
-- `scale`), and at 50% every coordinate here reads about double what it does in
-- UIParent's space -- so a cell physically 30% across the screen reported ~60%,
-- the test flipped, and the tooltip anchored off the left edge. Convert into
-- UIParent's space before comparing.
function Widget.tooltip:AnchorTooltip()
	local right = self:GetRight()

	if right then
		local inUIParentSpace = right * self:GetEffectiveScale() / UIParent:GetEffectiveScale()
		if inUIParentSpace > (GetScreenWidth() / 2) then
			GameTooltip:SetOwner(self, 'ANCHOR_LEFT')
			return
		end
	end

	GameTooltip:SetOwner(self, 'ANCHOR_RIGHT')
end

-- Both widget types deliberately name their tooltip builder RefreshTooltip
-- rather than UpdateTooltip -- see the long note above ItemSlot:RefreshTooltip
-- (components/item.lua) for why that name is load-bearing. Losing the
-- UpdateTooltip name also loses the incidental refresh Blizzard's own
-- GameTooltip_OnUpdate poll was giving us, so anything that changes what a
-- hovered widget should be saying has to ask for the redraw explicitly.
--
-- IsShown() as well as IsOwned(), because ownership is not hover. SetOwner in
-- AnchorTooltip claims the tooltip and nothing ever gives it back: OnLeave below
-- calls GameTooltip:Hide(), which hides it but leaves the owner pointing here, so
-- IsOwned stays true long after the mouse has gone. On IsOwned alone the next
-- Update -- one arrives on every packet -- re-ran the whole SetHyperlink/Show
-- sequence and popped a tooltip open beside a cell the cursor was nowhere near,
-- again on every packet after that. Through the pool it was worse: the owning
-- button can be Free()d and Restore()d onto different coordinates while still the
-- owner, so the re-show described a DIFFERENT item, anchored to a button whose
-- SetPoint had not landed yet.
--
-- A hidden tooltip never needs refreshing, and nothing legitimate wants one: the
-- only caller that shows a tooltip from scratch is OnEnter, which calls
-- RefreshTooltip directly and does not come through here.
function Widget.tooltip:RefreshTooltipIfOwned()
	if GameTooltip:IsOwned(self) and GameTooltip:IsShown() then
		self:RefreshTooltip()
	end
end

-- Guarded, not a bare GameTooltip:Hide(). There is one GameTooltip for the
-- whole UI, and by the time our OnLeave runs another frame's OnEnter may
-- already have taken ownership of it -- hiding unconditionally then blanks a
-- tooltip that belongs to something else. Only hide what is still ours.
function Widget.tooltip:OnLeave()
	if GameTooltip:IsOwned(self) then
		GameTooltip:Hide()
	end
end
