# Workspace compositor contract

Contract in tested product revision
`d2037af92cb3a47a08a9755e5996d2c4b0cae28d`; source/image gates, the exact-source
ISO/RPM build and testing PXE publication pass. All four ISO scenarios, both
English/Dutch checkout parity cases, pristine offline/native/recovery and scoped
native workspace/notification checks pass. The product is **not fully
qualified**: startup measurement is blocked; first-frame, hardware and generic CSD
limits remain open in [desktop validation](desktop-validation.md).
This documentation update is separate from the tested installed-product artifacts.
Main integration is complete at `bee9d722021301875823e6285a6eef2896b283eb`;
the intervening CI-only fix 9974aaee changes no installed-product payload.
Artifact qualification remains bound to d2037af.

The compositor's `require("workspaces")` is the sole owner of identity,
numbering, layouts, minimize and persistence. Shared remains the first-install
mode; the managed base configuration uses dwindle. Without a personal workspace
default, explicit user.lua native layout choices remain authoritative. Enabling
per-monitor mode or taking ownership of the default layout is a deliberate choice.
The module never renumbers or merges live workspaces. A persisted assignment is
an ordered list of ten globally unique IDs, rather than an arithmetic block.
It adopts unowned workspaces already on that output, then allocates unused IDs.
This preserves existing windows/layouts and avoids destructive ID collisions.
A disconnected owner's workspaces remain reachable as guests after the ten
local slots on the surviving output; reconnect moves the whole workspace home.
A full local list never makes guest windows inaccessible.

## API (schema v1)

`$XDG_RUNTIME_DIR/cybexos/workspaces.json` is atomically replaced on relevant
compositor events. Arrays are JSON arrays (including when empty):

- `v:1`, `mode:"shared"|"per-monitor"`,
  `defaultLayout:"dwindle"|"scrolling"|"floating"|"unmanaged"`,
  `defaultLayoutManaged:boolean`, `nativeDefaultLayout:string`,
  `titlebarsEnabled:boolean`, `capabilities:{scrolling:boolean,titlebars:boolean}`,
  `error:string` (empty on success).
  `capabilities.titlebars` describes native availability, independently of the
  titlebarsEnabled preference or whether any workspace uses Floating. It stays
  true for a loaded, successfully configured component while its bars are hidden.
- `monitors:[{name,identity,label,activeWorkspace,workspaces:[integer IDs]}]`.
  Only independent enabled outputs occur here; mirrors own no workspaces.
- `workspaces:[{id,localNumber,monitor,label,layout,layoutManaged,layoutOverride,nativeLayout,guest,ownerIdentity}]`.
  `monitor` is the current reachable output, `ownerIdentity` the persisted
  physical owner (empty for an unowned guest). `localNumber` is 1–10 for a local
  slot; guest rows use 0 and an unambiguous label. In Shared mode regular global
  IDs remain labels/numbers. Empty local slots are included. Each row occurs
  once. Special/named workspaces are never allocated or rearranged.
  `layout` uses the defaultLayout enum. `layoutManaged` is true only for an
  explicit workspace override or a managed default. Otherwise native
  `workspace.tiled_layout` and `general.layout` remain authoritative. Custom
  native layouts such as master report `layout:"unmanaged",nativeLayout:"master"`;
  never normalize this to Tiled. Native strings are bounded to 64 safe token
  characters. Floating reports its underlying native layout as dwindle.
  `layoutOverride:boolean` separately reports a recorded explicit per-workspace
  choice. It remains true even when that choice equals the default. An inherited
  managed default has `layoutManaged:true,layoutOverride:false`; an inherited
  native layout has both false. UI inheritance/reset state must use
  layoutOverride, never effective-layout equality. New snapshots always include
  the flag; parsers must tolerate its absence in older v1 snapshots and retain
  their legacy behavior until receiving the updated compositor snapshot.
- `minimized:[{address,workspace,monitor}]`: original regular workspace and
  last known monitor. Windows live in `special:cybexos-minimized` until restore.
  The compositor validates the live window before acting; UI cached rows confer
  no authority to act on a nonexistent or recycled address.

