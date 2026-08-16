--[[
	savedFrameSettings.lua
		Default persisted settings for the 'extbank' frame, plus the plain
		GetDB() accessors for the two fields core Bagnon has no notion of.
		The live FrameSettings layer over these is in frameSettings.lua.
--]]

local Bagnon = LibStub('AceAddon-3.0'):GetAddon('Bagnon')
local SavedFrameSettings = Bagnon.SavedFrameSettings

function SavedFrameSettings:GetDefaultExtBankSettings()
	local defaults = SavedFrameSettings.extBankDefaults
	if not defaults then
		defaults = {
			-- "bag slots" here are ExtBank bag-slot indices (0-based, one
			-- per possible equipped container), not real bagIDs -- the
			-- show/hide-in-shared-grid machinery in FrameSettings only
			-- needs a list of slot numbers, it doesn't care what they mean.
			availableBags = {},
			hiddenBags = {},

			frameColor = {0, 0, 0, 0.5},
			frameBorderColor = {0.6, 0.4, 1, 1},
			scale = 1,
			opacity = 1,
			point = 'CENTER',
			x = 250,
			y = 0,
			frameLayer = 'HIGH',

			-- Wider than core's own defaults for a reason specific to this
			-- frame: the bag-slot strip above the grid draws all MAX_BAGS
			-- (70) slots whenever it's shown, and sizes its own column count
			-- to whatever width the grid below it settles on (see
			-- bagFrame.lua's GetColumnCount). At 8 columns the strip fits
			-- ~11 per row, i.e. 7 rows of mostly-locked placeholder icons
			-- stacked above the items; at 11 it fits 14 per row and comes
			-- down to 5. Still adjustable per-player by the "Columns" slider
			-- -- this only moves where it starts.
			itemFrameColumns = 11,
			itemFrameSpacing = 2,
			bagBreak = false,
			bagsPerPage = 5,
			bagFrameShown = true,

			hasMoneyFrame = true,
			hasBagFrame = true,
			hasDBOFrame = true,
			hasSearchToggle = true,
			hasSortButton = false,
			hasOptionsToggle = true,

			dataBrokerObject = 'BagnonLauncher',
			reverseSlotOrder = false,
		}

		for i = 0, Bagnon.ExtBank.MAX_BAGS - 1 do
			table.insert(defaults.availableBags, i)
		end

		SavedFrameSettings.extBankDefaults = defaults
	end

	return defaults
end

-- Core's own dispatch (GetDefaultSettings) only special-cases a fixed set
-- of hardcoded frameIDs and has no branch for ours -- unlike guild bank,
-- which core already knew about, so its own companion settings file could
-- just override GetDefaultGuildBankSettings and rely on core's existing
-- dispatch to call it. Ours needs the dispatch itself extended, so wrap it
-- instead of editing the vendored file.
local super_GetDefaultSettings = SavedFrameSettings.GetDefaultSettings
function SavedFrameSettings:GetDefaultSettings(frameID)
	local frameID = frameID or self:GetFrameID()
	if frameID == 'extbank' then
		return self:GetDefaultExtBankSettings()
	end
	return super_GetDefaultSettings(self, frameID)
end


--[[ Accessors for the two extbank-only fields ]]--
-- Both default above (bagsPerPage, bagFrameShown); neither exists in core
-- Bagnon's own savedFrameSettings.lua, so these are additions rather than
-- wraps. See frameSettings.lua for the live layer that reads and writes
-- them, and for why neither of these needs to be defined before it.

function SavedFrameSettings:SetBagsPerPage(count)
	self:GetDB().bagsPerPage = count
end

function SavedFrameSettings:GetBagsPerPage()
	return self:GetDB().bagsPerPage
end

function SavedFrameSettings:SetBagFrameShown(shown)
	self:GetDB().bagFrameShown = shown
end

function SavedFrameSettings:GetBagFrameShown()
	return self:GetDB().bagFrameShown
end