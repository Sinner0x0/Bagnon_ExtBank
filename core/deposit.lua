--[[
	deposit.lua
		Everything that hangs off a right-click on an item in the player's
		REAL bags while the vault is open.

		One hooksecurefunc on UseContainerItem (HookInventoryDepositWatch, at
		the bottom) arms both halves of this file:
		  - the page-aware correction, which relocates a deposit that landed
		    on some other page onto the one the player is actually looking at
		  - the stuck-item warning, which explains the orphaned client-side
		    lock left behind when the server refuses the deposit

		Both halves need a delay -- one waits for the server's answer, the
		other looks at the aftermath -- which is the only reason this module
		mixes in AceTimer-3.0 at all (see main.lua's NewModule call). 3.3.5
		has no C_Timer; AceTimer is embedded and loaded by core Bagnon's own
		embeds.xml, so it's already present by the time this file runs.
--]]

local Bagnon = LibStub('AceAddon-3.0'):GetAddon('Bagnon')
local ExtBank = Bagnon.ExtBank


--[[ Right-click deposit, scoped to the currently-displayed page ]]--
-- extBank.lua's own right-click deposit is itself a hooksecurefunc
-- post-hook on ContainerFrameItemButton_OnClick (and on
-- ContainerFrameItemButton_OnModifiedClick, for the shift+right-click
-- "equip this container" case) -- fires after the real click already ran,
-- no OnClick replacement, no taint -- and never checks where it landed.
--
-- WHERE it lands is the part that matters here, and it is not what an
-- earlier version of this comment claimed. Read against extBank.lua
-- itself -- ProjectEbonhold ships its addon Lua inside the client's MPQ
-- patch rather than on disk, so it has to be extracted to be read --
-- its handler is:
--
--     local freeSlot = FirstFreeActiveSlot()          -- in bags[activeBag]
--     if freeSlot ~= nil then
--         ExtBankMove(bag, slot, CONTENT_BASE + activeBag, freeSlot, 0)
--     else
--         ExtBankMove(bag, slot, 0xFF, 0, 0)          -- first free anywhere
--     end
--
-- So 0xFF is only the FALLBACK, reached when the active bag is full or
-- has no container equipped. The normal case targets one specific bag.
--
-- And `activeBag` is pinned to 0 for as long as this addon is installed.
-- It has exactly two writers in the whole of extBank.lua: a clamp in
-- ExtBank_OnPacket (`if activeBag >= unlockedBags then activeBag =
-- max(0, unlockedBags - 1)`, which from 0 can never raise it), and the
-- bag-strip buttons' OnClick. Those buttons are children of
-- ExtBankFrame, which HideNativeWindow (core/nativeHooks.lua) hides
-- permanently -- so they are never clicked and never write it.
--
-- The consequence for everything below: while ext bag 0 has a free slot,
-- EVERY right-click deposit lands in ext bag 0. The correction in this
-- file is therefore the normal path whenever the player is looking at a
-- page that doesn't include bag 0 -- not the occasional fixup the rest of
-- this comment used to describe. Each such deposit costs two server round
-- trips, which is inherent: a sibling hooksecurefunc cannot cancel or
-- redirect the native's move, only follow it.
--
-- An EARLIER version of this addon tried to
-- do better by overriding OnClick outright on core's own Bagnon.ItemSlot
-- class -- which, for the player's own real bag/bank windows, is under
-- default settings literally the same live Blizzard globals
-- (ContainerFrame1Item1 etc, see ItemSlot:GetBlizzardItemSlot in
-- Bagnon/components/item.lua) the stock UI itself uses. Replacing THEIR
-- OnClick with an addon-authored closure taints those buttons outright --
-- not just for our own redirect logic, for EVERY click on them, forever --
-- which is exactly what broke plain right-click "use" and shift-click
-- "split stack" everywhere, not just near the vault. Never do that again.
--
-- This version hooks the same safe way extBank.lua itself does
-- (hooksecurefunc, never touching any button's OnClick), but can't have
-- two independent hooks racing to send two different ExtBankMove
-- destinations for the same click -- whichever request the server
-- processes first wins, and there's no way to cancel or reorder a sibling
-- hooksecurefunc listener. So this only *observes* at click time (snapshot
-- which cells are occupied beforehand), then -- once ParsePacket confirms
-- the server's own response -- issues a SEPARATE, already-existing,
-- already-safe action (MoveWithinVault, an ExtBankMove call of our own,
-- not a Blizzard-protected function) to relocate the item onto the current
-- page, if there's room.

ExtBank.pendingDeposits = nil -- list of GetTime() stamps, one per in-flight real-inventory deposit, or nil

-- Destinations we have already sent a relocation to and not yet seen answered:
-- claimedSlots[bagIndex][slot] = GetTime() of the send.
--
-- Module state rather than a local inside CorrectPendingDeposit, and that is the
-- whole point. The server answers one move per packet (measured -- see
-- ConsumePendingDeposit), so a burst of right-clicks arrives as a burst of
-- SEPARATE packets, each its own CorrectPendingDeposit call. A per-call table
-- therefore only ever stopped two items in the SAME packet colliding, which is
-- the rarer half of the problem: across packets the model still showed our own
-- outstanding destination empty (the server has not answered our relocation yet),
-- so GetCurrentPageFreeSlot -- which scans page bags in order, slot 0 upward, and
-- returns the first hit -- handed out the identical cell every time. The second
-- and later relocations then targeted an occupied cell, which the server refuses
-- outright with no packet at all (see main.lua's Move wrappers), so every deposit
-- after the first was silently left on the wrong page with its arm already spent.
-- Measured as 1 of 6 relocated in a six-item burst.
ExtBank.claimedSlots = nil

-- How long an armed click stays worth acting on. The correction answers one
-- specific click, so it's only meaningful while the server's response to THAT
-- click is still outstanding -- a round trip, not minutes. Past that the click
-- is long over, and crediting whatever changed next to it would relocate an
-- item the player never deposited.
local DEPOSIT_RESPONSE_WINDOW = 3 -- seconds

-- Abandon every outstanding arm. This is the "stop caring" path, NOT part of the
-- correction flow: components/frame.lua's OnHide calls it because a closed window
-- has no page to correct onto. CorrectPendingDeposit deliberately does not --
-- see ConsumePendingDeposit and the note above CorrectPendingDeposit itself.
function ExtBank:ClearPendingDeposit()
	self.pendingDeposits = nil
	self.claimedSlots = nil
end

-- Remember that a relocation to this cell is in flight, so the next packet's pass
-- does not pick it again while the model still shows it empty.
function ExtBank:ClaimSlot(bagIndex, slot)
	local claimed = self.claimedSlots
	if not claimed then
		claimed = {}
		self.claimedSlots = claimed
	end

	claimed[bagIndex] = claimed[bagIndex] or {}
	claimed[bagIndex][slot] = GetTime()
end

-- Whether a relocation to this cell is still outstanding.
--
-- Bounded by the same DEPOSIT_RESPONSE_WINDOW as the arms, and for the same
-- reason: a relocation the server silently refused is never answered, so an
-- unbounded claim would block a genuinely free cell for the rest of the session.
-- Expiring in the reader rather than on a timer keeps this to one clock read on a
-- path that is already walking these cells.
function ExtBank:IsSlotClaimed(bagIndex, slot)
	local claimed = self.claimedSlots and self.claimedSlots[bagIndex]
	local at = claimed and claimed[slot]
	if not at then return false end

	if GetTime() - at > DEPOSIT_RESPONSE_WINDOW then
		claimed[slot] = nil
		return false
	end
	return true
end

-- Spend exactly one arm: one right-click's worth of "waiting for an answer".
--
-- Oldest first. The server answers in the order it received, and one packet
-- carries one move (measured -- every response in a six-deposit burst was its own
-- packet), so the oldest outstanding click is the one any given answer is about.
function ExtBank:ConsumePendingDeposit()
	local pending = self.pendingDeposits
	if not pending or #pending == 0 then return end

	table.remove(pending, 1)

	if #pending == 0 then
		self.pendingDeposits = nil
	end
end

-- A LIST, not a single slot. A player emptying several items into the vault
-- clicks well within one server round trip, and a single slot meant every click
-- but one was silently dropped: the second click overwrote the first's arm
-- before any response landed, so only one of them ever got the page-aware
-- correction the README promises.
function ExtBank:ArmPendingDeposit()
	local pending = self.pendingDeposits
	if not pending then
		pending = {}
		self.pendingDeposits = pending
	end
	pending[#pending + 1] = GetTime()
end

-- How many armed clicks are still waiting on an answer, dropping any that have
-- aged out on the way past.
--
-- Expiry matters because not every armed click results in a deposit, and one
-- that doesn't is never answered. Two ways that happens: UseContainerItem
-- reaches us but not the native deposit (it hooks
-- ContainerFrameItemButton_OnClick, we hook the API, so a /run or another
-- addon's call arms only ours), and right-clicks the server rejects outright
-- (vault full, no bag equipped, empty source slot, a container that still has
-- items in it). A rejection looks exactly like silence, so the client can't
-- tell them apart -- bounding the lifetime covers all of them without having to.
function ExtBank:HasPendingDeposits()
	local pending = self.pendingDeposits
	if not pending then return 0 end

	local now, live = GetTime(), 0
	for i = 1, #pending do
		if now - pending[i] <= DEPOSIT_RESPONSE_WINDOW then
			live = live + 1
			pending[live] = pending[i]
		end
	end
	for i = #pending, live + 1, -1 do
		pending[i] = nil
	end

	if live == 0 then
		self.pendingDeposits = nil
	end
	return live
end

function ExtBank:IsBagOnCurrentPage(bagIndex)
	local itemFrame = self.window and self.window:GetItemFrame()
	if not itemFrame then return false end

	for _, b in itemFrame:GetVisibleBags() do
		if b == bagIndex then return true end
	end
	return false
end

-- The slice of ExtBank.cells that GetVisibleBags (this frame's current page)
-- actually covers, first cell with no item in it.
--
-- Skips anything already promised to an earlier relocation whose answer is still
-- outstanding (see IsSlotClaimed): the server hasn't answered those yet, so the
-- model still shows them empty, and without the check every deposit in a burst
-- would be sent to the same cell.
--
-- Returns nil plus a reason rather than a bare nil, because there are three
-- different ways to have nowhere to put it and the player was previously told
-- "current page is full" for all three -- including the case where they have
-- simply toggled every bag off and the page holds no slots at all.
function ExtBank:GetCurrentPageFreeSlot()
	local itemFrame = self.window and self.window:GetItemFrame()
	if not itemFrame then return nil, nil, 'nowindow' end

	local anyBags = false
	for _, bagIndex in itemFrame:GetVisibleBags() do
		anyBags = true
		local size = (self.bags[bagIndex] and self.bags[bagIndex].size) or 0
		local cells = self.cells[bagIndex]

		for slot = 0, size - 1 do
			if not (cells and cells[slot]) and not self:IsSlotClaimed(bagIndex, slot) then
				return bagIndex, slot
			end
		end
	end

	return nil, nil, (anyBags and 'full' or 'nobags')
end

-- Called from ParsePacket (core/model.lua) with the list of cells that packet
-- put items into, once the model has caught up with whatever the server did in
-- response to a deposit HookInventoryDepositWatch below saw coming.
--
-- It no-ops when nothing is armed, when the click didn't actually result in a
-- deposit (e.g. the item wasn't vault-eligible), or when the item already landed
-- on the page being looked at -- but per this file's header, that last case means
-- specifically "the current page includes ext bag 0". Off such a page this runs
-- on essentially every deposit, so treat it as a hot path, not an edge case.
--
-- Bounded by the number of live arms, and that bound is load-bearing rather
-- than tidiness: a kind == 0 snapshot reports every occupied cell as newly
-- gained, because ClearModel wipes the model before the cell list is applied.
-- Without the bound, one armed click answered by a full refresh would march the
-- entire vault onto the current page.
--
-- ARM LIFECYCLE -- an arm dies only by being SPENT on an answer, or by ageing
-- out of DEPOSIT_RESPONSE_WINDOW. It is never spent merely because a packet
-- arrived, and this is the whole point:
--
-- An earlier version opened with an unconditional ClearPendingDeposit(), which
-- destroyed every arm on EVERY packet. That made the correction self-defeating,
-- because our own relocation's result is itself a packet: the echo landed while
-- the NEXT click's arm was live, wiped it, then did nothing (its cell is on the
-- current page -- we just put it there), and that next click's own deposit
-- packet then found nothing armed. Measured in a six-deposit burst, deposits 2
-- and 5 were silently left on the wrong page for exactly this reason, in an
-- alternating pattern: every correction killed the fix queued behind it.
--
-- So the rule is by DESTINATION, not by packet:
--   off-page gained cell -> answers an armed click: spend one arm, relocate it
--   on-page gained cell  -> spend NOTHING. It is either our own echo (always
--                           on-page, since our corrections target the current
--                           page by construction) or a deposit that already
--                           landed where the player is looking and needs no
--                           action. Neither wants an arm.
--
-- The cost of that asymmetry is an unspent arm lingering up to the window when a
-- deposit lands on-page. That only loosens the snapshot bound slightly, and it
-- fails in the safe direction -- unlike spending arms on echoes, which drops
-- real corrections on the floor.
-- `arms` is the live arm count, passed in by ParsePacket rather than re-derived
-- here: HasPendingDeposits sweeps and compacts the pending list in place, so
-- calling it again would run that mutation a second time for one packet. See the
-- comment at its call site in core/model.lua for why the value is still valid by
-- the time we get it.
function ExtBank:CorrectPendingDeposit(gained, arms)
	if arms == 0 or not gained then return end

	-- ParsePacket calls us BEFORE it broadcasts EXTBANK_MODEL_UPDATED, so the
	-- item frame hasn't reconciled yet and its cached page lists still describe
	-- the previous packet. That matters whenever this packet also equipped or
	-- unequipped a bag, since GetAllVisibleBags filters on GetBagSize() > 0 --
	-- we would otherwise decide "is this bag on the current page?" against a
	-- page that no longer exists in that shape. Cheap to drop; UpdateEverything
	-- drops them again a moment later anyway.
	local itemFrame = self.window and self.window:GetItemFrame()
	if itemFrame then
		itemFrame:InvalidateVisibleBags()

		-- And clamp the page, for the same reason and in the same breath. The page
		-- lists are about to be rebuilt from currentPage, which UpdateEverything's
		-- own clamp has not reached yet -- so if this packet also dropped the bag
		-- count (unequipping a bag mid-deposit), currentPage can still name a page
		-- that no longer exists. GetCurrentPageBags then computes a start index past
		-- the end, yields nothing, and caches an EMPTY page: every landed cell reads
		-- as off-page, the arm is spent, and GetCurrentPageFreeSlot reports 'nobags'
		-- -- telling the player "no bag shown on this page" while bags are plainly
		-- on screen, and relocating nothing.
		--
		-- ClampCurrentPage, not SetCurrentPage: the latter runs a full synchronous
		-- UpdateEverything and sends ITEM_FRAME_PAGE_UPDATE, which is both wasted
		-- (the broadcast at the end of this packet does it anyway) and re-entrant
		-- from inside ParsePacket.
		itemFrame:ClampCurrentPage()
	end

	local complained
	for i = 1, #gained do
		if arms == 0 then return end

		local landed = gained[i]
		if not self:IsBagOnCurrentPage(landed.bagIndex) then
			-- Spent here, BEFORE working out whether anything can be done about
			-- it. A deposit we can't relocate has still been answered; leaving
			-- its arm live would have the next packet retry a correction for an
			-- item already given up on, and re-print the message with it.
			arms = arms - 1
			self:ConsumePendingDeposit()

			local dstBag, dstSlot, why = self:GetCurrentPageFreeSlot()
			if not dstBag then
				-- Once per packet, not once per item -- a bulk deposit into a
				-- full page would otherwise print the same line a dozen times.
				if not complained and why ~= 'nowindow' then
					complained = true
					if why == 'nobags' then
						UIErrorsFrame:AddMessage('Void Storage: no bag shown on this page -- item stored on another page', 1, 0.8, 0)
					else
						UIErrorsFrame:AddMessage('Void Storage: current page is full -- item stored on another page', 1, 0.8, 0)
					end
				end
				return
			end

			-- Claimed only if the request actually went out. Move returns false when
			-- ebonhold.dll's native is not callable, and claiming a cell we never
			-- asked for would block it for the whole response window.
			if self:MoveWithinVault(landed.bagIndex, landed.slot, dstBag, dstSlot) then
				self:ClaimSlot(dstBag, dstSlot)
			end
		end
	end
end


--[[ Stuck-item warning ]]--
-- A right-click deposit the server refuses doesn't just fail quietly: it
-- leaves the item permanently greyed out in the player's bags and completely
-- untouchable -- it can't be picked up, used, sold or moved. Confirmed
-- in-game, including that it won't respond to a mouse drag at all, so this is
-- a genuinely stuck item and not just a cosmetic tint.
--
-- Why it happens, in order:
--   1. Blizzard's own ContainerFrameItemButton_OnClick runs first and calls
--      UseContainerItem. With a banker session live (the only state the vault
--      can be open in -- extBank.lua closes on BANKFRAME_CLOSED) the client
--      reads that as a bank deposit: it flags the item locked and sends
--      CMSG_AUTOSTORE_BANK_ITEM.
--   2. ebonhold.dll swallows that packet on the wire -- see extbank_client.h,
--      ExtBank_ShouldDropSend / Detour_NetSend -- so the item never lands in
--      the REAL bank. Its own comment explains why it has to: extBank.lua's
--      deposit is a hooksecurefunc post-hook, which runs too late to cancel
--      Blizzard's native deposit, so it's killed at the socket instead.
--   3. Because the packet never reaches the server, nothing ever answers it,
--      and the client's optimistic lock is never released.
--   4. Separately, extBank.lua's post-hook fires its own ExtBankMove, which
--      the server DOES receive and refuse ("No free slot accepts that item"),
--      leaving the item sitting in the bag -- still locked.
--
-- So the lock is orphaned client state, and it lives in the client's own item
-- data rather than in the UI -- which is why GetContainerItemInfo reports it,
-- and why /reload does NOT clear it: a reload restarts the Lua VM but never
-- re-requests item data.
--
-- What DOES clear it is the server writing that slot again. Nothing in Lua can
-- ask for that directly, but it falls out of any real inventory change the
-- server accepts, and a full relog is only the blunt instance of it (every slot
-- rebuilt at once). Observed in-game, and the shape of the observation is what
-- pins the rule down to the SLOT: with two items stuck at the same time,
-- withdrawing ore from the vault un-stuck the stuck ore and left the stuck
-- potion greyed. The ore came back into the stack that was already stuck, so
-- that one slot got rewritten and no other did -- and withdrawing into a
-- different bag entirely, where nothing merges, leaves the greyed item greyed.
--
-- Not settled, and left that way on purpose since nothing depends on it: this
-- can't yet distinguish "the server rewrote that slot" from "the client
-- refreshed every slot holding that item ID". The test that separates them is
-- to get a FULL stack stuck (nothing can merge into it) and then withdraw the
-- same item, forcing it into a fresh slot -- still greyed means the rule is
-- per-slot as written above.
--
-- Either way this is not a recovery route worth telling players about. It needs
-- the stuck item to be stackable, a matching stack sitting in the vault, room
-- left in the stuck stack, and the server's autostore to pick that stack over
-- any other -- four conditions, each of which fails silently.
--
-- The route the warning message DOES give is unconditional: make the vault able
-- to accept the item (equip a bag, or free a slot) and right-click it AGAIN.
-- The lock is never released there -- it just stops mattering, because
-- extBank.lua's post-hook fires a second ExtBankMove, the server accepts this
-- one, and the item is removed from the bag server-side. An empty slot has
-- nothing left to keep locked. Note the item ends up in the VAULT, not restored
-- in place. Confirmed in-game rather than merely reasoned: a greyed item
-- right-clicks into the vault normally once there is room for it.
--
-- Verified dead ends, so they don't get re-tried later: ExtBankMove'ing the
-- item onto its own slot, and ExtBankMove'ing it to the first free live
-- inventory slot (dstBag 0xFE), both leave it greyed -- consistent with the
-- above, since neither one gets the server to write the slot. Preventing
-- the lock in the first place would mean stopping UseContainerItem from
-- running at all, i.e. replacing a Blizzard API global -- out of scope.
--
-- What's left is to make sure the player understands what happened rather
-- than being left with a dead item and no explanation.

-- How long after the click to look. Long enough that a deposit which WORKED
-- has already emptied the slot (a refusal and a success are indistinguishable
-- at click time -- both are silence from our side), short enough that the
-- message still reads as feedback for the click that caused it.
local STUCK_CHECK_DELAY = 2 -- seconds

-- How long to wait before looking a second time, when the first look found
-- the player carrying the item (see the cursor guard below). Only needs to
-- outlast the drop, not another server round trip.
local STUCK_RECHECK_DELAY = 1 -- seconds

-- Scheduled STUCK_CHECK_DELAY after every deposit click. Deliberately checks
-- the SYMPTOM rather than predicting it from "the vault had no room": that
-- catches every reason the server refuses (no bag equipped, vault full, an
-- item it won't take, a container that still has items in it) without this
-- file having to keep its own copy of the server's rules.
function ExtBank:CheckDepositStuck(bag, slot, link, rechecked)
	if not link then return end

	-- The deposit went through -- the slot is empty now, or the bags have been
	-- rearranged since and it holds something else. Nothing stuck either way.
	if GetContainerItemLink(bag, slot) ~= link then return end

	-- Still sitting there AND still flagged locked. A deposit that failed
	-- without orphaning a lock would leave the item here unlocked and
	-- perfectly usable, which needs no warning.
	if not select(3, GetContainerItemInfo(bag, slot)) then return end

	-- An item the player is merely HOLDING looks identical to a stuck one at
	-- this point: 3.3.5 leaves a picked-up item in its slot, flagged locked,
	-- until the move completes -- the same behavior GetVerifiedCursorSource
	-- (core/cursor.lua) relies on. So "locked" can't tell a carried item from
	-- an orphaned lock; cursorSrc can, because the PickupContainerItem hook
	-- records which slot the held item came out of.
	--
	-- Looked at once more rather than dropped, because the ambiguity is
	-- temporary in one direction only: a genuinely stuck item is still stuck a
	-- second later, while a carried one has almost always been put down by
	-- then. Once, not in a loop -- a player who parks an item on the cursor
	-- and walks away shouldn't leave a timer rearming itself forever, and
	-- unlike the deposit lock, "still carrying it" is a state they can see.
	-- Verified, not read raw. cursorSrc is only written by the PickupContainerItem
	-- hook, so it holds "where the last item picked up out of a container came
	-- from", which core/cursor.lua spends fifty lines explaining is not the same as
	-- "where the thing on the cursor now came from" -- ClearCursor leaves the
	-- coordinates behind, and PickupInventoryItem loads the cursor without touching
	-- them. Comparing them raw meant an unrelated carried item (a weapon dragged off
	-- the character pane) whose stale coordinates happened to name this slot read as
	-- "the player is just holding this one", suppressing the warning on the recheck
	-- and leaving a genuinely stuck item unexplained for good. The link check is the
	-- same one GetVerifiedCursorSource already does for drops.
	local src = self:GetCarriedInventorySource()
	if src and src.bag == bag and src.slot == slot then
		if not rechecked then
			self:ScheduleTimer('CheckDepositStuck', STUCK_RECHECK_DELAY, bag, slot, link, true)
		end
		return
	end

	self:ReportStuckItem(link)
end

-- One message, printed in full every time a stuck item is found. Not
-- de-duplicated: each message answers one right-click the player just made,
-- so a repeat is feedback for a repeated action rather than spam. The two
-- recovery routes are the whole point of the message -- the opening clause
-- only says something went wrong -- so withholding them from a player who is
-- evidently still stuck would be backwards.
--
-- Nothing here remembers which items it has already reported, deliberately.
-- A per-item key would have to be keyed on something (bag, slot, link) that
-- an unrelated item can legitimately come to occupy later, which turns one
-- wrong report into permanent silence for the next real one -- a worse
-- failure than saying it twice.
--
-- Sent as a single AddMessage rather than three so it lands as one block in
-- the chat frame -- three calls could be split apart by whatever else is
-- printing at that moment (loot, combat spam), which is how a warning ends up
-- read as three unrelated fragments.
function ExtBank:ReportStuckItem(link)
	-- "Make room in the vault" rather than "equip a bag", because that is the
	-- actual precondition -- the re-click works whenever the vault can accept
	-- the item, and a player stuck because it was FULL needs to free a slot,
	-- not add a bag. Equipping is parenthesised as the common case only.
	--
	-- The re-click fix doubles as the prevention advice (it is the same action
	-- either way), which is why no separate "to avoid this next time" half is
	-- needed -- that collapse is most of what keeps this short.
	DEFAULT_CHAT_FRAME:AddMessage(("|cffff5555Void Storage:|r %s is stuck -- it can't be used, moved or sold. |cffffd200Fix:|r make room in the vault (equip a bag in the strip above), then right-click it again. |cffffd200Or:|r log out and back in -- /reload won't work."):format(link))
end

-- UseContainerItem is a plain stock Blizzard global, always present --
-- unlike core/nativeHooks.lua's own targets (_G.ExtBankOpen/etc, which only
-- exist once ebonhold.dll's natives have loaded), this needs no
-- PLAYER_LOGIN/load-order gating and can hook immediately from OnEnable.
local depositWatchHooked = false

function ExtBank:HookInventoryDepositWatch()
	if depositWatchHooked then return end

	hooksecurefunc('UseContainerItem', function(bag, slot)
		if not (bag and bag >= 0 and bag <= 4) then return end -- not real live-inventory (bank, keyring, ...)

		-- "Is the vault open?", and our own window being on screen is only half of
		-- that. On the session's first open main.lua waits for the snapshot before
		-- showing anything (~100ms, longer if it is late, forever if it never comes),
		-- but the NATIVE side set its own isOpen the moment ExtBank_Open ran -- so its
		-- right-click deposit post-hook is already live in that gap, and a deposit
		-- made there is a real deposit that can be really refused. Gated on IsShown()
		-- alone, neither the page correction nor -- the part that matters -- the
		-- stuck-item warning armed for it, leaving the player with an item that cannot
		-- be used, moved or sold and nothing on screen explaining why.
		if not (ExtBank:IsWaitingForModel()
			or Bagnon.FrameSettings:Get(ExtBank.FRAME_ID):IsShown()) then return end
		ExtBank:ArmPendingDeposit()

		-- Read the link HERE, not in the check itself: by then the slot may be
		-- empty (deposit worked) or hold something else, and the check needs to
		-- know what was actually clicked to tell those apart. A locked item is
		-- still fully readable in its slot, so this works for the stuck case too.
		ExtBank:ScheduleTimer('CheckDepositStuck', STUCK_CHECK_DELAY, bag, slot, GetContainerItemLink(bag, slot))
	end)

	depositWatchHooked = true
end
