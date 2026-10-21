# Desktop workspace controls

Open **Settings → Workspaces** to choose **Shared** or **Per-monitor** numbering,
the default layout, and a layout for an individual workspace. Existing and new
installations start in Shared mode. Without a saved managed layout choice, the
compositor preserves the native `general.layout` from the user's configuration
(normally dwindle). Changing layout never
enables the dock or changes its pins or auto-hide preference.

In Per-monitor mode the compositor supplies each display's local numbers 1–10.
Each bar marks the workspace visible on its own display, including displays
without keyboard focus. Numbered/dot style, minimum visible slots and hide-empty
remain the existing bar preferences. Occupied and current workspaces stay
visible. A disconnected display's reachable visiting workspaces use the
compositor's explicit labels, including their old connector where needed. The
UI does not infer monitor identity or calculate IDs from arithmetic blocks.

The layout symbol next to each bar's workspace strip shows Tiled, Scrolling or
Floating, or Custom with the native layout name (for example, master). Click it
to cycle that display's active numbered workspace. Scrolling appears
in the settings choices only when the compositor reports native support. A
missing decoration component is shown explicitly; the titlebar switch saves the
preference but does not claim an unavailable plugin can draw titlebars.
The default layout readout says **Unmanaged (master)** when the user's native
layout remains authoritative. Choosing or resetting the default deliberately
enables compositor management; simply opening Settings never changes it.
An individual workspace's **Default** option and reset clear its saved override
with `set_layout(id, "default")`, including when the default is unmanaged.
The action value `default` is never a saved layout preference.
An explicit layout choice remains owned by that workspace even when it equals
the global default. For example, choosing Tiled while the default is Tiled
keeps that workspace Tiled after changing the default to Floating. The picker
continues to show Tiled and offers reset; only Default clears the override.

## Window and keyboard controls

| Control | Action |
| --- | --- |
| Super+1…0 | Focus workspace 1–10, local to the focused display in Per-monitor mode |
| Super+Shift+1…0 | Move the focused window using the same mapping |
| Super+Ctrl+Shift+arrow | Move the focused window to another display |
| Super+Ctrl+L | Cycle workspace layout; Super+L continues to lock |
| Super+Ctrl+Alt+M | Minimize the focused window; Super+M continues to open Slack |
| Super+Ctrl+M | Restore a minimized window |
| Super+Tab | Open/close the overview |
| Overview arrows / Tab | Select a window |
| Overview Page Up / Page Down | Select a workspace, including the New workspace tile |
| Overview Enter | Restore/focus the selected window or focus the selected workspace |
| Overview Ctrl+N / Ctrl+L | New workspace / cycle the selected workspace layout |
| Overview Ctrl+M / Ctrl+Enter / Ctrl+W | Minimize / maximize or restore size / gracefully close the selected window |
| Overview drag | Move a window to the destination tile; New workspace allocates through the compositor |

The overview includes minimized windows on their original workspace, with an
icon and a Minimized label instead of a live capture. Typing filters them like
other windows. The launcher Windows provider also labels minimized windows and
their monitor/workspace, and restores them before focus. Scratchpads and other
special workspaces keep their existing behavior. Named regular workspaces remain
in the overview and use the validated native named-workspace dispatcher. This
also covers `renameworkspace 1 research`, which retains a positive ID: native
name and numbered/named kind survive tile serialization, selection and drops.
Live workspace/window metadata takes priority over a stale numbered snapshot,
and works before the initial snapshot exists. Names are escaped as Lua data;
special workspaces and control characters remain rejected. Named-workspace
windows remain reachable through the launcher and dock; numbered-layout and
minimize controls are unavailable for them, matching the compositor API.

The optional dock restores minimized windows on click or through **Restore
window** in its menu. Clicking a focused app with exactly one window minimizes
it; apps with multiple windows retain cycling. Its menu also provides minimize.
Configure it through **Settings → Bar → Dock**, linked from the workspace page.
With the dock off, global minimize/restore shortcuts and the overview/launcher
remain available. If native titlebars are unavailable, Super+mouse drag/resize
and the overview's maximize, minimize and close controls remain usable.

The compositor's personal choices live only in
`$XDG_CONFIG_HOME/cybexos/workspaces.json` (normally
`~/.config/cybexos/workspaces.json`). Shell restarts read them through the runtime
snapshot and never push startup defaults. Assignment persistence, monitor
identity ambiguity, reconnect behavior and mode-owned floating state are
documented in [the compositor contract](desktop-workspace-architecture.md).

## Integration contract

- Register `singleton DesktopWorkspaces DesktopWorkspaces.qml` in
  `Common/qmldir` (lead has done this) and initialize it from `shell.qml`, so its one snapshot reader
  exists even when the dock and workspace bar module are off. No startup
  commands or preference mirroring are performed.
