# Welcome guide, shortcut editor and wallpaper picker: shared contract

This document fixes the interfaces between the welcome guide, the keyboard
shortcut editor and the wallpaper picker so they can be built in parallel. It
describes the agreed design; when an implementation must deviate, update this
file in the same change and say why.

## Goals

- **Welcome guide.** A first-login guide that runs inside the Quickshell shell,
  so every choice applies live to the real desktop behind it. It must not ask
  again for what the installer already set: language, keyboard, Wi-Fi,
  account, time zone, computer name, application groups and the NVIDIA
  driver. It shows those as a summary with links to change them.
- **Shortcut editor.** Shortcuts can be viewed and edited without writing Lua.
  The Super+K sheet, the new **Settings → Keyboard shortcuts** page and the
  welcome guide all show the same live data.
- **Wallpaper picker.** Choosing a wallpaper is the welcome guide's main
  step. The picker offers the bundled Cybex OS wallpapers offline, Wallhaven
  online and the user's own folder. The same components are used by
  Settings.

Ownership rules, which apply everywhere:

- Vendor files in the Nix store are immutable.
- `~/.config/cybexos/hypr/user.lua` is the user's own file. It is never
  written, generated or migrated, and it still loads last.
- Settings writes data files, never Lua.
- Strings read from data files are never evaluated as Lua.

## 1. Keyboard shortcuts

### 1.1 Action catalog (`desktop/hypr/bindings.lua`)

Every vendor binding becomes an *action* with a stable ID. IDs are lowercase
dotted, `group.name`, with optional numeric suffixes, for example
`apps.terminal` or `workspaces.switch.3`. They are a public contract: never
rename one, because users' `keybindings.json` refers to them.

Each action has:

- `id`
- `group` and `label`. The binding description remains `"Group: Label"`, so
  the Super+K sheet keeps working without changes.
- default `keys`: one or more Hyprland key strings.
- the dispatcher and the existing bind options (`repeating`, `locked`,
  `mouse` and so on).
- `editable`: false for mouse-drag bindings and for the `Hardware keys` group.
- `protected`: true for actions that may be remapped but must always keep at
  least one key and can never be disabled. At least these are protected:
  `shell.lock`, `shell.exit`, `shell.settings` and `shell.shortcuts`.
- an optional feature gate, using the existing `features` table. Actions whose
  feature is off are not part of the catalog at runtime.

