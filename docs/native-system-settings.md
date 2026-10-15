# Native system settings

CybexOS Settings includes Network, Sound, Displays, Keyboard, Touchpad, Region,
Online Accounts and Security. The
Wi-Fi popover, network details, sound drawer and calendar account action open
these pages. Settings search includes them too. The compact controls remain
available.

## Delivered behavior

| Page | Native controls | External support |
| --- | --- | --- |
| Network | A list of saved Ethernet/Wi-Fi profiles with their status, and the physical adapters; VPN and WireGuard profiles with a connect switch each, import of OpenVPN/WireGuard files and confirmed removal; a Wi-Fi hotspot with its name, password and join QR code; for the selected profile, autoconnect, metering, automatic/manual/disabled IPv4 and IPv6, address, gateway and DNS; edits wait in the page's Apply bar | `nm-connection-editor` for other VPN types and detailed VPN settings, enterprise certificates, bridges and advanced routing |
| Sound | Output and input device lists (network outputs folded), volume and mute, microphone level meter; ports of the default devices, output balance, hardware profiles, and per-application level, mute and playback/recording routing | `pavucontrol` for advanced controls |
| Online Accounts | Provider, identity and attention status; calendar enable/disable; confirmed local removal; administrator locks | `gnome-online-accounts-gtk` for provider setup, browser authentication and reconnection |
| Displays | Arrangement preview that also selects the display to edit, with drag and keyboard placement; per display: on/off, resolution, refresh rate, scale, rotation, flip, mirroring and adaptive sync; a 15-second trial before anything is saved | `~/.config/cybexos/hypr/user.lua` for monitor rules the page does not cover (bit depth, HDR, reserved areas) |
| Keyboard | Search installed XKB layouts and variants; add, remove and reorder up to four layouts; configure switching shortcuts and switch immediately | Personal `user.lua` rules retain final precedence |
| Touchpad | Tap to click, natural scroll direction, three-finger swipe between workspaces and pointer sensitivity, drafted behind Apply; existing scroll speed control applies immediately | Pointer sensitivity is Hyprland's shared mouse/touchpad setting; per-device rules remain available in `user.lua`. The swipe is a gesture, saved as `touchpad.workspaceSwipe` in `input.json`; a `user.lua` gesture on the same fingers replaces it |
| Region & formats | Search installed timezones and locales, then explicitly apply system timezone or language; existing clock and temperature format controls | Normal system Polkit authorization; additional locales require Fedora language packs |
| Security | Fingerprint reader and enrolled fingers, guided enrolment with live progress, confirmed removal, the system fingerprint switch; registered security keys, adding by touch, confirmed removal | fprintd's own Polkit authorization for enrolment; pkexec for the authselect switch; a terminal for keys that need a PIN to register ([details](security.md)) |

GOA continues to own account authentication and credentials. The shell reads
metadata and never requests access tokens or passwords. Calendar data still
comes from Evolution Data Server. Disabling calendars or removing an account
affects other applications using that account on this computer; removal does not
delete the remote account.

GNOME Settings remains installed for GNOME Calendar's own account-management
entry point. CybexOS's settings entry points no longer launch it or impersonate
a GNOME session. Removing GNOME Settings, replacing GNOME Calendar, replacing
the login manager and building a new ISO are separate work.

## State and failure handling

NetworkManager, PipeWire/WirePlumber and GOA own their settings. None of the new
device, connection or account data is stored in `shell.json`. Shell reset/undo
does not change these services. System pages show a status line only while
their first read is in flight and after a failure, which offers Refresh.
Network and Displays edits wait in an Apply bar pinned to the page foot. It
names the pending changes, or the problem that blocks them, and during a
trial counts down to the automatic restore with **Revert now** and **Keep
changes**. Sound changes apply at once.

Network edits clone the full libnm connection and validate the result. Version
checks reject concurrent changes. Unedited settings, routes, secret flags,
stored Wi-Fi credentials and secondary addresses in DHCP profiles are preserved.
Unsupported IP methods remain accessible through the advanced editor.

