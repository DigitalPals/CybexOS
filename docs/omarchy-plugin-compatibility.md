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

## Install and configure

Put a complete plugin checkout in
`~/.local/share/fedora-config/plugins/<manifest-id>/`. The directory must match
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

Preferences refresh within two seconds. Use `cybex plugin reload` after
changing plugin **code**; this restarts the managed `quickshell.service`.
Disable with `cybex plugin disable <id>`; files and preferences remain.
Deploy the updated Quickshell role before using this on an older desktop.

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

## Host contract

| Area | Implemented behavior |
| --- | --- |
| Manifest | Schema 1, all six kinds and combinations; `entryPoints` must exactly match kinds (`bar-widget` maps to `barWidget`); every referenced QML file validated |
| Paths and identity | Directory matches ID; ASCII letters, digits, dots, underscores and hyphens; no `..`, absolute entrypoints, missing files or escaping entrypoint symlinks |
| Widget injection | `bar`, `moduleName`, `settings` supplied at creation; native API 1 remains unchanged |
| Other entrypoints | Optional `shell`, `manifest`, `pluginRegistry`, `barWidgetRegistry`, `omarchyPath`, `barConfig`, `settings`, `service` injected after construction, matching upstream |
| Services | One shared instance per enabled package; own-service lookup and own clone alias; service retained across ordinary preference updates and shared across outputs |
| Panels, overlays, menus | Lazy creation, `open(payloadJson)`, `close()`, `summon`, `hide`, `toggle`, `isPluginOpen`, `call`; `keepLoaded` retains closed entries; otherwise hiding destroys them |
| Combined kinds | Service and widget can coexist with UI; lifecycle routing chooses panel, then overlay, then menu when several UI kinds are declared |
| Settings | Defaults plus persisted values; locked atomic merge writes; native-bar instances write their own overrides; unrelated fields preserved |
| Replacement bar | Component catalogue, metadata, layout, orientation, scoped UI controls and bar-config mutation; repeated widgets supported; omitted layout widgets hidden without stopping their services |
| Menus | Application listing, basic name/subtext search, icons and launch through Quickshell desktop entries; `appsChanged` notification |
| UI | All 35 QML components from the pinned upstream `Ui` directory, including forms, popups, sliders, media backgrounds and speed-test overlay |
| Theme | `qs.Commons` Style, Color, Util and Border APIs, with Cybex palette/font/rounding and upstream role names/helpers |
| IPC | `shell` target: `ping`, `summon`, `hide`, `toggle`, `call`, `listPlugins`, `rescanPlugins`, `setPluginEnabled`; plugin-defined targets remain available |
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

Normal preference polling preserves running widget/service state. Changing
layout, enablement, or code can recreate objects; plugins must persist state
needed across those events. Native-bar Omarchy popups coordinate ownership
with Cybex popouts. Lifecycle failures are reported without intentionally
restarting the entire shell.

Preferences and package data stay in the existing user-owned roots described
in [the widget architecture](architecture/user-widgets.md), outside release
replacement and rollback. Bar configuration, instance names, sections, and
settings are saved in `plugins.json`; there is no second `shell.json` store.

## Remaining limits

- No automatic emulation of Arch packages, Omarchy's general command suite,
  Hyprland scripts, system paths, or external backends. Plugins depending on
  those still need their dependencies installed or a Fedora-specific adapter.
- Authentication, lock-screen/polkit services, and privileged first-party
  host capabilities are not supplied. Cross-plugin private service lookup is
  unavailable. The compatibility theme's lock/polkit colors do not implement
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
- No marketplace install/update UI, manifest-generated settings editor,
  live plugin-code watcher, or complete Omarchy shell IPC command surface.
  Use the CLI for settings and a managed restart for code reloads.
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

Validation runs in Fedora 44 on Debian `thebeast`, which has no managed
Quickshell desktop service. No persistent user plugins are installed by the
tests. A physical Hyprland session, real audio/notifications, and pointer/grab
behavior still need live qualification under the repository's sole-PID and
journal checks. Headless validation does not establish universal or future
version compatibility.

All 16 `tests/run` source stages passed, including 738 JavaScript tests and
242 QML files (no lint errors; six nonfatal upstream warnings). The final
active-bar geometry change was rechecked with QML lint and the complete
real-engine plugin suite. The container and downloaded upstream sources used
for this validation were disposable; no persistent desktop deployment was made.
