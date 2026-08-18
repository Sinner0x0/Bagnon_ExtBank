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

-- Fresh tables rather than wiping the existing ones in place. Nothing outside
-- this file ever holds a reference to either -- every reader reaches them
-- through ExtBank.cells/ExtBank.bags at call time (components/item.lua's
-- GetCellData, components/itemFrame.lua's GetBagSize, components/bag.lua's
-- GetBagData, core/deposit.lua) -- so swapping costs nothing, and it leaves the
-- OLD cell table intact for ParsePacket below to diff the incoming snapshot
-- against.
local function ClearModel(self)
	self.unlockedBags = 0
	self.bags = {}
	self.cells = {}
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
	-- `< 8` and not `< 10` is deliberate, and mirrors extBank.lua:59 exactly.
	-- See docs/non-issues.md §1 before "fixing" it.
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

	-- Which cells this packet puts items INTO, in the order the server listed
	-- them. core/deposit.lua uses it to find where a just-clicked right-click
	-- deposit actually landed.
	--
	-- Built here rather than by diffing a snapshot taken at click time, because
	-- the packet already names exactly the cells that changed: the old approach
	-- deep-copied the whole vault (up to 70 tables and 2520 entries) on every
	-- right-click in the player's bags -- including potions and lockboxes that
	-- were never deposits at all -- and then had to rediscover the landing site
	-- by walking pairs(), which has no defined order and so picked arbitrarily
	-- when a packet filled more than one cell.
	--
	-- Captured before ClearModel below swaps in fresh tables. For a kind ~= 0
	-- delta previousCells is the same table we are about to write into, which is
	-- still correct -- each cell is compared against its own previous value
	-- before that value is overwritten. For a kind == 0 snapshot it keeps
	-- pointing at the pre-snapshot state, which is what the diff wants.
	--
	-- Only built when a deposit is actually in flight; otherwise the answer is
	-- thrown away, so nothing is allocated.
	--
	-- Read ONCE and carried to CorrectPendingDeposit below, which used to re-derive
	-- it for itself. That is not just a saved call: HasPendingDeposits sweeps the
	-- pending list against DEPOSIT_RESPONSE_WINDOW and compacts it in place, so it
	-- was real mutation running twice for one packet on a path core/deposit.lua's
	-- own header calls hot. Nothing between here and there can change the answer --
	-- the cell loop never arms a deposit, and GetTime() is fixed for the whole
	-- frame, so no arm can age out midway.
	local arms = self:HasPendingDeposits()

	-- `self.hasModel` is still false here for the session's FIRST packet -- it is
	-- set below, after the cell loop -- and that is exactly the case the diff
	-- cannot answer. previousCells is ExtBank.cells, which stays `{}` until
	-- something has been parsed, so `before` is nil for every record, the
	-- `not before` arm fires for every occupied cell, and `gained` becomes THE
	-- ENTIRE VAULT in packet order. CorrectPendingDeposit then walks that list and
	-- spends its arm on the first entry whose bag is off the current page -- an
	-- arbitrary item that has sat untouched in some ext bag for weeks, not the
	-- deposit the arm was raised for -- and drags it onto page 1.
	--
	-- Nothing unusual is needed to reach it: core/deposit.lua's watch arms across
	-- the whole native session by design, so any right-click made between the
	-- native open and the first snapshot lands here.
	--
	-- Skipping the BUILD rather than the correction is what makes this free -- with
	-- `gained` nil, CorrectPendingDeposit returns on its own first line, and not one
	-- table is allocated for a list that could only ever be wrong.
	--
	-- The arms are deliberately NOT spent on the way past. The first snapshot is the
	-- answer to ExtBankOpen, not to the click; the click's own answer is still
	-- coming as a later packet, and that one has a real previousCells to diff
	-- against. Burning the arms here would silently drop the correction the README
	-- promises for every deposit made during the wait.
	--
	-- This does NOT make CorrectPendingDeposit's `arms` bound redundant -- see the
	-- note at its own comment. A kind == 0 snapshot still reports every occupied
	-- cell as newly gained on every LATER full refresh (an unlock confirmation, for
	-- one), where hasModel is true and the diff runs for real. The bound is what
	-- caps that at one cell per packet.
	local watchingDeposits = arms > 0 and self.hasModel
	local previousCells = self.cells
	local gained, nGained = nil, 0
	if watchingDeposits then gained = {} end

	-- Both the bag records and `ub` being consumed only here -- and not for
	-- kind ~= 0 -- mirrors extBank.lua:63-79. See docs/non-issues.md §2.
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
			-- `bi >= 0` bounds the DEPOSIT side only, not the parse. A cell record
			-- naming a bag below CONTENT_BASE yields a negative bagIndex, which the
			-- mirrored original tolerates harmlessly -- it only ever reads
			-- cells[activeBag] with activeBag >= 0, so a stray cells[-1] just sits
			-- there. Ours is not inert: core/deposit.lua would find bag -1 off-page
			-- (it can never be on one), spend an arm, and send a MoveWithinVault whose
			-- source resolves back to CONTENT_BASE + -1 = 19, the bag-slot strip. So
			-- the guard goes on the `gained` push, where the exposure actually is,
			-- rather than on the assignment below -- which stays byte-for-byte with
			-- extBank.lua per the mirroring policy (docs/non-issues.md §2).
			if watchingDeposits and bi >= 0 then
				-- Newly occupied, occupied by a DIFFERENT item than before, or
				-- an existing stack that grew. A right-click deposit can land
				-- as any of the three, and that last one -- merging into a
				-- partial stack already in the vault -- changes only the count,
				-- so an occupied/not-occupied diff never saw it at all.
				local before = previousCells[bi] and previousCells[bi][slot]
				if not before or before.itemId ~= itemId or count > (before.count or 0) then
					nGained = nGained + 1
					gained[nGained] = { bagIndex = bi, slot = slot }
				end
			end

			self.cells[bi][slot] = { itemId = itemId, count = count, lowGuid = guid,
				enchant = ench, randomProp = rnd, durability = dur }
		end
	end

	self.hasModel = true

	-- See core/deposit.lua -- this is the "model's caught up" signal that
	-- turns a snapshot taken right before a real-inventory deposit click into
	-- an actual page-aware relocation, now that the cells above reflect
	-- whatever the server just did in response.
	self:CorrectPendingDeposit(gained, arms)

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