Public functions called through `hyprctl eval`:
`focus(localNumber, monitorName)`, `move(address, localNumber, monitorName)`,
`focus_id(id)`, `move_id(address,id)`, `next(direction,monitorName)`,
`new_workspace(monitorName)`, `set_mode(mode)`, `set_default_layout(layout)`,
`set_layout(id,layout)`, `cycle_layout(id)`, `set_titlebars_enabled(boolean)`,
`minimize(address)`, `restore(address)`, `activate(address)`,
`move_monitor(direction,address)`. Optional address/monitor select current focus;
optional layout ID selects the focused regular workspace. `next` accepts -1/1;
`move_monitor` accepts left/right/up/down/next/previous. Invalid/stale targets
raise errors before dispatch. `activate` restores minimized windows first.
`focus_id` permits a currently live regular workspace or a persisted local slot;
`move_id` validates both destination and current live window. Window addresses
must match `0x` plus 1–16 hexadecimal digits. Success returns nil; new_workspace
returns the selected ID. Callers must check process exit status.
`set_layout(id,"default")` removes a workspace override and restores inheritance;
"default" is an API action, never a persisted layout value. Cycling an unmanaged
custom layout starts at dwindle. `set_default_layout` always deliberately takes
ownership, even when selecting the same displayed layout.

## Personal choices and lifecycle

`$XDG_CONFIG_HOME/cybexos/workspaces.json` is authoritative personal data:
`{v:1,mode,defaultLayout,manageDefaultLayout,titlebarsEnabled,layouts:{"ID":"layout"}}`.
No preference file means `manageDefaultLayout:false`; the module does not write
`general.layout`, create a preference file, or claim existing native layout rules.
Mode, titlebar and workspace-only edits preserve this false flag, including
across reloads. The stored defaultLayout is a managed enum placeholder until
`set_default_layout` deliberately sets manageDefaultLayout true. Existing v1
files without the flag retain their previous managed-default semantics.
Every deliberate per-workspace choice is saved, including choices equal to the
current default. Default edits preserve all these overrides and affect only
inheriting workspaces. Only `set_layout(id,"default")` removes an override.
Existing sparse preference maps retain every recorded entry; choices discarded
by an older implementation cannot be reconstructed, and missing entries keep
their inherited semantics. No migration invents missing personal choices.
Settings reads this compositor snapshot and sends setters only for deliberate
edits. workspaceMode/workspaceDefaultLayout/floatingTitlebars are not persisted
in shell.json; there is no second preference owner or startup push of defaults.
The custom Workspaces settings page can use `Settings.sectionKeys.workspaces=[]`.
Display custom values as “Custom (master)” / “Aangepast (master)”, or equivalent;
the unmanaged value is informational, never a setter argument. The reset action
must send `set_layout(id,"default")`, rather than the displayed default enum.
An absent native layout query falls back to dwindle for reporting only.
No installer writes personal choices into managed runtime trees.

`$XDG_STATE_HOME/cybexos/workspace-assignments.json` retains physical assignments
across compositor sessions. A bounded session file in the runtime directory
retains minimize metadata across Lua reloads, scoped by HYPRLAND_INSTANCE_SIGNATURE.
The module also retains live floating ownership on window tags, which survive
config reloads. A shell restart needs only reread the snapshot. A compositor
restart preserves choices/assignments, but cannot restore windows that exited.
Old event subscriptions/timers/rules are retired on Lua reload.

All input is strict bounded JSON parsed using the existing displays.lua reader;
no personal file is executed as Lua. Writes use private directories and atomic
replacement. Invalid files are ignored as a whole and reported in snapshot
error; setters refuse to overwrite a corrupt personal file. Native titlebar
availability is reported independently of the user's enabled preference.

## Integration and qualification

