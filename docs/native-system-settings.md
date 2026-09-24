# Native system settings

CybexOS Settings now includes Network, Sound, Displays and Online Accounts. The
Wi-Fi popover, network details, sound drawer and calendar account action open
these pages. Settings search includes them too. The compact controls remain
available.

## Delivered behavior

| Page | Native controls | External support |
| --- | --- | --- |
| Network | Physical adapters and saved Ethernet/Wi-Fi profiles; autoconnect, metering, automatic/manual/disabled IPv4 and IPv6, gateway and DNS; explicit Apply/Discard | `nm-connection-editor` for VPNs, enterprise certificates, bridges and advanced routing |
| Sound | Existing device selection, volume, microphone meter and application mixer; hardware profiles, ports, stereo balance, playback/recording stream routing and mute | `pavucontrol` for advanced controls |
| Online Accounts | Provider, identity and attention status; calendar enable/disable; confirmed local removal; administrator locks | `gnome-online-accounts-gtk` for provider setup, browser authentication and reconnection |
| Displays | Arrangement preview with drag and keyboard placement; per display: on/off, resolution, refresh rate, scale, rotation, mirroring and adaptive sync; a 15-second trial before anything is saved | `~/.config/cybexos/hypr/user.lua` for monitor rules the page does not cover (bit depth, HDR, reserved areas) |

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
does not change these services. System pages show their own operation status
instead of the shell preference window's “Saved · applies live” indication.

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

## Displays

The Displays page lists every output Hyprland reports, including disabled
ones. The arrangement is drawn in Hyprland's layout coordinates. A dropped
display snaps to the nearest shared edge (at least 64 logical pixels long) and
never overlaps another. Changing a display's size keeps its neighbours on the
side they were on. With the arrangement focused, arrow keys place the selected
display beside the others. Scale presets are limited to values Hyprland keeps
for the chosen mode, that is multiples of 1/120 that divide the mode into
whole logical pixels.

**Apply** starts a trial:

1. `scripts/display-settings.py` writes the candidate to
   `$XDG_RUNTIME_DIR/cybexos/displays-trial.json`.
2. It arms a transient `systemd-run --user` timer
   (`cybexos-display-trial-<token>`), which restores the previous settings
   after 20 seconds.
3. It runs `hyprctl eval 'require("displays").apply_trial(...)'`, so the
   trial goes through the same Lua that loads the saved file at startup.

If the timer cannot be armed, nothing is applied. If Hyprland rejects a rule,
the helper undoes the change immediately.

The page counts down 15 seconds:

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
