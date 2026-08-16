--[[
	model.lua
		This module's own copy of the vault's contents, built from the
		SMSG_EXTBANK_UPDATE payload core/nativeHooks.lua feeds us.

		ProjectEbonhold's own UI addon (modules/extBank/extBank.lua) already
		parses the same packet and keeps its own model, but that model lives
		in `local` upvalues and is not reachable from outside -- so this
		builds an independent copy from the same wire data, mirroring
		extBank.lua's own byte reader field-for-field so the two stay in
		sync.
--]]

local Bagnon = LibStub('AceAddon-3.0'):GetAddon('Bagnon')
local ExtBank = Bagnon.ExtBank


--[[ Model ]]--

-- unlockedBags : number of unlocked bag-slots
-- bags[b]      : { itemId, lowGuid, size } equipped container in slot b, or nil
-- cells[b][s]  : { itemId, count, lowGuid, enchant, randomProp, durability } or nil
ExtBank.unlockedBags = 0
ExtBank.bags = {}
ExtBank.cells = {}

-- True once at least one snapshot has ever been parsed this session. Lets
-- main.lua's OnNativeOpen tell "we already have something real to show" apart
-- from "this is the very first open and nothing's arrived yet".
ExtBank.hasModel = false

local function ClearModel(self)
	self.unlockedBags = 0
	for k in pairs(self.bags)  do self.bags[k]  = nil end
	for k in pairs(self.cells) do self.cells[k] = nil end
end


--[[ Wire format parse (SMSG_EXTBANK_UPDATE hex payload) ]]--
-- u8 kind, u8 unlockedBags, u8 nBags,
-- nBags * { u8 bagIndex, u32 itemId, u32 lowGuid, u8 size },
-- u16 nCells,
-- nCells * { u8 bag, u8 slot, u32 itemId, u32 count, u32 lowGuid, u32 enchant, i32 randomProp, u8 durability }
-- kind == 0 is a full snapshot (clears the model first); the cell list
-- always follows and applies as an update (itemId == 0 clears a slot).

local function u8 (b,p) return b[p], p+1 end
local function u16(b,p) return b[p]+b[p+1]*256, p+2 end
local function u32(b,p) return b[p]+b[p+1]*256+b[p+2]*65536+b[p+3]*16777216, p+4 end
local function i32(b,p) local v; v,p = u32(b,p); if v >= 2147483648 then v = v - 4294967296 end; return v,p end

function ExtBank:ParsePacket(hex)
	if type(hex) ~= 'string' or #hex < 8 then return end

	local b, n = {}, 0
	for i = 1, #hex, 2 do
		n = n + 1
		b[n] = tonumber(string.sub(hex, i, i + 1), 16) or 0
	end

	local p = 1
	local kind, ub, nBags
	kind,  p = u8(b, p)
	ub,    p = u8(b, p)
	nBags, p = u8(b, p)

	if kind == 0 then -- full snapshot
		ClearModel(self)
		self.unlockedBags = ub

		for _ = 1, nBags do
			local idx, itemId, guid, size
			idx,    p = u8(b, p)
			itemId, p = u32(b, p)
			guid,   p = u32(b, p)
			size,   p = u8(b, p)

			if itemId ~= 0 then
				self.bags[idx] = { itemId = itemId, lowGuid = guid, size = size }
			else
				self.bags[idx] = nil
			end
		end
	end

	local nCells
	nCells, p = u16(b, p)

	for _ = 1, nCells do
		local bag, slot, itemId, count, guid, ench, rnd, dur
		bag,    p = u8(b, p)
		slot,   p = u8(b, p)
		itemId, p = u32(b, p)
		count,  p = u32(b, p)
		guid,   p = u32(b, p)
		ench,   p = u32(b, p)
		rnd,    p = i32(b, p)
		dur,    p = u8(b, p)

		-- self.CONTENT_BASE, not a local: the addressing constants live on the
		-- module (declared in main.lua, next to the header comment that
		-- explains the scheme) because main.lua's own action wrappers need
		-- them too. Read at call time, so main.lua loading first is fine.
		local bi = bag - self.CONTENT_BASE
		self.cells[bi] = self.cells[bi] or {}

		if itemId == 0 then
			self.cells[bi][slot] = nil
		else
			self.cells[bi][slot] = { itemId = itemId, count = count, lowGuid = guid,
				enchant = ench, randomProp = rnd, durability = dur }
		end
	end

	self.hasModel = true

	-- See core/deposit.lua -- this is the "model's caught up" signal that
	-- turns a snapshot taken right before a real-inventory deposit click into
	-- an actual page-aware relocation, now that the cells above reflect
	-- whatever the server just did in response.
	self:CorrectPendingDeposit()

	-- NOT self:SendMessage -- that's AceEvent-3.0's own message bus (mixed
	-- into this module via NewModule(..., 'AceEvent-3.0')), a completely
	-- separate registry from Bagnon.Callbacks (the bespoke pub/sub every
	-- Classy-based UI widget's RegisterMessage actually listens on, see
	-- utility/callbacks.lua / utility/ears.lua). Sending on the wrong one
	-- means the widgets never hear about it -- they'd only ever show
	-- whatever the model happened to hold at their last OnShow, which on a
	-- first open is nothing at all.
	Bagnon.Callbacks:SendMessage('EXTBANK_MODEL_UPDATED')
end
