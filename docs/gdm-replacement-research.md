# Replacing GDM while preserving single-password startup

Research date: 2026-09-24. CybexOS baseline: `f89ae3d`.
Implementation: SDDM integration is present in both workstation provisioning
and image packaging. The running workstation has not been switched from GDM.
Source checks pass; full encrypted-install qualification is still pending.
ISO creation and PXE publication were deferred at the user's request. The
disposable builder completed the desktop RPM; it was stopped during image
composition, and its temporary artifacts were removed. No replacement ISO
was completed or booted.
The implementation uses only Fedora packages and the shared configuration
helper described below.

## Validation completed

- `./tests/run`: passed, including static checks, 1,040 unit tests and
  20 Python fixture programs. The active workstation's live QML lifecycle
  check was skipped by the gate; no live shell changes were made.
- `image/check-source`: passed 13 welcome checks, 83 Python tests and four
  Node checks. These include the guest-only login/keyring qualification harness.
- Login policy: 18 tests cover encryption checks, boot-attempt consumption,
  concurrent starts, invalid policy, live-media isolation and safe defaults.
  Both encryption verifiers also recognized the actual encrypted Btrfs host
  through read-only inspection.
- Session launchers: six process scenarios cover normal exit, startup failure
  and a real compositor-child SIGKILL in both deployment paths.
- An isolated GNOME Keyring/Secret Service fixture successfully created, read
  and deleted a synthetic secret. This does not establish LUKS/PAM handoff.
- Full disposable Fedora 44 Ansible test: first install passed (233 tasks OK,
  115 changes); the second pass had 197 tasks OK and **zero changes**. Rendered
  configuration/service assertions passed. Uninstall passed (40 tasks OK,
  18 changes), including exact restoration of the previous display-manager
  alias, PAM/configuration and existing user preferences. SDDM was selected for
  next boot without being started during provisioning.

The VM fixture now seeds valid JSON preferences and optionally reuses
inventory-pinned downloads, checked on both host and guest, to avoid transient
font-server timeouts. No installation or restoration assertions were skipped.
All disposable builder/test artifacts were removed after these checks.

**Still unqualified:** actual encrypted boot, boot-cache/keyring handoff,
graphical greeter recovery and physical hardware behavior. The four-cold-boot
qualification harness covers these software recovery cases when ISO testing
resumes. The running workstation remains on GDM.

## Decision

Moving completely away from GDM is technically viable with Fedora's **SDDM**,
systemd's `pam_systemd_loadkey` and GNOME Keyring's existing PAM module.
This is the most practical candidate for an encrypted, single-user CybexOS
installation. It needs managed configuration and lifecycle handling, but no
new authentication module or fork of a login manager.

Keep the running workstation on GDM until a replacement image passes the
acceptance checks below. Source-level viability is not evidence that our
complete Fedora initramfs, SELinux, installer and desktop path works with SDDM.