Existing behaviour, keys and descriptions are preserved exactly unless this
document says otherwise. Alternate keys for the same action (`Print` and
`` Super+` `` for a region screenshot) are one action with several keys. The
two zoom steps, `windows.zoom-in` and `windows.zoom-out`, are separate
actions. They keep their shared description so the sheet can still show
them as one row.

Other streams rely on these IDs:

- **Shell:** `shell.launcher`, `shell.settings`, `shell.shortcuts`,
  `shell.control-panel`, `shell.notifications`, `shell.lock`, `shell.exit`,
  `shell.assistant` (feature-gated)
- **Apps:** `apps.terminal`, `apps.browser`, `apps.files`
- **Windows:** `windows.close`, `windows.overview`, `windows.toggle-floating`
- **Workspaces:** `workspaces.switch.1` to `workspaces.switch.10`, and
  `workspaces.move.1` to `workspaces.move.10`
- **Web apps:** `webapps.slack`, `webapps.whatsapp`, `webapps.youtube`,
  `webapps.google-photos`, `webapps.x`
- **Other:** `clipboard.history`, `capture.region`

### 1.2 Key strings

- **Canonical form:** `MOD + MOD + KEY`.
  - Modifiers come from `SUPER`, `CTRL`, `ALT` and `SHIFT`, uppercase, in that
    order. A key with no modifier is just `KEY`.
  - `KEY` is an xkb keysym name such as `Return`, `B`, `comma`, `grave`,
    `F9` or `XF86AudioMute`.
  - A single-letter keysym is written in uppercase.
  - `code:N` names a layout-independent keycode, for keys that have no
    reliable keysym on the current layout.
  - Mouse keys (`mouse:272`, `mouse_down` and so on) may appear in vendor
    defaults but cannot be assigned by the editor.
- **Equality:** two key strings are equal when they have the same set of
  modifiers and their keys match case-insensitively. Both the Lua and the JS
  side implement `normalize` and `same` and check them against shared test
  vectors in `tests/fixtures/keybindings/`.

### 1.3 Preferences file: `$XDG_CONFIG_HOME/cybexos/keybindings.json`

The file is owned by the user and written only by the Settings backend,
atomically. It is sparse, so a missing file means "all defaults".

```json
{
  "v": 1,
  "actions": {
    "apps.browser":  { "keys": ["SUPER + SHIFT + B"] },
    "webapps.slack": { "keys": [] }
  },
  "custom": [
    { "id": "custom.gmail", "group": "Web apps", "label": "Gmail",
      "keys": ["SUPER + M"], "run": { "type": "webapp", "id": "gmail" } },
    { "id": "custom.gimp", "group": "Apps", "label": "GIMP",
      "keys": ["SUPER + ALT + G"], "run": { "type": "app", "desktopId": "gimp.desktop" } },
    { "id": "custom.site", "group": "Web", "label": "Docs",
      "keys": ["SUPER + ALT + D"], "run": { "type": "url", "url": "https://example.org" } },
    { "id": "custom.notes", "group": "Apps", "label": "Notes",
      "keys": ["SUPER + ALT + N"], "run": { "type": "command", "command": "kitty -e nvim ~/notes.md" } }
  ]
}
```

**`actions` entries** replace an action's keys. An empty list means the
action is disabled.

**`custom` entries:**

- `id` matches `^custom\.[a-z0-9-]{1,40}$`.
- `group` (no colon) and `label` are at most 64 characters, with no control
  characters.
- Each action or entry has at most 4 keys.
- `run.type` is one of:
  - `app`: a desktop file ID, launched the same way as the launcher's Apps
    tab.
  - `webapp`: launched with `cybexos-webapp launch ID`.
  - `url`: `http` or `https` only, opened with the default browser.
  - `command`: one line, at most 512 bytes, run through Hyprland's
    `exec_cmd`.

**Size and validation:** the file is at most 64 KiB and is read through the
bounded JSON reader in `displays.lua`. An invalid file never stops Hyprland:
the vendor defaults apply and the reason is published.

**Resolution** is deterministic and runs in Lua at every config load:

1. Start from the catalog defaults.
2. Apply overrides to editable actions.
   - An override of a protected action to `[]` is ignored.
   - A protected action always keeps its reserved default keys, in addition to
     any remap, so a typo such as `SUPER + Lcok` cannot leave it unbound.
     Its published `keys` are the accepted remap keys followed by the defaults.
   - Overrides for unknown or non-editable actions are ignored.
3. Overrides and custom entries claim their key combinations.
   - A default binding that uses a claimed combination loses that key. This
     is reported as `displaced`.
   - A combination already held by a protected action's default cannot be
     claimed. The claim is dropped and reported as `conflict`.
   - When two claims compete, the earlier one wins. Overrides come first, in
     catalog order, then custom entries in file order. The later claim is
     dropped and reported as `conflict`.
4. Bind the result. Then `user.lua` runs.

A loading error is published as `_G.__cybexos_keybindings_error`, a string or
nil, as `__cybexos_input_error` is today. `hyprland.lua` loads the
preferences after `bindings` and before `user.lua`.

### 1.4 Resolved state: `$XDG_RUNTIME_DIR/cybexos/keybindings-state.json`

After resolving, Lua writes the result atomically, using a temporary file and
a rename. The shell reads it and does not repeat the resolution:

```json
{ "v": 1, "error": null,
  "actions": [ { "id": "apps.browser", "group": "Apps", "label": "Browser",
                 "keys": ["SUPER + SHIFT + B"], "defaultKeys": ["SUPER + B"],
                 "editable": true, "protected": false, "hidden": false,
                 "changed": true, "custom": false } ],
  "custom": [ { "id": "custom.gmail", "group": "Web apps", "label": "Gmail",
                "keys": ["SUPER + M"], "run": { "type": "webapp", "id": "gmail" } } ],
  "diagnostics": [ { "type": "displaced", "id": "webapps.slack", "keys": "SUPER + M", "by": "custom.gmail" } ] }
```

`hidden` marks the `Hardware keys` group, which the sheet leaves out.
`user.lua` runs after this file is written. The shell therefore compares the
state with `hyprctl binds -j`:

- A catalog key that is no longer bound with the action's description is
  shown as "changed in user.lua".
- A described binding that is not in the catalog is listed read-only as
  "From user.lua".

### 1.5 Applying changes

A `keybindings` service in the existing system-settings backend, a sibling of
`system_settings_input.py`, applies changes the same way input preferences
are applied:

1. Compare the version hash, so a concurrent edit is rejected rather than
   overwritten.
2. Write the file atomically.
3. Run `hyprctl reload`.
4. Verify `__cybexos_keybindings_error == nil` with `hyprctl eval`.
5. If that fails, restore the previous bytes, reload again and report the
   error.

### 1.6 QML model: `Common/Keybindings.qml` (singleton)

The UI uses only this API. Additions are fine; renames are not.

```
readonly property bool loaded / busy
readonly property string error               // user-facing load/apply error, "" if none
readonly property var actions                // rows: { id, group, label, keys[], defaultKeys[],
                                             //   editable, protected, hidden, changed, custom,
                                             //   run (custom only), source: "default"|"changed"|"custom"|"user" }
readonly property var userBinds              // read-only rows from user.lua: { keys[], group, label }
readonly property var diagnostics
readonly property bool dirty                 // draft differs from the saved file
function refresh()
function keysFor(id) -> [keyString]          // effective keys, including the draft; [] if unbound or unknown
function action(id) -> row | null
function conflicts(keyString, exceptId) -> [{ id, group, label, protected, source, editable, hidden, uncertain? }]
function setKeys(id, keys) / disable(id) / reset(id) / resetAll()
function setManyKeys([{ id, keys }])          // one edit: all changes or, if one is refused, none
function addCustom({ group, label, keys, run }) -> id
function updateCustom(id, patch) / removeCustom(id)
function apply()                             // saves the draft through the backend
function discard()
signal applied()
signal failed(string message)
```

`Common/KeybindEditor.js` holds the pure functions, so they can be tested
under Node:

- `normalize` and `same`.
- `fromKeyEvent({ key, modifiers, nativeScanCode, text })`, which returns
  `{ keys, complete }`. A lone modifier is never complete.
- `isReserved(keys)`. A recording cannot claim a key that would make the
  session unusable.
- `display(keys)`, which returns keycap labels such as `["Super", "Shift", "B"]`.
  It reuses `KeybindHelpers`.

While a shortcut is being recorded, the recording window activates Quickshell
0.3's `ShortcutsInhibitor`, so Hyprland passes bound keys through.

### 1.7 Interfaces

- **Settings → Keyboard shortcuts** (page id `shortcuts`, listed beside
  Keyboard):
  - search by action or keys;
  - filters: All, Changed, Conflicts, From user.lua;
  - groups in sheet order;
  - per row: Edit (record), Reset and Disable;
  - Add shortcut (app, website, web app or command);
  - Reset all;
  - the apply bar.
- **Super+K sheet:** gains an "Edit shortcuts" action that opens that page.
- **Keyboard map component** (`Settings/ShortcutKeyboardMap.qml`): shows the
  Super+letter and Super+digit keys with their actions and marks protected
  keys. Clicking a free key offers "Open an app / website / web app / command".
  It is used by the welcome guide and by the Settings page.

As built:

- **Page.** `Settings/ShortcutsPage.qml`, rows `Settings/ShortcutRow.qml`. It
  holds a `Claim` on `Keybindings` while visible and Settings is open. A row's
  Reset is its SettingsRow undo chip, as on every other settings row, shown
  for changed vendor actions; Disable is a compact action and protected rows
  show a dimmed lock in its place. Custom rows edit through the Add form and
  have Remove instead of Disable. Rows from `userBinds`, mouse drags and
  hardware keys are read-only. The rows are one roving tab stop
  (Up/Down/Home/End, Enter records, Delete disables). Search matches labels
  and groups, translated and English, and key combinations by modifier and
  key names; the "Conflicts" filter combines Lua's `conflict`/`displaced`
  diagnostics with duplicate combinations among the shown rows (draft and
  `userBinds` included). "Changed" lists vendor overrides and custom
  entries; "From user.lua" lists `source: "user"` rows and `userBinds`.
  `failed(message)` and `Keybindings.error` appear at the top of the page
  and in the Apply bar. Reset all asks inline and edits the draft.
- **Recorder.** `Settings/ShortcutRecorder.qml`, a modal card over its host
  (the page's overlay; in the welcome guide, the guide window's content item).
  `start(id, label, keys, allowAdd)` then `accepted(combo, mode)` or
  `canceled()`; `mode` is `replace` or `add` (another key, at most four). It
  feeds `KeybindEditor.fromKeyEvent`; Escape cancels, a bare Backspace/Delete
  clears. A reserved combination keeps listening and shows its reason. A
  complete one is checked with `Keybindings.conflicts(keys, actionId)`:
  reserved protected defaults, `user.lua` holders and non-editable holders (a
  hidden hardware key) block, because `user.lua` loads last and an edit cannot
  unbind a hardware key; other holders are offered as Replace, which removes
  that key from all of them in one `setManyKeys` edit (a refused step leaves
  the draft as it was and the card open) before the host applies the new keys.
  Uncertain holders only warn (see §6). When the card closes, on cancel or
  accept, focus returns to the item that had it when `start()` ran (an Edit
  button, a map key, or the window's focus holder) and otherwise to the
  host's `fallbackFocus` (the welcome step, whose key commands bubble up to
  the guide); without that, hiding the card leaves the window with no focus
  item and the guide's Return, Escape and Ctrl+PageUp/PageDown do nothing.
  A host that sets focus itself (the Settings page's rows) does so afterwards.
  The `ShortcutInhibitor` is enabled only while
  listening and is released when a combination completes, on cancel and
  accept, when the window deactivates (recording pauses), when the
  compositor cancels it, when the card hides and on destruction.
- **Keyboard map.** Keys show their action (workspace switches as
  "Workspace N"), a lock for protected or reserved keys, an amber edge for
  keys used more than once and italic for `user.lua` keys. A free key is
  lit; choosing it shows the four run types and emits
  `addRequested(combo, type)`, which opens the Add form prefilled with that
  key. A bound, editable key emits `editRequested(id)`. The map draws the
  QWERTY layout, but matches keysyms, so it is correct on other layouts
  except for the key positions.
- **Add form.** `Settings/ShortcutCustomForm.qml`: run type, then an app from
  `DesktopEntries` (visible entries with valid IDs), a URL (`https://` is
  added when no scheme is typed), a web app (the seeded IDs plus installed
  ones from `cybexos-webapp list --json`) or a command; name, group (default
  per type) and keys recorded with the recorder. It saves with `addCustom` or
  `updateCustom`.
