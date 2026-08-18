# Non-issues — findings investigated and deliberately not fixed

A register of code-review findings that look like real defects, were checked
properly, and were left alone on purpose.

It exists because these keep getting re-raised. The reasoning behind each one is
not visible from the code — it lives in the *original* addon this module mirrors,
or in server behaviour that no source in this repo describes. A reviewer reading
only `core/model.lua` will flag them again, correctly, every single time.

Each entry records what gets flagged, why it is not a bug, and — importantly —
**what evidence would reopen it**. None of these is "won't fix because it is
hard". They are all "the obvious fix is the riskier option".

If you are a reviewer and you have landed here from a code comment: the entry
below is an argument, not a rule. If you can supply the evidence in its *Reopen
if* section, the verdict changes.

Orientation for the paths below. `core/…` and `components/…` are this addon,
one directory up from here. `../Bagnon`, `../Bagnon_Config` and "the vendored
fork" mean the Bagnon addon folder sitting *beside* this one — true whether that
is a dev checkout or `Interface\AddOns`, since Bagnon installs as a sibling.
`extBank.lua` is ProjectEbonhold's own vault module, which ships inside the
client rather than on disk.

---

## The mirroring policy, once

`core/model.lua` is a field-for-field port of `ExtBank_OnPacket` in
ProjectEbonhold's own `modules/extBank/extBank.lua`. That addon parses the same
`SMSG_EXTBANK_UPDATE` payload, but keeps its model in `local` upvalues that
nothing outside the chunk can read — so we decode the same bytes a second time
rather than reusing its result.

Both readers therefore run on **every** packet, ours chained after theirs. Two
consequences drive most of this file:

1. **Divergence is a cost, not a neutral.** The port's value is that it can be
   diffed against the original and read as obviously equivalent. A local
   "improvement" makes the next protocol change harder to apply.
2. **We are never the first to see a malformed packet.** The native reader
   already ran and already threw. Hardening only our copy does not spare the
   player anything; it changes which addon's name appears in the error.

Where the original's assumptions are *empirically validated by the native UI
working in game*, deviating from them means betting against evidence.

---

## 1. Short-packet guard admits a 4-byte payload

**Where:** [`core/model.lua`](../core/model.lua) — `if type(hex) ~= 'string' or #hex < 8 then return end`
**Mirrors:** `extBank.lua:59`, byte-identical.

**What gets flagged.** The fixed header is 5 bytes (`kind`, `unlockedBags`,
`nBags`, `u16 nCells`) = 10 hex characters, but the guard only requires 8. A
4-byte payload passes it and then errors on `b[5]` — *"attempt to perform
arithmetic on a nil value"*. `#hex < 10` looks like the obvious floor.

**Why it stays.**

- **It is not a bounds check and never was.** A packet with a truthful header but
  a lying `nBags`/`nCells` overruns and dies exactly the same way. Raising the
  constant closes one arbitrary case out of many, while implying to the next
  reader that the parser validates length. It does not.
- **Unreachable in practice.** A 4-byte `SMSG_EXTBANK_UPDATE` is not a shape the
  server emits.
- **The native handler errors first.** We chain after it (see
  `core/nativeHooks.lua`), so such a packet throws on `extBank.lua`'s identical
  guard before `ParsePacket` is reached.

**Reopen if:** a malformed packet is actually observed on the wire, or the
mirroring policy is dropped. The fix then is real bounds checking on every read
— not a bigger constant.

*Dispositioned 2026-08-16; re-raised and re-confirmed the same day.*

---

## 2. `nBags` records and `unlockedBags` are consumed only under `kind == 0`

**Where:** [`core/model.lua`](../core/model.lua) — the `if kind == 0 then` branch.
**Mirrors:** `extBank.lua:63-79`, structurally identical.

**What gets flagged.** `nBags` is read unconditionally as part of the header, but
the `nBags * { u8 bagIndex, u32 itemId, u32 lowGuid, u8 size }` records — 11
bytes each — are consumed only inside the `kind == 0` branch. So a packet with
`kind ~= 0` and `nBags > 0` would leave `p` pointing at the first bag record when
`u16 nCells` is read, decoding every cell from the wrong offset. `self.unlockedBags
= ub` is likewise assigned only inside that branch, so a delta reporting a newly
purchased slot would leave the model stale — slot greyed out, price misquoted.

Both halves are real readings of the code. Neither is reachable.

**Why it stays.**

- **The native UI would break identically.** This is the decisive point. If the
  server ever sent `kind ~= 0` with `nBags > 0`, ProjectEbonhold's own Void
  Storage window would desync in exactly the same way, for every player on the
  server. It does not. So the server sets `nBags = 0` whenever `kind ~= 0`.
- **The same applies to the dropped `ub`.** `extBank.lua:97` reads `unlockedBags`
  immediately after parsing (`if activeBag >= unlockedBags then ...`). If unlock
  confirmations arrived as deltas rather than snapshots, the *native* purchase
  flow would visibly fail to refresh. It does not, so unlocks come as snapshots.
- **The suggested fix is the riskier one.** "Consume the bag block for every
  `kind`" assumes `nBags` always counts records that are physically present.
  The current code assumes the server only writes that block for snapshots —
  an assumption the working native client validates on every session. Swapping a
  validated assumption for an unvalidated one is a downgrade, and if it is wrong
  it desyncs in the opposite direction, on the packets that currently work.

**Not verifiable locally.** `ebonhold.dll` forwards the raw payload to
`ExtBank_OnPacket` as hex without parsing it (`extbank_client.h`), so the
`kind`/`nBags` relationship is decided entirely server-side. No source available
here settles it; the native client's observable behaviour is the only evidence
we have, and it points one way.

**Reopen if:** a `kind ~= 0` packet carrying `nBags > 0` is captured on the wire,
or the native Void Storage window is seen to desync after a vault operation. Then
both halves are genuine and the parser needs a real fix — consume the bag block
unconditionally *and* bound the record loops on the actual byte count.