- Register `Settings/WorkspacesPage.qml` as the `workspaces` settings page and
  searchable rows for `workspaceMode`, `workspaceDefaultLayout`, `floatingTitlebars`.
  `sectionKeys.workspaces` is empty: those choices belong exclusively to the
  compositor's user-owned `~/.config/cybexos/workspaces.json`, not shell.json.
  Custom rows intentionally have no shell `settingKey`; search opens this page
  without treating these values as shell preferences. Individual rows provide
  custom reset actions. Dock controls have one owner, the Bar page.
- The page reads the runtime snapshot and sends deliberate setter calls only
  after `Settings.loaded`. Missing/invalid snapshots disable compositor-only
  controls and retain existing shared navigation. A shell restart never sends
  default values back to the compositor.
- Snapshot v1 uses monitor `workspaces` integer-ID arrays, workspace `guest`
  and `ownerIdentity` fields, `capabilities.scrolling/titlebars` booleans, an
  `error` string, and `titlebarsEnabled` for the saved titlebar choice. Guest
  `localNumber:0` is preserved. Only the compositor allocates new IDs.
- Optional v1 `defaultLayoutManaged`/`nativeDefaultLayout` and workspace
  `layoutManaged`/`nativeLayout` fields preserve native custom layout readouts.
  Earlier v1 snapshots without ownership flags retain managed behavior.
  `layout: "unmanaged"` and unknown custom layouts never become Tiled in the UI.
  Snapshot rows carry an explicit numbered kind in presentation; live named
  workspaces are not decorated or dispatched as those cached rows.
- Workspace `layoutOverride:boolean` is the authoritative inheritance bit.
  The picker and its reset state use it independently of `layoutManaged` and
  equality with the global default. `layoutManaged` describes layout support/
  management, not inheritance. For older v1 snapshots missing `layoutOverride`,
  the parser retains the previous heuristic: unmanaged rows and rows equal to
  a managed default display Default; other managed rows display their layout.
  That compatibility path cannot reconstruct a same-layout explicit choice
  absent from the older snapshot. No UI setter is sent to repair or guess it.
- The UI also touches the dedicated `Common/Dock.qml` model, in addition to
  DockWindow.qml, to route all dock activation through restore-before-focus.
- Public module calls execute with argv `["hyprctl", "eval", expression]`, in
  one bounded queue, with a live-address recheck immediately before execution.
  Success requires normal exit, status zero, and exactly `ok` on stdout:
  hyprctl may otherwise return a Lua error while exiting zero. Errors remain
  visible in the workspace settings page. A five-second operation deadline and
  missing-binary handling release the queue. Native fallback dispatcher objects
  continue through `Hyprland.dispatch`. No shell interpolation is used.
- New-workspace drag uses one eval expression: the module's returned ID is
  passed directly to `move_id`. Creating a new workspace selects it through the
  module; dropping on an existing tile remains a silent move.

## Provenance

Reviewed Omarchy `v4.5.0-rc1`, exact revision
`03ff1eff3812933f7088484533784d2f63eaf19a`: its
`shell/plugins/bar/widgets/Workspaces.qml`, `default/hypr/workspace-modes.lua`,
`default/hypr/workspace-layouts.lua`, and
`bin/omarchy-hyprland-workspace-layout-toggle`, with relevant tests
`test/shell.d/hyprland-monitor-workspaces-test.sh`,
`hyprland-floating-workspaces-test.sh`, `hyprland-workspace-layout-test.sh`,
`workspace-layout-mode-migration-test.sh`, and the monitor-overlay acceptance
fixture. Upstream's MIT license (David Heinemeier Hansson) was read. The UI
implementation here is original CybexOS code built on its existing bar, dock,
overview, settings, theme and validated command helpers. It adopts the ideas of
per-display active state, visible layout control and mode-aware activation;
it does not copy upstream's connector/block mapping, layout subprocess/cache,
shell execution or substantial source. No later moving-branch fix was imported.

## UI validation

Tested against the local diff based on
`3b310d106255558ca213c955ef37ee314e8681f2`; no UI-agent commit was made in the
shared checkout. The integrated final revision and release gates are the lead's
responsibility.

