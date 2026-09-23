# Personal bar widgets

Create a widget for the installed user without changing the distro. The active
release's [widget contract](../../../docs/architecture/user-widgets.md) is the
authoritative API reference; read it before implementing behavior.

## Ownership and workflow

1. Inspect `cybex plugin list`. Use a unique lowercase ID such as
   `personal.focus`; preserve an existing package with that ID.
2. Create `~/.local/share/cybexos/plugins/<id>/manifest.json` and its QML
   entrypoint. Use an ordinary QtQuick Item and declare
   `required property var pluginApi`. Declare `apiVersion: 1` in the manifest.
3. Use `pluginApi.settings`, `pluginApi.theme`, and `pluginApi.setSetting()`.
   Keep helper code/assets in the package and persistent data under
   `pluginApi.dataPath`. Do not import private Common/Bar components or
   hardcode a release path. Widgets run as trusted code with the user's access.
4. Enable with `cybex plugin enable <id> --width 120 --order 0`.
   New packages are disabled until explicitly enabled. Enablement and settings
   refresh within two seconds. QML code edits require a Quickshell restart.
5. Set preferences with `cybex plugin set <id> <key> '<JSON value>'`.
   This merges one key under a lock. Never replace the whole registry or edit
   built-in `shell.json` module lists to register a plugin.
6. Verify the widget in the bar and run `cybex plugin list` again.
   API/manifest problems appear there; QML load errors appear on the widget's
   error tooltip. Use `cybex plugin disable <id>` to recover without
   deleting code, preferences, or data.

V1 places widgets before the right-hand built-in modules. Width is 24–320
pixels; lower order comes first, with IDs breaking ties. Widgets that exceed
the available space are hidden with a count and tooltip. Each output gets its
own widget instance; settings and state are shared. Run shared background
services separately rather than starting one daemon per output.

For a live check, follow the repository's `tests/lib/quickshell-live` begin/end
workflow described in [managed configuration](managed-configuration.md). Test
through `quickshell.service`; never leave a second source-tree shell running.

## Minimal package

`manifest.json`:

```json
{
  "id": "personal.focus",
  "name": "Focus",
  "version": "1.0.0",
  "apiVersion": 1,
  "entrypoint": "Widget.qml"
}
```

`Widget.qml`:

```qml
import QtQuick

Rectangle {
    required property var pluginApi
    color: pluginApi.theme.background
    radius: 5
    Text {
        anchors.centerIn: parent
        text: parent.pluginApi.settings.label || "Focus"
        color: parent.pluginApi.theme.foreground
        font.family: parent.pluginApi.theme.fontFamily
        font.pixelSize: parent.pluginApi.theme.fontSize
    }
}
```

After creating the package:

```bash
cybex plugin set personal.focus label '"Deep work"'
cybex plugin enable personal.focus --width 120
```

An API mismatch preserves the package and its settings but does not execute
its QML. Do not lower a manifest's API version to bypass that check; adapt the
implementation to a supported API. External programs, services, and network
APIs remain the plugin author's dependencies; list them when handing off.