*First raised 2026-08-16.*

---

## 3. `nativeWindowHooked` is set even when the native side panel was absent

**Where:** [`core/nativeHooks.lua`](../core/nativeHooks.lua) — `ExtBank:HideNativeWindow()`.

**What gets flagged.** The early return covers only a missing `_G.ExtBankFrame`. If the
main frame exists but `_G.ExtBankBagFrame` does not, the `if nativeSide then` block is
skipped, yet `nativeWindowHooked = true` still runs — so every later open returns
immediately and the native bag-slot panel is never hooked and never hidden. It would sit
on screen alongside our window for the rest of the session, which is the exact
duplicate-UI state the function exists to prevent.

**Why it stays: the state is not reachable.**

`BuildUI()` in `extBank.lua:243-300` is straight-line code. It creates `ExtBankFrame` at
line 244 and `ExtBankBagFrame` at line 278, with nothing between them but unconditional
property setters on the frame it just made, plus one `UIPanelCloseButton`. No branches, no
early returns, no `pcall`. Both are named `CreateFrame` calls, so each populates `_G` the
instant it runs, and lines 233/244/278 are the only places those two frames are ever
assigned in the whole file.

The ordering is what closes it. `BuildUI()` has exactly one caller — `ExtBank_Open()` at
`extBank.lua:606`, `if not frame then BuildUI() end` — and our hook chains *after* the
native function: the `ExtBank_Open` chain calls `previousOpen(...)` first, then
`ExtBank:OnNativeOpen()`, which reaches `HideNativeWindow()`. By the time we look, the
native open has returned and `BuildUI()` has run to completion.

That leaves two possible states, and the code already handles both:

- `BuildUI()` never ran → neither global exists → caught by `if not native then return end`,
  flag correctly left false to retry next open.
- `BuildUI()` ran → **both** globals exist.

"Main frame present, side panel absent" requires `BuildUI()` to have thrown somewhere in
the 30 lines between 244 and 278. That would abort the native open with a visible Lua
error and leave the vault broken natively, for every player, with or without this addon.

**Moving `nativeWindowHooked = true` inside `if nativeSide then` is not the fix.** It is
dead code, since the branch is unreachable — and if the state *were* reachable it would be
actively wrong: leaving the flag false means the next open re-enters and runs
`hooksecurefunc(native, 'Show', native.Hide)` on the main frame *again*. `hooksecurefunc`
stacks rather than replaces, so every subsequent open would add another post-hook to a
chain that never stops growing. Nothing visibly breaks — `Hide()` is idempotent — but
`ExtBankFrame:Show()` ends up walking an ever-longer chain of closures for the life of the
session. A real fix would need one flag per frame, so each is hooked exactly once, not a
relocated assignment.

The `if nativeSide then` guard itself is worth keeping. It costs nothing, and it is honest
about the fact that we do not own that frame.

**Reopen if:** `ExtBankBagFrame` is observed nil while `ExtBankFrame` is non-nil at the top
of `HideNativeWindow`, or ProjectEbonhold changes `BuildUI` to construct the side panel
lazily. The fix is then per-frame flags — never a moved assignment.

*Investigated 2026-08-16 against `extBank.lua`'s `BuildUI` and the open-chain ordering.*

---

## 4. No `IsAddOnLoaded` fallback if `Bagnon_Config` is already loaded

**Where:** [`components/frameOptions.lua`](../components/frameOptions.lua) — the
`ADDON_LOADED` watcher.

**What gets flagged.** The whole options-panel patch is armed only by a *future*
`ADDON_LOADED` for `Bagnon_Config`. If that addon were already loaded when this file runs,
the event has fired and the handler never will — silently costing the "Void Storage"
dropdown entry, the Bags Per Page slider, the credit block, and the graying of the two
checkboxes that must not be live. `main.lua` guards the identical race for `PLAYER_LOGIN`
with `if IsLoggedIn() then ... end`, so the asymmetry looks like an oversight.

**Why it stays: it is not possible on 3.3.5a.**

The finding rests entirely on the premise that the client re-loads previously-loaded
load-on-demand addons during a `ReloadUI` startup. **That premise is false on WotLK
3.3.5a.** Tested in game on the live Ebonhold client, not reasoned about:

> Fresh login → open the vault → click its gear, which loads `Bagnon_Config` and shows the
> panel (dropdown row, slider and credits all confirmed present) → `/reload` → before
> touching the options panel, `/run print(IsAddOnLoaded('Bagnon_Config'))` → **nil**.

The addon was not re-loaded, so its `ADDON_LOADED` never fired ahead of ours. Opening the
options panel afterwards loads it for the first time that session, the still-armed watcher
catches it, and the full integration applies — verified on screen after the reload.

Nothing else reaches the bad ordering either. Every `LoadAddOn('Bagnon_Config')` call site
in the vendored fork is a click handler — `Bagnon\main.lua:40` (options-loader `OnShow`),
`main.lua:403`, `components/titleFrame.lua:77`, `components/optionsToggle.lua:57` — all of
which run long after `Bagnon_ExtBank` has loaded and registered the watcher. No installed
addon force-loads it at startup.

The only ways in are synthetic: setting `## LoadOnDemand: 0` in `Bagnon_Config.toc`, or a
third addon that force-loads it during the startup sequence. Neither is a state a player
lands in.

So this is not a bug — it is an unguarded load-order assumption that the platform happens
to guarantee. The three-line guard would be harmless in itself, but adding it asserts that
the race is real and invites the next reader to preserve a defence against nothing.

**Reopen if:** the vendored fork stops shipping `Bagnon_Config` as load-on-demand, a
startup-time `LoadAddOn('Bagnon_Config')` call site appears, or the options integration is
ever observed missing after a `/reload`.

*Verified in game 2026-08-16; re-raised and re-confirmed the same day.*

---

## 5. Item cells draw no quality border, and uncached items show `?`