- **Passed:** 105 Node tests across desktop-workspaces, window-commands,
  workspaces, overview-helpers, desktop-navigation, launcher-providers,
  dock-helpers and tabler-icons. These exercise arbitrary non-block IDs,
  monitor-specific state, connector changes, guests, missing/corrupt snapshots,
  minimized-window inclusion/activation, stale addresses, eval error responses,
  capability gating, startup preference guards, commands and existing controls.
  Review regressions additionally exercise positive-ID named tile selection
  and drops, missing/stale snapshots, named launcher/dock activation, closed
  native windows, safe quoted names, unmanaged/custom layout fields, older v1
  compatibility, Default override clearing, and focused dock minimization.
  The R2 explicit-override follow-up was tested on the uncommitted diff based
  on `66b14a22dcc691851ed5ba87c57d88c7f98df8ef`: an explicit Tiled choice equal
  to the default remains selected after a global Floating change, Default
  clears ownership, and older snapshots retain their previous heuristic.
- **Passed:** `git diff --check` for the working tree at the UI handoff.
- **Blocked on host prerequisites:** `python3 -B tests/installation-parity.py`
  ran 21 tests and reported 24 fixture errors from missing `ansible-playbook`;
  `PYTHONPATH=image python3 -B -m unittest image.test_installation_parity
  image.test_user_parity` ran 34 tests and reported 9 errors from missing Ansible
  and the GNOME SMB schema. These runs do not pass parity. The lead's Fedora
  environment must run both gates after integration.
- **Pending integration/runtime:** QML lint/loading and real compositor
  multi-monitor, scaling/rotation, lid/mirror, minimize geometry, fullscreen,
  groups, native scrolling and decoration qualification. The UI agent did not
  alter the active desktop or create host containers/VMs. Node fixtures are not
  runtime or installation qualification. Temporary UI test logs are removed
  after this report; no UI-agent build artifacts are retained.

## Dutch strings for lead integration

Add these missing catalog entries through the existing catalog workflow:
The earlier handoff strings below have been integrated by the lead. The review
follow-up adds only `Custom (%1)` and `Unmanaged (%1)`; `Default` already exists.

```json
{
  "Custom (%1)": "Aangepast (%1)",
  "Unmanaged (%1)": "Onbeheerd (%1)",
  "Configure dock": "Dock instellen",
  "Cycle workspace layout": "Werkbladindeling wisselen",
  "Default workspace layout": "Standaardindeling voor werkbladen",
  "Display": "Beeldscherm",
  "Enter to restore or switch · drag to move · Page Up/Down for workspaces": "Enter om te herstellen of wisselen · sleep om te verplaatsen · Page Up/Down voor werkbladen",
  "Floating titlebars": "Titelbalken voor zwevende vensters",
  "Floating windows": "Zwevende vensters",
  "Maximize / restore": "Maximaliseren / herstellen",
  "Minimize": "Minimaliseren",
  "Minimized": "Geminimaliseerd",
  "Native titlebars are unavailable. Use Super-drag and the overview controls.": "Native titelbalken zijn niet beschikbaar. Sleep met Super en gebruik de knoppen in het overzicht.",
  "Native titlebars for windows that need them": "Native titelbalken voor vensters die ze nodig hebben",
  "New workspace": "Nieuw werkblad",
  "Open the overview with Super+Tab. Enter restores a window; Ctrl+M minimizes; Ctrl+L cycles layouts; Page Up/Down selects workspaces.": "Open het overzicht met Super+Tab. Enter herstelt een venster; Ctrl+M minimaliseert; Ctrl+L wisselt de indeling; Page Up/Down selecteert werkbladen.",
  "Per-monitor": "Per beeldscherm",
  "Restore window": "Venster herstellen",
  "Scrolling": "Schuivend",
  "Scrolling is unavailable in this compositor build": "Schuivende werkbladen zijn niet beschikbaar in deze compositorversie",
  "Select a workspace": "Selecteer een werkblad",
  "Shared": "Gedeeld",
  "Shared keeps global numbers. Per-monitor gives each display its own 1–10.": "Gedeeld gebruikt globale nummers. Per beeldscherm geeft elk beeldscherm eigen nummers van 1 tot 10.",
  "The bar layout button cycles the layout of its own display": "De indelingsknop in de balk wisselt de indeling van het eigen beeldscherm",
  "The dock is optional in every layout. Minimized windows remain in the overview and launcher.": "Het dock is optioneel bij elke indeling. Geminimaliseerde vensters blijven in het overzicht en de starter staan.",
  "Tiled": "Getegeld",
  "Used by workspaces without their own layout choice": "Voor werkbladen zonder eigen indelingskeuze",
  "Visiting workspace": "Werkblad van een ander beeldscherm",
  "Workspace": "Werkblad",
  "Workspace command failed": "Werkbladopdracht mislukt",
  "Workspace controls are waiting for the compositor": "Werkbladinstellingen wachten op de compositor",
  "Workspace layout": "Werkbladindeling",
  "Workspace mode": "Werkbladmodus"
}
```
