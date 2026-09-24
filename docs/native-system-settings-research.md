# Integrating system settings into CybexOS

Research date: 2026-09-24. Repository baseline: `834c1f0`.
Status: research baseline. The recommendations below describe the repository
before implementation. See [the implemented settings integration](native-system-settings.md)
for the delivered behavior, validation and remaining coverage.

**Recommendation.** Add Network, Sound and Online Accounts pages to the existing
CybexOS Settings window. Reuse the current shell services and let NetworkManager,
PipeWire/WirePlumber and GNOME Online Accounts (GOA) remain responsible for system
state. Keep GNOME Settings installed during the transition. Its removal is a
separate milestone after both shell and application entry points are covered.

The first implementation should deliver Sound settings and shared navigation.
In parallel with that work in the roadmap, validate the Fedora-packaged standalone
GOA frontend as the account setup fallback. Full native account authentication
should not block improvements to everyday system controls.

**What exists today.** Paths below are relative to
`roles/desktop/files/quickshell/` unless stated otherwise.

| Area | Existing implementation | Remaining external dependency |
| --- | --- | --- |
| Network | `Common/WifiState.qml`, `Common/NetworkDetails.qml`, `scripts/network-tool.py`: radio/scanning, connect/disconnect/forget, hidden Wi-Fi, DNS presets/custom DNS, band selection, QR sharing and diagnostics | `Popovers/WifiPopover.qml` and `NetworkOverlayWindow.qml` launch `nm-connection-editor`, falling back to `gnome-control-center network` |
| Sound | `Common/Audio.qml`, `Popovers/Drawer/DrawerSound.qml`: output/input selection, mute/volume, microphone meter and playback application volumes; routing helpers move existing streams | The drawer launches `pavucontrol`, falling back to `gnome-control-center sound`; no general card profile/port editor |
| Online accounts | `Common/Calendar.qml` and `scripts/calendar-events.py` read calendars through GOA and Evolution Data Server (EDS) | `Calendar.manageAccounts()` opens GNOME Settings with a process-local `XDG_CURRENT_DESKTOP=GNOME` override |
| Settings window | `Settings/SettingsView.qml`, `Common/Settings.qml`, `Common/SettingsSearchData.js` already provide navigation, search, page routing and focus behavior | No dedicated Network, Sound or Online Accounts pages |

On the inspected Fedora 44 workstation, `nm-connection-editor` is installed and
`pavucontrol` is absent. Neither is explicitly selected in the shared desktop
package task or desktop RPM. `pulseaudio-utils`, which supplies the already-used
`pactl`, is explicitly selected only by the XPS hardware role. Portable settings
must declare their dependencies rather than inherit the builder/workstation's
package history.

ISO package changes need attention in two places: `image/cybexos-desktop.spec`
and `roles/desktop/tasks/main.yml`. `image/applications:package_names()` also
imports that desktop task's package list into the ISO application payload.
Changing the RPM dependency alone would therefore leave GNOME Settings in the
image. GNOME Calendar is already selected through that shared task.

**Shared integration design.** Use three pages, tentatively `NetworkPage.qml`,
`SoundPage.qml` and `AccountsPage.qml`, within the existing Settings window. Add
their identifiers to the page allowlist, navigation, loaders and search index.
Route menubar actions to `Settings.showSetting()` so search and popovers reach
the same controls. Preserve the compact popovers for quick changes.

Keep device/profile/account data in shared service models, outside `shell.json`.
That file should retain presentation preferences only. Network edits need a
draft, validation and explicit Apply/Cancel; sound sliders can apply live.
The Settings window's current global “Saved · applies live” status must not
claim that a pending system operation succeeded. Show operation-specific pending,
failed, applied and rollback states. Shell reset/undo must not erase system
connections or accounts.

Use the existing Python/JSON helper pattern for capabilities unavailable in QML.
Pass structured input through stdin, use bounded requests and sanitized errors,
and correlate replies to the request/device that initiated them. Run as the
session user and let system services enforce authorization through their normal
polkit path. Start listeners on demand, share them across views and release them
when no consumer remains. Reuse current services before introducing a general
settings daemon or a second settings application.

**Network: extend the working implementation.** The first page should expose
physical interfaces and saved profiles, connection status, autoconnect, metered
status, per-profile DNS, and IPv4/IPv6 automatic/manual configuration. Preserve
existing QR, band and diagnostics behavior. Current DNS presets modify multiple
saved physical profiles; present that as an explicitly broad operation and keep
it distinct from editing one connection.