Applying an active profile creates a 60-second NetworkManager checkpoint and
changes only the in-memory profile. **Keep changes** saves the profile and ends
the checkpoint. **Revert now**, leaving the page or closing Settings restores the
previous settings. NetworkManager also owns the timeout if the UI or helper
exits. Inactive profiles save without activation. A trial requires user
confirmation of connectivity; activation alone does not prove internet access.

The sound helper re-resolves capabilities before changing them. Application
streams require their PipeWire serial as well as their transient index, so an
index reused by another stream is rejected. Internal filter streams are excluded
from routing controls, and the XPS speaker filter retains its existing gain
policy. Hardware and stream rows keep stable identities during refreshes.

`Common/SystemSettingsBackend.qml` owns one request channel per domain. Its
consumers acquire and release service monitors; monitors and snapshot readers
stop when no page needs them. Requests use bounded JSON through stdin with
explicit argument arrays, timeouts and sanitized errors. Network mutations use
the session user's normal NetworkManager authorization path.

The shared desktop Ansible package task and `image/cybexos-desktop.spec` declare
the standalone editors, libnm, GLib tools and PulseAudio client utilities. The
image application payload consumes the shared task's package list too.

## VPN and hotspot

The Network page has a **VPN** group and a **Hotspot** group between the
connection list and the selected connection's settings. The drawer's Network
tab adds one compact VPN switch under Tailscale, but only when at least one
VPN profile exists: the connected or connecting profile, else the one used
most recently. Tailscale keeps its own row and is not a VPN profile here.

Both surfaces use `scripts/network-tool.py` (`vpn` and `hotspot` requests,
JSON on stdin). The Settings page reaches it through the network settings
service (`system_settings_network.py`), so VPN and hotspot requests share the
page's one request channel and busy state. Their failures appear on the row
they concern rather than as the page's status line, and they never touch a
pending connection edit.

### VPN

- **List.** NetworkManager profiles of type `vpn` (OpenVPN, OpenConnect,
  vpnc, SSH and other installed plugins) and `wireguard`, with their type and
  state, from the same `nmcli connection show` the network snapshot already
  runs. Naming each plugin costs one extra `nmcli` read on the Settings page.
- **Connect.** CybexOS runs no network applet, so nothing would answer
  NetworkManager when a VPN needs a password. For one user-requested
  activation, `scripts/network_vpn_agent.py` registers a secret agent on the
  system bus, activates the profile from the same process (NetworkManager
  asks that process's agent first), and answers only that profile's `vpn`
  secret request by running the plugin's own sign-in dialog, the
  `auth-dialog` from its `NetworkManager-*-gnome` package that nm-applet also
  uses. Every other request gets `NoSecrets`, so another agent can still
  answer it. Secrets go from the dialog straight into the D-Bus reply; they
  are never logged, written to disk or passed to the shell, and `SaveSecrets`
  is declined, so a profile keeps its own secret storage. The agent
  unregisters when the activation succeeds, fails, is canceled or times out
  (50 seconds). Failures are reported from NetworkManager's reason: a
  canceled sign-in, a rejected login, a missing plugin, no network to run
  over, and so on.
- **Import.** *Import VPN…* opens a file picker (the Settings folder dialog in
  file mode, starting in Downloads) for an OpenVPN `.ovpn` or a WireGuard or
  OpenVPN `.conf` file of at most 1 MiB. The helper only sniffs the format,
  then runs `nmcli connection import type openvpn|wireguard file …`.
  NetworkManager names a WireGuard profile and interface after the file, so a
  file name that is not a valid interface name is imported through a
  symlink with a valid name in a private temporary directory (the key is
  never copied) and the profile is renamed after the file. Imported profiles
  get `connection.autoconnect no`; NetworkManager starts an imported
  WireGuard profile at once, so the import also takes it down. `nmcli`'s
  diagnostics are classified, never shown, because a parser error can quote
  a line of the file.
- **Remove.** *Remove…* asks on a second row; only the confirming press
  sends `confirmed: true`, and the helper refuses a removal without it, or
  for a profile that is not a VPN.
- **Advanced editing** stays in `nm-connection-editor`.

### Hotspot

The group appears only on a computer with a Wi-Fi adapter. It is one switch,
the network name and, while the hotspot is on, *Show password and QR code*.

- The hotspot is one NetworkManager profile, `CybexOS hotspot` with a fixed
  UUID, created on first use: access-point mode on 2.4 GHz, WPA2-PSK (CCMP,
  PMF off for the widest client and driver support), `ipv4.method shared`,
  `connection.zone nm-shared` and `connection.autoconnect no`. It never
  starts at boot; the switch starts it again.
- The password is generated (16 characters from an alphabet without
  look-alike characters, about 79 bits) and reaches `nmcli` only through
  `passwd-file` on stdin, like a Wi-Fi password. NetworkManager stores it in
  the profile on the first start and reuses it afterwards. The Settings page
  never holds it: the join card, the network overlay's QR page, asks the
  helper for the code and the password together and drops both when it
  closes. Change the password in the advanced editor.
- The adapter is chosen to avoid dropping Wi-Fi: an idle second adapter that
  can host an access point is preferred. NetworkManager runs one connection
  per adapter, so on a single adapter the Wi-Fi connection drops while the
  hotspot runs; the group says so before it is switched on. An adapter
  without access-point support, or Wi-Fi switched off, disables the switch
  with the reason.
- Renaming a running hotspot restarts it under the new name.

### Firewall

Shared mode runs NetworkManager's DHCP and DNS server (dnsmasq, which no
Fedora package pulls in, so the desktop package task and the RPM's
`Requires` both install it) for the clients and NAT for their traffic. NetworkManager puts a shared connection in firewalld's
`nm-shared` zone, which accepts DHCP, DNS and ICMP to this computer and
forwards client traffic; the strict `cybexos` zone (target `DROP`) would
refuse the clients' DHCP and DNS. The hotspot profile therefore names
`nm-shared` explicitly. The checkout installer's adoption of physical
profiles into the `cybexos` zone skips profiles whose `ipv4.method` is
`shared`, and the ISO never rebinds profiles, so both installation paths
leave the hotspot (and any other shared connection) in `nm-shared`.
`tests/verify-system` and the VM convergence check expect exactly that. The
`cybexos` zone template itself is unchanged.

