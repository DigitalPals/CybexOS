# Settings

The Settings window (Super+, or **Cybex OS Settings** in the launcher) is the
shell's own preferences and the system settings it manages. This page records
how it is organised since the October 2026 redesign; the code is
`desktop/quickshell/Settings/` with the page list in `Common/Settings.qml`.

## Layout

- **Rail.** At the top, Search opens the palette. Below it come **Home** and
  three groups of six pages:
  - **Personalize:** Appearance, Wallpaper, Bar & Control Center, Workspaces &
    dock, Notifications and Plugins.
  - **Devices:** Displays, Sound, Network, Touchpad, Keyboard and Power.
  - **System:** Security, Online accounts, Assistant, Applications, Region &
    language and Backup & storage.

  Every page has its own glyph. The rail fits without scrolling at the default
  size, which is 960 × 700 at a 12 px base and about 1120 × 817 at the default
  14 px. In a shorter window it scrolls. Below about 860 units of width it
  compresses to its glyphs.
- **Header.** It holds Back (also Alt+Left), then the page and what it is
  about, the save state ("Saving… / Saved", with Undo after a reset), the
  **Changes** chip and Close. Back walks the pages visited since the window
  opened. Closing the window forgets that trail.
- **Tabs.** A page that holds more than one view shows underlined tabs above its
  content:
  - **Keyboard:** Layouts and Shortcuts.
  - **Backup & storage:** Backups, Recovery points and Disk space.

  Tabs only switch the view. A segmented control only ever changes a value, so
  the two never look alike.

## Home

Home replaces About. From top to bottom it shows:

1. The computer's name, release and hardware, and the update state.
2. One strip with storage, battery (memory on a desktop), backups and network.
   Each reading opens its page.
3. **Needs attention**. This lists:
   - unapplied changes;
   - a system change being prepared, ready to review, or waiting for a restart;
   - backups that are not set up;
   - the [system check](system-check.md)'s problems and suggestions.

   Each item has one action. The system check row runs `cybex doctor` again.
4. **Recently changed**. These are the settings changed in this window, each
   with Show and Undo.
5. **About this computer**. This holds shell health, the Welcome guide and the
   settings file.
6. **Reset all**, in a group of its own.

Recently changed keeps at most eight entries in
`~/.local/state/cybexos/shell/settings-recent.json`. It records only settings
that the search index can name, and only while the window is open; Control
Center toggles are not recorded. Undo restores the value the entry started
from. An entry whose setting has moved on since then is not shown.

## Search palette

"/", Ctrl+K or Ctrl+F opens the palette over the window. It searches:

- pages;
- settings, each with its current value;
- actions, such as opening Software Update, running the system check, changing
  the password, adding a fingerprint or a shortcut, backing up now, or opening
  the settings file.

The index is `Common/SettingsSearchData.js`: `ROWS`, with hidden `terms` such as
"dnd" or "vrr", and `ACTIONS`. Enter goes to the row and highlights it.
Ctrl+Enter switches a setting on or off in place.

## Changes

Most settings apply as they change. These drafts wait for Apply instead:

- touchpad, keyboard layouts and shortcuts, which apply to the session;
- the system timezone and language, and recovery-point cleanup, which build a
  system change.

They are kept for the session in `InputDrafts`, `Keybindings`, `RegionDrafts`
and `RetentionDraft`, so leaving a page keeps them. The rail marks each page
that has a draft. The header's chip counts the drafts, and **Review changes**
lists every one with its old value.

Apply settles each session draft one at a time. It then prepares at most one
system change, because the updater keeps one deployment at a time. A
timezone and a language chosen together are one request (`cybex config region`
with two triples), so one generation and one restart. Recovery-point cleanup is
a separate maintenance preview, prepared after the regional change is applied.

Settings that build a system change say so on their group heading with
**Administrator · restart**. SSH Server says **Administrator**, because it needs
authorization but no restart. Once a system change is prepared, the chip
follows it through preparing, review in Software Update, and restarting to
finish.

Displays and Network edits stay on their own page and do not join Changes.
Applying either starts a keep-or-revert trial. Leaving the page reverts a
running trial and drops edits that were not applied.

## Page ids

IPC (`cybexos-runtime ipc settings open ID`), the launcher and other views open
pages by id. Ids from before the redesign still work:

- `about` opens `home`;
- `shortcuts` opens `keyboard` on Shortcuts;
- `storage` opens `backup` on Disk space;
- `modules`, `widgets` and `drawer` open `bar`;
- `system` opens `power`.

`Settings.showPanel(page, screen, key)` chooses the tab a legacy id or a moved
row names (`legacyTabs`, `keyTabs`). Otherwise it opens a tabbed page on its
first view.

## Tests

- `tests/settings-pages.py` runs the real shell under a private headless Sway.
  It opens every page and tab and follows the legacy ids. It also drives Back,
  the palette (Enter and Ctrl+Enter), Recently changed with Undo, and two
  drafts reviewed and applied from the Changes sheet. A recording `cybex`
  checks that the sheet sends one combined `cybex config region` call. Run it
  through `nix develop` with grim and wtype.
- `tests/quickshell/settings-*.test.cjs` hold the page model, search, palette,
  Changes and Recently changed contracts.
- `tests/settings-runtime.py` is the installed-VM audit of every page and tab;
  see [the settings audit](measurements/settings-audit-2026-10-27.md).