Deploy `workspaces.lua` and every `workspace_*.lua` companion alongside the
other compositor modules on both install paths. Load after monitors/displays,
looknfeel and user.lua. The XPS Shared policy exposes a mode switch to the
authoritative owner; it is disabled only while Per-monitor is selected.
Opening ownership runs synchronously on `window.open`, bound to the qualified
compositor's `openLate` event after native floating rules and grouping. It reads
the actual workspace name and native floating state before mapping returns.
Numeric `r[]` and `n[false]` selectors both include renamed positive-ID
workspaces, so no numeric opening window rule is installed. The shared
float-exclusion collector is no longer consumed or modified by this module;
native rules have already established independent floaters before the event.

Native scrolling and optional decoration provenance, shortcuts, behavioral
evidence and remaining gates are recorded below and in desktop-validation.md.
Fixtures are source tests, not compositor or ISO qualification.

## Identity, collisions and transitions

The qualified HLMonitor exposes a short make/model description and a separate
serial, not separate manufacturer/model fields. Their length-prefixed values
form the physical fingerprint. Placeholder serials (`0`, all zeroes, `unknown`,
`none`, `null`) count as missing. A serial with no description remains stable
across connectors. With neither description nor serial the connector is the
only available identity. Internal panels are considered before externals;
connector order breaks ties, never Hyprland's recycled numeric monitor ID.

A connected monitor retains its existing fingerprint/identity binding. Saved
connector matches come next; remaining matching identities are assigned in
stable order. Duplicate or absent serials can distinguish attached survivors,
but two indistinguishable panels whose connectors both change cannot be
physically distinguished; stable connector order is the documented fallback.
No claim of perfect physical tracking is made for that ambiguous case.

Assignments own ten explicit IDs. Both live occupied IDs (including positive
IDs renamed into named workspaces) and every offline assignment are reserved.
New owners adopt unowned regular workspaces on their own output, then fill with
unused IDs. A renamed slot receives a new empty slot; the named workspace is
left intact. All ten occupied slots make `new_workspace` report capacity;
existing guest windows are still listed and reachable. Assignments are bounded
to 64 monitor identities, 640 slots; preferences to 1024 layout exceptions;
minimize to 256 windows; every data file to 256 KiB. Exceeding a bound reports an
error instead of stealing an ID or dropping live windows.

Shared ↔ Per-monitor transitions do not renumber or merge workspaces, move
individual windows, alter window groups, or reset layouts. Shared keeps global
numbered shortcuts and the existing XPS rule owner. Per-monitor disables that
owner, installs one set of monitor rules, and reclaims whole owned workspaces
using workspace.move rather than the focus dispatcher's visible-workspace
swap behavior. Offline owners become guests without losing their IDs or layout
choices. Reconnection reclaims those IDs and restores unrelated visible
workspaces. Mirror outputs never acquire assignments. Lid close/open is the
same disabled-output/reconnect contract. Physical scaling, rotation and reserved
bar/dock areas are read when restoring normalized floating geometry.

The vendor three-finger horizontal swipe is replaced with an event-driven local
list gesture while Per-monitor is selected and restored in Shared. Existing
Touchpad opt-outs and user.lua gesture overrides take precedence. Special and
named workspaces keep their existing bindings/behavior. Floating windows get
mode-owned tags only when the mode actually floats them, or a legacy opening
tag proves ownership. Pre-existing floaters and native app/dialog rules keep
their ownership. A new member of a mode-owned floating group inherits that
ownership before the original member can close. All
members are claimed before any grouped window floats. Fullscreen and pinned
windows retain their state; reconciliation runs again when they leave it.
Explicit Super+F floating choices release mode ownership for every member of
the selected window's group before the compositor toggles that group once. New
members inherit the existing group's manual choice before arrangement, so
opening a grouped client cannot reverse manual tiling or floating through reload.
Group provenance also follows new members while named or special, so renaming
back or closing the original owner cannot discard that choice; it does not
change the native floating state on those destinations.
That manual tag takes precedence over a legacy opening-rule tag, including its
dynamic `*` form, so newly opened Floating windows remain tiled after Super+F
through subsequent events and configuration reloads.

Renamed/named/special workspaces retain their native floating state and never
gain Floating-workspace decorations. Existing origin ownership stays with a
window for a later return to a numbered destination. A saved numbered layout
override suspends while its ID has a user name and resumes when numbered again;
renaming never deletes the saved choice. Previously unowned floating windows
are preserved because they cannot be distinguished safely from deliberate user
floaters.