For profile editing, add a focused Python PyGObject/libnm adapter. The installed
`NM 1.0` namespace supports connection validation, `RemoteConnection.update2`,
profile version IDs and checkpoint operations. Preserve the full original
profile, change only supported fields and reject concurrent edits. NetworkManager
updates replace the supplied settings map, so constructing a partial profile
risks losing unrelated configuration. Ordinary settings reads exclude secrets;
preserving secret flags and stored credentials needs dedicated tests.
[Connection update contract](https://networkmanager.dev/docs/api/latest/gdbus-org.freedesktop.NetworkManager.Settings.Connection.html),
[libnm connection API](https://networkmanager.dev/docs/libnm/latest/NMRemoteConnection.html).

For changes to an active connection, use a NetworkManager checkpoint with a
rollback timeout and a “Keep changes” action. This lets NetworkManager restore
connectivity if the UI closes or crashes. Verify saved-profile and runtime
restoration on Fedora 44; do not assume a successful helper exit proves both.
Keep the checkpoint limited to affected devices.
[Checkpoint API](https://networkmanager.dev/docs/api/latest/gdbus-org.freedesktop.NetworkManager.html).

Keep `nm-connection-editor` as a clearly named advanced editor initially. VPN
plugins, bridges, VLANs, complex routes and enterprise certificate configuration
need more than a basic form. The current helper creates enterprise Wi-Fi with
PEAP/MSCHAPv2; this is not complete enterprise support. A new enterprise editor
must handle CA certificates and server identity validation before claiming that
coverage. Do not expand this first task into a full NetworkManager replacement.

**Sound: the best first native page.** Reuse `Audio.qml` and factor the drawer's
device/application controls into shared components. Add hardware profile selection
(for example Bluetooth headset versus playback mode), available ports, channel
balance, per-application mute and explicit application routing. Keep existing XPS
speaker tuning behavior: its virtual output and physical volume-control sink are
intentionally different.

The installed Quickshell build exposes writable channel volumes, stream nodes,
default devices and a peak monitor. Its installed QML type declarations do not
expose a `PwDevice` card-profile API. Upstream documentation from another version
must not be assumed to match this build.
[Quickshell node API](https://quickshell.org/docs/v0.2.1/types/Quickshell.Services.Pipewire/PwNode/).

Use native QML bindings for existing controls. For card profiles, ports and
stream routing, a small helper using `pactl --format=json list ...` and explicit
argument arrays fits the existing PipeWire-Pulse stack. Refresh capabilities
after hotplug/profile changes and resolve current IDs before mutations; do not
persist transient numeric IDs. Subscribe to changes while the page is open.
Declare `pulseaudio-utils` in the shared package contract. `wpctl` offers profile
and route setters too, but mixing both backends for the same control would add
unnecessary state coordination.
[pactl reference](https://github.com/pulseaudio/pulseaudio/blob/v17.0/man/pactl.1.xml.in),
[WirePlumber control API](https://pipewire.pages.freedesktop.org/wireplumber/man/wpctl.html).

Retain an explicitly packaged `pavucontrol` advanced fallback until the page
covers the functions users need. Replacing the GNOME fallback is useful even
before every advanced control is native. Do not add meters that keep recording
after the page closes, or rebuild the microphone meter for every monitor.

**Accounts: native management, delegated authentication.** Keep GOA, EDS and
GNOME Keyring. A CybexOS account page can list provider/identity, show whether
attention is needed, toggle calendar integration and remove a local account
through GOA. Removal should explain that other applications sharing the account
are affected; it does not delete the remote Google account.

Build its model using Python `gi.repository.Goa`/Gio and GOA object/property
notifications. Return only display metadata and action results to QML. Do not
read access tokens just to display account status or copy them into shell
configuration. The installed GI namespace exposes account properties through
GObject properties; generated C getter names are not all Python methods.
Use an asynchronous D-Bus Properties.Set with completion/error handling for
changes, and verify it against the installed version.
[GOA interface contract](https://github.com/GNOME/gnome-online-accounts/blob/3.58.1/data/dbus-interfaces.xml).

Two API distinctions change the implementation plan: `Manager.AddAccount`
accepts credentials and account details; it is not a browser-sign-in command.
`EnsureCredentials` checks/refreshes existing credentials and can report expired
authorization; it is not an interactive reconnect dialog.
[AddAccount API](https://gnome.pages.gitlab.gnome.org/gnome-online-accounts/method.Manager.call_add_account.html),
[EnsureCredentials contract](https://github.com/GNOME/gnome-online-accounts/blob/3.58.1/data/dbus-interfaces.xml).

| Authentication option | Assessment |
| --- | --- |
| Launch `gnome-online-accounts-gtk` | Best initial fallback. Fedora 44 packages the standalone GTK frontend with GOA, GTK4 and libadwaita dependencies; it does not list GNOME Settings as a dependency. Validate real Google sign-in/reconnect on Hyprland before switching. |
| Small CybexOS C/GTK4 helper around libgoa-backend | Best later integration if direct Add/Reconnect actions are needed. Host GOA's provider dialogs in a separate process; keep account overview and controls in QML. Requires building and maintaining a small version-sensitive native helper. |
| Implement a separate OAuth/calendar stack | Defer. It adds ownership of OAuth client setup, callbacks, refresh/revocation, credential storage and calendar integration for little immediate benefit. |

Sources: [Fedora 44 standalone frontend](https://packages.fedoraproject.org/pkgs/gnome-online-accounts-gtk/gnome-online-accounts-gtk/fedora-44.html),
[XApp project](https://github.com/xapp-project/gnome-online-accounts-gtk),
[GOA provider API](https://github.com/GNOME/gnome-online-accounts/blob/3.58.1/src/goabackend/goaprovider.h),
[Google desktop OAuth requirements](https://developers.google.com/identity/protocols/oauth2/native-app).

The GOA 3.58.1 provider API takes a `GtkWidget` parent for asynchronous Add,
Refresh and Show operations. A QML window cannot simply be passed as that GTK
parent. `GoaBackend` introspection is unavailable on the inspected host, while
`Goa` introspection is available. Therefore do not plan a pure Python/QML call to
the provider UI. The small compiled helper should own its GTK window, cancellation
and completion; browser/provider UI stays outside Quickshell. This is a researched
architecture, not a validated sign-in prototype.

There is an application-level dependency beyond the shell: GNOME Calendar's
new-calendar and edit-calendar pages call its GNOME Settings launcher for online
accounts. Before removing `gnome-control-center`, adapt those entry points through
a maintained application change, replace the relevant application workflow, or
retain GNOME Settings. Do not install a fake `gnome-control-center` executable
or impersonate GNOME's settings D-Bus service.
[New-calendar entry point](https://github.com/GNOME/gnome-calendar/blob/gnome-50/src/gui/calendar-management/gcal-new-calendar-page.c),
[Existing-account entry point](https://github.com/GNOME/gnome-calendar/blob/gnome-50/src/gui/calendar-management/gcal-edit-calendar-page.c).

**Delivery sequence and acceptance.**

| Milestone | Deliverable | Evidence required |
| --- | --- | --- |
| 1. Shared routing and Sound | Native Sound page, reusable controls, explicit helper dependencies and standalone advanced fallback | Hotplug, Bluetooth profile changes, default and existing-stream routing, XPS filter preservation, microphone lifetime and backend failure tests |
| 2. Network profiles | Native common connection editor, per-profile DNS, checkpoints and advanced editor | DHCP/manual IPv4/IPv6, preservation of unknown settings/secrets, concurrent edits, polkit denial, rollback after lost UI, multiple adapters and unsupported profile handling |
| 3. Online Accounts | Native account overview/actions; standalone GOA frontend for Add/Reconnect | Existing-account compatibility, browser return/cancel, expired authorization, locked keyring/autologin, offline state, GOA restart and calendar enable/remove behavior |
| 4. Direct sign-in integration, if warranted | Small GOA provider-dialog helper | Build/runtime compatibility with target GOA, duplicate-window prevention, cancellation, focus/parenting, service failure and clean process exit |
| 5. Package removal | Remove explicit GNOME Settings dependencies only once remaining launchers are covered | Shell and application launcher audit, clean Fedora dependency resolution, installed package manifest and ISO first-boot verification |

Extend existing audio, network, calendar and Settings tests around behavior and
failure cases. Run the repository checks before deployment. Future live shell
tests must use `tests/lib/quickshell-live` at start/end and leave the service-owned
Quickshell as the sole instance. Source checks cannot qualify OAuth sign-in,
hardware routing or a clean ISO installation; report those separately.

Installed versions inspected: Quickshell
`0.2.1^git20260209.dacfa9d-5.fc44`, NetworkManager `1.56.1`, GOA `3.58.1`,
GNOME Settings `50.4`, WirePlumber `0.5.17`, PulseAudio utilities `17.0`.
These are workstation observations, not a future ISO manifest. Space savings
and the dependency closure after removal remain unmeasured.
