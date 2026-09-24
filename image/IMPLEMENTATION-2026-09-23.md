# ISO experience implementation — 2026-09-23

Worktree: `CybexOS-wt/iso-experience-20260923`, beside the main checkout

Branch: `feat/iso-experience-20260923`

Base: `3c585cd`

This implements the source changes from the [ISO audit](AUDIT-2026-09-23.md).
The implementation stayed in this worktree while another agent used `main`.
At the user's request, no ISO was created or tested. No build VM, installer,
PXE operation, signed release or host desktop deployment was run.

## Delivered

| Audit suggestion | Implementation |
| --- | --- |
| Share desktop defaults | `assets/desktop-contract.json` supplies wallpaper, helper and seeding contracts. Workstation and image share wallpaper assets, Bluetooth defaults, boot artwork, sysctl and firewall sources. Private plugins/monitor rules/credentials are excluded. T3's runtime callback path and optional private portal binding are corrected. |
| Brand boot and installer | GRUB/Syslinux appearance, existing Cybex Plymouth animation/unlock artwork, welcome and Cockpit installer share the dark/warm palette. Boot/media-check/recovery commands remain available. Target initramfs is regenerated after live configuration removal. |
| Improve first-login time | Essential desktop files precede Hyprland; large offline applications seed in the background with progress/retry. Installed users seed before reboot. Atomic copies preserve existing personal data and defer editor/tool activation until dependencies exist. |
| Minimal encrypted installation | Three pages: setup, disk, review. Automatic encrypted Btrfs is default; one initial account/LUKS password, locked root, encrypted-root verification before autologin, normal login when encryption is disabled. Keyboard is applied before password entry. Anaconda handles validation and disk writes; advanced storage retains the stock UI. |
| Build feedback/recovery | Resource/dependency preflight, Fedora-compatible seed tools, unique build IDs, phases/timings, revision/configuration provenance, verified download cache, xz/zstd switch, checksummed atomic artifact delivery and interruption cleanup. Brave repository omission fixed. |
| Qualification/PXE tools | Explicit opt-in live/install harnesses, portable OVMF discovery, isolated disk identity, offline guest networking, live and installed checks, shared Quickshell lifecycle helper, default artifact cleanup. PXE publication preserves existing files and verifies checksum, refresh, image list, PXE and service status. |
| Desktop RPM updates | Source/build-derived version, migration epoch, fingerprint-pinned public update channel, local signed-repository preparation, independent signature verification and rejection of packages containing a different/disabled channel. Actual URL, signing key and hosting remain operator inputs. |

See [README.md](README.md) for commands and [INSTALLER.md](INSTALLER.md) for
the Fedora 44 API contract, state handling and target finalization.

## Review findings fixed

- Correct `brave-browser.repo` policy selection and explicit missing-file failure.
- Wait for Anaconda startup; use its supplied browser URL/port and correct
  Fedora 44 password-hashing API.
- Serialize confirmation and installation, use a durable worker, avoid
  status/worker state races, invalidate old plans, and reject changed disks.
- Restore the shared firewall zone after Anaconda's default SSH exception;
  regenerate installed initramfs after removing live-only settings.
- Keep boot-keyboard conversion and live keyboard application ahead of
  password entry. Changing the layout clears password fields and review state.
- Defer LazyVim/toolchain activation during background copying, and keep
  incomplete files from becoming live defaults.
- Accept prerelease RPM filenames, reject symlinked checksum manifests,
  and atomically refuse even a concurrently created empty output directory.
- Verify actual RPM signatures rather than accepting digest-only success;
  check embedded update-channel digests before signing a desktop release.
- Require checksum sidecars for VM input, use the actual shared Quickshell
  audit helper, and register signal cleanup in imported entry points.

## Source-only verification

- `image/check-source`: **13 existing image/Qt tests + 61 Python image-tooling,
  parity, installer and release tests + 4 installer state tests passed**.
- Headless browser fixture: real frontend with fake Cockpit transport; three
  pages, keyboard changes, encryption default, explicit erase confirmation,
  password clearing, progress/reload recovery and 390px layout passed.
- `tests/run`: repository syntax/lint, **895 JavaScript tests**, QML helpers,
  configuration integration, policy, application/helper and existing recovery
  fixtures. The live Quickshell lifecycle test is skipped when a managed
  desktop is active; no second shell instance was launched.
- Fedora 44 Kickstart parsing: expanded compose (139 native application
  selections plus three Flatpaks) and target post-install scripts passed.
- Independent source review checked Anaconda 44.30/Web UI 68 interfaces and
  installation sequence. iVentoy 1.0.41 response shapes were inspected
  statically from its official release; no iVentoy service was contacted.
- Whitespace checks passed. Optional `rpmspec --parse` could not run because
  this host lacks `rpmspec`; no package tools were installed on the host.

Qt fixtures used an isolated PySide6 6.11.2 environment, not a composed Fedora
image. The browser test used installed Chromium/Brave with temporary Playwright
Core 1.63.0. Task-created dependencies, screenshots and scratch files are
removed after verification; no ISO, VM disk or large diagnostic output is kept.

## What these checks do not establish

A newly built ISO still needs real Fedora/Cockpit authorization, actual DBus
tasks, BIOS/UEFI boot, offline installation, encrypted/unencrypted target boot,
autologin, screen lock, sudo, non-US/dead-key input and keyring behavior verified.
Physical GPU, Secure Boot, suspend/resume and network-zone behavior need their
own hardware coverage. No performance numbers or successful current-ISO boot
claim can be inferred from the fixtures.

The qualification harness remains unqualified too: initial SSH access and LUKS
unlock use bounded graphical key injection without prompt recognition. A real
VM run is needed to establish timing reliability. Its failures cannot count as
a successful qualification report.

The signed repository tool is implemented but no production channel exists
without the operator's key and URL. Default builds keep desktop updates disabled.
The shared password is initial only; later account and disk password changes
are independent. The keyring remains protected and may request unlock after
automatic login. xz stays default until an authorized zstd size/startup comparison.