- **Super+K sheet.** "Edit shortcuts" calls `Session.closeKeys()` and
  `Settings.showPanel("shortcuts")`. While open, the sheet holds a
  `Keybindings` claim, only to mark rows: a filled accent dot for changed or
  custom rows, a ring for `user.lua` rows. Collapsed numbered rows stay
  unmarked.
- **Welcome step.** `Welcome/ShortcutsStep.qml` shows the map, the main
  shortcuts (keycaps from `Keybindings.keysFor`) with Edit, an inline Apply
  bar and "All shortcuts in Settings".

## 2. Welcome guide

### 2.1 Pieces

- **`Common/Welcome.qml` (singleton).** Holds state, decides when to open,
  tracks practice tasks and the checklist.
- **`Common/WelcomeHelpers.js`.** Pure logic, tested under Node.
- **`WelcomeWindow.qml`.** A `FloatingWindow` titled exactly
  `Welcome to Cybex OS`; `desktop/hypr/looknfeel.lua` already floats and
  centres it.
- **`Welcome/*.qml`.** One file per step, plus shared parts.
- **`shell.qml`.** Instantiates the window and adds the `welcome` IPC target.

### 2.2 State: `$XDG_STATE_HOME/cybexos/welcome.json`

```json
{ "v": 1, "status": "new|open|completed|dismissed", "step": "wallpaper",
  "seen": ["hello", "wallpaper"], "practice": { "launcher": true },
  "checklist": { "backup": "later" }, "version": "1.0.0-beta.3", "notified": false }
```

