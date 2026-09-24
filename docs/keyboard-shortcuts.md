# Keyboard shortcuts

Press `Super+K`, or use **Keyboard shortcuts** in the Control Panel, to open
the shortcut sheet. It lists the keybindings Hyprland actually has, read with
`hyprctl binds -j` each time the sheet opens. There is no separate list to
fall out of date, and a failed read is shown as an error.

A binding appears in the sheet when it has a description. Descriptions use
the form `Group: Label`, for example `Apps: Terminal`. CybexOS's own groups
are Shell, Apps, Web apps, Development, Windows, Workspaces, Clipboard,
Capture, Dictation and Hardware keys, in that order. New groups follow them,
and a description without a group is listed under Other. Several bindings with
the same description show as alternatives, and numbered bindings such as
`Switch to workspace 1` to `10` are shown as one row.

## Your own shortcuts

Add personal bindings to `~/.config/cybexos/hypr/user.lua`. CybexOS loads it
after its own configuration and never changes it. Give each binding a
`description` so it appears in the sheet:

```lua
local function bind(keys, dispatcher, description)
  -- Unbinding first replaces a CybexOS binding on the same keys and keeps
  -- configuration reloads from stacking duplicates.
  hl.unbind(keys)
  return hl.bind(keys, dispatcher, { description = description })
end

bind("SUPER + G", hl.dsp.exec_cmd("gimp"), "Apps: GIMP")
bind("SUPER + ALT + N", hl.dsp.exec_cmd("kitty -e nvim ~/notes.md"), "Notes: Open notes")
```

Hyprland reloads its configuration when it notices the change; run
`hyprctl reload` if it does not. The next time the sheet opens it includes the
new rows, without restarting the shell. A binding without a description still
works; it is just not listed. Check for mistakes with `hyprctl configerrors`.
