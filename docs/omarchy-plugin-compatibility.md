# Omarchy plugin compatibility

Cybex supports all six Omarchy plugin kinds: **bar-widget, service, panel,
overlay, menu, and replacement bar**. Packages using the implemented host
contract can run unchanged. This includes the tested upstream Pomodoro widget,
Media service/widget, and Bar replacement. It is not a guarantee that every
Omarchy plugin or built-in desktop integration works.

The implementation targets Omarchy commit
[`60663faf8764253646f1d6166e864b608d4a0fa1`](https://github.com/omacom/omarchy/tree/60663faf8764253646f1d6166e864b608d4a0fa1),
inspected on 2026-09-19. Its `schemaVersion: 1` describes manifest structure;
it does not freeze the host API across future upstream releases.

## Parity assessment and implementation (2026-09-19)

**The main management and runtime gaps are now implemented; compatibility is
still qualified by the limits below.** The preceding audit used a fresh
`git ls-remote` and upstream checkout to confirm that the pinned commit above is
still Omarchy's default-branch HEAD. This comparison does not cover its separate
development branch.

| Capability | Assessment against that upstream revision |
| --- | --- |
| Six plugin kinds, defaults, service/UI lifecycle, repeated widgets, replacement bars | Implemented, with representative fixtures and the limits below; not universal package compatibility |
| Git package management | `add`, `update [--preview]`, and `remove`; candidate manifests/entrypoints are validated before installation or fast-forward. Dirty/diverged checkouts are rejected; settings and data survive removal |
| Built-in customization | `clone <id> <new-id> [--edit]`, with `--from <omarchy-checkout>` for built-in manifests and `clonePaths`. Installed originals are disabled and restored when the clone is removed. Native Cybex built-ins are not replaced by Omarchy clone IDs |
| Management menus | Settings → Plugins supports trusted Git installs, enable/disable, update preview/update, clone and confirmed removal; built-in imports from an Omarchy checkout use the CLI |
| Code reload | Two-second discovery refresh detects package edits and loads versioned snapshots, including relative QML/JS imports. `keepLoaded` services survive code reload; disable/re-enable or `plugin restart` recreates them |
| Shell IPC | Added configuration/theme refresh, placement and settings mutations, panel toggling, transparency and geometry methods. Mutations are queued, and Cybex schemas/validation differ; this is not exact signature/result parity |
| First-party integrations | Full bars receive narrow idle, nightlight, notification and media adapters backed by Cybex. Authentication, Omarchy commands and external backends are not supplied |
| Manifest acceptance | Stricter here, not identical. For example, Cybex requires an ID beginning with a letter, while upstream's package CLI also accepts a leading digit; Cybex also requires entrypoint keys to exactly match declared kinds |

The lack of a marketplace is a local limitation, but is **not established as
a parity gap** by this upstream revision. Its plugin catalogue enumerates local
packages and its management menu handles enable/disable/clone/remove.

Implemented commands and menus share the existing locked preference writer.
Package updates never run plugin installers or Git hooks. Git preview reports
changed files; validation covers manifests and entrypoint paths, not arbitrary
QML behavior or plugin dependencies. Runtime failures remain visible through
plugin diagnostics and replacement-bar fallback.

Comparison sources at the pinned revision:
[shell contract](https://github.com/omacom/omarchy/blob/60663faf8764253646f1d6166e864b608d4a0fa1/docs/omarchy-shell.md),
[package updater](https://github.com/omacom/omarchy/blob/60663faf8764253646f1d6166e864b608d4a0fa1/bin/omarchy-plugin-update),
[clone command](https://github.com/omacom/omarchy/blob/60663faf8764253646f1d6166e864b608d4a0fa1/bin/omarchy-plugin-clone),
[management menu](https://github.com/omacom/omarchy/blob/60663faf8764253646f1d6166e864b608d4a0fa1/bin/omarchy-menu-plugin),
and [service proxies](https://github.com/omacom/omarchy/blob/60663faf8764253646f1d6166e864b608d4a0fa1/shell/services/PluginFirstPartyServiceApi.qml).

Audit verification: `node --test tests/quickshell/*.test.cjs` completed with
736 passes, two skips (installed Qt enum checks unavailable on the Debian host),
and no failures. `tests/user-plugins.py` passed in a disposable Fedora 44
container with Quickshell and two headless Sway outputs, including runtime
replacement/rollback and the Omarchy entrypoint suite. Eight Omarchy fixture
files matched current upstream HEAD byte-for-byte; both Pomodoro fixture files
matched their recorded commit. This audit did not repeat the full `tests/run`
pipeline or physical desktop qualification. That audit changed only this document; the implementation below adds code and regression tests.

## Install and configure

Install a trusted package with `cybex plugin add <git-url-or-local-repository>`,
then enable it, or put a complete plugin checkout in
`~/.local/share/cybexos/plugins/<manifest-id>/`. The directory must match
its manifest ID. Preserve the manifest, QML, relative imports, scripts, and
assets. No manifest conversion or Omarchy installation is required. Packages
are trusted executable QML running as the desktop user; they are not sandboxed.
Enabling a package does not run its installer or install its dependencies.

For the tested `markbus-ai/omarchy-pomodoro` package:

```bash
cybex plugin enable markbusking.pomodoro --section right --width 90
cybex plugin set markbusking.pomodoro workMinutes 25
cybex plugin set markbusking.pomodoro sound false
cybex plugin list
```

### Declared settings

Upstream schema 1 defines no settings format, so Cybex reads an optional
`barWidget.schema` array, the convention used by packages such as
`digitalpals.model-usage`. The widget's settings dialog (Settings → Bar →
the widget) draws each entry as an ordinary settings row, with its `label`,
`description`, a changed-value mark, and a reset to its default:

| `type` | Extra keys | Control |
| --- | --- | --- |
| `boolean` | | Switch |
| `enum` | `options` | One-of-many picker |
| `multiselect` | `options`, optional `noSelectionText` | Toggle chips |
| `integer`, `number` | `min`, `max`, optional `step` | Slider when both bounds are set, otherwise a validated number field |
| `string` | | Text field |

Every entry needs a `key`; `label` falls back to the key. `options` are strings
or `{ "value", "label" }` objects. The default is the entry's `defaultValue`,
else `barWidget.defaults[key]`. An entry with an unknown type or no options,
or whose saved value its control cannot show exactly (wrong type, an undeclared
option, a number out of range), is not drawn as a row. That key, and any saved
key the schema does not mention, stays in the dialog's raw JSON editor, so no
saved value is hidden. The schema is presentation only: the CLI and IPC still
accept any JSON value. Cybex's own `apiVersion` manifests can declare the same
`barWidget.schema`; their defaults come only from each entry's `defaultValue`.

Preferences apply at once. Package code refreshes within two seconds while
Settings is open and within five minutes otherwise; `cybex plugin update`
reloads at once, and `cybex plugin reload` requests an immediate scan through
the running shell. `cybex plugin restart` explicitly restarts the managed
`quickshell.service`.
Disable with `cybex plugin disable <id>`; files and preferences remain.
Deploy the updated Quickshell role before using this on an older desktop.

Manage packages in **Settings → Plugins**, or from the CLI:

```bash
cybex plugin update markbusking.pomodoro --preview
cybex plugin update markbusking.pomodoro
cybex plugin clone markbusking.pomodoro personal.pomodoro --edit
cybex plugin remove personal.pomodoro
# Import a built-in from a trusted checkout of the pinned upstream revision:
cybex plugin clone omarchy.spacer personal.spacer --from ~/Code/omarchy
```

Cloning copies settings, enables the new ID and disables an installed original.
Removing the clone restores the original's previous enablement and selected-bar
state. Removing any package preserves its preferences and persistent data.
Clones are editable copies without Git history; update their source explicitly.
Enabling a built-in import does not install its operating-system dependencies.

Hot reload uses snapshots under `$XDG_RUNTIME_DIR/cybex-plugin-code/`, keyed by
shell PID/start time and package fingerprint. Old snapshots remain for the
session so retained services can still read their original assets; later scans
remove dead sessions, and logout clears the runtime directory. Original package
paths and persistent data remain user-owned. Ordinary settings edits preserve
service/widget state. Package edits recreate UI and non-`keepLoaded` services;
plugins must persist state they need across those events. Editing a symlink's
external target is not watched; keep executable dependencies inside the package.

Placement supports `--section left|center|right`, `--width 24..320`, and
integer `--order`. Omarchy widgets default to their manifest's `defaultSection`
or center. Native API 1 widgets default to right. The native bar bounds each
section's plugin space and reports overflow instead of covering built-ins.

For a widget whose manifest declares `barWidget.allowMultiple: true`:

```bash
cybex plugin instance example.widget work --section left --width 100
cybex plugin instance example.widget personal --section right --width 100
cybex plugin set example.widget label '"Work"' --instance work
cybex plugin merge example.widget '{"label":"Personal"}' --instance personal
```

Named instances replace the implicit single instance and appear on each output.
They inherit plugin defaults/base preferences, with independent overrides.
Remove one with `cybex plugin instance example.widget personal --remove`.
Removing the last returns to the implicit single instance. These commands do
not enable a disabled plugin; enable it separately.

A plugin declaring a `bar` entrypoint can replace the native bar:

```bash
cybex plugin bar omarchy.bar --position top
cybex plugin bar omarchy.bar --position left
cybex plugin bar native
```

The selected replacement receives a catalogue and layout of enabled Omarchy
widgets. Native bars are retired while it is active. A construction failure
restores the native bar and exposes an error. Top, bottom, left and right are
supported by the tested upstream replacement; position is its configuration,
not a change to Cybex's native bar preference.

## Built-in Model Usage

The [Model Usage](https://github.com/DigitalPals/omarchy-modelusage) plugin
(`digitalpals.model-usage`) ships inside the shell as the built-in `modelusage`
widget: an unchanged copy in `ModelUsage/`, hosted by a native bar module
through this adapter's bar facade (see `ModelUsage/README.md`). It is placed,
enabled and configured in Settings → Bar like any built-in widget, and is
updated with CybexOS; `scripts/sync-model-usage` re-vendors a new upstream
commit.

An installed copy of the package is listed under Settings → Plugins with that
reason and is never loaded, so it cannot draw a second widget; `cybex plugin
enable` and `add` refuse it. Remove it with `cybex plugin remove
digitalpals.model-usage`. Its settings in `plugins.json` are not carried over,
but the scripts share their state and saved keys (`~/.local/state/omarchy/`,
`~/.config/omarchy/model-usage/`), so re-enter only the source and server
settings.

The first built-in usage widget, retired in settings schema 25, left a quota
cache (`~/.cache/quickshell/model-usage.json`) that deployment deletes. Proxy
management keys it saved under `~/.local/state/quickshell/model-usage-*.key`
are left in place; delete them yourself if you no longer need them.

## Host contract

| Area | Implemented behavior |
| --- | --- |
| Manifest | Schema 1, all six kinds and combinations; `entryPoints` must exactly match kinds (`bar-widget` maps to `barWidget`); every referenced QML file validated |
| Paths and identity | Directory matches ID; ASCII letters, digits, dots, underscores and hyphens; no `..`, absolute entrypoints, missing files or escaping entrypoint symlinks |
| Widget injection | `bar`, `moduleName`, `settings` supplied at creation; native API 1 remains unchanged |
| Other entrypoints | Optional `shell`, `manifest`, `pluginRegistry`, `barWidgetRegistry`, `omarchyPath`, `barConfig`, `settings`, `service` injected after construction, matching upstream |
| Services | One shared instance per enabled package; own-service lookup and clone alias; service retained across preference updates and shared across outputs; `keepLoaded` services also survive code reload |
| Panels, overlays, menus | Lazy creation, `open(payloadJson)`, `close()`, `summon`, `hide`, `toggle`, `isPluginOpen`, `call`; `keepLoaded` retains closed entries; otherwise hiding destroys them |
| Combined kinds | Service and widget can coexist with UI; lifecycle routing chooses panel, then overlay, then menu when several UI kinds are declared |
| Settings | Defaults plus persisted values; locked atomic merge writes; native-bar instances write their own overrides; unrelated fields preserved |
| Replacement bar | Component catalogue, metadata, layout, orientation, scoped UI controls and bar-config mutation; repeated widgets supported; omitted layout widgets hidden without stopping their services |
| Menus | Application listing, basic name/subtext search, icons and launch through Quickshell desktop entries; `appsChanged` notification |
| UI | All 35 QML components from the pinned upstream `Ui` directory, including forms, popups, sliders, media backgrounds and speed-test overlay |
| Theme | `qs.Commons` Style, Color, Util and Border APIs, with Cybex palette/font/rounding and upstream role names/helpers |
| IPC | `shell` target: `ping`, `summon`, `hide`, `toggle`, `call`, `listPlugins`, `rescanPlugins`, `setPluginEnabled`, `enablePlugin`, `putBarWidget`, `moveBarWidget`, `setBarWidget`, `togglePanelAt`, `reloadConfig`, `applyTheme`, `toggleBarTransparency`, `listShellConfig`, `debugBarGeometry`; plugin-defined targets remain available |
| Helpers | Bundled `omarchy-shell` forwards IPC to the already-running matching runtime; `omarchy-notification-send` uses desktop notification D-Bus |

`OMARCHY_PATH` points to the bundled compatibility directory and its `bin`
directory is on the shell's PATH. It is not a complete Omarchy checkout.
The IPC helper supports `-q`, timeouts, and default `{}` payloads for summon
and toggle; it never starts another shell. `listPlugins` reports Cybex's
plugin descriptors and runtime errors, not an identical upstream JSON schema.

Ordinary plugins receive their own registry/service/settings access. A full
bar also receives the installed widget catalogue and can control enabled
plugin UI. It receives service-less facades for hosted widget entries, as in
upstream's third-party replacement-bar contract. Manifest-supplied internal
flags cannot make an installed package first-party or grant host capabilities.
These API boundaries do not sandbox trusted QML.

A preference change preserves running widget/service state. Changing
layout, enablement, or code can recreate objects; plugins must persist state
needed across those events. Native-bar Omarchy popups coordinate ownership
with Cybex popouts. Lifecycle failures are reported without intentionally
restarting the entire shell.

Preferences and package data stay in the existing user-owned roots described
in [the widget architecture](architecture/user-widgets.md), outside release
replacement and rollback. Bar configuration, instance names, sections, and
settings are saved in `plugins.json`; there is no second `shell.json` store.

## Plugin appearance

Native widget panels and shared Omarchy popup outer backgrounds inherit the
menubar's color and opacity, including glass mode. Inner cards, controls and
menus retain their own palette roles for contrast. Plugins drawing custom
windows still own their styling.

On the native Cybex bar, shared Omarchy `KeyboardPanel` and `PopupCard`
components share the native panels’ six-logical-pixel gap from the visible
menubar edge and screen sides. They remain centred on their widget (or the bar when `centerOnBar`
is set), including with a bottom bar. This applies to Model Usage without
editing its package. Replacement bars retain their existing popup spacing;
plugins that create their own windows control their own placement.


Native surfaces and Omarchy plugins share the font, logical-pixel sizing,
accessibility scale, spacing density, border and corner settings described in
[Shell appearance](shell-appearance.md). Appearance settings apply individually;
there are no appearance presets.

The defaults use JetBrainsMono Nerd Font at 12px, standard spacing, no panel
border and 16px panel corners. At the default accessibility scale,
Model Usage's `Style.space(420)`
is 420 logical pixels (840 image pixels on a 200% output). Qt applies monitor
scaling; the shell never multiplies geometry by monitor scale itself.

Settings → Appearance → Plugins provides an additional interface scale (75–200%). Border mode
**Shell** inherits the shared border; Accent/Subtle/Custom use the plugin width
and opacity overrides. Corner value -1 follows the shared panel corners; 0 is
square. Existing explicit plugin overrides are preserved until changed or reset. Scaling affects shared Omarchy UI, including bar widgets.

Advanced users can set `pluginThemeOverrides` in
`~/.config/cybexos/shell.json`, using flat Omarchy shell tokens:

```json
{
  "pluginThemeOverrides": {
    "popups.border": "#9ecbeb #a992e0 45deg",
    "popups.border-width": "2 1 2 1",
    "font.base-size": 14,
    "spacing.scale": 1.1
  }
}
```

Precedence: shared shell settings, plugin appearance overrides, explicit session
`applyTheme` imports, then persistent advanced tokens. Resetting Plugins clears
advanced tokens. An empty `applyTheme` palette/shell clears session imports and
restores live inheritance. `shell debugPluginTheme` reports effective native
and plugin sizing/borders. Omarchy theme files are not watched. Plugin-owned
hardcoded styles (such as Model Usage's inner usage-card borders) remain under
that plugin's control. Native critical-notification and keyboard-focus borders
retain their status indications.

## Remaining limits

- No automatic emulation of Arch packages, Omarchy's general command suite,
  Hyprland scripts, system paths, or external backends. Plugins depending on
  those still need their dependencies installed or a Fedora-specific adapter.
- Authentication, lock-screen/polkit services, and privileged first-party
  host capabilities are not supplied. Cross-plugin private service lookup is
  unavailable; full bars receive only the four narrow service adapters. The compatibility theme's lock/polkit colors do not implement
  those systems.
- A replacement bar cannot render native Cybex API 1 widgets. Hosted widget
  facades do not expose service objects: a widget relying on direct service
  access can work in the native bar yet need adaptation in a third-party
  replacement. This includes the tested Media widget, whose native-bar
  service access is verified; playback inside a replacement is not claimed.
- Replacement `updateEntryInline` writes plugin-level preferences. Independent
  named overrides are writable through the native bar, CLI, or full layout
  mutation; replacement facades are not keyed by instance. Full `shell.json`
  mutation is unavailable; only bar presentation/layout is persisted.
- No remote marketplace catalogue. Generated settings rows cover only the
  `barWidget.schema` types listed under Declared settings.
  `applyTheme` updates the Omarchy compatibility palette/style for the session,
  not Cybex's persisted theme. `reloadConfig` refreshes plugin preferences;
  Cybex shell settings retain their existing file watcher.
- IPC mutations return acceptance before the serialized helper writes finish;
  check plugin diagnostics for persistence errors. Layout validation is stricter
  than upstream (for example, out-of-range indices are rejected, not clamped).
  Native-bar transparency/geometry is not exposed through the Omarchy adapter.
- Built-in clones that have no installed source cannot restore an absent
  Omarchy package on removal. This host does not import Omarchy's whole built-in
  catalogue or replace native Cybex widgets by matching their names.
- The media adapter supports player selection and basic transport; it does not
  reproduce Omarchy's feedback overlays or player-launch policy.
- Application removal explicitly returns false. The menu application bridge
  does not reproduce Omarchy's launch feedback, icon-index refresh, hidden-app
  configuration or fuzzy ranking.
- Third-party fonts, audio files, commands and network daemons remain package
  dependencies. Pomodoro sound needs `pw-play` and its sound files; use
  `sound false` when absent. QtMultimedia is installed for the shared video UI.
- Mihoro's network backend and arbitrary marketplace packages have not been
  qualified. The fixture results must not be generalized to every plugin.

The [vendored source notes](../roles/desktop/files/quickshell/compat/omarchy/README.md)
describe upstream provenance and modifications. MIT notices accompany the
runtime components and immutable test fixtures.

## Verification

`tests/user-plugins.py` uses disposable user roots and the actual Quickshell
engine under a private headless Sway compositor with **two outputs**. It checks:

- unchanged Pomodoro manifest/QML at commit
  `54dec957244d7090bc1c46be7244f8a60a7f4866`, popup mapping/focus and timer state;
- unchanged Omarchy Spacer QML, and unchanged Media/Bar packages at the pinned
  Omarchy commit (Media service loads; actual player/audio playback is untested);
- native API 1 behavior through runtime replacement and rollback;
- all six entrypoint kinds, shared service lifetime, own-service scope,
  manifest flag sanitization, payload delivery, lazy unload and keepLoaded;
- independent instance settings/writes, layout roundtrips, invalid mutation
  rejection, defaults and concurrent preference writes;
- the replacement bar's widget catalogue, vertical placement, restoration of
  native bars after replacement failure, and cleanup on disable;
- the bundled IPC helper against the running test shell, plus QML error checks.

Sway is a test dependency, not a desktop runtime dependency. Tests defer
engine checks if another `qs` is active. Task-owned engines, compositors,
sockets and user roots are cleaned up. Static QML lint covers the whole shared
UI kit; not every form control, media backend or gesture has runtime coverage.

Validation runs in Fedora 44 containers on a Debian build server, which has no managed
Quickshell desktop service. No persistent user plugins are installed by the
tests. A physical Hyprland session, real audio/notifications, and pointer/grab
behavior still need live qualification under the repository's sole-PID and
journal checks. Headless validation does not establish universal or future
version compatibility.

The earlier runtime implementation passed all 16 `tests/run` source stages, including 738 JavaScript tests and
242 QML files (no lint errors; six nonfatal upstream warnings). The final
active-bar geometry change was rechecked with QML lint and the complete
real-engine plugin suite. The container and downloaded upstream sources used
for this validation were disposable; no persistent desktop deployment was made.

Implementation verification adds `tests/plugin-packages.py` for Git installation,
preview, valid/invalid updates, dirty-checkout protection, clone restoration,
built-in imports, removal retention and snapshot identity. The Quickshell suite
also loads the Plugins settings page, exercises added IPC calls and first-party
adapter scope, and edits a relative JS import while both outputs are running to
verify UI reload and retained service identity/state. QML lint covers the new UI.
Physical audio/idle/nightlight behavior is not qualified by the headless fixture.

For this management/reload change, validation passed with 736 JavaScript tests
(two host Qt-enum skips), all 244 QML files linted, the extended two-output engine
suite, package transaction tests, both deployment fixtures, Ruff and ShellCheck.
The full 16-stage source gate was not repeated. No persistent desktop deployment
was possible on the Debian build server, which has no installed Quickshell.
