# Installer-only ISO (tty1 kiosk) — 2026-10-24

This records the change from a live desktop ISO to a medium that boots straight
into the installer. The source was frozen before this result record; this
document is not part of the image's source identity. Unrelated workspace
changes were preserved. No workstation deployment, physical disk operation,
host reboot or release publication was performed.

## Exact testing image

- Filename: `nerdos-1.0.0-beta.2-20261024-installer-kiosk-6421fc1ac80f.iso`.
- Beast path: `/data/pxe/iso/nerdos-1.0.0-beta.2-20261024-installer-kiosk-6421fc1ac80f.iso`.
- Size: 7,120,576,512 bytes (6.63 GiB); companion checksum: 128 bytes.
- SHA-256: `219b6af61f7ecce186e13bed2dc11f6dc89c332acc53610738e32b33b85ad186`.
- Source NAR: `sha256-ZCH8GsgPGf+GiW+62mT+dIJqt5AwKEIKZZZI9/uRWmg=`.
- Frozen source: `/nix/store/y0cgkqsp7m73s3zfcgyfly03fbha6yyg-source`.
- Source revision: `uncommitted`; version: `1.0.0-beta.2`; NixOS: 26.05.
- Nixpkgs: `da6dc0e7b26060f2f71ce3ef7088fb56ee44fa36`; medium kernel 7.2.11;
  tzdata 2026c; Slint 1.18.1 built with rustc 1.95.0.
