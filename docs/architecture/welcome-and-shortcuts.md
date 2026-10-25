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
function conflicts(keyString, exceptId) -> [{ id, group, label, protected, source }]
function setKeys(id, keys) / disable(id) / reset(id) / resetAll()
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
  "checklist": { "backup": "later" }, "version": "1.0.0-beta.3" }
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

Every step can be skipped. Back and Continue are always available. Escape
asks to finish later rather than discarding progress.

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