- **When it opens:** a missing file means first login. The guide opens once
  the desktop is ready, on the focused screen.
- **When it doesn't:**
  - `completed` or `dismissed` never reopens it by itself.
  - Safe mode never opens it.
  - Neither does a session started with `CYBEXOS_WELCOME=0`.
- **Persistence:** progress is saved on every step change, so a shell
  restart resumes on the same step. An unreadable file is reported and not
  overwritten, following the same rule as `shell.json`.
- **Dismissal:** Escape, the window close button, IPC `close`, and **Skip for
  now** (including on the finish step) set `dismissed`, keeping all progress.
  It never reopens automatically after dismissal. The first dismissal sends
  “You can finish setting up any time: open the launcher and search for Welcome.”
  `notified` remembers this across restarts. **Finish** sets `completed`.
  Manual reopening resumes the saved step; a completed guide starts at `hello`.
- **Readiness:** Settings is loaded and the wallpaper window has rendered its
  first decoded image frame, or its solid fallback when there is no image.
- **Reopening:** the launcher (`Welcome to Cybex OS`; search terms: welcome,
  setup, tour, getting started), Settings → About, and
  `cybexos-runtime ipc welcome open`.

### 2.3 Steps

1. **`hello`.** Greets the user by full name. Shows the installer's choices
   (language, keyboard layout, time zone) with Change links into Settings.
   Shows the network state and offers Connect when offline.