## Displays

The Displays page lists every output Hyprland reports, including disabled
ones. The arrangement is drawn in Hyprland's layout coordinates. A dropped
display snaps to the nearest shared edge (at least 64 logical pixels long) and
never overlaps another. Changing a display's size keeps its neighbours on the
side they were on. The arrangement also picks the display the rows below
edit. Each display is a Tab stop: Enter or Space selects it, and arrow keys
place it beside the others. A display that is off or mirroring takes no room
in the layout and appears as a chip under it, so it can still be selected.
Scale presets are limited to values Hyprland keeps
for the chosen mode, that is multiples of 1/120 that divide the mode into
whole logical pixels.

**Apply** in the page's Apply bar starts a trial:

1. `scripts/display-settings.py` writes the candidate to
   `$XDG_RUNTIME_DIR/cybexos/displays-trial.json`.
2. It arms a transient `systemd-run --user` timer
   (`cybexos-display-trial-<token>`), which restores the previous settings
   after 20 seconds.
3. It runs `hyprctl eval 'require("displays").apply_trial(...)'`, so the
   trial goes through the same Lua that loads the saved file at startup.

If the timer cannot be armed, nothing is applied. If Hyprland rejects a rule,
the helper undoes the change immediately.

The Apply bar counts down 15 seconds:

- **Keep changes** saves the candidate atomically to
  `~/.config/cybexos/displays.json` and disarms the timer. A confirm is
  refused, and the change undone, when the saved file changed since the page
  read it or when it arrives more than three seconds after the countdown.
- **Revert now**, Escape, the countdown ending or closing Settings reload
  Hyprland, which rebuilds every rule from the unchanged files on disk. The
  timer does the same if the shell is not running.

The saved file is JSON owned by the user, keyed per physical monitor:

- `desc:` plus Hyprland's make/model/serial description, so choices follow a
  monitor across ports.
- The connector name when that description is empty or could match another
  connected monitor, for example twin panels without serials.

Entries for monitors that are not connected are kept.

