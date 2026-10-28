# Beta.11 testing ISO — 2026-10-28

The Settings fixes, regression tests and [audit report](settings-audit-2026-10-27.md)
were committed and pushed directly to `main` as `cfcdded8eeb5242169c941b5ff744bb22aae099a`. The checkout was already
on `main` and matched the remote, so no branch merge was necessary. `VERSION`
advanced from beta.10 to beta.11, past every existing served testing image.
This build record is a subsequent documentation-only commit.

## Artifact and exact source

- PXE host: `thebeast` (`10.10.0.7`).
- Served ISO: `/data/pxe/iso/cybexos-1.0.0-beta.11.iso`.
- Size: 7,120,576,512 bytes (6.63 GiB).
- Download: <http://10.10.0.7:16000/iso/cybexos-1.0.0-beta.11.iso>.
- Checksum: <http://10.10.0.7:16000/iso/cybexos-1.0.0-beta.11.iso.sha256> (92 bytes).
- SHA-256: `38d8aeabba1401149ac6ea2d7b3b4db5ce610cf378b701a0f7dc7b8af3a7aa1c`.
- Source revision: `cfcdded8eeb5242169c941b5ff744bb22aae099a`.
- Source NAR: `sha256-RTJ/X2KVAiRerjCb67zAtE7sI7ih+IiUwLB4stTMqS8=`.
- Frozen source: `/nix/store/0qmzba2h259z257685baancs8l4ldci7-source`.
- Embedded release: `1.0.0-beta.11`, NixOS 26.05, x86_64-linux.

The ISO and shared-contract derivation used an explicit local Git flake pinned
to that revision, rather than a mutable working tree. The lock file was unchanged.
No public release or signed-channel publication was created.

## Checks actually exercised

- The ISO and shared installation-contract check built successfully. The native
  installer package's Rust tests passed during the build.
- `scripts/check-image-parity` passed against the completed ISO and the exact
  pinned Git input. Its 41 sections verified source, locked inputs, desktop/QML,
  updater, installer screen/service, machine templates, offline payload, system
  configuration and executables. The image/source version, revision and NAR
  identities matched.
- The actual completed ISO booted under UEFI in a disposable QEMU VM. The
  observed release was beta.11 at the exact revision and NAR above; offline
  metadata of the bundled installer source independently matched that NAR.
  Both `cybexos-installer-ui.service` and `cybexos-installerd.service` were active.
  The native 1280×800 installer screen was visually inspected and displayed
  beta.11 with the explicit development-build acknowledgement. No disk was
  selected or partitioned. The live updater correctly returned `unavailable`.
- The ISO was copied and checksummed outside the served tree, then added with
  its correctly named checksum using atomic, non-overwriting links. Both served
  files have mode `0644`. A served-file SHA-256 check passed. A complete HTTP
  download independently produced the same SHA-256; the HTTP checksum sidecar
  also matched.
- iVentoy refresh returned `result: success`. Status returned `running`,
  `iventoy.service` stayed active, and the image tree listed beta.11 together
  with beta.7, beta.8, beta.9 and beta.10. Existing image and checksum sizes,
  modification timestamps and inodes were unchanged. No PXE restart was needed.

The earlier Settings audit remains separate evidence. This build task exercised
image parity and a live UEFI boot; it did not repeat the installed Settings
matrix, perform a fresh disk installation, or qualify physical PXE, hardware,
Secure Boot, encrypted installation or signed-channel updating.

## Cleanup and retained deliverables

The VM lease `64fca4dde38448e2b9d5c5bbc8354317` closed normally;
`agent-resource check` reported no remaining resources, preserved volumes or
errors. Its blank disk, firmware variables, serial log and QMP directory were
removed. Task staging `/data/tmp/cybexos-beta11-20261028-UcbEUN`, including
extracted image files, temporary copies, logs, scripts and the screenshot, was
removed after recording this evidence. No task VM or mount remains.

Retain the requested ISO (7,120,576,512 bytes) and checksum (92 bytes) at the
served paths above for testing, plus this small repository record for review.
The final ISO output `/nix/store/4099hqviaqcn0vk6d8spz3j6kymfh2p4-cybexos-1.0.0-beta.11-x86_64-linux.iso` (6.7 GiB) and shared-contract result `/nix/store/69vivdblnkpj2xbsqahzabf16lz2mpr3-cybexos-shared-installation-contract.json` (16 KiB) remain
in the ordinary Nix-managed build cache. Pre-existing images, runtime data and
unrelated resources were preserved; no global cache pruning was performed.