Minimize records every group member and uses a hidden special workspace with a
window-local origin tag. PID, live mapped address, tag and compositor-session
signature guard stale metadata. `activate` restores before focus. Restoring a
floating window rescales normalized geometry into the current usable rectangle
and clamps the whole frame; fullscreen internal/client state is retained.
Super+Ctrl+M restores a minimized window even with the dock disabled. The
runtime session file is not loaded into another compositor session, and tags
die with their windows, so recycled addresses do not inherit hidden state.

## Shortcuts and titlebars

- Super+1…0 and Super+Shift+1…0: focused monitor's local slot / move window.
- Super+mouse wheel and the vendor horizontal swipe: monitor-local navigation.
- Super+Ctrl+L: cycle workspace layout. Super+L remains screen lock.
- Super+Ctrl+Alt+M: minimize. Super+M remains the Slack web app.
- Super+Ctrl+M: restore a minimized window, including when the dock is disabled.
- Super+Ctrl+Shift+arrows: separate display move, retaining useful geometry.
- Existing Super+left mouse drag, Super+right mouse resize, Super+Q close and
  Super+F floating continue to provide controls if native titlebars are absent.

Optional native titlebars are declared on every compositor config parse when installed,
and render only for Floating layouts. The fixed path is
`/usr/lib64/cybexos/titlebars.so`. `titlebarsEnabled` is the personal request;
`capabilities.titlebars` means the native registry confirms the plugin, its
required callback exists, and native configuration/button setup succeeded.
Loaded Tiled and disabled Floating modes report capability true with native
rendering disabled. Missing/unrelated registry entries, missing required APIs,
or failed configuration/button setup report false, even with an installed file.
Setup runs once per Lua lifecycle/theme change while hidden or visible;
rendering changes update only the enabled option. Unchanged event refreshes
reuse successful setup without config writes, button resets or duplicate buttons.
Loss of registry/API availability or any setup failure invalidates the cached
success, so recovery verifies setup again even when returning to old preferences.
A missing/ABI-incompatible plugin never disables keyboard/mouse controls.
Titlebars consume `cybexos/theme/tokens.json` (`surfaceRaised`, `text`, UI font
and text size) through the strict JSON reader. The existing
`cybexos_system_theme()` trigger refreshes them without another theme owner or
polling. The packaged native `clear_buttons()` extension clears existing
buttons before exactly three themed buttons are added, preventing duplicate
hit targets and stale icon textures. Its clear/re-add and pointer/theme behavior
passed historical isolated native tests on earlier product source; the exact
evidence scope and current-candidate gates are in desktop-validation.md.
User.lua can supply
`__cybexos_titlebar_colors={background,foreground,font,size}` deliberately.
The loaded-plugin registry gates all native callbacks and dynamic no-bar rules.
Runtime events, preference edits and theme refresh never declare/load plugins.
After hyprbars is registered, an exact known-CSD class rule suppresses its bars
for `org.gnome.Nautilus` and `org.gnome.TextEditor`; that rule is retired on
reload/plugin absence. This is an explicit application policy, not automatic
Wayland CSD detection or a claim about Firefox/Electron and arbitrary clients.

Directory initialization uses system Python once per output directory per
compositor lifetime: O_NOFOLLOW directory open, effective-UID ownership check,
fchmod(0700), and a cryptographically random temporary prefix. Event writes use
only Lua I/O and atomic rename in that private directory; identical snapshots
and assignments are skipped. File modes inherit the process umask; the checked
0700 directory is the privacy boundary. Invalid or unreadable personal files
cannot be silently overwritten by setters. A same-UID actor can edit their own
preferences; this is not a sandbox against the account owner.

## Provenance and native dependencies