- [ISO download](http://10.10.0.7:16000/iso/nerdos-1.0.0-beta.2-20261024-installer-kiosk-6421fc1ac80f.iso)
  and [checksum](http://10.10.0.7:16000/iso/nerdos-1.0.0-beta.2-20261024-installer-kiosk-6421fc1ac80f.iso.sha256).

This is an unreleased development image. The installer requires explicit
consent to use its exact bundled test source; production authentication and the
separate signed-release prerequisites are unchanged.

## Resulting behavior

The boot menu offers **Install NerdOS 1.0.0-beta.2**, a safe-graphics entry
(`nomodeset`, firmware framebuffer), a text-mode entry and verbose boot
diagnostics. The live NVIDIA entry and its second kernel are gone: the screen
draws with the CPU through any KMS driver or simpledrm, and the installed system
still selects its own NVIDIA driver.

No desktop session starts. tty1 shows `nerdos-installer`, a Slint software
renderer drawing directly to KMS/DRM in a logind seat session as the
unprivileged `nerdos-installer` user. The medium has no live account,
compositor, display manager, sudo or SSH. The root `nerdos-installerd` service
keeps the draft and drives the existing worker (`nerdos-install --json-ui`),
whose validation, disk-identity recheck and erase guard are shared with the
terminal and automated installers. The screen owns no state; it is restarted
after a keyboard-layout change and resumes from the service's next snapshot.
tty2 is a root recovery shell; the menu also opens the text installer.

The visible flow is welcome/system check, **Disk**, **You**, **Review**,
installation progress and completion. Advanced choices are on demand:
applications, the NVIDIA driver choice, serial numbers, Wi-Fi, keyboard,
language, installation details and saving the log to USB. The username field
only accepts `[a-z][a-z0-9-]`, folding capitals and accents with a visible note;
the optional full name becomes the account description. Reserved names come
from the evaluated default system. Passwords are entered twice. The computer
name follows the username until edited. The UI is English-only.

Time zones come from tzdata's `zone.tab`, countries and backward links, with
search by city, country, alias, word or offset, a map with day/night shading,
the live local time and the next clock change from the TZif data. The zone is
detected from the connection unless chosen manually; a manual choice is never
overridden.

The medium carries the free part of the default desktop as an offline payload
(store paths of a representative default installation without its per-machine
initrd); unfree groups and NVIDIA drivers still download. The image is
6.63 GiB, against 9.54 GiB for the previous live-desktop GUI image.

## Build and source checks

The exact frozen source passed the ISO build and the Nix `parity`, `lifecycle`,
`system`, `product`, `nvidia-evaluation` and `xps-system` checks. The lifecycle
check passed 547 unit tests, including the installer worker and the new
installer-service tests (review, re-review and token-bound install without a
password in any snapshot or saved draft; confirmation and reserved names;
keyboard restart; prompt shutdown with a connected screen; idle-worker
cancellation; attached-screen reporting), and 21 system-settings tests. The
screen's 19 Rust unit tests (name filter, time zones, map, zoom) passed in its
Nix build.

`checks.vm` failed in the Beast's sandboxed build. Its new local Software step
(staging `hello`, part of separate uncommitted Software/cleanup work in this
checkout) evaluates the VM's exact system derivation, which depends directly on
`stdenv-linux`. Neither the test node's registered closure (2,360 paths) nor the
prebuilt candidate or `hello` contains it, so Nix in the VM planned 2,219
bootstrap derivations and failed without network access. Reproducing the
in-VM derivation on the host gave the identical path. The installer change did
not alter that test or its closure; the step depends on the VM reaching a
binary cache. That check's earlier pass was recorded in a different environment.

Image/source parity passed for the completed ISO: 39 checks covering the
bundled source and input sources, the installer screen binary, service and
network helper, the offline payload's system path and `/etc`, release and
installer files, the desktop/updater packages and the boot profiles.

## Actual installation qualification

Both runs used the exact ISO and source identity above, UEFI/KVM, 12 GiB RAM,
four CPUs, NAT networking, an 80 GiB disposable disk and the standard
application selection. They ran the frozen source's
`scripts/qualify-installations --interactive`, which drives the real tty1
screen with QMP keyboard and absolute-pointer input. The serial console only
observes the service's snapshots.

| Check | Unencrypted install | Encrypted install |
| --- | --- | --- |
| Medium runs only the installer screen and service; no live account, compositor or display manager | Passed | Passed |
| Development consent by Enter; only disk preselected | Passed | Passed |
| Encryption switch by pointer click | Passed, turned off | Left on (default) |
| Typed `Nerd QA` and `NerdQA`; service received `nerdqa`, `nerdqa-nerdos` | Passed | Passed |
| Both passwords typed; reviewed plan matched the screen | Passed | Passed |
| Erase click to completion (capture times, 20 s polling) | Passed, 4 min 44 s | Passed, 5 min 4 s |
| Installed boot, serial password login, source identity | Passed | Passed |
| Runtime encryption state, desktop configuration and health, SDDM login | Passed, plain root | Passed, LUKS2 root |
| Two password changes, reboots and keyring unlock | Passed | Passed, new disk key accepted and old key rejected |
| Staged updater failures, interruption, apply, trial boot, confirmation, rollback | Not run | Passed |

The time zone was detected from the connection as `Europe/Amsterdam`. The real
welcome, disk, account, review, progress, completion and installed-desktop
captures were inspected.

The encrypted system additionally passed the actual staged updater:

- Independent upstream discovery and complete staging passed while the
  unpublished NerdOS endpoint accurately reported HTTP 404. Nixpkgs was already
  current at the revision above, so that candidate did not change packages.
- A personal baseline was staged, applied, trial booted, authenticated and
  confirmed. Deliberate evaluation and build failures retained the active
  system and working lock. Killing a real staging worker during a build, then
  rebooting, produced the expected interrupted state and a healthy desktop.
- A local candidate was staged, applied, trial booted, authenticated and
  confirmed, then rolled back through the real updater. Personal files,
  service state and preferences passed preservation checks throughout; the
  candidate-only file disappeared after rollback.

## Findings from real tests

These were found by booting actual images and fixed before the image above:

- Boot-time units that conflicted with `getty@tty1` never started. Wants-only
  conflicts inside the boot transaction make systemd drop one side before any
  kernel command-line condition is checked. Boot-time units no longer conflict;
  only the on-demand text-installer switch does.
- Pointer clicks were ignored where a `FocusScope` was declared above a
  `TouchArea`. Buttons, switches and picks now declare their focus scope first.
- In a 6 GiB VM the default out-of-memory policy stopped the whole service and
  reset the screen. The service now continues so the worker's failure is shown.
  A stop also closes connected screens before waiting for the server.
- The qualification harness matched its own shell with `pgrep -f quickshell`,
  and its failure diagnostics needed Python, which the medium no longer has.
- The harness restarts the service (to add a serial console to the QA system)
  and then pressed Enter before the screen had reconnected; the key reached no
  page. The screen now identifies itself in its `hello`, snapshots report
  attached `screens`, and the harness waits for one.
- One earlier encrypted lifecycle run failed upstream discovery on the GitHub
  API's unauthenticated rate limit for the Beast's shared address. This is an
  external limit and reports as unreachable, not as an update.

Two earlier frozen sources (NARs `sha256-PhyJnCs…` and `sha256-4dOCnrk…`) were
built and partially qualified while fixing the last three items; neither image
was published.

Development observations on earlier iteration builds, not repeated on the image
above: a German keyboard choice restarted the screen with
`XKB_DEFAULT_LAYOUT=de` (physical Z/Y typed `yz`), the menu's text installer and
recovery shell took over tty1/tty2, and a BIOS boot showed the UEFI-required
stop screen with a restart action.

## Delivery and cleanup

The completed ISO and checksum were verified in task staging on the Beast's
root filesystem and again after moving them into the served ISO tree, with
mode 0644. A full HTTP download matched the SHA-256 above, and the companion
checksum was downloadable. iVentoy refresh returned `result: success`; its
status moved from `refreshing` to `running`. The image tree lists the new
filename as image 8 beside the four existing NerdOS images, which were
preserved. `iventoy.service` was active; no restart was needed.

Only the requested ISO (7,120,576,512 bytes) and checksum (128 bytes) are
retained from this task in `/data/pxe/iso`. The task's staging directory
(sources, crate build directory, VM disks, extracted image payloads, captures
and logs) was removed, along with four task-built Nix-store ISO outputs and
the iteration VM runner (27.2 GiB). Normal shared Nix build dependencies remain
cached. No task VMs, test processes or mounts remain on the Beast or the
development host, and neither has user-image output under
`~/.local/share/nerdos/images/`.

## Not covered

Physical AMD/Intel/NVIDIA display output, touchscreens, real HiDPI panels and
display zoom, an unmodified LAN PXE boot of this image, Wi-Fi joining, USB log
saving, non-US keyboard layouts and the text installer on this exact image,
signed production-channel updates and Secure Boot remain outside these checks.
The documented XPS camera and hardware/security release blockers remain in
force.