When a connected monitor moves from a connector key to its physical identity,
Apply merges the old entry into the physical entry and removes the connector
alias. This includes early files whose connector entries have no description.
Unknown fields survive, with the physical entry taking precedence. Keeping
both entries could silently undo an edit: `displays.lua` emits sorted keys,
and Hyprland's [monitor rule manager](https://github.com/hyprwm/Hyprland/blob/v0.56.2/src/config/shared/monitor/MonitorRuleManager.cpp)
chooses the last matching rule. A stale `eDP-1` entry therefore overrode the
new `desc:LG Display ...` position, scale and mode. Connector entries explicitly
describing other hardware are left intact.

Live verification on Hyprland 0.56.2 reproduced an Apply requesting the
built-in display at `(0, 540)` while the stale connector rule kept it at
`(0, 0)`. With the alias migrated, Apply and Keep placed it at `(0, 540)` and
the layout survived a reload. A 160% / 60 Hz trial applied and reverted to
200% / 120 Hz; an unattended arrangement trial also restored through the
systemd watchdog. The repaired preferences work with the installed runtime.

`roles/desktop/files/displays.lua` reads the file with a strict, size- and
depth-bounded JSON parser and never executes it:

- It is loaded from `hyprland.lua` in a `pcall`, after the vendor `monitors`
  module and before `~/.config/cybexos/hypr/user.lua`.
- A missing file changes nothing. An invalid one is ignored as a whole and
  reported in `$XDG_RUNTIME_DIR/cybexos/displays-status.json`, and the page
  shows that error. The vendor rules then stay in effect.
- Each saved rule starts from the vendor rules that match the same monitor,
  which the vendor module records in `_G.__cybexos_vendor_monitor_rules`. This
  keeps fields such as bitdepth, colour management or a vendor VRR policy
  unless the user chose another value.
- Every field the page owns is written explicitly, so a trial never inherits
  a previous trial's value. A reload retires the module's event subscriptions.
- Hyprland applies monitor rules last-first, so saved choices override vendor
  rules and `user.lua` overrides both.

A display turned off on this page records the displays that were on beside it
(`disabledWith`). It stays off only while one of those companions is
connected and on. `displays.lua` re-evaluates this on `monitor.added` and
`monitor.removed`, so undocking a laptop whose panel was turned off beside an
external monitor turns the panel back on. A display is only turned off while
a different one remains on.

Not covered: per-dock profiles for different sets of monitors, HDR and
bit-depth controls, and custom modelines. Use `user.lua` for those.

## Validation and maintenance

### Keyboard, touchpad and system region

Input preferences are user-owned data in
`$XDG_CONFIG_HOME/cybexos/input.json` (normally `~/.config/cybexos/input.json`).
Only edited fields are saved. Unknown top-level, section and unchanged-layout
metadata survive; version hashes reject concurrent writes. A malformed file or
symlink is left untouched and explained in Settings. The helper takes an
exclusive lock, atomically writes the new file, and reloads Hyprland. A rejected
reload restores the original bytes and reloads again; failure of that recovery
is explicitly reported. It never rewrites `user.lua`.

The shared `input_preferences.lua` loader uses the existing bounded JSON
parser, validates all fields before applying any, and contains corrupt-file
errors so the compositor can start. It loads after the release's input defaults
and before `user.lua`. Therefore a personal override can intentionally supersede
a saved setting. Settings reads effective compositor values when refreshed.
Layout switching retains the release's compose/third-level options; selecting
Caps Lock as a switch replaces its Compose role. Switching to the next layout
changes the current session only, while the first saved layout is the sign-in
default. Shell reset/undo does not reset these input preferences.

Region changes go through `org.freedesktop.timedate1.SetTimezone` and
`org.freedesktop.locale1.SetLocale` on the system bus, with normal interactive
Polkit authorization. No privileged helper, password capture or custom Polkit
exception is installed. Choices come from the installed timezone and locale
catalogs. Requests reject stale values, preserve existing `LC_*` overrides,
verify the resulting properties, and report authorization denial, cancellation
or service failure. Changing the system language sets `LANG`; applications use
it after signing out and back in. Separate timezone/language Apply actions
avoid a misleading partially successful combined change. Shell clock and
temperature formats remain independent personal settings.