Stock Fedora 44 greetd is less suitable for the complete requirement. Its
automatic `initial_session` skips PAM authentication, which prevents the
standard password-loading/keyring authentication sequence from running.
Its ordinary password-login keyring support does not resolve this difference.
[Versioned greetd worker](https://github.com/kennylevinsen/greetd/blob/0.10.3/greetd/src/session/worker.rs),
[initial-session implementation](https://github.com/kennylevinsen/greetd/blob/0.10.3/greetd/src/context.rs).

An upstream module, `pam_fde_boot_pw`, exists specifically for this greetd gap,
but it was not available in the configured Fedora repositories. Adopting it
would add a third-party authentication package for CybexOS to maintain and
qualify. That is a poor trade for this task compared with SDDM's standard path.
[Module documentation](https://git.sr.ht/~kennylevinsen/pam_fde_boot_pw/blob/master/README.md).

## Credential and session flow

The intended sequence is:

1. The owner enters the LUKS passphrase during boot.
2. The boot password agent temporarily caches it in the kernel keyring.
3. SDDM automatically starts the selected owner's CybexOS session.
4. Its PAM authentication stack loads the cached password and supplies it to
   GNOME Keyring; the session stack starts/unlocks the keyring.
5. The existing `hyprland-quickshell` launcher starts the desktop.

Systemd explicitly documents this use with `sddm-autologin`: load the password
with `pam_systemd_loadkey`, then use `pam_gnome_keyring`, with a service
`KeyringMode=inherit` override. The keyring password must match the LUKS
passphrase. The installed systemd-pam 259.9 package provides the module.
[Version-matched systemd documentation](https://github.com/systemd/systemd/blob/v259/man/pam_systemd_loadkey.xml).

Fedora's existing SDDM autologin PAM stack must be extended in the correct
order, retaining its SELinux, account, session and login bookkeeping. Keep
`gnome-keyring` and explicitly retain `gnome-keyring-pam` after removing GDM.
No blank keyring password, plaintext password file or password-processing
shell helper is required by this design.
[Fedora autologin PAM configuration](https://src.fedoraproject.org/rpms/sddm/raw/f44/f/sddm-autologin.pam),
[SDDM authentication implementation](https://github.com/sddm/sddm/blob/v0.21.0/src/helper/backend/PamBackend.cpp).

The existing CybexOS installer initially gives the disk and account the same
password. These passwords can later diverge; the keyring is another separately
encrypted store. Migration must preserve existing keyrings and must never
silently reset them. The current installer promises protected keyrings with
possible first-use unlocking; it does not qualify an end-to-end boot-password
handoff. See [the installer contract](../image/INSTALLER.md).

The standard cache expires after 2.5 minutes. Long boot delays, an unavailable
cache, a different recovery passphrase, a mismatched keyring password or token
unlock without the expected passphrase can therefore require manual keyring
unlock. Preserve that fallback. Do not persist passwords or make the cache
unlimited to conceal these cases. Multiple encrypted volumes also require a
test because the password loader selects the last cached password.
[Password-cache documentation](https://github.com/systemd/systemd/blob/v259/man/systemd-ask-password.xml).

## Once-per-boot policy

| Event | Required result |
| --- | --- |
| Ordinary encrypted cold boot | LUKS unlock, automatic desktop, unlocked keyring when the matching boot password is available |
| Lock or suspend/resume | Existing Hyprlock authentication |
| Logout or compositor crash | Authenticated recovery login |
| Login-manager restart during this boot | No repeated automatic desktop entry |
| Missing keyring password/cache | Protected keyring remains locked until explicitly unlocked |
| Unencrypted installation | Existing normal-login policy remains in force |

SDDM's `Relogin=false` handles session exit while its daemon remains alive.
However, a fresh daemon process treats startup as its first display again.
Thus it needs an additional once-per-boot guard for our stricter restart
policy. This is not a claim that our current GDM setup already guarantees
that restart behavior.
[SDDM display lifecycle](https://github.com/sddm/sddm/blob/v0.21.0/src/daemon/Display.cpp).

SDDM clears that first-display flag **before** attempting autologin, so PAM or
early session failure does not authorize another attempt in the same daemon.
Greeter recovery also relies on Fedora's patch introduced in SDDM 0.21.0-12:
it maps every nonzero session exit or signal to a session error. Unpatched
0.21.0 can mistake launcher exit status 1 for an authentication error and leave
the greeter unavailable. Fedora 44's 0.21.0-13 includes the fix. The disposable
qualification deliberately injects exit status 1 to exercise this case;
source inspection and fixtures do not establish a successful boot result.
[First-attempt ordering](https://github.com/sddm/sddm/blob/v0.21.0/src/daemon/Display.cpp#L255-L269),
[Fedora patch](https://src.fedoraproject.org/rpms/sddm/raw/f44/f/sddm-0.21.0-fix-restart-greeter-when-helper-is-in-a-wrong-state.patch),
[Fedora package and changelog](https://src.fedoraproject.org/rpms/sddm/raw/f44/f/sddm.spec).

Both CybexOS launchers run Hyprland once and stop the desktop user target when
it exits. They deliberately omit `start-hyprland`: its watchdog restarts a
crashed compositor inside the same login session, whereas this policy requires
returning to the password greeter. The watchdog can preserve a prior lock state,
but it does not implement that login policy. Launcher fixtures verify normal
exit, startup failure and a real SIGKILL without a second compositor start.
[Hyprland 0.56.2 watchdog](https://github.com/hyprwm/Hyprland/blob/v0.56.2/start/src/main.cpp).

The shared root-owned `/usr/libexec/cybexos-login-prepare` helper runs before
SDDM. It reads `/etc/cybexos/login.json`, verifies the owner and root encryption
(including every member of a multi-device Btrfs filesystem),
and atomically consumes `/run/cybexos-login/autologin-used` before the first
automatic-login attempt. Subsequent daemon starts disable autologin. The marker
survives service stop/restart and disappears at reboot. Failed early attempts
also consume the marker. Concurrent preparation is serialized with a file lock.
A fresh password greeter defaults to the CybexOS session; an existing SDDM
session choice is preserved. This helper never reads or handles passwords.
The live ISO exception requires
both its boot command line and a root-owned live-account marker.

SDDM 0.21 does not accept a `--config` file option. Its managed configuration
uses the highest-precedence `/etc/sddm.conf`, written atomically as a regular
file with restored SELinux labeling. Preparation first disables stale autologin
from a previous boot. A file under `/run` alone would not be read. [Configuration reader](https://github.com/sddm/sddm/blob/v0.21.0/src/common/ConfigReader.cpp).

## Integration and acceptance

Fedora 44 provides SDDM 0.21.0-13 and a generic Wayland greeter backend using
Weston. Use a packaged backend first. A custom Hyprland greeter/theme would be
additional work without improving ordinary automatic startup.
[Fedora SDDM](https://packages.fedoraproject.org/pkgs/sddm/sddm/fedora-44.html),
[generic Wayland backend](https://packages.fedoraproject.org/pkgs/sddm/sddm-wayland-generic/fedora-44.html).

SDDM is Fedora-packaged, but should not be described as Fedora KDE's guaranteed
long-term default: Fedora documents a transition to Plasma Login Manager.
Package availability and upstream maintenance should be rechecked when the
replacement is qualified. [Fedora change](https://fedoraproject.org/wiki/Changes/PlasmaLoginManager).

Workstation provisioning installs SDDM and the generic Weston greeter backend,
then selects SDDM for the next boot without restarting the current display
manager. The new boolean `desktop_autologin` setting accepts saved
`gdm_autologin` answers as a compatibility alias; an explicit new value wins.
Provisioning backs up the previous display-manager alias, PAM and managed
configuration once. Uninstall restores them without interrupting the session.
Existing GDM packages remain available for recovery; new images do not request
GDM. The existing session launcher and Hyprlock remain in use.

The desktop RPM installs the same helper, PAM template and systemd drop-in.
Its post-transaction step applies the PAM template while preserving the original
SDDM-owned file. Fedora retains ownership of that PAM path. The service uses
`KeyringMode=inherit`; the authentication stack loads the systemd boot key before
calling GNOME Keyring, preserving Fedora account/SELinux/session bookkeeping.

Qualify a disposable encrypted installation before changing the default:

- Fresh boot creates/unlocks a protected login keyring without a second prompt;
  existing keyrings and a synthetic saved secret survive repeated boots.
- Normal logout, Hyprland crash, SDDM crash/restart and early startup failure
  cannot produce another unprotected automatic session.
- Missing/expired cache, password mismatch and recovery-key boot retain a
  working manual unlock path, without resetting the keyring.
- Suspend/resume, alternate keyboard layouts, monitor/GPU behavior, portals
  and account access work with SELinux enforcing.
- Both live-media startup and installed-system behavior work, including
  unencrypted installs and rollback to the previous login manager.

Removing GDM does not itself remove every GNOME package. Calendar still calls
GNOME Settings, which still pulls in settings-daemon. The former explicit
settings-daemon dependency and GNOME idle-power writes have been removed. Retain GOA, Evolution Data
Server and GNOME Keyring for the native account/calendar features. Measure the
replacement image's actual dependency and size reduction before claiming a
performance or footprint improvement.

## Operation and recovery

For checkout installations, configure `desktop_autologin` through the saved
installer configuration. Provisioning records the selected owner and choice in
`/etc/cybexos/login.json`; the helper makes the final eligibility decision at
boot. Image installations receive this policy from the confirmed installation
plan. Turning the policy off leaves normal password login available.

The nonsecret decision can be inspected with:

```bash
sudo cat /run/cybexos-login/status.json
systemctl show sddm.service -p KeyringMode
sudo journalctl -b -u sddm.service
```

Do not reset an existing keyring to resolve an unlock prompt. Its password may
differ from the disk/account password, or the brief boot cache may be missing.
Ordinary SDDM password login uses Fedora's existing PAM configuration, and
applications retain their normal keyring-unlock prompt.

If a workstation migration needs recovery, log into a text console and select
the retained GDM service for the next boot with
`sudo systemctl enable --force gdm.service`. This requires the retained GDM
package; fresh SDDM-only images do not include it. The one-time login backups
are under `/var/lib/cybexos/backups/login/`. A full CybexOS uninstall restores
those original files and the original display-manager alias. Selecting a
next-boot manager does not terminate the running graphical session.
