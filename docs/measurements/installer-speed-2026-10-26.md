# Installer performance and Omarchy research — 2026-10-26

## What Omarchy does

The current upstream Omarchy ISO installer writes a prebuilt Arch + Omarchy
btrfs filesystem image rather than installing its approximately 940 common
packages individually. The image is compressed with zstd; a parallel writer
decodes independent frames, with `zstdcat | dd` as a fallback. The installer
assigns a new filesystem identity, expands the filesystem, installs the
machine-specific package delta from an offline mirror, then configures the
machine and its owner. Image and mirror verification start while the user is
answering the configuration questions. Per-machine secrets and identities are
created during installation.

Upstream advertises under one minute on the fastest machines and up to five
minutes on older computers. Those are upstream claims, not measurements made
by this task. Omarchy itself was researched, not installed or benchmarked here.

Sources inspected at exact upstream revision
`b851dfa665ead6520f799cc704572a7c5b39587e`:

- [ISO README, method and advertised installation time](https://github.com/omacom/omarchy-iso/blob/b851dfa665ead6520f799cc704572a7c5b39587e/README.md).
- [Root-image builder](https://github.com/omacom/omarchy-iso/blob/b851dfa665ead6520f799cc704572a7c5b39587e/builder/build-root-image.sh).
- [Installation phases, verification, image placement and machine setup](https://github.com/omacom/omarchy-iso/blob/b851dfa665ead6520f799cc704572a7c5b39587e/configs/airootfs/usr/share/omarchy-iso/orchestrator/phases_impl.py).

## Applying the useful part to NixOS

CybexOS already carries a prebuilt free desktop closure on its ISO. Its fresh
installer invokes `nixos-install`, which builds the selected configuration in
the target store and offers the live store as a substituter. However, Nix
recipes using `runCommandLocal` set `allowSubstitutes=false`. That prevents the
target build from substituting those outputs even when the medium already
contains their exact bytes. The beta.5 baseline rebuilt 851 derivations,
including 290 Fish completion outputs, and copied 1,757 paths locally.

The installer now evaluates the reviewed machine's system derivation, queries
its dependencies with `--include-outputs`, and explicitly copies available
outputs into the fresh target store. An explicit Nix copy can transfer these
outputs regardless of their substitution policy. The normal `nixos-install`
then reuses them and builds the remaining machine-specific configuration.

The graph comes from the actual choices, rather than the entire medium, so
disabled application groups are not copied solely because they are bundled.
Available build dependencies and input sources may also be copied; these are
Nix store contents, not applications enabled in the installed system. Nix
performs the transfer and content checks. The signature exemption is confined
to the trusted live store → freshly formatted local store transfer, matching
the installer's existing source-copy policy. Remote caches retain signature
checks. Passwords remain outside source and store paths.

This applies Omarchy's central idea—reuse work completed while building the
ISO—through Nix's own store. It retains generated hardware configuration,
machine-owned locks, the selected application groups, the normal installer and
the staged updater. It does not clone account state or replace per-machine
NixOS configuration with a generic installed root image. Optional applications
absent from the ISO still need their normal downloads.

## Validation method

Both images are tested with the real tty1 Slint installer, using QMP keyboard
and pointer input, development consent and the final erase click. The default
case uses LUKS2 encryption and every default application group. VMs have four
vCPUs, 12 GiB RAM, an 80 GiB disposable virtio disk, UEFI firmware, virtio
graphics and QEMU user networking on the Beast's Threadripper 9970X. The host
and existing disks are not installation targets.

Stage observations are sampled every 20 seconds. Before/after times therefore
have polling uncertainty and are single-run observations, not a statistical
hardware benchmark. The beta.5 baseline ran first; host page caches and
external download servers were not controlled. The new daemon also preserves
the worker's elapsed time in the completion status, where beta.5 reset it to
zero.

The CI controller does not offer a CybexOS job. Host-only qualification uses
`agent-resource` supervised leases and CI capacity reservations. VM disks and
other disposable files live in each lease's managed workspace.

A focused real Nix regression also built an output with
`allowSubstitutes=false`, seeded a new target store, checked its contents, and
successfully used it with `--offline --max-jobs 0`. The installer, daemon,
network and qualification regression suites passed 106 Python tests.

## Measured installation result

| Encrypted default installation | beta.5 | beta.6 |
| --- | ---: | ---: |
| Observed installation time | 263.192 s (4m23s) | 182.045 s (3m02s) |
| Worker completion time | unavailable (reset to zero) | 168 s (2m48s) |
| Derivations actually built | 851 | 375 |
| Fish completion derivations built | 290 | 192 |
| System unit derivations built | 201 | 52 |
| Planned download | 839.1 MiB | 838.9 MiB |
| ISO size | 7,120,576,512 bytes | 7,120,576,512 bytes |

The observed default installation was 81.147 seconds, or 30.8%, shorter; actual
rebuilds fell 55.9%. The beta.6 installation reused 3,376 prebuilt paths in
about 68.8 seconds. These transfer seconds are included in the installation
time. The improvement did not increase the ISO size.

The separate beta.6 unencrypted minimal-selection run completed in 106 worker
seconds (121.441 observed seconds). It reused 3,292 paths in 56.176 seconds and
built 268 derivations. This selection disables developer, proprietary, Steam,
Docker and connected-widget groups; other shared defaults remain enabled.
There is no beta.5 minimal baseline, so it is not a second before/after result.

Comparable observed times above run from the first `installing` observation
to the first `complete` observation. Their timestamps were captured before
copying diagnostic logs out of the guest. The qualification driver's separate
`observedElapsedSeconds` field also includes that diagnostic transfer; it is
retained as evidence but is not used for this comparison. Screenshots, when
enabled, also fall inside that field's interval. The beta.6 worker timer
measures the interval from the confirmed installation request to completion
without polling or diagnostic overhead.

The default selection still downloads approximately 839 MiB of optional
packages absent from the free payload. The remaining build count includes
machine-specific configuration and packages absent from that payload. A
sub-minute installation is not established by these measurements. Further
work should measure cold physical USB/PXE reads and network downloads before
expanding the payload; copying a larger image can trade one bottleneck for
another.

## Exact beta.6 artifact

- Served filename: `cybexos-1.0.0-beta.6.iso`.
- SHA-256: `74d07ff07ed9d05498801ce957bf837bce7ce2b16b41aeca9dfa934c1cb39d22`.
- Frozen source: `/nix/store/19fk3kkaxm7r9cj2mdm78zz8idz33gx4-source`.
- Source NAR: `sha256-472b7XdZ/7605zmLSqCBaaEeKwTT/DKudiGaW3aXxuI=`.
- Embedded revision: `uncommitted`; this is a development testing image.

The image build, source-parity check and installation/runtime qualification
use that same immutable source. This results record and the wording correction
from “completion screen” to “completion status” in `docs/installation.md` were
written after the snapshot. Executable changes and `VERSION` match the tested
source.

## Checks actually exercised

- The beta.5 baseline passed the native graphical encrypted default install,
  installed UEFI boot, desktop health, exact source identity, welcome guide,
  keyboard shortcuts, disk/keyring unlock and two password-change/reboot cycles.
  Its updater lifecycle was not run.
- Beta.6 passed those same encrypted default-install checks. Its actual staged
  updater also passed evaluation failure, build failure, killed-worker recovery,
  local apply, GRUB trial boot, unconfirmed-trial fallback, authenticated desktop
  confirmation and rollback. Personal module, package, service, VPN key, widget,
  settings and state survived those transactions.
- The separate unencrypted minimal-selection installation passed installed
  UEFI boot, password desktop login, source identity, welcome, keyboard
  shortcuts, desktop health and two password-change/reboot cycles with keyring
  unlock. It did not run a second updater lifecycle.
- Independent upstream discovery and a complete staged upstream build passed
  while the CybexOS endpoint returned HTTP 404. The candidate changed Nixpkgs
  from `da6dc0e7b26060f2f71ce3ef7088fb56ee44fa36` to
  `1f607aa79b6356ed45d3cd3c8079c196e79efa2c`, preserving the exact CybexOS input
  and working lock. That upstream candidate was built and validated but not
  applied; local configuration candidates exercised application and rollback.
- The ISO build, shared installation contract, 32 native installer tests and
  all 40 exact ISO/source parity checks passed. Parity covers the bundled source,
  locked inputs, installer, desktop, updater and offline payload.

These checks do not qualify physical PXE, physical graphics/Wi-Fi/NVIDIA,
Secure Boot hardware, BIOS runtime boot or signed vendor-channel delivery.
The CybexOS public endpoint remains unavailable; this development ISO uses the
explicit development-consent flow and does not bypass release authentication.

## PXE delivery and cleanup

- Testing ISO: `/data/pxe/iso/cybexos-1.0.0-beta.6.iso`, 7,120,576,512 bytes
  (6.63 GiB), retained for physical testing.
- Checksum: `/data/pxe/iso/cybexos-1.0.0-beta.6.iso.sha256`, 91 bytes,
  naming that ISO. Both files have readable mode `0644`.
- [ISO download](http://10.10.0.7:16000/iso/cybexos-1.0.0-beta.6.iso) and
  [checksum download](http://10.10.0.7:16000/iso/cybexos-1.0.0-beta.6.iso.sha256).
- SHA-256 matched the build, staging copy, served file and full HTTP download;
  the downloaded checksum sidecar matched too.
- iVentoy refresh returned `result: success`, status returned `running`,
  the image tree listed beta.6, and `iventoy.service` was active. No service
  restart was needed. All previous images were preserved.

[Machine-readable evidence](installer-speed-2026-10-26.json) retains the actual
before/after observations, reviewed choices, runtime and lifecycle results,
source-parity identities, delivery checks and lease cleanup receipts.

All four managed leases are closed with empty remaining-resource lists and no
cleanup errors. Their workspaces, VM disks, serial logs and QMP directories are
absent. `/var/tmp/cybexos-installer-speed-KuoJWD` and the staging directory
outside the served tree were removed; no task-owned processes or mounts remain.
The duplicate task-owned Nix ISO output was deleted after delivery, freeing
6.63 GiB. Shared Nix dependencies remain in the normal build cache. No files
were created under `~/.local/share/cybexos/images`, and the running workstation
was not reconfigured or rebooted.