`components/item.lua`'s `ItemSlot:Update` sets a texture and a count and nothing else. Core
Bagnon's own `ItemSlot` calls `SetBorderQuality` (`Bagnon/components/item.lua:264`), which
colours a border texture from `GetItemQualityColor`. So an epic and a grey look identical in
the vault while the player's bags, bank and guild bank — same Bagnon chrome, same window —
draw the rarity outline. It is the single most obvious visual gap in the addon and it gets
flagged by every reviewer who reads `item.lua` on its own.

**This was implemented once and reverted.** Two independent blockers, both outside this
addon, and neither visible from the file being reviewed.

**The server does not send quality.** The cell record is, in full (`core/model.lua`):

```
u8 bag, u8 slot, u32 itemId, u32 count, u32 lowGuid, u32 enchant, i32 randomProp, u8 durability
```

There is no quality field. `ParsePacket` is a field-for-field mirror of `extBank.lua`'s own
reader, so this is not a field we forgot to parse — it is not on the wire. The same is true
of the item's name, icon and everything else that would come from item data.

**The client cannot be made to fill the gap.** The only remaining source is
`GetItemInfo(itemId)`/`GetItemIcon(itemId)`, which read the local item cache, and this
server does not answer bulk item queries. The observed result of the earlier attempt was
borders on *some* items and not others — which is worse than none, because a cell with no
border becomes ambiguous between "this is a grey item" and "the client has not cached this
item". The same cache is why uncached items render `INV_Misc_QuestionMark` with an empty
tooltip on a fresh login.

And there is nothing to retry against: 3.3.5a has no `GET_ITEM_INFO_RECEIVED`. A polling
retry would be re-issuing exactly the queries the server is already declining, on a timer,
for every cell in the vault.

**Scoped 2026-08-17 — the hovered cell is the one exception, and it does not reopen this
entry.** A first hover was already sending a *single-item* query (the side effect of
`SetHyperlink`), and the server does answer those — a second hover of the same item has
always shown a complete tooltip. What was broken was purely client-side rendering order:
the tooltip drew from the cache before the answer landed, and nothing redrew it after.
`SetTooltipItem` (`components/widget.lua`) now shows a "Retrieving item information"
placeholder and watches the local cache — one query per hover, no re-asking, a 5s cap —
then rebuilds the tooltip and the icon together. What stays out of reach is exactly what
this entry describes: *bulk* resolution, borders and icons for every cell at once,
unprompted by a hover. The queries it needs are the ones the server declines, and
partial resolution across the grid is still the failure mode for the border feature.

