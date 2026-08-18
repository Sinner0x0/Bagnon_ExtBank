# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Bagnon companion module that replaces ProjectEbonhold's built-in "Void Storage"
(ExtBank) window with a Bagnon-style one. WoW 3.3.5a (WotLK, build 12340),
interface 30300, **Lua 5.1**.

Not a standalone addon: it registers as a Bagnon module and builds its UI out of
Bagnon's own component classes. No Bagnon code is vendored here — `## RequiredDeps:
Bagnon` guarantees it is loaded first, and every file opens with
`local Bagnon = LibStub('AceAddon-3.0'):GetAddon('Bagnon')`.

The repo root **is** the addon folder, and is often cloned directly into
`Interface\AddOns\Bagnon_ExtBank`. `.githooks/` is dev-only and does not ship.
Most of `docs/` **does** ship, so a zip install matches a clone: `non-issues.md`
because shipped source cites it by relative path in four places, and `images/`
because the shipped `README.md` embeds them. Dated review snapshots (`review-*.md`) do
not — `build.sh` names `non-issues.md` explicitly and derives the images from the
README's own `src=` refs, so nothing else in `docs/` is picked up by accident.

## Commands

```bash
bash .github/scripts/build.sh              # -> dist/Bagnon_ExtBank-<version>.zip (needs `zip`)
bash .github/scripts/stamp-version.sh      # sync version/date across .toc + main.lua
bash .github/scripts/stamp-version.sh --check   # verify only; what pre-push and CI run
find . -name '*.lua' -print0 | xargs -0 -r -n1 luac5.1 -p   # syntax check (what CI runs)
git config core.hooksPath .githooks        # one-time, enables the hooks below
```

There is **no test suite**. Verification is the Lua 5.1 syntax check plus testing
in the live client.

The syntax check needs a **5.1** parser specifically — `luac5.1 -p`, matching the
`lua5.1` package CI installs. A newer Lua is worse than none here: a 5.4 parser
happily accepts the `goto` and integer division the 3.3.5a client rejects, so it
passes files the game cannot load. `build.sh` additionally needs `zip`. Neither
tool is required to work on the addon — CI runs both on every PR — so check what
is actually available before claiming a change was verified locally.

The syntax check only proves a file *parses*. There are no WoW API stubs here, so
anything touching Bagnon's classes or the ebonhold packet path is verified only by
loading it in the client — do not claim a change is verified without saying where
it was checked.

`build.sh` derives the shipped file list from the `.toc`, following `<Script>`/
`<Include>` refs through the XMLs, and fails if a referenced file is missing. Adding
a Lua file means adding it to `core.xml` or `components.xml`.

## Version and date live in two places, deliberately

- `Bagnon_ExtBank.toc` — `## Version:` is the **single source of truth**, and
  bumping it is what publishes a release. `## X-Date:` sits beside it.
- `main.lua` — `ExtBank.VERSION` / `ExtBank.DATE`, which is what the options panel
  prints.

The duplication is required, not an oversight: the client parses every `.toc`
**once at launch** and serves `GetAddOnMetadata` from that cache forever, so a
drop-in update plus `/reload` would keep showing the version the player logged in
with. Lua files *are* re-executed by `/reload`.

**Never hand-edit `ExtBank.VERSION`, `ExtBank.DATE`, or `## X-Date:`.** Bump
`## Version:` in the `.toc`; `stamp-version.sh` mirrors it into `main.lua` and
stamps both with today's date. The `pre-commit` hook runs it and re-stages both
files; `pre-push` and CI re-check with `--check`. `--check` compares the two files
against each other, never against the clock — do not "fix" it to compare against
today, or every PR merged a day late fails.

On Windows, `sed` is built in text mode, so a stamp rewrites those two files as LF.
`core.autocrlf` is on, so the staged bytes are identical either way and `git diff`
stays clean. The LF/CRLF warnings from git are normal here.

## Architecture

### Load order and shared state

`.toc` order is `main.lua` → `core.xml` → `components.xml`, and `main.lua` must stay
first: it creates the module and declares the addressing constants everything else
reads.

```lua
local ExtBank = Bagnon:NewModule('ExtBank', 'AceEvent-3.0', 'AceTimer-3.0')
Bagnon.ExtBank = ExtBank
```

All cross-file state hangs off that table (`ExtBank.bags`, `.cells`,
`.unlockedBags`, `.cursorSrc`, `.pickSrc`, `.window`, the addressing constants).
A `local` in one file is invisible to the others, so nothing shared is ever a
file-local. AceTimer is mixed in for `core/deposit.lua`'s two delayed checks **and**
for `main.lua`'s first-snapshot wait (`ShowWindowOnceModelReady`) — 3.3.5 has no
`C_Timer`. Both callers matter: dropping the mixin because `deposit.lua` no longer
needs it throws on the first vault open of every session, from inside a handler
that has already suppressed the native window.

