# Keyboard shortcuts

Press `Super+K`, or use **Keyboard shortcuts** in the Control Panel, to open
the shortcut sheet. It lists the keybindings Hyprland actually has, read with
`hyprctl binds -j` each time the sheet opens. There is no separate list to
fall out of date, and a failed read is shown as an error.

A binding appears in the sheet when it has a description. Descriptions use
the form `Group: Label`, for example `Apps: Terminal`. Cybex OS's own groups
are Shell, Apps, Web apps, Development, Windows, Workspaces, Clipboard,
Capture and Dictation, in that order. New groups follow them, and a
description without a group is listed under Other. Several bindings with the
same description show as alternatives, and numbered bindings such as
`Switch to workspace 1` to `10` are shown as one row.

`Super+I` (**Shell: Assistant**) talks to the Cybex OS Assistant: tap it to
type a question, or hold it, speak, and release to send. See
[Cybex OS Assistant](assistant.md).

`Super+Tab` (**Windows: Overview**) opens the window overview: every
workspace's windows as live thumbnails, with arrow-key, filter and
drag-to-move controls. See [Window overview, dock and top processes](overview-and-dock.md).

The volume, brightness and media keys are described as `Hardware keys` so
`hyprctl binds` still explains them, but the sheet leaves that group out: the
keys are labelled on the keyboard itself.

The sheet uses up to three columns, as many as its width allows, and keeps the
groups in reading order: down the first column, then the next. The split puts
whole groups in each column so the columns end at about the same height. A row
whose keys do not fit beside its label puts them on the lines below it.

## Web apps

The Web apps group opens the web apps Cybex OS installs for every account:
`Super+M` Slack, `Super+W` WhatsApp, `Super+Y` YouTube, `Super+Shift+P` Google
Photos and `Super+Shift+X` X. Each binding runs `cybexos-webapp launch ID`,
which opens the site in Brave Origin's app mode when Brave Origin is installed
and in Firefox otherwise. Remove one with **Remove web app…** in the launcher
or `cybexos-webapp remove ID`; it is not added back by later updates, and its
shortcut then shows how to reinstall it. Add other sites with **Install web
app…** in the launcher or `cybexos-webapp install --url ADDRESS`. Installed web
apps appear in the launcher's Apps tab.

## Clipboard history

`Super+Ctrl+V` opens the launcher on its History tab. `Enter` pastes the
selected entry into the window you were using, `Shift+Enter` only copies it,
and `Ctrl+P` pins it so it stays at the top of the list after the history is
pruned or cleared.

## Capture

| Keys | Action |
| --- | --- |
| `Print`, `` Super+` `` | Screenshot: drag out a region, or click a window to capture exactly that window |
| `Shift+Print` | Screenshot of the focused screen |
| `Alt+Print`, `` Super+Alt+` `` | Scrolling screenshot |
| `` Super+Shift+` `` | Start or stop a screen recording |
| `` Super+Ctrl+Shift+` `` | Start or stop a screen recording with the webcam |
| `Super+Shift+O` | Copy the text, or the QR code or barcode, in a region |
| `Super+Print`, `Super+Shift+C` | Pick a colour |

Screenshots are saved in `~/Pictures/Screenshots` and copied to the
clipboard; click the notification to edit one in Satty.

For a scrolling screenshot, select the area to capture, then scroll its
content down at a normal pace. Press `Enter`, `Escape` or the shortcut again
to finish, or click the red indicator in the menubar. The frames are joined
where they overlap into one tall image; a header or footer that stays in
place appears once. A capture stops by itself after 90 seconds or 24,000
pixels. Scrolling back up adds nothing, and a part scrolled past too quickly
to overlap is joined with a gap, which the notification mentions.

A webcam recording shows a round camera preview in a corner of the recorded
area, and the recording includes it. Drag the preview to move it to another
corner. It closes when the recording stops. Without a camera the recording
goes ahead without it, and a notification says so.

Recordings use the graphics card's video encoder when its driver offers H.264
encoding: VA-API on Intel and AMD, and NVENC on NVIDIA with the proprietary
driver. Otherwise they are encoded in software, as is an attempt whose
hardware encoder fails to start. If you install `gpu-screen-recorder`
yourself, NVIDIA systems record with it instead. Run `screen-record --encoder`
to see what the next recording will use. Recordings have no sound.

The text shortcut decodes a QR code or barcode first and copies its content;
the notification says whether it was a link or Wi-Fi details. Links are never
opened. Without a code, the text in the region is recognised and copied.

The colour picker copies the colour's hex value, such as `#1E1E2E`, and shows
it in a notification. `Escape` cancels.

## Changes saved by Settings

The shortcut backend stores Settings changes in
`$XDG_CONFIG_HOME/cybexos/keybindings.json` (normally
`~/.config/cybexos/keybindings.json`). A missing file means vendor defaults.
The data is sparse: only changed actions and your custom shortcuts are saved.
Action IDs stay stable even if a label changes. For example:

```json
{
  "v": 1,
  "actions": {
    "apps.browser": { "keys": ["SUPER + ALT + B"] },
    "webapps.slack": { "keys": [] }
  },
  "custom": [
    { "id": "custom.notes", "group": "Apps", "label": "Notes",
      "keys": ["SUPER + ALT + N"],
      "run": { "type": "command", "command": "kitty -e nvim ~/notes.md" } }
  ]
}
```

Each entry has at most four keys. An empty list disables an action; lock,
exit, Settings and the shortcut sheet must keep a key. Hardware and mouse-drag
bindings cannot be edited. Workspace scroll actions can be remapped to keys. Custom IDs start with `custom.` followed by 1–40
lowercase letters, digits or hyphens. Group and label are at most 64
characters; the group has no colon. Neither accepts control characters.