Confirmed in game 2026-08-17, cold-cache test: with `Cache\WDB\enUS`'s `itemcache.wdb`
and `itemnamecache.wdb` deleted, the placeholder resolves into the full tooltip on the
first hover — so the server answers hover-triggered single-item queries even from a
completely empty cache. The native vault UI on the same cold cache renders the miss and
never recovers until re-hovered, so this is a deliberate improvement over the mirror,
not a divergence to re-litigate. The same test settled a "regression" report against
the addon: first-hover tooltips had *seemed* fine for weeks only because the cache was
warm (every deposited item passes through the player's bags and is cached there), and
went visibly wrong when a client update wiped the WDB cache — no addon commit changed
first-hover behaviour. The name-only stub is the split caches: `itemnamecache` can
answer while `itemcache` still can't.

Note the two symptoms are one cause. A fix for the `?` icons is a fix for the border and
vice versa; neither can be done without the other, and neither can be done from Lua.

**Reopen if:** `SMSG_EXTBANK_UPDATE` starts carrying a quality byte — it would show up in
`extBank.lua`'s own reader first, and `core/model.lua` should be re-mirrored against it — or
the server starts answering item queries for uncached items reliably enough that *every*
cell resolves. Partial resolution is the failure mode, not a partial success.

---

## 6. `reverseSlotOrder` looks unread by both layout paths

`components/savedFrameSettings.lua` ships `reverseSlotOrder = false` as a real persisted
default, `ItemFrame` subscribes to `SLOT_ORDER_UPDATE`, and Bagnon_Config leaves the
"Reverse Slot Order" checkbox **live** for this frame (only `guildbank` is greyed —
`Bagnon_Config/panels/frameOptions.lua:266`). Meanwhile a repo-wide grep finds no reader:
both `Layout_Default` and `Layout_BagBreak` iterate `for slot = 0, GetBagSize(bagIndex) - 1`
ascending and unconditionally. It reads as a setting wired to nothing.

It is not. The reversal happens one level up, inside core: `FrameSettings:GetVisibleBagSlots`
(`Bagnon/components/frameSettings.lua:447`) returns a *reversed iterator* when the setting is
on, and `ItemFrame:GetAllVisibleBags` consumes exactly that iterator. So toggling the box
reverses bag order in the grid.

Core's own item frame does no more than this — `Bagnon/components/itemFrame.lua:364` is the
same unconditional ascending `for slot = 1, self:GetBagSize(bag)`. Reversing slots *within* a
bag is not a thing Bagnon does anywhere, for any frame. This addon therefore honours the
setting to precisely the degree core honours it, which is the correct target: a Void Storage
window that reversed slot-within-bag while the bag window next to it did not would be the
actual bug.

**Reopen if:** core Bagnon starts reversing slots within a bag, at which point this frame
should match it.

---

## 7. Three claims about vendored code that are simply false

Grouped because they share a cause: each is a guess about `../Bagnon` made without reading
it. The source is on disk, one directory up. Read it before flagging any of these again.

**`ScheduleTimer` only forwards one argument.** The claim is that the WotLK-era
AceTimer-3.0 signature is `ScheduleTimer(callback, delay, arg)`, so `core/deposit.lua`'s
stuck-item check receives a nil `link` and the whole feature is dead code. The vendored
library is `Bagnon/libs/AceTimer-3.0/AceTimer-3.0.lua`, `MINOR = 1017` — the vararg rewrite:
`function AceTimer:ScheduleTimer(func, delay, ...)` (`:113`), `argsCount = select("#", ...)`
(`:86`), `unpack(timer, 1, timer.argsCount)` (`:307`). All arguments arrive. Three reviewers
raised this independently and all three were wrong.

**`GetDefaultExtBankSettings` hands out a shared mutable table.** The claim is that
memoizing `extBankDefaults` aliases one table across profiles, so "restore defaults" restores
current values. Core never keeps the reference: `SavedFrameSettings:GetDB()` runs
`copyDefaults(self.frameDB, self:GetDefaultSettings())` (`Bagnon/components/savedFrameSettings.lua:118`),
and `copyDefaults` recurses into subtables (`tbl[k] = copyDefaults(tbl[k] or {}, v)`, `:29`).
Every nested table is freshly allocated per frame.

**`SavedFrameSettings:GetFrameID()` does not exist.** The claim is that the settings classes
use `GetID()`, so the `frameID or self:GetFrameID()` fallback would throw. It is defined at
`Bagnon/components/savedFrameSettings.lua:123`, and core's own `GetDefaultSettings` carries
the identical fallback line. The wrap is a faithful mirror. (`FrameSettings` — a *different*
class — does use `GetID()`, which is what makes this look inconsistent.)

**Reopen if:** the vendored Bagnon is replaced with a build where any of the above is
actually true. Check the file, not the vintage.

---

## 8. The two `SetDisabled` calls in `frameOptions.lua`

Both get flagged, in mirror image: that `SetDisabled(isExtBank)` on the sort checkbox
re-enables it for frames core meant to disable, and that the one-directional
`SetDisabled(true)` on the bag-frame checkbox leaves it greyed for every frame once the
player has visited extbank. They cannot both be right, and in fact neither is —
`Bagnon_Config/panels/frameOptions.lua` settles it:

- The **bag-frame** checkbox is written unconditionally, both directions, on every pass:
  `self:GetToggleBagFrameCheckbox():SetDisabled(self:GetFrameID() == 'keys' or self:GetFrameID() == 'guildbank')`
  (`:257`). Core repairs it for us the moment the dropdown moves off extbank, so
  one-directional is enough.
- The **sort** checkbox is never passed to `SetDisabled` at all. The only three call sites in
  Bagnon_Config are `:257`, `:266` and `:269`, and none is the sort box. Nothing else
  competes for it, so driving both directions there is safe.

**Reopen if:** either of those lines changes shape in the vendored Bagnon_Config —
specifically if the bag-frame write becomes guarded, or the sort box gains a `SetDisabled`
call of core's own.

*Entries 5-8 verified against the vendored sources on 2026-08-17; entry 5's in-game
behaviour reported from an earlier build that implemented and then reverted the border.*

---

## 9. Escape calls `ExtBank_Close()` three times; the X button calls it once

**Where:** [`components/frame.lua`](../components/frame.lua) — `Frame:OnHide`, and
[`core/nativeHooks.lua`](../core/nativeHooks.lua) — the `_G.ExtBank_Close` wrapper.

**What gets flagged.** Closing our window with Escape produces three
`ExtBank_Close()` calls inside a single frame; the X button and walking away from
the banker each produce one. That looks like the close funnel re-entering itself,
which is the same failure family as the constructor re-entrancy that freezes the
client — so it reads as serious.

**Why it stays.** Measured with a `debugstack` on every call, across three
sessions. Only the first call is ours, and it is correct:

| # | Immediate caller | Whose code |
|---|---|---|
| 1 | `components/frame.lua:184` (our `OnHide`) ← `[C]: Hide` ← `FrameXML/UIParent.lua:2116` (`CloseSpecialWindows`) | ours, and required |
| 2 | `extBank.lua:697` (its `BANKFRAME_CLOSED` handler) ← `[C]: CloseBankFrame` ← `Bagnon/components/frame.lua:207` | ProjectEbonhold's |
| 3 | identical stack to #2 — `BANKFRAME_CLOSED` is dispatched twice | ProjectEbonhold's |

The mechanism is entirely outside this addon. Escape runs
`CloseSpecialWindows`, which hides *every* shown `UISpecialFrames` entry — and
core Bagnon registers one per frame at creation
(`Bagnon/components/frame.lua:38`). So Escape hides our vault window (→ call #1,
the branch that exists to keep `extBank.lua`'s `isOpen` upvalue honest) *and*
Bagnon's bank window, whose `OnHide` calls `CloseBankFrame()`
(`Bagnon/components/frame.lua:203-216`). That fires `BANKFRAME_CLOSED`
synchronously, and `extBank.lua` closes the vault from its own handler. Calls #2
and #3 are one addon calling its own global in response to an event another addon
raised; deduplicating them would mean suppressing ProjectEbonhold's calls to its
own code, which is not ours to do.

Note this route exists **only because of us**: `extBank.lua` registers nothing in
`UISpecialFrames` (only `voidStorage.lua:47` does, for a different frame), so
Escape does not touch the vault in the native UI at all. That is why it was worth
tracing rather than dismissing.

**Why the extra calls are harmless.** `extBank.lua`'s `ExtBank_Close` body is
idempotent — `isOpen = false`, a `Hide()` on an already-hidden frame,
`StaticPopup_Hide` on nothing, and a `RestoreBankPanel` that disarms itself via
`hidBankPanel`. On our side `OnNativeClose` reaches
`FrameSettings:Hide()`, whose counter clamps at zero rather than going negative,
and the re-entrant `OnHide` never fires because the frame is already hidden. The
only call with an effect outside the client is `ExtBankSetActive(0)`, repeated.

Measured behaviour after all three routes: window closed, session ended,
reopening took one click, no Lua error.

**Left unexplained on purpose.** `BANKFRAME_CLOSED` is dispatched **twice** on the
Escape route (once on walk-away), each time synchronously inside a
`CloseBankFrame()` from core Bagnon's `Frame:OnHide`. What drove the second hide
sat below the traceback's cut-off. It is not chased further because the answer
lies entirely between core Bagnon and the client, changes nothing here either way,
and calls #2 and #3 are already accounted for whatever it turns out to be.

**Reopen if:** `components/frame.lua` appears **more than once** in a single
Escape's stacks — that would be genuine re-entrancy in our funnel and a real bug —
or if the call count changes shape (an *open* burst, rather than a close burst,
would be the dangerous one: `FrameSettings:Show()` increments the same counter
that `Hide()` decrements, and only the clamp at zero is currently absorbing the
imbalance).

**Related, deliberately not done.** `OnNativeClose` calls `FrameSettings:Hide()`,
which decrements, where `Hide(true)` would force. Forcing is arguably the honest
expression of intent — this window has exactly one owner, unlike core's inventory
that the bank auto-opens — but there is no symptom behind it, so it is recorded
here rather than changed.

*Dispositioned 2026-08-17 from probe logs; stacks reproduced on the X-button and
walk-away routes as controls.*

---

## 10. Hooking `_G.ExtBankMove` once, at load, silently stops working

**Where:** [`main.lua`](../main.lua) — `ExtBank:Move`.

**What looks reasonable.** `ExtBank:Move` re-resolves `_G.ExtBankMove` inside the
`type(...) == 'function'` guard on **every single call**, rather than caching the
function once — the pattern every other native wrapper here follows would suggest
hoisting it into a local at `OnEnable` or file load, the same way `_G.ExtBankUnlock`
looks cacheable right next to it. That reads like a missed tidy-up, and it is the
first thing the next person to touch this file will be tempted to "fix".

**Why it stays exactly as written.** `ebonhold.dll` re-registers `_G.ExtBankMove` as
a brand-new function object on **every `SMSG_EXTBANK_UPDATE`** — not once at load,
not once per session. Measured with a probe wrapper across multiple sessions: every
mid-session re-arm landed within 1ms of a `PKT` line with no exceptions, and a
wrapper installed once at open time was reliably displaced by the very first
snapshot packet, which arrives roughly 100ms after the window opens — before a
player could plausibly have deposited anything yet. `_G.ExtBankOpen`, a DLL native
hooked the identical way, showed no such behaviour, so this is specific to
`ExtBankMove` and not a general "you cannot hook a DLL native" problem.

Caching the global in a local would silently break under exactly this condition: it
would work for calls made before the first snapshot lands, then start calling a
stale, disconnected function object the DLL no longer routes anywhere — the item
picked up, the move simply never happening, and nothing in Lua to point at why.

**This addon is unaffected precisely because it does the "wrong-looking" thing.**
Reading `_G.ExtBankMove` fresh at call time, on every call, is what makes
re-registration invisible here. Any refactor toward caching it is the regression,
not the fix.

**Reopen if:** a future measurement shows the DLL has stopped re-registering the
global — that needs a fresh multi-session probe run to establish, not just an
absence of trouble in casual play.

*Established from a probe run against the live server, 2026-08-17.*

---

## 11. Bag-strip slots don't refuse a drop onto an occupied slot client-side

**Where:** [`components/bag.lua`](../components/bag.lua) — `Bag:DropCarriedBag`.

**What gets flagged.** [`components/item.lua`](../components/item.lua)'s content
cells refuse a drop onto an occupied cell before any packet goes out
(`ItemSlot:RefuseIfOccupied`, added in `d2d57d0` after probing showed the server
rejects an occupied-cell move outright — no swap, no merge). `Bag:DropCarriedBag`
has no equivalent: it verifies the cursor source and calls `EquipBagToSlot`
unconditionally, even though `Bag:IsEquipped()` is right there to check against.
The bag-slot strip (`HDR_BAG`, bag 19) is a genuinely separate address space from
the content bags, so the cells' finding does not automatically cover it, and the
asymmetry reads like the same gap left half-closed.

**Investigated in-game, 2026-08-17.** Dragging a second bag onto a strip slot that
already holds one is refused by the server outright, with an explicit UI message
that the slot is occupied — no swap. The carried bag simply falls back into the
player's inventory via the existing unconditional `ClearCursor()` in
`DropCarriedBag`. Unlike the silent content-cell case this refusal comes back with
clear player-facing feedback, so there is no "the interaction looks like it worked"
failure mode here to guard against.

**Deliberately not mirrored client-side.** A few lines using `IsEquipped()` would
make the two drop targets behave identically — instant refusal instead of a round
trip and a bag flying back a moment later — but that is a UX-polish difference, not
a correctness one, and adding it was weighed and declined: nothing is lost, stuck,
or silently wrong today without it.

**Not fully settled:** the confirmed case dropped onto a strip slot holding an
*empty* bag. Whether the refusal is unconditional on the slot being occupied, or
the server would behave differently once the occupied bag holds items, was not
tested — the empty-target result already answered the question that mattered for
the decision above, so the contents case was never run. Do not read this entry as
proof of that case.

Also untested, and for the same reason: the probe carried a **bag**, which is what
the explicit UI message is an answer to. What the server says when the carried item
is not a container at all — the drop still sends `EquipBagToSlot`, and
`ClearCursor()` still runs unconditionally — was not checked. If that one is mute,
the "clear player-facing feedback" line above does not cover it.

**Reopen if:** a swap or a lossy accept is ever observed against a bag-strip slot
whose occupant has contents, or a non-bag payload turns out to be refused
silently, or the round-trip UX becomes a real complaint rather than a theoretical
one.

*Investigated in-game 2026-08-17.*

---

## 12. `ItemSlot:Update`'s cache is not dropped when the button is rebound

**Where:** [`components/item.lua`](../components/item.lua) — `ItemSlot:SetSlot`, and the
`shownTexture`/`shownCount`/… cache in `ItemSlot:Update`.

**What gets flagged.** Item buttons are pooled: `Free()` hides one and puts it back,
`Restore()` hands it to a completely different `(bagIndex, slot)`, and `SetSlot`
rebinds it. `Update` keeps a five-field cache and early-outs when nothing changed —
so rebinding a button without clearing that cache looks like a textbook stale-render
bug, and "clear the cache in `SetSlot`" looks like the obvious one-line fix. It was
in fact written that way first, then removed.

**Why it stays.** The cache is only ever assigned immediately before the two writes
it guards, and those two lines are **the only thing in the addon that paints an item
button's icon and count** — the template's own `OnEvent`/`OnUpdate` are nil'd in
`Create`, and nothing else calls `SetItemButtonTexture`/`SetItemButtonCount`. So the
cache describes *this button's pixels*, not the cell it happens to be bound to, and
`Free`/`Restore`/`SetSlot` repaint nothing. A rebound button therefore either resolves
to something different — a miss, and it is redrawn — or to exactly what it is already
showing, in which case skipping the write is correct.

**Scope.** "Icon and count" is the whole of that premise, and it is narrower than it
first reads: `UpdateSearch`'s `SetAlpha` is a third write that paints the button, and
its input — the addon-wide search string — is not in the cache key. That is deliberate
and needs no invalidation here either, but for the opposite reason: the fade is
re-derived from `Bagnon.Settings:GetTextSearch()` on **every show**, in
`ItemSlot:OnShow`, so a `Restore()`d button never inherits the previous binding's
alpha and a search changed while the window was closed is picked up on the way back
in. Removing that call is what a stale fade would come from, not the missing
`SetSlot` invalidation — closing this entry's argument over the fade would reach the
wrong fix.

Verified by mutation rather than by reading: deleting the invalidation changes no
observable behaviour, because a rebind that *matters* always differs in at least one
keyed field. Adding it back asserts a hazard that does not exist and invites the next
reader to preserve it.

**Reopen if:** anything other than `ItemSlot:Update` gains the ability to paint an
item button — a second `SetItemButtonTexture` call site, a restored template script,
or a Blizzard handler re-attached to these buttons. Then the cache stops describing
the pixels and needs a real invalidation point.

---

## 13. The in-vault pick is still not on the cursor

**Where:** [`core/cursor.lua`](../core/cursor.lua) — `ExtBank.pickSrc`, `SetPick`, `ClearPick`.

**What gets flagged.** A left-click on a vault cell arms a "virtual pick" that puts
nothing on the real cursor, so the player is mid-gesture with no cursor payload. The
obvious complaint is that this is invisible state, and the obvious fix is to put the
item on the cursor properly.

**Why it stays.** There is nothing to put it on. Bag `20 + b` is not a container the
client API recognises, so `PickupContainerItem` cannot be called for a vault cell and
`CursorHasItem()` will never report one — which is the whole reason the virtual pick
exists. Cursor payloads are not something Lua can synthesise on 3.3.5a.

What *was* addressed is the consequence rather than the cause: the origin cell now
carries a highlight for as long as a pick is outstanding (`ItemSlot:UpdatePicked`,
driven by `EXTBANK_PICK_CHANGED`), a right-click always means "withdraw" instead of
being spent completing a forgotten move, and the pick is cleared by the bag strip's
*click* path as well as by the cell paths and `Frame:OnHide`. So the state is visible
and short-lived even though it is not on the cursor. (The strip's *drop* path
deliberately does not clear it, and does not need to — §15. A *non-item* payload
released over a cell does spend it, which is this entry's accepted cost reached by a
drag rather than a click — §16.)

**Not cleared by paging, and that is deliberate.** The page bar and the mouse wheel
briefly did clear it, on the reasoning that a re-flowed grid would let the pick
complete itself onto whatever cell took the origin's spot. That reasoning is wrong —
`pickSrc` holds absolute `{ bagIndex, slot }` coordinates, and the destination is read
off the cell the player actually clicks — and the clear removed the addon's
cross-page move outright: pick on page 1, page across, click to place. Reverted; see
`ItemFrame:OnMouseWheel`.

**Known gap.** The highlight sits on the origin cell, so paging away leaves an
outstanding pick with no on-screen cue until the player pages back — `ItemSlot:OnShow`
re-runs `UpdatePicked` against the live `pickSrc`, so it returns with the cell rather
than needing an arm or clear to repaint it. `Frame:OnHide` still bounds the pick to
the life of the window.

**Reopen if:** a client-side way to load the cursor from a non-container address
appears, or the highlight proves insufficient in practice — a player reporting a move
they did not intend would be the signal. The fix would be a cue that survives paging
(the page bar naming the carried item, say), **not** clearing the pick on the page
step, which has now been tried and cost the feature.

*Entries 12 and 13 dispositioned 2026-08-17 alongside the correctness pass.*

---

## 14. The options header keys `GetAddOnMetadata` on a hardcoded folder name

**Where:** [`components/frameOptions.lua`](../components/frameOptions.lua) —
`local ADDON_NAME = 'Bagnon_ExtBank'`, read once by
`GetAddOnMetadata(ADDON_NAME, 'Title')`.

**What gets flagged.** `GetAddOnMetadata` keys on the addon's **folder** name, and
that literal is a guess about how the addon was installed. GitHub's "Download ZIP"
extracts as `Bagnon_ExtBank-<branch>`, so the lookup returns nil for anyone who did
not clone — and nil into `%s` is not a blank, it is a throw:

```
$ lua5.1 -e "print(('%s'):format(nil))"
bad argument #1 to 'format' (string expected, got nil)
```

Worse, the throw lands inside the `ADDON_LOADED` handler, *after* the frame-selector
patch above it has installed and *before* everything below — including the
`UpdateWidgets` wrap at the bottom of the file. The player would get a working
"Void Storage" dropdown entry with no slider, no credit block, and the live "Enable
Bag Frame" checkbox this file's own long note calls a trap. Escalated as a release
blocker on that reading, and 3.3.0 added the obvious fix: `local ADDON_NAME = ...`,
the chunk vararg, which is the real folder name.

**Why it stays: a renamed folder does not load at all.** The client resolves an addon
as `Interface\AddOns\<Folder>\<Folder>.toc`. Rename the folder on its own — which is
exactly what a ZIP install *is* — and the `.toc` inside no longer matches it. Tested
in game on the live Ebonhold client, not reasoned about:

> Renamed the folder in `Interface\AddOns` → character select → the addon is not in
> the AddOns list at all, and nothing of it runs in game.

So the scenario cannot produce the throw. It produces an addon that is simply absent,
which is loud, immediate, and fixed by the rename every addon README already asks
for. There is no half-patched options panel and no live checkbox, because no line of
this addon ever executes.

The release path is not exposed either. `.github/scripts/build.sh` stages into
`build/Bagnon_ExtBank/` and zips *that folder*, so the asset extracts under the
correct name whatever the tag calls the `.zip`.

**What is genuinely left**, once the false premise is removed: renaming **both** the
folder and the `.toc` to match. That loads normally and does make every
`GetAddOnMetadata('Bagnon_ExtBank', …)` here answer nil. It is a deliberate two-step
by someone who has already learned the two names must agree — not a default install
path — and it costs one line in one options panel.

**And the vararg is not the one-liner it looks like.** Only `main.lua` is listed in
the `.toc`; every other file in this addon, `frameOptions.lua` included, loads through
`core.xml` / `components.xml`. Whether the addon-name vararg survives a
`<Script file="">` hop on 3.3.5a is not settled by the 3.3.5 documentation, and a
sweep of a stock install (~60 addons, Ace3, Auctionator, WeakAuras, NotPlater's own
3.3.5 port) found **no** XML-loaded file anywhere that captures it — the idiom is only
ever used in `.toc`-listed files. Closing this properly therefore means a capture in
`main.lua`, a type guard for the client that hands over nothing, and a third piece of
identity state on the module table, to cover a case reached only by renaming both
halves. Nothing else in the addon wants the folder name: there are no
`SavedVariables` and no `Interface\AddOns\…` texture paths, so this literal has
exactly one consumer.

**Reopen if:** a player is actually observed with a renamed folder *and* a matching
renamed `.toc` — a support report of the options panel missing its slider and credits
is the signal — or anything in this addon starts needing the folder name for a real
path (a texture of our own would do it). The minimal fix then is
`GetAddOnMetadata(ADDON_NAME, 'Title') or 'Bagnon ExtBank'` at the format site: one
expression, no load-order assumptions, and it holds whatever the lookup fails on. The
vararg capture is only worth its three files if that second trigger arrives.

*Premise disproved in game 2026-08-17, after being raised as a blocker by that day's
review.*

---

## 15. The bag strip's drop path does not clear the in-vault pick, unlike its click path

**Where:** [`components/bag.lua`](../components/bag.lua) — `Bag:OnReceiveDrag`, against
the `ExtBank:ClearPick()` that `Bag:OnClick` opens with.

**What gets flagged.** `Bag:OnClick` clears the pick first thing and states why:
*"Toggling a bag's contents re-flows the grid, and unequipping one removes cells
outright, so a pick armed before this click would complete itself onto a cell the
player never aimed at."* `Bag:OnReceiveDrag` is an `IsLocked()` early return and a
`DropCarriedBag()`, and clears nothing — nor does `DropCarriedBag`, while
`components/item.lua`'s own drop route does. Two drop paths on one widget that
disagree, reading as a fix applied to the click half and never carried across.

The two really are separate events, not two names for one. Click-pickup the bag in
your bags and click a strip slot, and the slot gets `OnClick`, which clears. Press and
hold on the bag, drag, and release over the slot, and it gets `OnReceiveDrag` only —
the mouse-down landed on a frame in the bags window, so no `OnClick` follows. The
2026-08-17 review filed that as a should-fix with a one-line remedy: `ExtBank:ClearPick()`
at the top of `OnReceiveDrag`.

**Why it stays: the rationale does not transfer.** `OnClick`'s two cases *remove*
cells — toggling drops a bag out of `GetAllVisibleBags`, unequipping removes it
outright, and unequipping can destroy the very cell `pickSrc` names. `OnReceiveDrag`
has exactly one outcome: a bag equipped into an empty strip slot. That only ever
*adds* cells, and it cannot touch the pick's source bag.

**Tested in game 2026-08-17**, both shapes, with a pick armed before the drop:

> **Equipping into the first free slot** — no grid movement at all. The new index
> sorts above every equipped one, so `ItemFrame:GetAllVisibleBags` (ascending strip
> order, `GetBagSize > 0`) appends it and nothing already placed changes position or
> page.
>
> **Equipping into a gap** — unequip a middle bag, equip a new one into the hole. Here
> the viewed page *does* change, the inserted index shifting every later bag one
> position along the page slice. The pick survives it, and completing it afterwards
> moves the item onto the cell clicked, correctly.

`pickSrc` holds absolute `{ bagIndex, slot }` and the destination is read off the cell
the player actually clicks, so a re-flow changes what is on screen, not what the pick
names — the same fact §13 records against the page bar. Reverse Slot Order turns every
equip into the gap-fill shape (the reversed iterator puts the new high index first),
which is the same mechanism as the case tested, not a further one.

**And the fix would cost a working gesture.** Arm a pick, equip a bag, complete the
pick is a coherent sequence, and the test above is exactly it. `ClearPick` in
`OnReceiveDrag` deletes it — the same shape of mistake as the page-bar clear §13
already tried and reverted: reasoning about a re-flow hazard that absolute coordinates
do not have, paid for with a move the addon actually supports.

**What is genuinely left** is not this entry's to hold: after a re-flow that pushes the
origin cell off the viewed page, an outstanding pick has no on-screen cue until the
player pages back. That is §13's *Known gap*, reached identically by the page bar and
bounded by `Frame:OnHide` either way.

**Reopen if:** the strip's drop path gains an outcome that removes cells — a drop onto
an *occupied* strip slot that swaps or unequips rather than being refused (§11 records
the server's current refusal) — in which case `OnClick`'s rationale applies verbatim
and the one-liner is right. A player report of a vault move they did not intend,
traced to a pick armed before a bag equip, would do it too.

*Investigated in game 2026-08-17, after that day's review raised it as a should-fix.*

---

## 16. A non-item drag released over the grid spends an outstanding pick

**Where:** [`components/item.lua`](../components/item.lua) — `ItemSlot:OnReceiveDrag`,
an unconditional `self:DropCarriedItem()`.

**What gets flagged.** Blizzard fires `OnReceiveDrag` for **any** cursor payload —
spell, macro, money, item — while `DropCarriedItem`'s first test is `CursorHasItem()`,
false for all the non-item ones. So control falls straight into the
`elseif ExtBank.pickSrc` branch and issues a real `MoveWithinVault`. Arm a pick on a
vault cell, then drag a spell off the action bar and release it over the grid: the
spell leaves the bar, and a vault item relocates on a gesture that had nothing to do
with the vault. Raised as a should-fix by the 2026-08-17 review, remedy `GetCursorInfo()
== nil` on the branch.

**Why it stays: the gesture is the mistake, and the spend is the cost §13 already
accepts.** Reaching this means arming a virtual pick and then abandoning it mid-move to
go do something unrelated. That is the same shape §13 records as the accepted price of
a pick that cannot be put on the cursor — *"a leftover pick silently hijacks the next
click on any cell"*. The trigger here is a drag release rather than a click, but
nothing that makes the cost tolerable turns on which event delivers it:

- The origin cell has carried a highlight for the whole time the pick has been
  outstanding (`ItemSlot:UpdatePicked`), so the state was on screen when the player
  turned to the action bar.
- The outcome stays inside the vault. The item lands in the cell the cursor was over —
  nothing is withdrawn, destroyed or charged for, it is visible where it landed, and
  the player puts it back with the same two clicks that moved it.
- `Frame:OnHide` still bounds the pick to the life of the window.

**The action-bar half is not ours.** Dragging an action off a bar and releasing it
somewhere that does not take it is a Blizzard interaction with a Blizzard outcome; this
addon neither causes it nor can decline it. What the addon owns is the pick — and the
same misuse spends it either way, since a guarded handler only leaves it armed for the
*next* click, which is the case §13 already covers.

**Same call as §15, made for a different reason.** There the fix was declined because
its rationale did not transfer and it would have deleted a working gesture. Here it is
declined because the state it guards is reached only by walking away from a half-made
move, and what it prevents is a reversible relocation inside the player's own vault.
Neither is "the guard would be wrong" — both are "the guard buys less than it asserts".

**If it is ever taken**, the shape is `GetCursorInfo() == nil` on the
`elseif ExtBank.pickSrc` branch inside `DropCarriedItem`, **not** on `OnReceiveDrag`:
the vault's own cell-to-cell drag deliberately puts nothing on the real cursor (see
`ItemSlot:OnDragStop`), so it passes that test, while the deposit path above it still
needs `CursorHasItem()` reachable. Note it changes the click path too — a left-click on
a cell while a spell rides the cursor would stop completing the pick and arm a new one
on the cell clicked instead.

**Reopen if:** a player reports a vault move they did not make and it traces to a
non-item payload rather than to a forgotten click, or the `pickSrc` branch gains an
outcome that leaves the vault — a withdraw, a destroy, anything with a cost — rather
than moving a cell within it. §13's *Reopen if* still covers the pick in general; this
entry holds only the drag-release trigger.

*Dispositioned 2026-08-17, after that day's review raised it as a should-fix.*

---

## 17. Right-click on a bag-slot strip button never fires while the cursor is loaded

**Where:** [`components/bag.lua`](../components/bag.lua) — `Bag:OnClick`.

**What gets flagged.** The 2026-08-17 review's §9 opened with this repro: pick an item
up out of your bags so it rides the cursor, then right-click an equipped strip slot to
unequip its bag. The old guard was

```lua
if not self:IsLocked() and not self:DropCarriedBag() then
```

and `DropCarriedBag` returns true on `CursorHasItem()` alone, so the whole body — the
`button == 'RightButton'` test included — was short-circuited away. The review's
reading was that `EquipBagToSlot` went out instead, the server refused it (§11), and
the unequip silently never happened.

**Investigated in-game, 2026-08-18.** The symptom is real and reproduces exactly as
described: the cursor empties, the bag is not unequipped, and no error is shown. The
*cause* is not this addon. **The client itself cancels a loaded cursor on
right-button-down and consumes the press**, so `Bag:OnClick` never runs at all for
that gesture. It was verified after the fix below, with the equip path no longer
reachable from `RightButton` and no `ClearCursor()` anywhere on that branch: the
cursor still empties and nothing else happens. Nothing this addon sends or swallows
is involved, and no `EquipBagToSlot` was ever going out on that route.

That is engine behavior on every frame in the UI, not something a strip button can
override. This addon already bows to it elsewhere: `ItemSlot:OnClick`
([`components/item.lua`](../components/item.lua)) guards its right-click withdraw on
`not CursorHasItem()` for the same reason, which is why the cells never showed this
shape.

**What was really broken, and is fixed.** The bad guard was reachable — just not by
right-click. The button is `RegisterForClicks('anyUp')`, so **MiddleButton, Button4
and Button5** reached it: while carrying, they fired the bogus `EquipBagToSlot` plus
`ClearCursor()`; with an empty cursor they fell into a bare `elseif self:IsEquipped()`
and toggled the bag's contents out of the grid on a gesture that was never given a
meaning. Both are closed by testing the button before the drop and naming it on every
branch. Confirmed in-game: middle-click is now inert, and right-click with an empty
cursor unequips.

**So §9's first repro is not fixable and does not need to be.** Do not re-file "right-
click while carrying should unequip" — the press does not reach Lua. Left-click
remains the drop target for a carried bag, which is what the tooltip has always said.

**Reopen if:** a right-click made while carrying is ever observed reaching
`Bag:OnClick` (a `print` at the top of it is the whole test), which would mean the
client's cancel is conditional in some way not seen here.

*Investigated in-game 2026-08-18.*