### Data flow

```
ebonhold.dll  --SMSG_EXTBANK_UPDATE-->  _G.ExtBank_OnPacket(hex)
  -> our chained hook            (core/nativeHooks.lua)
  -> ExtBank:ParsePacket(hex)    (core/model.lua)  fills bags/cells/unlockedBags
  -> Bagnon.Callbacks:SendMessage('EXTBANK_MODEL_UPDATED')
  -> every widget redraws
```

**Two message buses exist, and `self:SendMessage` means a different one depending
on what `self` is.** On a Classy *widget* it is the Ears mixin, backed by
`Bagnon.Callbacks` — the bespoke pub/sub every widget's `RegisterMessage` listens
on. On the *module* (`ExtBank`) it is AceEvent's own registry, a completely separate
one nothing in the UI listens to. That is why `core/model.lua` publishes model
updates as `Bagnon.Callbacks:SendMessage('EXTBANK_MODEL_UPDATED')` explicitly:
`self:SendMessage` there would reach nobody, and the window would only ever show
whatever the model held at its last `OnShow`.

### Three ways this addon attaches to code it doesn't own

1. **Bare-global chaining** (`core/nativeHooks.lua`). `ExtBank_OnPacket` /
   `ExtBank_Open` / `ExtBank_Close` are plain globals that ProjectEbonhold assigns
   unconditionally — one owner each. Capture the previous value, call it, then run
   ours. Must wait for `PLAYER_LOGIN`; addon load order is not guaranteed.
