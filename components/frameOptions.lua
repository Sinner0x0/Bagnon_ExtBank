--[[
	frameOptions.lua
		Our entries in Bagnon_Config's Frame Settings panel (Interface
		Options > Bagnon): the 'extbank' dropdown item, the credit block,
		the "Bags Per Page" slider, and the two checkboxes that get grayed
		out for this frame.

		Split out from frame.lua because none of this is about our Frame
		class -- it patches a different addon entirely, and touches only
		Bagnon.FrameOptions / Bagnon.OptionsSlider / StaticPopupDialogs.
--]]

local Bagnon = LibStub('AceAddon-3.0'):GetAddon('Bagnon')


--[[ Options integration ]]--
-- Bagnon_Config's Frame Settings panel has its own frame-selector dropdown
-- with the same kind of hardcoded item list core uses elsewhere -- 'bank',
-- 'keys', and 'guildbank' if that addon's loaded -- and no entry for ours.
-- Unlike the monkeypatches in frame.lua and savedFrameSettings.lua,
-- Bagnon_Config is LoadOnDemand: it may not exist yet when this file runs
-- (it only loads when the player actually opens it), so the patch has to
-- wait for that instead of running immediately.
-- Waiting on the event alone is enough -- no IsAddOnLoaded fallback is
-- needed, because 3.3.5a never re-loads a LoD addon across /reload, so
-- ADDON_LOADED cannot already have fired. See docs/non-issues.md §4.
local watcher = CreateFrame('Frame')
watcher:RegisterEvent('ADDON_LOADED')
watcher:SetScript('OnEvent', function(self, event, addonName)
	if addonName ~= 'Bagnon_Config' then return end
	self:UnregisterEvent('ADDON_LOADED')

	local dropdown = Bagnon.FrameOptions and Bagnon.FrameOptions:GetFrameSelector()
	if not dropdown then return end

	local super_Initialize = dropdown.Initialize
	dropdown.Initialize = function(self)
		super_Initialize(self)
		self:AddItem('Void Storage', Bagnon.ExtBank.FRAME_ID)
	end

	-- "Enable Bag Frame" and "Enable Sort Button" are both grayed out for this
	-- frame below, for two different reasons.
	--
	-- Sort is simply unsupported: Frame:HasSortButton() (frame.lua) hardcodes
	-- false, since Bagnon.Sorting can't drive ExtBankMove, and no setting the
	-- player picks could change that.
	--
	-- The bag frame IS settings-backed (see the HasBagFrame note in
	-- frame.lua), but this frame already has a better control for the same
	-- thing -- the bag-toggle icon on the menu-button line, whose state
	-- persists per character (components/frameSettings.lua's "Bag-frame-shown
	-- persistence"). Leaving the checkbox live would mean two controls for one
	-- strip, where the weaker one is a trap: switching it off removes the
	-- toggle icon AND the purchase button (bagFrame.lua) along with the strip,
	-- and the options panel is then the only way back. Frozen on its default,
	-- the strip is always available and the toggle is the single way to show
	-- or hide it.
	--
	-- Graying rather than hiding is core's own idiom here -- frameOptions.lua's
	-- UpdateWidgets already grays these same boxes for 'keys'/'guildbank' --
	-- and it keeps the checkbox column identical for every frame. Never hide
	-- them instead: the rows below would need hand-re-anchoring to close the
	-- gaps in the fixed vertical chain frameOptions.lua's AddWidgets() sets up
	-- once at load, which both jumps the whole column two rows whenever the
	-- frame dropdown moves into or out of extbank (settings sliding out from
	-- under the player's cursor) and duplicates that chain plus
	-- frameOptions.lua's private CHECK_BUTTON_SPACING here, where any later
	-- edit to the chain would silently break it.

	-- Three free-text lines, extbank-only -- crediting this addon separately
	-- from Bagnon itself. Nothing in vendored Bagnon_Config has a slot for
	-- per-frame text like this, so these are plain widgets of our own.
	-- Stacked bottom-up off the panel's own bottom-left corner (see below the
	-- three constructors) rather than hung downward off the last checkbox:
	-- the checkbox column is at its full height for extbank now that nothing
	-- is hidden, and trailing ~50px of text off the end of it risked running
	-- past the panel's bottom edge. The slider column is pinned to the
	-- panel's bottom RIGHT and is 180 wide, so a bottom-LEFT block clears it
	-- horizontally at any panel width.

	-- "<Title> v<Version> -- <Date>". The version and date come from the
	-- module's own constants, NOT from GetAddOnMetadata: .toc metadata is
	-- parsed once at client launch and cached, so after a drop-in update and a
	-- /reload this line would still print the previous build's values. See the
	-- Identity block in main.lua, which also covers how the two stay in sync
	-- with the .toc. Title is still read from the .toc -- it's the addon's
	-- display name, it only changes if the addon is ever renamed, and by then
	-- a stale header is the least of it. ADDON_NAME is the addon's FOLDER name
	-- (what GetAddOnMetadata keys off), not necessarily its ## Title text.
	local ADDON_NAME = 'Bagnon_ExtBank'
	local ExtBank = Bagnon.ExtBank
	local headerText = Bagnon.FrameOptions:CreateFontString(nil, 'ARTWORK', 'GameFontNormalSmall')
	headerText:SetJustifyH('LEFT')
	headerText:SetText(('%s v%s -- %s'):format(
		GetAddOnMetadata(ADDON_NAME, 'Title'),
		ExtBank.VERSION,
		ExtBank.DATE))
	headerText:Hide()

	local CREDIT_LINE = 'Developed by Sinner0x0'
	local GITHUB_URL = 'https://github.com/Sinner0x0/Bagnon_ExtBank'

	local creditText = Bagnon.FrameOptions:CreateFontString(nil, 'ARTWORK', 'GameFontHighlightSmall')
	creditText:SetJustifyH('LEFT')
	creditText:SetNonSpaceWrap(true)
	creditText:SetText(CREDIT_LINE)
	creditText:Hide()

	-- "An actual link" in a 3.3.5 client can't mean a real browser
	-- navigation -- the game has no way to launch one. What every other
	-- addon means by a "clickable" URL is this same pattern: click it, get
	-- a popup with the address already selected in a copyable EditBox, so
	-- Ctrl+C just works. StaticPopupDialogs (same mechanism as bagFrame.lua's
	-- own BAGNON_EXTBANK_UNLOCK_CONFIRM) already has first-class EditBox
	-- support built in (hasEditBox), so that's what this reuses rather than
	-- hand-rolling a floating box of our own.
	--
	-- A plain FontString can't receive clicks -- it's a Button with a
	-- FontString wired in via SetNormalFontObject/SetText (the standard way
	-- to get a text-only, chrome-free clickable button; no XML template
	-- involved), colored/underlined so it visibly reads as a link rather
	-- than a disabled label.
	StaticPopupDialogs['BAGNON_EXTBANK_SHOW_LINK'] = {
		text = 'Bagnon_ExtBank GitHub (Ctrl+C to copy):',
		button1 = CLOSE,
		hasEditBox = true,
		editBoxWidth = 350,
		-- `self.editBox` is the Cataclysm-era StaticPopup instance field; 3.3.5a's
		-- own StaticPopup implementation resolves the edit box by global name
		-- instead ($parentEditBox). Take whichever is actually there rather than
		-- betting on one: on the wrong client the field is nil, and this handler
		-- is invoked from inside Blizzard's StaticPopup_OnShow, so indexing it
		-- throws out of THEIR code and leaves a half-built popup with no URL in
		-- it -- for the one control whose entire job is to hand the player a URL.
		OnShow = function(self)
			local editBox = self.editBox or _G[self:GetName() .. 'EditBox']
			if not editBox then return end

			editBox:SetText(GITHUB_URL)
			editBox:HighlightText()
			editBox:SetFocus()
		end,
		EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
		EditBoxOnEnterPressed = function(self) self:GetParent():Hide() end,
		timeout = 0,
		whileDead = 1,
		hideOnEscape = 1,
	}

	local githubLink = CreateFrame('Button', nil, Bagnon.FrameOptions)
	githubLink:SetNormalFontObject('GameFontHighlightSmall')
	githubLink:SetHighlightFontObject('GameFontNormalSmall')
	githubLink:SetText(GITHUB_URL)
	githubLink:GetFontString():SetPoint('TOPLEFT')
	githubLink:GetFontString():SetJustifyH('LEFT')
	githubLink:SetWidth(githubLink:GetFontString():GetStringWidth())
	githubLink:SetHeight(githubLink:GetFontString():GetStringHeight())
	githubLink:SetScript('OnClick', function()
		StaticPopup_Show('BAGNON_EXTBANK_SHOW_LINK')
	end)
	githubLink:Hide()

	-- Stacked bottom-up, so the block grows upward from the panel's bottom
	-- edge instead of downward into it -- see the note above the three
	-- constructors. Set here rather than at each constructor because the
	-- anchors run in the opposite order to the reading order the widgets are
	-- built in.
	githubLink:SetPoint('BOTTOMLEFT', Bagnon.FrameOptions, 'BOTTOMLEFT', 16, 16)

	creditText:SetPoint('BOTTOMLEFT', githubLink, 'TOPLEFT', 0, 4)
	creditText:SetPoint('RIGHT', Bagnon.FrameOptions, -16, 0)

	headerText:SetPoint('BOTTOMLEFT', creditText, 'TOPLEFT', 0, 4)
	headerText:SetPoint('RIGHT', Bagnon.FrameOptions, -16, 0)

	-- The "how many bags per page" control (see itemFrame.lua's own
	-- Pagination section for what this drives) -- extbank-only, same as
	-- creditText above, so it's stacked into the existing slider column
	-- (opacity -> scale -> spacing -> columns -> layer) rather than
	-- anywhere in the checkbox/text column those two live in. No locale
	-- entry for this addon-specific slider; a literal label string is fine
	-- here the same way CREDIT_LINE above is a literal string, not an L.*
	-- lookup.
	local bagsPerPage = Bagnon.OptionsSlider:New('Bags Per Page', Bagnon.FrameOptions, 1, 20, 1)
	bagsPerPage:SetPoint('BOTTOMLEFT', Bagnon.FrameOptions:GetLayerSlider(), 'TOPLEFT', 0, 20)
	bagsPerPage:SetPoint('BOTTOMRIGHT', Bagnon.FrameOptions:GetLayerSlider(), 'TOPRIGHT', 0, 20)

	bagsPerPage.SetSavedValue = function(self, value)
		self:GetParent():GetSettings():SetBagsPerPage(value)
	end

	bagsPerPage.GetSavedValue = function(self)
		return self:GetParent():GetSettings():GetBagsPerPage()
	end

	-- No manual UpdateValue() call needed anywhere below -- OptionsSlider's
	-- own OnShow (widgets/slider.lua) already calls it every time this
	-- slider transitions from Hidden to Shown, which is exactly every time
	-- UpdateExtBankWidgets below shows it (switching the dropdown
	-- INTO extbank from anything else). Nothing but this slider itself
	-- ever writes bagsPerPage, so that's the only refresh point that
	-- matters.
	bagsPerPage:Hide()

	local function UpdateExtBankWidgets(panel)
		local isExtBank = panel:GetFrameID() == Bagnon.ExtBank.FRAME_ID

		if isExtBank then
			headerText:Show()
			creditText:Show()
			githubLink:Show()
			bagsPerPage:Show()
		else
			headerText:Hide()
			creditText:Hide()
			githubLink:Hide()
			bagsPerPage:Hide()
		end

		-- The two grayed boxes need opposite handling, because core's own
		-- UpdateWidgets (which has already run by the time we get here)
		-- treats them differently.
		--
		-- It never touches the sort box's disabled state for any frame, so
		-- nothing but us would ever re-enable it -- drive both directions.
		panel:GetSortButtonCheckbox():SetDisabled(isExtBank)

		-- The bag-frame box it DOES set every pass, from its own hardcoded
		-- 'keys'/'guildbank' list. Only force it on the way in, then: a
		-- SetDisabled(isExtBank) here would re-enable the box core had just
		-- correctly grayed for those two frames, and re-stating their frame
		-- IDs on our side to avoid that would put back exactly the kind of
		-- duplication of core's private layout knowledge this rewrite got rid
		-- of. Leaving extbank needs no cleanup from us -- core's next pass
		-- re-establishes the right state for whatever frame we landed on.
		if isExtBank then
			panel:GetToggleBagFrameCheckbox():SetDisabled(true)
		end
	end

	local super_UpdateWidgets = Bagnon.FrameOptions.UpdateWidgets
	function Bagnon.FrameOptions:UpdateWidgets()
		super_UpdateWidgets(self)
		UpdateExtBankWidgets(self)
	end
end)