2. **`wallpaper`.** The wallpaper picker (§3), with tabs: Cybex OS
   collection, Wallhaven, My pictures. Holding Space fades the window so the
   desktop shows through.
3. **`style`.** Dark or light; accent from the wallpaper or a theme preset;
   glass; text size and density. It writes the same `Settings` keys as the
   Appearance page.
4. **`keys`.** Practice. Each task is ticked only when the shell observes it
   happen:
   - `launcher`: the launcher opened.
   - `terminal`: a new toplevel window appeared and then closed.
   - `workspace`: the focused workspace changed away and came back.
   - `overview`: the overview opened.
   - `shortcuts`: the Super+K sheet opened.

   The keycaps come from `Keybindings.keysFor(id)`, so remapped keys are
   shown. The window is pinned during this step, so it follows workspace
   switches.
5. **`shortcuts`.** The keyboard map (§1.7), the main shortcuts with Edit, and
   a link to Settings → Keyboard shortcuts.
6. **`finish`.** A summary plus an optional checklist. Each item reads its
   real state and is never ticked by a click:
   - web apps: keep or remove the seeded ones, add others; Open Software;
   - AI assistant: choose an agent and sign in;
   - fingerprint and security keys: only when a reader is present;
   - backups;
   - online accounts.

   "Later" is remembered per item.

Web apps have no completion tick because keep/remove is a personal choice.
Fingerprint setup is shown only for a ready reader. The existing security
backend has no cheap, reliable FIDO device-presence probe, so security keys are
an always-available plain Settings link without a tick. Other unavailable
checklist probes also remain unticked links rather than inferred successes.

Every step can be skipped. Back and Continue are available (Back is disabled
on Hello); Escape dismisses, preserving progress as specified above.

Integration notes (as implemented):

- **Wallpaper step.** `Welcome/WallpaperStep.qml` embeds
  `WallpaperPicker { embedded: true; automaticOnlineLoad: true }` with its own
  tab state; `escapeRequested` dismisses the guide like Escape elsewhere.
  `applied` needs no handler: the guide stores no wallpaper progress, and
  Finish reads `Settings.wall`. Holding Space peeks from anywhere on the step,
  including a focused thumbnail or button (Enter activates those), except
  while a `TextInput`/`TextEdit` such as Wallhaven search has focus, where
  Space types. Qt Wayland repeats a held key as release/press pairs, so only
  a non-repeat release ends the peek; losing window activation ends it too.
- **Keycaps.** `Welcome.keysFor(id)` returns
  `Keybindings.keysFor(id).map(KeybindEditor.display)`, the keycap-label
  arrays `Welcome/Keycaps.qml` renders; it starts no process and `[]` means
  unbound or not loaded. `WelcomeWindow` holds a Keybindings `Claim` while it
  is visible (`acquire` on show, `release` on hide or destruction), so a
  closed guide runs nothing. The practice step shows "Not bound" for a loaded
  action without keys, names each shortcut of a two-shortcut task, and keeps
  "No live binding is available" for an unavailable model. The workspace
  pair follows the observed start: `WelcomeHelpers.workspaceActions(start)`
  returns `["workspaces.switch.<away>", "workspaces.switch.<start>"]`
  (2 → 1 when unknown; only the way out when the start has no number key).
  A Node test checks every action ID in the guide against the ungated Lua
  catalog.
- **Small windows.** At the 640 × 480 minimum, or with large text, the step
  rail hides (its optional section hides first when only height is short),
  a short window drops the lead line (the window height decides, never the
  step area whose margin the choice changes: that was a binding loop), and the practice task list stacks
  under its card. The wallpaper step fills the viewport, with a
  `Theme.scaled(240)` floor; below it the step scrolls rather than clipping.

### 2.4 IPC target `welcome`

`open(step: string): string` takes `""` for the saved step and returns `ok`
or `unknown`. The other calls are `close(): void` and `status(): string`,
which returns JSON `{ open, status, step, practice, checklist }`.
`reset(): void` exists for tests and qualification; it deletes only
`welcome.json`.

The old Fedora-era wallpaper calls `popular`, `results` and `pick`, and
`WallhavenHelpers.ipcItems`, were made for the removed out-of-process window.
They are deleted. `browse`, `list`, `set` and `status` stay.

## 3. Wallpaper picker

- **Components:** the components work outside the Settings page scaffold:
  - an online view (Wallhaven), with an embedded preview panel;
  - a library grid, used for the user's folder and the bundled collection.

  Settings → Wallpaper and the welcome guide use the same components.
