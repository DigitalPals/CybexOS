# Workspace compositor contract

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
looknfeel and user.lua, so opening rules can exclude independent floating
rules. The XPS Shared policy exposes a mode switch to the authoritative owner;
it is disabled only while Per-monitor is selected.
The collected `__cybexos_float_exclusions.class/title` values are ordinary Lua
arrays. Rule signatures encode private array copies with JSON length markers;
the collector's tables stay unchanged. Both signatures and opening rules use
the same copied patterns, including nonempty Settings/welcome/app exclusions.

Native scrolling and optional decoration provenance/qualification, shortcuts,
behavioral evidence, and remaining hardware gates are recorded below as the
implementation is verified. Fixtures are source tests, not compositor or ISO
qualification.

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
mode-owned tags only when the mode actually floats them or its opening rule did;
pre-existing floaters and excluded app float rules keep their ownership. All
members are claimed before any grouped window floats. Fullscreen and pinned
windows retain their state; reconciliation runs again when they leave it.
Explicit Super+F floating choices release mode ownership for every member of
the selected window's group before the compositor toggles that group once.
That manual tag takes precedence over the opening-rule tag, including its
dynamic `*` form, so newly opened Floating windows remain tiled after Super+F
through subsequent events and configuration reloads.

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
`capabilities.titlebars` means a plugin is actually loaded and configured.
A missing/ABI-incompatible plugin never disables keyboard/mouse controls.
Titlebars consume `cybexos/theme/tokens.json` (`surfaceRaised`, `text`, UI font
and text size) through the strict JSON reader. The existing
`cybexos_system_theme()` trigger refreshes them without another theme owner or
polling. A native `clear_buttons()` extension permits safe live button theme
changes; unmodified upstream supports only `add_button`, so its existing
buttons retain their colors until a config reload. The parent owns that native
extension and its qualification. User.lua can supply
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
opening-rule ownership and logical/rotated geometry are adaptations of the
pinned workspace-modes.lua. Its MIT copyright/permission/warranty notice is
retained in workspace_layouts.lua.

Inspected Hyprland `v0.56.2`, commit
`efb50993780079460b0cbed1363e2166a2de1d9f`: Lua query/dispatcher/rule/event/window,
monitor/workspace objects, and LuaFunctionGesture.cpp. Native scrolling is
already included (`src/layout/algorithm/tiled/scrolling`); `layout="scrolling"`
is a workspace rule. No compositor upgrade or scrolling plugin is needed.
Runtime availability probes the registered `scrolling.column_width` option;
unavailable Scrolling is not offered by cycle/setters and falls back to dwindle
when reading saved choices from an incompatible build. Parent's Fedora test
container had actual `hyprland-0.56.2-2.fc44`; its installed stubs were also read.
Source inspection is not a live all-layout qualification.

Inspected optional `omacom/omarchy-hyprland-titlebars` commit
`379ff910fcce9f0cc9b41f9a87c527997076a417` (parent selected v0.2.2), README,
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
avoidance remains unresolved; the parent's clear_buttons native patch and the
exact-class exclusions need runtime qualification. The inspected 0.56.2
`LuaBindingsConfigRules.cpp` resolves nonbuiltin `hl.window_rule` keys through
the registered window effect table, so `['hyprbars:no_bar']=true` is added only
after the native registry proves the plugin is loaded. Do not advertise general
duplicate-decoration avoidance. Its verifier needs a running outer
Hyprland, foot, grim, wayland-scanner and a C compiler; it launches a nested
compositor. On thebeast that verifier must run under the parent's managed
resource/VM lifecycle, not an unmanaged host session.

## Evidence and remaining gates

Starting revision `3b310d106255558ca213c955ef37ee314e8681f2`; tests ran on the
shared uncommitted implementation diff (the parent records the final integrated
revision). The R2 ownership/override follow-up was tested on `66b14a2` plus the
owned Lua/fixture/documentation diff. Actual source checks run by this agent:

- `./tests/hyprland-workspace-modes`: Passed, 161 behavioral assertions using
  local rpmlua. Covers serial ambiguity, connector changes, occupied/named IDs,
  full slots/guests, mirrors/lid reconnect, visible-workspace swap avoidance,
  mode transitions, native capability failure, gesture opt-out, independent
  floaters/fullscreen/groups/opening tags, manual ownership, minimize/reload/
  activate/group restore, scale/rotation/reserved areas, live-window validation,
  corrupted/bounded JSON and subscription retirement.
  Review regressions cover a first-introduction user.lua master default,
  unmanaged native workspace rules, mode/titlebar edits and reload without
  taking layout ownership, explicit overrides/default reset/cycling, legacy v1
  compatibility, manual tiling of OPENED* windows, Shared allocation around
  named ID 18, and declarative plugin/registry/known-CSD rule lifecycle.
  Nonempty ordinary class/title arrays reproduce the generated-config signature
  failure before the fix; regression checks require a clean initial snapshot,
  unchanged external tables, correct negative opening matches, no rule rebuild
  for identical patterns, and replacement rules after an in-place pattern edit.
  R2 regressions require every grouped member to release mode ownership before
  one manual toggle, preserve that choice through reload, and permit a later
  Floating selection to reclaim the tiled group. Explicit layout choices equal
  to old/new defaults survive default edits and reload, while default reset,
  inherited rows and legacy sparse preference maps retain distinct semantics.
- `./tests/hyprland-workspaces`: Passed XPS hotplug and explicit policy switching,
  and single-window margin fixtures for generic and XPS machines.
- Owned Lua syntax (`loadfile` via rpmlua), bash syntax and scoped diff whitespace
  checks: Passed.

No host VM/container or installed-desktop change was made by this agent. Parent
owns the leased native environment and must run actual compositor loading,
all three native layouts, opening dialogs/app rules/groups/fullscreen,
minimize/restore/window activation, live hotplug/mirror/lid/geometry tests, native
plugin/CSD/drag/buttons/reload/theme verification, plus both installation paths'
source/image parity and rebuilt payload qualification at one revision. Existing
fixtures are not an end-to-end install or real monitor qualification. Physical
hardware permutations and native titlebar CSD are still qualification gates.

Native directory-writer follow-up: on the parent's supervised GPU VM running
Hyprland 0.56.2-2.fc44 / Lua 5.4, a completed `io.popen` helper returned valid
stdout but `pclose` reported `nil, "No child processes", 10` because the
compositor had reaped its child. workspace_state accepts this Linux ECHILD case
only alongside the exact bounded helper success token; absent/malformed tokens
and explicit nonzero exit status remain failures. The fixed module source was
evaluated in that native compositor (without replacing its installed modules):
writing a JSON file returned `true:nil`, the directory mode was 0700 and the
expected JSON was read back. Diagnostic files were then removed. Four new
behavioral assertions cover ECHILD success, cached event writes, no success
token and explicit failed exit. This proves the native writer fix, not the
complete monitor/layout/minimize integration; parent must retransfer and rerun
those acceptance checks.
