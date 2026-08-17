# Changelog

All notable changes to Bagnon ExtBank are recorded here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
The version in `Bagnon_ExtBank.toc` is the source of truth — bumping it is what
publishes a release, so the entry below it should land in the same change.

## [Unreleased]

Nothing yet.

## [1.0.0] — 2026-08-17

First release. Replaces ProjectEbonhold's built-in Void Storage window with a
Bagnon-style one: all your storage bags merged into a single grid, with the same
chrome, search, and options as the rest of your Bagnon windows.

### The window

- Takes over automatically whenever Void Storage opens — the button on the bank
  window, `/extbank`, `/voidstorage`, or anything else that opens it. The native
  window is hidden; nothing about how you open Void Storage changes.
- Built as a real Bagnon frame (`extbank`), so it comes with the standard title
  bar, close button, search icon, bag toggle, gold display, and right-click
  options access, and it moves, scales, and remembers its position like the
  bags and bank windows do.
- Titled `<Name>'s Void Storage`, matching Bagnon's own title convention.
- Closing by any route — the X, Escape, or the native toggle — leaves the game's
  own idea of "is the vault open" in sync, so reopening always takes one click
  rather than two.
- On the first open of a session the window waits for the server's snapshot
  before appearing, instead of flashing an empty, undersized frame that resizes
  a moment later.

### Bag-slot strip

- One square for every one of the 70 Void Storage bag slots, drawn locked,
  empty, or equipped.
- Drag a bag from your inventory onto an empty square to equip it; right-click
  an equipped square to unequip it (the bag must be empty first).
- Left-click an equipped square to show or hide that bag's contents in the grid.
- A **Purchase** button above the strip shows the gold cost of your next slot
  and asks for confirmation before buying. Prices are read from ProjectEbonhold's
  own vault UI, so they match what the built-in window quotes; the server still
  enforces and charges the real cost. The button disappears once all 70 slots
  are bought.
- The strip is shown or hidden with the standard Bagnon bag-toggle icon, and
  that choice persists per character.

### Item grid

- Every bag you've toggled on pours into one continuous grid, laid out and sized
  by your normal Bagnon display settings (columns, spacing, item scale, opacity,
  empty-slot background).
- Split into pages so 70 bags never becomes an unusable wall of squares, with
  whole bags kept together rather than split across a page boundary. Flip pages
  with the mouse wheel over the grid or the `<` / `>` buttons below it; the page
  bar hides itself when everything fits on one page.
- Move items inside the vault by click-then-click or by dragging, including
  dragging onto a different page mid-drag.
- Right-click or shift-click an item to withdraw it to your bags.
- Right-click an item in your real bags while the vault is open to deposit it —
  it is then moved onto the page you are currently looking at, rather than
  wherever it first landed. If that page is full it stays where it landed and
  says so.
- Warns you, once and in full, if a refused deposit leaves an item locked in
  your bags, including both ways to recover.
- The Bagnon search box filters vault items exactly as it does your bags:
  matches stay bright, everything else dims.

### Settings

- Adds a **Void Storage** entry to Bagnon's frame dropdown (Interface Options →
  Bagnon, or right-click the window), with a **Bags Per Page** slider alongside
  the Bagnon-wide display options.
- `Bagnon_Config` is optional: without it everything works, there is simply no
  panel to change settings from.
- "Enable Bag Frame" and "Enable Sort Button" are shown grayed out for this
  frame, the same way Bagnon grays them for its own keyring and guild bank.
- The panel credits the addon with its version, release date, and a copyable
  GitHub link. The version and date are read from the addon's own code rather
  than its `.toc`, so they are correct after a `/reload` — the client reads
  `.toc` metadata once at launch and would otherwise keep showing whichever
  build you logged in with.

### Compatibility

- WotLK 3.3.5a (build 12340), interface 30300, on the ProjectEbonhold client —
  Void Storage is a ProjectEbonhold feature and lives entirely server-side.
- Requires [Bagnon for 3.3.5a](https://github.com/RichSteini/Bagnon-3.3.5). No
  Bagnon code ships here.
- Hooks ProjectEbonhold's `ExtBank_OnPacket` / `ExtBank_Open` / `ExtBank_Close`
  by chaining onto them, never replacing them, so the native UI keeps working.
- On a client without Void Storage the addon loads and does nothing.

### Known limitations

- No sorting. Bagnon's cleanup routine only understands real bag IDs, so the
  Clean button is off for this window rather than present and inert.
- A deposit the server refuses can leave the item greyed out and unusable in
  your bags until you free a vault slot and right-click it again, or relog. The
  addon warns you when this happens.
