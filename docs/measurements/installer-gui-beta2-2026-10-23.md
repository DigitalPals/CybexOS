# Graphical installer / beta.2 — 2026-10-23

This records the fresh graphical installer, shared account/encryption password,
desktop defaults and unattended live-session fix. The source was frozen before
this result record; this document is not part of the image's source identity.
Unrelated workspace changes were preserved. No workstation deployment, physical
disk operation, host reboot or release publication was performed.

## Exact testing image

- Filename: `nerdos-1.0.0-beta.2-20261023-gui-9bc2f93e7e83.iso`.
- Beast path: `/data/pxe/iso/nerdos-1.0.0-beta.2-20261023-gui-9bc2f93e7e83.iso`.
- Size: 10,241,574,912 bytes (9.54 GiB); companion checksum: 116 bytes.
- SHA-256: `c09fb3e222bbc1fea9218fe8ca0a89281f2de4caa796b3b9abd066660be299dc`.
- Source NAR: `sha256-m8L5Pn6DapNM6mYXdC5Bz4kI0jkJ/sJqT6aH/2vFlA4=`.
- Frozen source: `/nix/store/h02d8k5g9cnq64cihwj0m6jyrs7pqwb8-nerdos-gui-source`.
- Source revision: `uncommitted`; version: `1.0.0-beta.2`; NixOS: 26.05.
- Nixpkgs: `da6dc0e7b26060f2f71ce3ef7088fb56ee44fa36`.
- [ISO download](http://10.10.0.7:16000/iso/nerdos-1.0.0-beta.2-20261023-gui-9bc2f93e7e83.iso)
  and [checksum](http://10.10.0.7:16000/iso/nerdos-1.0.0-beta.2-20261023-gui-9bc2f93e7e83.iso.sha256).

This is an unreleased development image. The native welcome requires explicit
consent to use its exact bundled test source; production authentication and the
separate signed-release prerequisites are unchanged.

## Resulting behavior

The live desktop opens the native PySide6/Qt Quick installer. One setup page
collects disk, username and one password; computer name and regional defaults
are editable, with optional settings collapsed. Only one available disk is
preselected; multiple disks require a choice. The review names the disk and its
contents. **Erase disk & install** is the final destructive confirmation,
without serial-number or ERASE typing. Its root worker binds confirmation to
the reviewed plan and rechecks disk identity before writing. Six actual stages
report progress; completion follows unmounting and encryption cleanup. Restart
is explicit. GUI, terminal and automated installation share the same engine.

The shared password policy accepts at least eight characters without character
class rules or normalization. One private input sets both the account and
LUKS2 password. First desktop login remains password-based. Settings changes
both credentials while retaining the old disk key until the account commits;
its interruption record contains slot identities, never passwords. The ordinary
password/PAM path also changes the login keyring, using the authenticated user's
runtime socket. PAM reports keyring failures so a partially committed change
retains the matching disk key and explains the integration failure.

Model Usage is enabled by default. Hermes Agent, Remote Server, T3 Code, GitHub
and Fusebox start hidden, with explicit personal widget choices preserved.
LAN discovery is enabled through Avahi and the existing firewall gates. Bibata
Modern Classic, size 24, is packaged and selected for the compositor, GTK,
XWayland, system session environment and SDDM.

The ISO disables hypridle and the session-lock service, ignores automatic
logind idle/lid actions, guards the lock shortcut and removes live Lock controls.
It cannot automatically lock or suspend an unattended installation. Installed
systems retain their ordinary idle locking, suspend and password fallback.

## Build and source checks

The exact frozen source passed the ISO build and the Nix lifecycle, shared
installation parity, full product, XPS system and NVIDIA evaluation checks.
The lifecycle check passed 508 unit tests, its standalone helper checks, and
21 system-settings tests. Image/source parity passed for the completed ISO,
including the bundled source, input sources, native frontend/QML, desktop,
updater and kernel/initrd/system boot profiles.

The Quickshell suite passed 1,360 tests with 17 skipped and no failures (1,377
total). The native Qt/QML smoke check covered disk selection/reordering,
multiple-disk choice, input validation, review state and the close guard. Those
UI payloads did not change in the final credential-context correction.
Whitespace and shell syntax checks also passed.

## Actual installation and lifecycle qualification

Both runs passed using the exact ISO and source identity above, UEFI/KVM,
12 GiB RAM, four CPUs, NAT networking and an 80 GiB disposable disk. They drove
the packaged native GUI and real root installer, using the standard application
selection and an eight-character disposable QA password.

| Check | Unencrypted install | Encrypted install |
| --- | --- | --- |
| Invalid username and short-password errors; review/back; disk untouched until confirmation | Passed | Passed |
| Actual GUI installation and source identity on the installed machine | Passed | Passed |
| Installed boot, console password login and SDDM password login | Passed | Passed |
| Runtime encryption state and desktop configuration/health | Passed, plain root | Passed, LUKS2 root |
| Two account password changes, reboots and automatic login-keyring unlock | Passed | Passed, new disk key accepted and old key rejected |
| Bibata/session defaults, LAN discovery and enabled firewall | Passed | Passed |
| Live Lock shortcut leaves no locker or idle/lock service running | Passed | Passed |
| Untouched live desktop beyond the previous five-minute lock timeout | Passed, 310 seconds | Not repeated in this case |

Managed desktop health checked the sole service-owned Quickshell process and
the current invocation's journal. The real welcome and installation progress
were also visually inspected. No source-tree menubar was started beside it.

The encrypted system additionally passed actual supervised upstream staging and
local deployment, with these results:

- Independent upstream discovery and complete staging/build/validation passed
  while the unpublished NerdOS endpoint accurately reported HTTP 404. Nixpkgs
  was already current at the revision above, so the candidate did not change
  packages and was not applied. This does not qualify a changed upstream update.
- Personal baseline `5f85621f64704e71968f424efdb3bb33` was staged, applied, trial
  booted, authenticated and confirmed.
- Deliberate Nix evaluation and build failures retained the active system and
  working lock. Killing a real staging worker during a build, then rebooting,
  produced the expected interrupted state and a healthy usable desktop.
- Local candidate `23ac4dbfcb894045ba2964145e8a91c0` was staged, applied, trial
  booted, authenticated and confirmed, then rolled back through the real updater.
- Personal packages, service/state, VPN declaration and private key, widget
  plugin/settings/data, preferences and local modules passed preservation checks
  through failures, recovery, application and rollback. The candidate-only file
  disappeared after rollback and no pending transaction remained.

The plain case stops after installation and password round trips; updater
application was exercised on the encrypted case. Neither case substitutes
fixture status files, candidate systems or a mocked installer/updater.

## Findings from real installation tests

The first encrypted installation reached bootloader installation and failed
copying the full initrd into the previous 1 GiB ESP. The default product initrd
measured 1,457,957,958 bytes, its kernel 13,578,752 bytes, and the product closure
26,350,228,896 bytes. Early GPU drivers and firmware were retained. The shared
module now defines a 16 GiB ESP and a 64 GiB minimum disk; the installer consumes
that exported layout contract. The ESP accommodates ten retained generations
and copying the next generation before cleanup. The ten-generation boot limit
was preserved.

A subsequent image completed both GUI installs and password-based desktop
logins, but failed the post-password-change keyring check after reboot.
The password PAM stack needed to continue after `pam_unix`, and the elevated
worker needed the user's `XDG_RUNTIME_DIR`/keyring control socket. Both are now
explicit; keyring errors propagate through PAM. The qualification tool now
bounds secret-service waits and records PAM/keyring diagnostics and partial
password-change milestones on failure.

## Delivery and cleanup

The completed ISO and checksum were verified in task staging and again after
moving them into the Beast's served ISO tree, with mode 0644. A full HTTP
download matched the SHA-256 above, and the companion checksum was downloadable.
iVentoy refresh returned `result: success`; its status moved from `refreshing`
to `running`. The final image tree contained the new filename as image 5 and
the existing graphics-testing image as image 4. `iventoy.service` was active;
no service restart was needed.

Only the requested new ISO (10,241,574,912 bytes) and checksum (116 bytes) are
retained from this task in `/data/pxe/iso`, for physical testing. The existing
graphics-testing ISO/checksum pair was preserved. The served directory uses
19 GiB. All task VM disks/control directories, extracted payloads, staging/source
copies, captures and temporary logs were removed, along with five task-created
Nix-store ISO outputs. Normal shared Nix build dependencies remain cached.
Both local and Beast task output directories were verified absent, with no
remaining task VMs/test processes or mounts, and neither host had leftover
user-image output under `~/.local/share/nerdos/images/`.

Physical AMD/Intel/NVIDIA operation, X1 graphics recovery, an unmodified LAN PXE
boot, signed production-channel updates and Secure Boot remain outside these
VM checks. The documented XPS camera and hardware/security release blockers
remain in force; a complete hardware package build does not qualify hardware.
