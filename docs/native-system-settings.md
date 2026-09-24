# Native system settings

CybexOS Settings now includes Network, Sound and Online Accounts. The Wi-Fi
popover, network details, sound drawer and calendar account action open these
pages. Settings search includes them too. The compact controls remain available.

## Delivered behavior

| Page | Native controls | External support |
| --- | --- | --- |
| Network | Physical adapters and saved Ethernet/Wi-Fi profiles; autoconnect, metering, automatic/manual/disabled IPv4 and IPv6, gateway and DNS; explicit Apply/Discard | `nm-connection-editor` for VPNs, enterprise certificates, bridges and advanced routing |
| Sound | Existing device selection, volume, microphone meter and application mixer; hardware profiles, ports, stereo balance, playback/recording stream routing and mute | `pavucontrol` for advanced controls |
| Online Accounts | Provider, identity and attention status; calendar enable/disable; confirmed local removal; administrator locks | `gnome-online-accounts-gtk` for provider setup, browser authentication and reconnection |

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
