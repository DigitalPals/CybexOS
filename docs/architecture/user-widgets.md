# Persistent user widgets: API 1

Personal widgets extend an installed desktop without forking the distro.
Updates replace the shell implementation; the package, enablement, settings,
and state remain owned by the user. API 1 is a compatibility commitment: a
future shell refactor must keep this interface working or provide an adapter.
Changing the distro release number alone does not change the widget API.

An additional adapter recognizes all six Omarchy `schemaVersion: 1` plugin
kinds and injects their host interface. It shares this user-owned storage but does
not change native API 1. See [Omarchy compatibility](../omarchy-plugin-compatibility.md)
for supported UI modules, installation, and limits.

## Storage and ownership

Default paths below follow XDG config and data roots. The runtime
exports `FEDORA_CONFIG_PLUGIN_ROOT` and `FEDORA_CONFIG_USER_CONFIG_ROOT` for
the shell; the command helper honors these when present too.

| Contents | Default path | Update/rollback behavior |
| --- | --- | --- |
| Package source and assets | `~/.local/share/fedora-config/plugins/<id>/` | Never reconciled with vendor files |
| Enablement, order, width, settings | `~/.config/fedora-config/plugins.json` | Never written by deployment or shell-settings migrations |
| Plugin data | `~/.local/share/fedora-config/plugin-data/<id>/` | Retained; plugin controls its own format |
| Loader and API adapter | `~/.local/share/fedora-config/runtime/quickshell/` | Replaced by distro updates |

Uninstall retains user widget packages and data. Disabling a widget changes
only its enablement flag. Existing releases before API 1 cannot display these
widgets, but their ownership boundary retains the files for re-enablement on
a supporting release. Compatibility claims apply to releases supporting API 1.

## Package and preference formats

Each package has a `manifest.json`:

```json
{
  "id": "personal.focus",
  "name": "Focus",
  "version": "1.0.0",
  "apiVersion": 1,
  "entrypoint": "Widget.qml"
}
```

The ID matches its directory and uses lowercase letters and digits separated
by single dots or hyphens, beginning with a letter. IDs are case sensitive.
Entrypoints are `.qml` paths within the package; absolute paths, parent
traversal, missing files, and entrypoint symlinks escaping the package are
rejected. Name and package version are descriptive strings. Unsupported API
versions are reported without executing their QML.

The independent registry uses this shape (prefer the commands over hand edits):

```json
{
  "v": 1,
  "plugins": {
    "personal.focus": {
      "enabled": true,
      "width": 120,
      "order": 0,
      "settings": { "label": "Deep work" }
    }
  }
}
```

Absent packages are disabled by default. Width defaults to 120 pixels and
accepts integers from 24 to 320; order defaults to zero, with IDs breaking
ties. `settings` is an arbitrary JSON object owned by the plugin. Unknown
registry fields survive command writes. Corrupt registries and unsupported
registry versions are reported and preserved; writes refuse to reset them.

```bash
cybex plugin list
cybex plugin enable personal.focus --width 120 --order 0
cybex plugin set personal.focus label '"Deep work"'
cybex plugin disable personal.focus
```

`list` outputs JSON including disabled, missing, and incompatible packages.
`enable` validates a package's manifest and options; QML is checked when the
shell loads it. Commands serialize read-modify-write operations with a file
lock and atomically replace the registry. Use these commands for concurrent
agent/desktop edits; external editors must coordinate rather than replace a
stale copy of the file. Preferences refresh within two seconds. Restart the
managed Quickshell service after QML code changes.

## Public QML interface

The entrypoint is a QtQuick Item (including Rectangle, Text, Row, etc.) with
`required property var pluginApi`. The host supplies that property before
construction completes and assigns the item's width and height. Relative
imports and assets within the package work. Do not import shell-private
`Common`, `Bar`, or `Settings` types: they have no plugin compatibility promise.

| API member | Contract |
| --- | --- |
| `version` | Integer `1` |
| `id` | Package ID |
| `settings` | Current JSON settings object; treat as read-only |
| `setSetting(key, value)` | Asynchronously merge one JSON-serializable setting; read back from `settings` after refresh |
| `theme` | Read-only values: `foreground`, `background`, `accent` color strings, `fontFamily`, numeric `fontSize`, shared `typography` roles, boolean `reducedMotion` |
| `width`, `height` | Allocated dimensions, updated with the host |
| `screenName` | The output hosting this instance |
| `packagePath` | Absolute package directory for assets/helpers |
| `dataPath` | Absolute persistent user data directory; created when enabled through the command |

There is one instance per output. Shared settings and state are not separate
per monitor; plugins should manage shared workers separately. Settings values
must be JSON-serializable (no undefined, functions, cycles, or non-finite
numbers). Use plain QtQuick and available Qt/Quickshell modules; plugins own
any additional software, credential, and external-service dependencies.

API 1 places widgets before the built-in right-hand modules. Their combined
display budget is one quarter of the screen, with room reserved for an
overflow count. Excess widgets are hidden with a tooltip listing their names.
Placement in other columns, built-in drag ordering, and custom shell popouts
are not part of this API. Use QtQuick content inside the supplied bounds.

Malformed QML and incompatible manifests produce a local error placeholder;
hover it for details. The rest of the bar remains usable. Registry errors
have a separate indicator. These are trusted local code extensions, not
sandboxed programs: native crashes, infinite loops, or arbitrary actions in a
plugin cannot be contained by a QML component boundary. Disable a problematic
plugin through the terminal and restart the managed service if necessary.

## Compatibility and release verification

Keep API 1 available when introducing a new API. Do not reinterpret an API 1
property or require plugins to import new private implementation paths.
An incompatible plugin is preserved with its enabled preference intact so a
future compatible host can load it again. Do not claim that merely retaining
its files makes it functional on a host that does not support its API.

`tests/user-plugins.py`, included in `tests/run`, runs a fixed API 1 widget in
the real Quickshell engine with its package outside the runtime. It replaces
the runtime tree for simulated N, N+1, and rollback runs, checks package bytes
and preferences, tests local QML imports, malformed/incompatible widgets, and
writes a setting through the injected API. It also covers concurrent command
writes and corrupt/newer registry preservation. This is a source-level
compatibility fixture; it does not claim to exercise two published releases
or the complete package updater. Existing ownership/convergence gates check
the deployment boundary separately.

The real-engine test runs in isolated CI, never alongside a live `qs` process.
On an installed desktop, follow `tests/lib/quickshell-live` for service/PID
reconciliation and current-invocation journal checks.

For an agent-ready example, see the installed
[user widget skill reference](../../agent-skills/fedora-config/references/user-widgets.md).

### Shared typography

`api.theme.fontSize` remains the bar text size for existing API 1 widgets.
New widgets can select `api.theme.typography.bar`, `.control`, `.primary`,
`.secondary`, `.section`, or `.title` according to the text's purpose. Use
`api.theme.fontFamily` for text. These are live shared values, not constants
for a plugin to copy. See [the typography contract](../shell-typography.md).
