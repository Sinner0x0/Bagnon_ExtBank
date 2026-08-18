--[[
	savedFrameSettings.lua
		Default persisted settings for the 'extbank' frame, plus the plain
		GetDB() accessors for the two fields core Bagnon has no notion of.
		The live FrameSettings layer over these is in frameSettings.lua.
--]]

local Bagnon = LibStub('AceAddon-3.0'):GetAddon('Bagnon')
local SavedFrameSettings = Bagnon.SavedFrameSettings

-- Named, and read by BOTH the defaults table below and the accessors at the
-- bottom of this file. These two fields don't exist in core Bagnon, so they
-- reach the DB through plain accessors of ours rather than through core's
-- default-filling machinery -- which means a saved table that predates either
-- field, or a hand-edited SavedVariables, hands back nil where every other
-- setting would hand back its default. That is not a cosmetic difference:
-- GetBagsPerPage() feeds straight into math.ceil(total / n) in
-- components/itemFrame.lua's GetPageCount, so a nil there throws on every
-- single model update and the window never opens again. Nil is not the only
-- value that arrives unvalidated for the same reason -- see ToBagCount beside
-- the accessors at the bottom for the rest of them.
local DEFAULT_BAGS_PER_PAGE   = 5
local DEFAULT_BAG_FRAME_SHOWN = true

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
			bagsPerPage = DEFAULT_BAGS_PER_PAGE,
			bagFrameShown = DEFAULT_BAG_FRAME_SHOWN,

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
	if frameID == Bagnon.ExtBank.FRAME_ID then
		return self:GetDefaultExtBankSettings()
	end
	return super_GetDefaultSettings(self, frameID)
end


--[[ Accessors for the two extbank-only fields ]]--
-- Both default above (bagsPerPage, bagFrameShown); neither exists in core
-- Bagnon's own savedFrameSettings.lua, so these are additions rather than
-- wraps. See frameSettings.lua for the live layer that reads and writes
-- them, and for why neither of these needs to be defined before it.

-- Nothing but these two accessors touches GetDB().bagsPerPage, so this is the
-- one place a bad value can be stopped -- and with no core default-filling
-- behind them (the note on the defaults at the top of this file), nothing else
-- validates it. Two sources feed the field: the options slider hands
-- FrameSettings:SetBagsPerPage a raw Slider GetValue(), and SavedVariables is
-- player-writable.
--
-- What makes a non-integer worse than it looks is that this answer is a LOOP
-- BOUND, not just a count -- components/itemFrame.lua's GetCurrentPageBags does
-- `for i = (page - 1) * perPage + 1, ...`, so 5.0000001 has page 2 start at
-- all[6.0000001] and every index it walks is nil. Page 1 draws, every later page
-- comes back empty while the page bar still counts them, and no Lua error is
-- raised to point at it. GetPageCount and ClampCurrentPage stay well-behaved on
-- the same input, so nothing downstream catches it either.
--
-- Normalizing on READ as well as on write is what makes a value that is already
-- in the saved file -- written by an earlier version, or typed in by hand --
-- repair itself at load, with no migration step to run.
local function ToBagCount(value)
	local count = math.floor(tonumber(value) or DEFAULT_BAGS_PER_PAGE)

	-- `not (count >= 1)` rather than `count < 1`: every comparison against NaN
	-- is false, so this form sends a hand-edited 0/0 to the default as well.
	if not (count >= 1) then
		return DEFAULT_BAGS_PER_PAGE
	end

	-- Bounded above to keep the domain finite. MAX_BAGS bags on one page is
	-- already all of them, and an unbounded inf passes the test above only to
	-- reach 0 * inf = NaN in that same startIdx, which empties page 1 too.
	return math.min(count, Bagnon.ExtBank.MAX_BAGS)
end

function SavedFrameSettings:SetBagsPerPage(count)
	self:GetDB().bagsPerPage = ToBagCount(count)
end

function SavedFrameSettings:GetBagsPerPage()
	return ToBagCount(self:GetDB().bagsPerPage)
end

function SavedFrameSettings:SetBagFrameShown(shown)
	self:GetDB().bagFrameShown = shown
end

-- The `== nil` test, not a plain `or`: false is a legitimate saved value here
-- (the player hid the strip on purpose), and `false or true` is true -- which
-- would pop the strip back open on their next /reload, the exact thing this
-- setting exists to persist.
function SavedFrameSettings:GetBagFrameShown()
	local shown = self:GetDB().bagFrameShown
	if shown == nil then
		return DEFAULT_BAG_FRAME_SHOWN
	end
	return shown
end