- **Bundled collection:** the images in the runtime's `wallpapers/`
  directory. Choosing one makes it the wallpaper by the same rules as a
  library file, including Matugen colours and rotation.
- **Wallhaven:**
  - Always safe for work.
  - Requests only after a user action. The guide's first listing counts as
    one, except on a metered connection, where the guide asks first.
  - Stays under 45 requests a minute: read `x-ratelimit-remaining` and pause
    on 429.
- **Filters:** topic chips (curated queries), Wallhaven's fixed colour
  palette, "More like this" (`like:ID`), and the existing sort, category and
  size filters.
- **Preview panel:** larger image, resolution, size, fit to the user's
  displays, the image's colours (`colors` from the listing), the uploader,
  the source and a link to the Wallhaven page. Details come from `/w/ID` on
  selection and are cached.
- **Selecting and applying:** selecting an image previews it; "Use this
  wallpaper" downloads and applies it.
- **Licensing:** Wallhaven images are never bundled or pre-cached. A
  download happens only when the user picks an image, into the user's own
  wallpaper folder.

## 4. Shared rules for implementers

- **Translations:** every `I18n.tr`/`I18n.format` string needs a Dutch entry
  in `Common/i18n/nl.js` (enforced by `tests/quickshell/i18n.test.cjs`).
- **New singletons:** register them in `Common/qmldir`.
- **Settings search:** new Settings rows get `SettingsSearchData.js` entries.
- **Docs:**
  - user-facing: `docs/keyboard-shortcuts.md`, `docs/welcome.md`, and the
    wallpaper section of the relevant doc;
  - this contract: update it when something deviates.