Inspected Omarchy tag `v4.5.0-rc1`, commit
`03ff1eff3812933f7088484533784d2f63eaf19a`: monitor-workspaces.lua,
workspace-modes.lua, workspace-layouts.lua, workspace-layout-toggle, its package
list and LICENSE, and shell tests hyprland-monitor-workspaces-test.sh,
hyprland-floating-workspaces-test.sh and hyprland-workspace-layout-test.sh.
The tag's migration cases for named workspace selection and saved layout/default
handling informed strict numeric selectors and explicit default overrides.
No subsequent moving-branch fixes were copied. Monitor allocation/persistence is
an independent implementation; floating claim tags, claim-before-group-float,
legacy opening ownership and logical/rotated geometry are adaptations of the
pinned workspace-modes.lua. Its MIT copyright/permission/warranty notice is
retained in workspace_layouts.lua.

Inspected Hyprland `v0.56.2`, commit
`efb50993780079460b0cbed1363e2166a2de1d9f`: Lua query/dispatcher/rule/event/window,
monitor/workspace objects, and LuaFunctionGesture.cpp. Native scrolling is
already included (`src/layout/algorithm/tiled/scrolling`); `layout="scrolling"`
is a workspace rule. No compositor upgrade or scrolling plugin is needed.
Runtime availability probes the registered `scrolling.column_width` option;
unavailable Scrolling is not offered by cycle/setters and falls back to dwindle
when reading saved choices from an incompatible build. The actual Fedora
`hyprland-0.56.2-2.fc44` package and its installed stubs were inspected.
Earlier all-layout native runs are recorded in desktop-validation.md;
source inspection alone is not native qualification.

Inspected optional `omacom/omarchy-hyprland-titlebars` commit
`379ff910fcce9f0cc9b41f9a87c527997076a417` (v0.2.2), README,
CMakeLists, main.cpp, barDeco.cpp, tools/verify.py and both licenses. Native
build needs CMake >=3.27, C++23, pkg-config `hyprland`, `libdrm`, `libinput`,
`libudev`, `pixman-1`, `wayland-server`, `xkbcommon`; it uses `-fno-gnu-unique`.
The shared object checks exact host/client Hyprland build hashes. Build against
exact Fedora Hyprland headers and rebuild/requalify on each compositor package
update; an Arch binary or matching minor version alone is insufficient. Package
both BSD-3-Clause LICENSE and MIT LICENSE.MIT. The plugin's Lua namespace stays
hyprbars, with workspace_tag and add_button support.

Upstream skips X11 border opt-outs and supports explicit hyprbars:no_bar rules;
it does not automatically detect Wayland client-side titlebars. Automatic CSD
avoidance remains blocked on a supported API. The packaged clear_buttons patch
has historical isolated native runtime evidence; exact-class exclusions remain
explicit policy with mixed-client acceptance limited as documented in
native-titlebars.md and desktop-validation.md. The inspected 0.56.2
`LuaBindingsConfigRules.cpp` resolves nonbuiltin `hl.window_rule` keys through
the registered window effect table, so `['hyprbars:no_bar']=true` is added only
after the native registry proves the plugin is loaded. Do not advertise general
duplicate-decoration avoidance. Its verifier needs a running outer
Hyprland, foot, grim, wayland-scanner and a C compiler; it launches a nested
compositor. On thebeast that verifier must run under an agent-resource managed
task/VM lifecycle.

## Evidence and remaining gates

Starting revision: `3b310d106255558ca213c955ef37ee314e8681f2`. The R15/R16/R18
workspace corrections are committed in
`607bce226d9f85c4e6307567a75cc5cfbc8b1243` and included in exact tested product
`d2037af92cb3a47a08a9755e5996d2c4b0cae28d`. The contracts above include the
reviewed renamed-opening, manual-group and named-provenance corrections.

`./tests/hyprland-workspace-modes` passes 233 pure-Lua behavioral assertions.
The exact Fedora source gate includes those assertions; XPS hotplug/policy,
single-window margins, syntax, source/image parity and actual Qt/runtime gates
also pass. These checks cover:

- Physical identity ambiguity, connector changes, occupied/named IDs, full
  slots/guests, mirrors/lid reconnect, visible-workspace swap avoidance and
  Shared/Per-monitor transitions.
