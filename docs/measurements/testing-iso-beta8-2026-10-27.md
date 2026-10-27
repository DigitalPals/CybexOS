# Beta.8 testing ISO — 2026-10-27

This image adds **Settings → Security → SSH Server**, quietly skips an initial
unpublished Cybex OS channel, and fixes the update source labels in dark and
light themes. See [SSH Server](../ssh.md) and [updates](../updates.md).

## Artifact and source

- PXE host: `thebeast` (`10.10.0.7`).
- Image: `/data/pxe/iso/cybexos-1.0.0-beta.8.iso`.
- Size: 7,120,576,512 bytes (6.63 GiB).
- Download: <http://10.10.0.7:16000/iso/cybexos-1.0.0-beta.8.iso>.
- Checksum: <http://10.10.0.7:16000/iso/cybexos-1.0.0-beta.8.iso.sha256> (91 bytes).
- SHA-256: `6651bb00f8b222274409db88792c64db88dbeced8bd2f11eebe879f930689761`.
- Frozen source: `/nix/store/32nxlr6kkbsq6i0ngh18yvm01mpkxi22-source`.
- Source NAR: `sha256-RimYlysKAz4nzPdphML/+Mij3VVE2AGLKvT79fLFbts=`.
- Embedded release: `1.0.0-beta.8`, revision `uncommitted`, NixOS 26.05.
- ISO output: `/nix/store/p2crf7jhdymsbwvvczqz332nhqvppcbw-cybexos-1.0.0-beta.8-x86_64-linux.iso`.
- Shared contract: `/nix/store/x9ijqvfc0mc65q1xcl361621a4833ydn-cybexos-shared-installation-contract.json`.
- Runtime driver: `/nix/store/44wll65gnf98xdqxg6194fv2021pnfhk-nixos-test-driver-cybexos-lifecycle`.

The ISO, shared-contract check and runtime driver used this exact immutable
source. A writable validation copy had the same NAR identity. This record was
written after the source freeze and is not bundled in the ISO. This is a
development image; no signed public release was created.

## Checks actually exercised

- The ISO build and shared installation-contract check passed.
- `tests/run` passed: 654 NixOS/helper unit tests, the additional native-helper
  suites, and 1,453 Node tests passed with 16 skipped and no failures.
- `tests/qml-lint` passed for 424 QML files and four harnesses. Eight existing
  warnings remain outside the new SSH group and changed update popover.
- `tests/update-flow.py` rendered the actual Quickshell UI under private
  headless Sway. It passed dark/light source-label color checks, source-toggle
  clicks, unpublished-vendor handling, independent upstream selection,
  preparation/review/apply requests, cancellation and recovery scenarios.
  Its command boundary is scripted; it does not activate an operating system.
- `scripts/check-image-parity` passed all 41 source/image/package comparisons,
  including the bundled source NAR, desktop, updater, installer, templates,
  offline payload, locked inputs and boot profiles.
- The packaged NixOS runtime driver passed in 207.09 seconds. Actual CLI
  requests, systemd workers and Nix builds exercised staging, review, personal
  configuration preservation, stale-apply rejection, discard and interrupted
  workers. Actual SSH password login over guest loopback passed before and
  after a cold shutdown/start; disabling SSH prevented the service from
  starting without its saved marker.
- A disposable UEFI VM installed the completed ISO through the JSON-plan
  installer with the minimal application selection. Installed source identity,
  quiet boot, GRUB entries, password desktop login, desktop health, onboarding,
  shortcut editing and password/keyring round trips passed. The Security page
  loaded; the real packaged SSH helper enabled the daemon, a guest-loopback
  password login succeeded, and disabling it succeeded. Interactive Polkit
  click-through was not exercised in this installed-image run.
- The actual installed updater discovered NixOS changes from
  `da6dc0e7b26060f2f71ce3ef7088fb56ee44fa36` to
  `718f670e845328e9c2cecdd832835712b2cbd065`, while Cybex OS reported
  `unpublished` without an error. The upstream-only worker built and validated
  a complete candidate, reaching review in about 519 seconds. Vendor identity
  and the working machine lock were preserved. This upstream candidate was
  not applied.
- The same installed-image run passed local staged application, authenticated
  trial boot, confirmation, intentional evaluation/build failures, killed-worker
  recovery across reboot, automatic fallback from an unconfirmed trial,
  explicit rollback and personal file/service/VPN/widget/state preservation.
- Staged, served and fully HTTP-downloaded ISO hashes matched. The checksum
  URL matched too. Completed files were placed with mode `0644`, preserving
  beta.7. iVentoy refresh returned `result: success`, status returned `running`,
  the image tree listed beta.7 and beta.8, and `iventoy.service` was active.

## Observations and limits

Only the initial channel document's HTTP 404 is neutral before any authenticated
channel sequence has been recorded. Missing signatures/manifests and a missing
previously authenticated channel still fail verification. Independent upstream
updates never require the vendor channel. The public beta channel was actually
absent during qualification; no release metadata or trust keys were fabricated.

An outdated qualification assertion expecting a vendor error was corrected
before the final source freeze. An earlier exact-source runtime-driver attempt
stalled waiting for its second-boot backdoor and was stopped. The same driver
passed on a diagnostic rerun with systemd debug logging; the stall's cause was
not established. The separate actual-ISO lifecycle run passed its reboot and
recovery checks. CUPS printer discovery also caused a long shutdown wait during
one installed-image reboot.

This run did not qualify encrypted installation, physical hardware, Secure
Boot, physical PXE boot, a successful changed-upstream activation, or signed
vendor-channel delivery. SSH LAN reachability was not physically tested.

## Cleanup

All eight task test leases were verified closed with no resources remaining.
Task VM disks, intermediate ISO copies, extracted files, writable source
copies, logs and screenshots were removed. The requested served ISO and its
91-byte checksum remain, along with repository changes and this record.
Content-addressed Nix outputs remain in the normal build cache.