`tests/native-input-region.py` exercises the production helpers with isolated
preferences and mocked compositor/system buses, including failed reload
recovery, unknown-field preservation, stale writes, invalid inputs, symlinks,
real stdin/subprocess failure handling, authorization requests and preserved
locale categories. `tests/hyprland-input` executes the shipped Lua loader under
LuaJIT. `tests/qml/tst_input_draft.qml` exercises the pages' draft, reorder and
filter functions with Qt's JavaScript engine. These tests do not claim a live
authorization prompt, physical keyboard/touchpad or fresh-install validation.

Both installation paths ship the same loader, pages and helpers, and use the
same XKB/timezone package resources. No installer applies these personal or
system region choices implicitly during reconfiguration.

Run the normal repository gate before deployment:

```sh
./tests/run
PYTHONDONTWRITEBYTECODE=1 python3 image/check-source
```

Additional integration checks:

```sh
# Private mount/network/PID namespaces with a separate D-Bus and NetworkManager.
# Requires sudo and never edits the workstation's network profiles.
./tests/system-settings-network-namespace

# After deploying through Ansible: uses only the managed quickshell.service.
./tests/system-settings-live
```

Display settings are covered without touching a live compositor:

- `tests/display-settings.py` runs the helper against fake `hyprctl`,
  `systemd-run` and `systemctl`. It covers trial, confirm, rollback, timer
  expiry, rejected rules, a timer that cannot be armed, concurrent edits, and
  symlinked or invalid saved files.
- `tests/hyprland-displays` runs `displays.lua` under LuaJIT with a recording
  `hl` mock.
- `tests/displays/documents.json` holds valid and invalid documents that the
  Lua and Python validators must agree on.
- `tests/quickshell/display-helpers.test.cjs` covers modes, scales, identities
  and the arrangement.
- `tests/hyprland-features` loads the whole configuration tree with a
  truncated and a hostile `displays.json`.

The isolated NetworkManager test covers active in-memory edits, confirmation and
persistence, explicit and automatic rollback, expired confirmation rejection,
inactive-profile edits and saved Wi-Fi password preservation. Backend unit
tests also cover address validation, concurrent changes, typed D-Bus values,
capability changes, stale audio streams and account action guards.

VPN and hotspot behaviour is covered without a real NetworkManager:

- `tests/network-connections.py` runs `network-tool.py` and the settings
  service with `nmcli` stubbed on `PATH`: parsing of terse `nmcli` output,
  import argument construction (including the WireGuard symlink), file
  validation, confirmed removal, hotspot profile creation with the password
  only on stdin, adapter choice, and error mapping that never echoes
  diagnostics. The secret agent runs against a fake NetworkManager on a
  private D-Bus daemon with a fake plugin dialog: only the activating
  profile's secrets are answered, a canceled dialog is reported as such, the
  agent always unregisters and no secret reaches the helper's output.
- `tests/quickshell/network-vpn-hotspot.test.cjs` covers the helpers and the
  structure of the drawer switch, the VPN and Hotspot groups, the join card
  and the folder dialog's file mode; the real-engine lifecycle harness
  constructs both groups against a hand-set snapshot.
- `image/test_installation_parity.py` runs the checkout's zone-adoption
  script against a stubbed `nmcli` and checks that the ISO path never
  rebinds profile zones.

A real VPN sign-in, a hotspot client joining, and the hotspot staying off
after a reboot need hardware and are on the manual checklist
(`docs/shell-settings-manual-verification.md`).

The managed live check opens and reopens all three pages, verifies their data
and monitor readiness, closes them and checks that readers/monitors stop. It
restores the previous Settings window state, verifies that the service owns the
sole Quickshell process, and checks the current journal for QML errors.
The `settings status` IPC method reports lifecycle flags without account or
device metadata.

Validated on Fedora 44 on 2026-09-24: repository gate, image source checks,
isolated NetworkManager transactions, managed page lifecycle and visual layout.
The standalone GOA frontend opened its provider picker under Hyprland. Real
provider sign-in, account deletion, Bluetooth hardware profile switching and a
fresh ISO boot were not exercised. Those remain release acceptance checks;
the existing tests do not imply their completion.