- **Tests:** Node tests in `tests/quickshell/` for pure logic. Lua tests must
  actually run, not be skipped, for example with `nix shell nixpkgs#luajit`.
  `tests/run` and the QML lint must pass. Real-engine checks run the actual
  shell under a private headless Sway, as `tests/assistant-overlay.py` does.
  `tests/welcome-guide.py`, `tests/wallpaper-picker.py` and
  `tests/shortcut-editor.py` draw with the installed desktop's fonts:
  `tests/shell_fonts.py` builds the default desktop's own `/etc/fonts`
  (`fonts.packages` and NixOS's conf.d) and points a private
  `FONTCONFIG_FILE` at it. Without it Qt substitutes the host's fonts; on a
  Debian host that is Nimbus Sans, whose medium and bold text is drawn
  oblique, so every screenshot looked italic although the shell is not.

## 5. Keyboard-shortcut backend: implementation notes and API additions

The §1.6 names and resolved-state schema are unchanged. `Keybindings` also
provides `acquire()` and `release()`. Consumers should use a `Claim` while
visible (`onClaimed: Keybindings.acquire()`, `onReleased:
Keybindings.release()`). Merely importing or reading the singleton starts no
process. `refresh()` makes one request without a claim; holding a claim keeps
the backend's existing 15-second refresh active. `busy` includes both reads
and writes. Edits return `true` on success or `false` and emit `failed` on
validation errors; `addCustom` returns the new ID or `false`. `apply()` returns
whether the request was accepted; wait for `applied()` or `failed(message)`.
`reset(id)` removes a vendor override, or restores a saved custom entry.
`resetAll()` removes all overrides and custom entries. `discard()` restores
the saved draft and refreshes. A refresh preserves a dirty draft and its
original version, so a later apply still rejects concurrent external edits.

`KeybindEditor.fromKeyEvent` returns `{keys: string, complete: bool}`; `keys`
is one canonical combination, not an array. It uses numeric Qt key/modifier
values and does not need a Qt object. Qt reports shifted symbols without the
base keysym. Shifted non-letter printable keys therefore use `code:N` when a
scan code exists, including international number rows; unknown keysyms use that fallback too.
AltGr is a layout selector outside the four supported modifiers and leaves a
recording incomplete. Qt Wayland's native scan code is already xkb
(evdev + 8). Hyprland 0.56.2's Lua `code:` parser stores that value unchanged,
and KeybindManager adds 8 to incoming evdev events before matching. Do not
subtract 8. Synthetic events without a known keysym or a valid scan code are
incomplete. This API is intended for Wayland, not Qt's other platform plugins.

**Layout keymap.** Hyprland matches a bind against the key's unmodified
(level 1) keysym, so `SUPER + SHIFT + code:10` is a different key to Lua and
JS than the vendor `SUPER + SHIFT + 1` and would bind beside it. The
`keybindings` snapshot therefore carries `keymap`, `{ "<xkb keycode>":
"<keysym>" }` for the first level of the main keyboard's active group
(`hyprctl devices -j`: `layout`, `variant`, `options`, `rules`, `model`, and
`active_keymap` to pick the group). It is built from `xkbcli compile-keymap`
(libxkbcommon, in the desktop runtime's PATH) by
`scripts/system_settings_keymap.py`, which reads the `xkb_keycodes` and
`xkb_symbols` sections (compact and `symbols[GroupN]=` forms) and is cached
per layout string in memory and as at most eight small files under
`$XDG_RUNTIME_DIR/cybexos/keymap-*.json`. Arguments are validated, the tool
runs with a 5 s timeout and a size cap, and any failure yields `{}`: no map
means no translation. `Keybindings.keymap` exposes it, and
`KeybindEditor.fromKeyEvent(event, keymap)` takes it as an optional second
argument and turns a `code:N` result into the keysym when the map has one
(US: `SUPER + SHIFT + 1`; AZERTY: `SUPER + SHIFT + ampersand`). Pass
`Keybindings.keymap` from every recorder.

`conflicts()` applies the same translation to a `code:N` key. When there is no
map entry for a `code:N` key with Shift, any action with the same modifiers
whose key is not a letter might be on that physical key, so each is reported
with `uncertain: true` (exact matches carry no flag). The UI should word those
as "may conflict".

The recorder reserves unmodified keys except F-keys/XF86 keys; modifier-only,
mouse, SysRq, power/sleep keys, Ctrl+Alt+F1–F12, Ctrl+Alt+Delete and
Ctrl+Alt+Backspace are also reserved. The Lua resolver independently reserves
the protected actions' default combinations, even when those actions have
been remapped. A protected action keeps those defaults bound in addition to any
remap (see §1.3), and its published `keys` include them. The draft preview in
`KeybindingsModel.js` does the same, and `setKeys` stores only the keys beyond
the defaults, so a protected remap back to just its defaults removes the
override. Only schema fields of a custom entry are copied into the state, and
the state encoder writes non-finite numbers as `null`; the Lua JSON decoder
already rejects overflowing numbers such as `1e999`.

The Python request is `{action: "apply", version, preferences}`; snapshots
return `{state, preferences, version, binds}`. The successful apply returns
`{version, preferences}` for the exact committed bytes. The service is
`SystemSettings.keybindings`, with no monitor process while idle.
`KeybindingsModel.js` contains pure draft/merge helpers; saved resolution is
always read from Lua's state, and only an unsaved draft is resolved in JS.

A `keybindings.json` that the loader rejects does not stop the page. The
snapshot still returns Lua's `state` and the live `binds`, with `preferences`
`{v: 1}`, the exact bytes' hash as `version`, and `preferencesError` (a string,
`""` when the file is fine). `Keybindings` exposes `preferencesError`, a
translated sentence ("Your keybindings.json could not be used, so your changes
are paused. Reset all to start again; the broken file is kept.") when Lua
rejects the file, otherwise the backend's own sentence; `preferencesDetail`,
Lua's technical reason without its `file.lua:line:` prefix (a parser position
such as "expected ',' or '}' at byte 61", English, `""` when there is none);
and `readOnly`, true while either side rejects the file.
While `readOnly`, every edit except `resetAll()` is refused with a failure.
`resetAll()` marks the draft dirty even though it looks unchanged; the next
`apply()` sends `replaceInvalid: true`. Only then does the backend replace the
file, after copying its exact bytes to `keybindings.json.invalid-<UTC
timestamp>` beside it (mode 0600, never overwritten or deleted). If that copy
fails nothing changes. The usual version check and reload rollback apply, and
the backup stays after a rollback. A file that is not a regular file (a
symlink, a FIFO) or is over 1 MiB is reported but cannot be replaced; repair it
by hand. `replaceInvalid` is ignored when the file is valid.

One transport addition touches `LauncherWindow.qml`: the existing `launcher`
IPC target now has `launchDesktop(desktopId: string): string`, returning
`ok`, `unknown` or `invalid`. This is needed to use the Apps tab's actual
`DesktopEntry.execute()` path, including field codes and terminal apps,
instead of interpreting desktop-file commands in Lua. IDs use ASCII desktop
file names ending in `.desktop` (letters, digits, `_@.+-`, no paths), up to
255 bytes. Web-app IDs use lowercase letters, digits and hyphens, up to 64
bytes; URLs use lowercase `http://` or `https://` and at most 2048 bytes.
These launch arguments are shell-quoted. Commands alone intentionally use
`exec_cmd` verbatim. Group/label limits count Unicode characters; command
limits count UTF-8 bytes.

When multiple catalog actions share a description, live missing keys can be
identified but additional user keys cannot be attributed to a particular
dispatcher. Such missing rows have `source: "user"` and only their surviving
keys. For unique descriptions, a remap or additional keys are shown on that
action. Additional keys under shared descriptions, and submap bindings, are
listed read-only in `userBinds`. Undescribed personal bindings are still omitted from `userBinds`,
as required by the sheet's existing description convention.

## 6. Shortcut editor UI: implementation notes

No `Keybindings` or `KeybindEditor` API was added or changed. The editor's
pure view logic is `Common/ShortcutEditor.js`, tested in
`tests/quickshell/shortcut-editor.test.cjs`: grouping and filters, search,
conflict decisions, recorder key commands, the keyboard-map layout and focus
moves, run-target validation with the backend's limits, and the sheet marks.

`decide(keys, conflicts, lookup)` returns `{kind, reason, blockers, replace,
maybe}`. `kind` is one of:

- `reserved`, with reason `modifier`, `mouse`, `power`, `system` or `invalid`;
- `blocked`, with reason `protected`, `user`, `hardware` (a hidden,
  non-editable holder) or `fixed` (any other non-editable holder). A holder
  with `editable: false` always blocks, since `setKeys` would refuse it;
- `replace`;
- `maybe`, when only `uncertain` holders remain;
- `free`.

Conflicts with `uncertain: true` never block and are never unbound; they go
to `maybe` and the recorder says "May conflict with …" and offers **Use
anyway**. With `lookup(id)` (the recorder passes `Keybindings.action`), a
protected holder blocks only when the combination is one of its reserved
`defaultKeys`; its extra keys are ordinary claims that Replace may take.

Protected rows: `lockedKeys(row)` is a protected row's reserved defaults
(present in its published `keys`), and `editableKeys(row)` the rest. Rows,
the recorder's "Now" line and the welcome step draw locked keys dimmed with a
lock. The keyboard map's `protected` flag (its lock) marks only those reserved
defaults. Hosts compute `nextKeys(editableKeys(row), combo, mode)`, so
"Replace added keys" replaces only the extras, and `setKeys` drops the
defaults again. The recorder's `start(id, label, keys, allowAdd, lockedKeys)`
offers "Add as another key" only when extras exist. Every recorder passes
`Keybindings.keymap` to `fromKeyEvent`.

While `Keybindings.readOnly`, the page and the welcome step show
`preferencesError` in a banner, with `preferencesDetail` after it in smaller,
quieter type (`SettingsHint.detail`; the page's error line no longer repeats
it).
Record, Disable, Reset, Add and the map's edit and add requests are refused.
Reset all stays enabled and explains `keybindings.json.invalid-<time>`, and
the Apply bar says the file will be replaced. `ShortcutsPage.handleEscape()`
is part of `SettingsView.handleEscape()`: an open Reset question or Add form
closes before Settings does. A host shorter than the recorder card scrolls the
card and keeps the capture area or the focused button in view.
`I18n.actionLabel()` names actions everywhere in the editor and the sheet, so
numbered labels translate through `"Switch to workspace %1"`-style entries.

Quickshell 0.3's type is `ShortcutInhibitor` (`enabled`, `window`, read-only
`active`, `cancelled()`), imported from `Quickshell.Wayland`. When the
compositor cancels an active inhibitor, Quickshell itself writes
`enabled = false`, which silently removes a QML binding. The recorder
therefore assigns `enabled` whenever its listening state changes rather
than binding it. `window` is the item's `QsWindow.window`.

`tests/shortcut-editor.py` runs the real shell under a private headless Sway.
Its fake `hyprctl reload` runs the real `bindings.lua` and
`keybinding_preferences.lua` through the Node tests' Lua stub, so the written
`keybindings.json` and the resolved state follow the actual Lua contract. It
also records `Super+Shift+1` without and then with a layout (the fake `hyprctl
devices` names `us`, compiled by the real `xkbcli`), remaps the protected
lock screen twice, and replaces a malformed file through the read-only page.
Headless Sway has no keyboard of its own: when a key-sending `wtype` exits,
Qt deactivates the window and nothing re-enters it, so the check keeps one
idle `wtype` attached for the session. An item reparented out of a clipped
Flickable was not painted by Qt's software renderer, so the welcome step
creates its recorder directly in the guide window's content item.