- Native capability failure, gesture opt-outs, independent floaters, fullscreen,
  groups/opening tags, manual ownership, minimize/reload/activate/group restore,
  scale/rotation/reserved areas and stale live-window validation.
- Strict/bounded/corrupt JSON, safe writer behavior and event-subscription
  retirement. user.lua master defaults and unmanaged native rules survive mode/titlebar edits and reload without taking ownership. Explicit choices equal
  to defaults survive default edits; reset, cycling and legacy sparse/v1
  inheritance retain their distinct meanings.
- R15 renamed positive-ID openings and suspended overrides, native dialog/user
  float rules and group ownership. There are no numeric opening rules and no
  consumption/mutation of the shared float-exclusion arrays.
- R16 manual-group provenance inherited before arrangement, and R18 ownership
  inherited while named/special without changing native floating state. Reload,
  original-owner closure and return to numbered workspaces preserve the choice.
- Declarative titlebar/registry/known-CSD rule lifecycle; loaded Tiled and disabled
  Floating capability reports; missing APIs/registry and native setup failures;
  recovery, cached successful setup and exactly-three-button theme refresh
  without event loads, redundant writes or duplicate buttons.

Fresh independent R22 found no actionable issue in the final correction scope.
Its detailed probes, historical native runs, external-helper reviews and
resource status are centralized in desktop-validation.md and the ledger.
Earlier native layout/titlebar tests retain their earlier product scope.

The writer accepts Linux ECHILD from `pclose` only with the exact bounded helper
success token; absent/malformed tokens and explicit nonzero exit status remain
failures. Its historical native JSON/0700 result and regression evidence are
recorded in validation.

All four exact d2037af ISO scenarios and English/Dutch checkout fresh/saved parity,
settings lifecycle and saved choices passed. Pristine offline upgrade/native
rebuild/convergence/recovery also passed. Its candidate-runtime report verifies
exact provenance, loaded titlebars, true capabilities, empty snapshot error and
one explicit Floating workspace.

The separate `qualification-plain-us-evidence/r15-workspace-rename-native.json`
report passed renamed/numbered opening, named-group provenance, original-owner
closure, manual tiled/floating groups, reload and restoration. These are stable
native observations, not first-frame/client-configure proof. Exact notification
action separation and restoration passed separately; validation records its
scope and the source/runtime-fixture coverage of action-bound/label edges.

The core prerequisite aggregate passes. Independent R27 is clean within its
completed scopes; English checkout was verified separately by the parent.
Actual startup/pixel/performance measurement is **BLOCKED** after four failed
attempts, zero accepted samples/comparison. R11 is scoped inert review only.
Warm04 passed root-policy/reconciliation validation but its Welcome frame was
black background/pointer only; null review response sent no input. Failure
preceded SSH fixture/warm-up; cause unknown, no proof of product regression.
Warm02's cause and warm03's exact offending bytes remain unknown. All startup
leases are closed/empty. No further VM series is planned; a future benchmark
requires visibly verified Welcome/portals and eight fresh equivalent boots with
current prerequisites, a reviewed retarget and unchanged guards, as detailed in
validation. R30 independently accepted scoped retention and verified both R29
repairs; it does not grant runtime/release acceptance. All 53 recorded leases are
closed, MAIN's workspace absent and no temporary VM/container retained; shared
services untouched. Baseline/intermediate payloads were removed; final testing
deliverables and bounded evidence remain. Original paths are historical map-resolution
identities. Validation records the historical-source limit and cleanup-time inventory
snapshot, which excludes later documentation/review/PR records.
Physical lid/mirror/dock/two-external/connector/identity/scaling permutations and generic Wayland CSD remain blocked.
[PR #21](https://github.com/DigitalPals/CybexOS/pull/21) merged at bee9d722 on
`2026-10-21T14:01:19Z` after both required hosted checks succeeded; origin/main
was verified at that merge. Validation distinguishes the tested d2037af
artifacts from the CI-only fix and merge. Active user desktop rollout
and public release remain unauthorized. These scoped results do not establish
full desktop/release acceptance.