2. **`hooksecurefunc`** (`PickupContainerItem`, `SplitContainerItem`,
   `UseContainerItem`, and the native frames' `Show` → `Hide`). Allows unlimited
   independent listeners, so it stacks safely alongside ProjectEbonhold's own
   hooks. `SplitContainerItem` (`core/cursor.lua`) is the only writer of
   `cursorSrc.count`, which is what decides whether a shift-drag deposits 5 of a
   stack or all 18 — don't audit the hook surface without it.
3. **Monkeypatching vendored Bagnon classes**, always in this shape:

   ```lua
   local super_X = Bagnon.Thing.X
   function Bagnon.Thing:X(...)
       if self:GetID() == 'extbank' then ... end
       return super_X(self, ...)
   end
   ```

   Used for the title, saved-settings dispatch, bag-frame-shown persistence, the
   options dropdown, and `Frame:OnHide` / `PlaceItemFrame`. Every other frameID
   must fall through unchanged. Never edit vendored Bagnon instead.

### Hard-won constraints — read before changing the relevant file

These are all documented at length in-file. The comments encode in-game findings,
several of them from real breakage; read a file's header and the comment above a
function before altering it.

- **Never replace a Blizzard button's `OnClick`.** For real bags, Bagnon's item
  slots *are* the live `ContainerFrame1Item1`-style globals. An earlier version
  overrode `OnClick` there and permanently tainted them, breaking right-click use
  and shift-click split everywhere in the UI. Observe via `hooksecurefunc`, then
  issue a *separate* action of our own (`core/deposit.lua`).
- **Never name a method `UpdateTooltip` on a Classy class.** Classy keeps class
  methods reachable through `__index` even after the instance field is nil'd, and
  Blizzard's `GameTooltip_OnUpdate` polls `owner.UpdateTooltip` ~5×/sec and
  re-invokes it, tearing the tooltip down mid-hover. The convention here is
  `RefreshTooltip`.
- **A constructor must not let `BAG_FRAME_UPDATE_SHOWN` escape.**
  `Frame:CreateBagFrame`/`CreatePageBar` assign `self.bagFrame`/`self.pageBar` only
  *after* `New` returns, so a synchronous relayout re-enters the constructor
  unboundedly — an instant client freeze. The message is the hazard, not `Show()`
  itself, and the two classes differ on that point:
  - `BagFrame:New` sets an `OnShow` script that sends the message, so it must not
    `Show()` from the constructor — core's `PlaceBagFrame` shows it a moment later.
  - `PageBar:New` sets **no** `OnShow`, so its `UpdateShown()` may and does
    `Show()`: `PlaceItemFrame` reads `IsShown()` in the same pass to size the
    window. Adding an `OnShow` to `PageBar` is what would arm the freeze.

  Both constructors document their own half. Don't "fix" one to match the other.
- **Item slots use a plain `.slot` field, never `SetID()`** — the container template's
  default logic reads `GetID()` plus the parent's as a real `(bag, slot)` pair.
- Lua 5.1 only: no `goto`, integer division, bitwise operators, or retail `C_*`
  namespaces.

### Addressing and the two "carried item" models

Wire addressing (mirrored from ProjectEbonhold's own module, constants in
`main.lua`): bag `19` is the bag-slot strip, `20 + b` is the contents of ext bag
`b`, `dstBag 0xFF` means first free vault slot and `0xFE` first free inventory slot.
Only bags `0..4` are accepted as move *sources* — probed against the live server,
not assumed, so gear and bank contents must pass through the player's bags first.

Two independent notions of what is being carried, and conflating them causes wrong
items to move:

- `ExtBank.cursorSrc` — a real inventory item, recorded by the `PickupContainerItem`
  hook. Nothing corrects it when the cursor is loaded or emptied by another route,
  so it **must** be re-verified at drop time via `GetVerifiedCursorSource()`, which
  checks the cursor's link still matches that slot.
- `ExtBank.pickSrc` — a virtual in-vault pick. Bag 20+ is not a real container, so
  this deliberately puts *nothing* on the cursor and has no visual cue; a leftover
  pick silently hijacks the next click on any cell. It is cleared in `Frame:OnHide`.

`Frame:OnHide` (`components/frame.lua`) is the single funnel every close path of a
*shown* window runs through — X button, Escape, native close. It clears the pick and
any pending deposit, hides the purchase popup, and calls `ExtBank_Close()` unless
`closingFromNative` is set. Put teardown there, not in `OnNativeClose`, which the X
and Escape paths never reach.

The one exception is `ClearPendingDeposit`, which deliberately runs in **both**.
`Hide()` on a frame that was never shown runs no `OnHide` script, and deposits arm
for the whole native session (`IsVaultSessionOpen`) — including the first-snapshot
wait and the give-up after it, where the window never appears at all. Only
`OnNativeClose` covers that gap; both copies carry the rationale.

### Grid, paging, and layout timing

Up to 70 bags × 36 slots = 2520 possible cells, so the grid paginates by **whole
bag** (`GetBagsPerPage()`), never splitting a bag across pages.
`GetAllVisibleBags()` is every toggled-on, still-equipped bag;
`GetCurrentPageBags()` is the page slice that actually gets built and laid out.
`currentPage` is intentionally not persisted.

Layout is **deferred**: `RequestLayout()` shows a one-shot `OnUpdate` frame that
applies `Layout()` next frame. There is deliberately no flag alongside that
`Show()` — it was a second copy of `throttledUpdater:IsShown()` and was removed;
see the note at the updater in `components/itemFrame.lua`. `EXTBANK_MODEL_UPDATED`
arrives in bursts, and re-anchoring every slot synchronously per message tore down
the tooltip under the mouse. `ItemFrame:OnSizeChanged` → `ITEM_FRAME_SIZE_CHANGE`
is what lets the outer frame catch up afterwards.

The grid's **width is pinned to the column count, not to content** — the bag strip
derives its own column count from the grid's rendered width, so a content-derived
width makes the strip oscillate between 5 and 14 columns as items come and go.

### Settings

Everything is keyed on frameID `'extbank'`. Defaults live in
`GetDefaultExtBankSettings` (`components/savedFrameSettings.lua`), reached by
wrapping core's `GetDefaultSettings` dispatch. Two fields core Bagnon has no notion
of — `bagsPerPage` and `bagFrameShown` — get plain DB accessors there plus a live
`FrameSettings` layer in `components/frameSettings.lua` that fires the message bus
on change. `bagFrameShown` defaults **true** (the strip is the reason to open this
window) and is persisted, unlike core's session-only, starts-hidden flag.

## CI and release

- **`ci.yml`** — `pull_request` into `main` only. There is deliberately no `push:`
  trigger: pushes to `dev` still re-run it through the PR's `synchronize` event, and
  a `push:` trigger would run the whole thing a second time alongside that. Lua 5.1
  syntax check, `.toc` metadata, the stamp `--check`, build, and uploads the zip as
  an artifact for in-client testing.
- **`release.yml`** — on push to `main`. Builds, then tags and releases *only if no
  tag matches the `.toc` version*. Bumping `## Version:` is what ships a release;
  merging anything else is a no-op, and re-runs are safe.
- **`claude-review.yml`** — needs `id-token: write`. The action mints its own GitHub
  token via OIDC rather than using `GITHUB_TOKEN`, and naming any `permissions:` key
  drops every unlisted scope to `none`.

Work happens on `dev` and merges to `main` by PR. `--generate-notes` builds release
notes from PR titles, which is why the PR ceremony is worth keeping for a solo repo.