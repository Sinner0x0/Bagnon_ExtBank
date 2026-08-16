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