Keys use `SUPER`, `CTRL`, `ALT`, `SHIFT` in that order, followed by an xkb
keysym such as `B`, `Return` or `comma`. `code:N` uses a layout-independent
xkb keycode. On Wayland the recorder's Qt scan code already has the same
value Hyprland expects: evdev + 8. Shifted digits and punctuation may be
recorded this way to avoid guessing the base symbol on international layouts.
Synthetic key events without a known keysym or scan code cannot be recorded.
AltGr is a layout selector outside the four supported modifiers and cannot be
recorded. The recorder keeps ordinary unmodified typing, VT recovery, secure attention,
SysRq and power/sleep keys reserved. It never records a lone modifier.

Custom launch types are `app` with `desktopId` (the same desktop-entry launch
as the Apps tab), `webapp` with `id` (`cybexos-webapp launch ID`), `url` with
an HTTP/HTTPS `url` (default browser), or `command` with a single-line
`command` of at most 512 UTF-8 bytes. App/web-app/URL arguments are quoted;
commands intentionally run as shell commands. App IDs are ASCII filenames
ending in `.desktop`, without paths; web-app IDs contain lowercase letters,
digits and hyphens. Website URLs are limited to 2048 bytes.

Applying a draft checks that the saved file has not changed elsewhere,
writes it atomically, reloads Hyprland and checks the contained loader error.
If reload or validation fails, the backend restores the exact previous bytes
(or removes the newly created file) and reloads again. Preferences must be a
regular file, not a symlink, with no duplicate JSON keys and at most 64 KiB.
An invalid file leaves the compositor on vendor defaults and publishes its
error; repair it before applying more changes.

Explicit overrides claim keys before custom entries, in catalog order; custom
entries follow file order. The first claim wins and displaces a default on
the same combination. Protected default combinations cannot be claimed by
another action, even when remapped. A protected action also keeps its
default combinations in addition to any remap, so a mistyped key name cannot
leave the lock screen, exit, Settings or the shortcut sheet unbound. Conflicts and displaced keys appear in
`$XDG_RUNTIME_DIR/cybexos/keybindings-state.json`, written atomically at every
configuration load before `user.lua`. The shell reads that result and compares
it with live Hyprland bindings to mark changes made in `user.lua`. Settings
never writes that Lua file: your personal layer below still loads last.

The recorder stores a Shift combination the way the vendor shortcuts are
written, with the key's unshifted name for your current layout (for example
`SUPER + SHIFT + 1` on a US keyboard and `SUPER + SHIFT + ampersand` on
AZERTY). If the layout cannot be read it stores the key's code instead and
warns that it may overlap other Shift shortcuts.

If `keybindings.json` cannot be loaded, the vendor shortcuts stay active, the
editor shows the reason and is read only, and **Reset all** is the way out.
Applying it replaces the file only after copying the old bytes to
`keybindings.json.invalid-<timestamp>` in the same directory; that copy is
never deleted.

## Your own shortcuts

Add personal bindings to `~/.config/cybexos/hypr/user.lua`. Cybex OS loads it
after its own configuration and never changes it. Give each binding a
`description` so it appears in the sheet:

```lua
local function bind(keys, dispatcher, description)
  -- Unbinding first replaces a Cybex OS binding on the same keys and keeps
  -- configuration reloads from stacking duplicates.
  hl.unbind(keys)
  return hl.bind(keys, dispatcher, { description = description })
end

bind("SUPER + ALT + G", hl.dsp.exec_cmd("gimp"), "Apps: GIMP")
bind("SUPER + ALT + N", hl.dsp.exec_cmd("kitty -e nvim ~/notes.md"), "Notes: Open notes")
```

Hyprland reloads its configuration when it notices the change; run
`hyprctl reload` if it does not. The next time the sheet opens it includes the
new rows, without restarting the shell. A binding without a description still
works; it is just not listed. Check for mistakes with `hyprctl configerrors`.

## Windows, zoom, game mode and gestures

These are in the sheet too; this is what they do.

- **Scratchpad.** `Super+-` shows or hides the scratchpad, a special
  workspace that opens over the current one. `Super+Shift+-` moves the active
  window there without showing it. The workspace strip in the menubar never
  shows the scratchpad as a numbered workspace.
- **Window groups.** `Super+G` makes the active window a group, shown as tabs
  in one tile, or turns a group back into separate windows. A window opened
  while a group has focus joins it. `Super+Ctrl+G` moves the active window out
  of its group, and `Super+Alt+←`/`→` switch between the windows in a group.
- **Zoom.** `Super+Z` magnifies the screen around the pointer to 2×, and
  pressing it again returns to 1× from any zoom. `Super+Ctrl+=` and
  `Super+Ctrl+-` change the zoom in 0.5× steps between 1× and 4×. A
  configuration reload also returns to 1×.
- **Game mode.** `Super+Shift+G` turns off animations, blur, shadows, rounded
  corners and gaps, and keeps the screen from locking or the computer from
  suspending when idle. The menubar shows a gamepad while it is on; click it,
  or press the keys again, to turn it off and get everything back as it was.
  It ends with the session. From a terminal: `game-mode on`, `game-mode off`,
  `game-mode toggle` or `game-mode status --json`.
- **Touchpad gestures.** Swipe three fingers left or right to switch
  workspace, or up to open the overview. Turn the workspace swipe off in
  **Settings → Touchpad → Swipe between workspaces**. A gesture of your own in
  `user.lua` on the same fingers and direction replaces the Cybex OS one:

  ```lua
  hl.gesture({ fingers = 3, direction = "horizontal", action = "move" })
  ```
