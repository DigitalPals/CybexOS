# Beta.5 testing ISO — 2026-10-26

The requested x86_64 testing image contains the menubar, Control Center and
staged-updater fixes described in
[the implementation record](update-system-fix-2026-10-26.md). The build used
the existing working-tree changes, with `VERSION` advanced from beta.4 to
beta.5, past all existing served images. No workstation was reconfigured or
rebooted, and no public release was published.

## Artifact and source

- PXE host: `thebeast` (`10.10.0.7`).
- Served image: `/data/pxe/iso/cybexos-1.0.0-beta.5.iso`.
- Size: 7,120,576,512 bytes (6.63 GiB).
- Download: <http://10.10.0.7:16000/iso/cybexos-1.0.0-beta.5.iso>.
- Checksum: <http://10.10.0.7:16000/iso/cybexos-1.0.0-beta.5.iso.sha256>.
- SHA-256: `9a50fb4c0df8a9eb001ee5afe9754656a955d2575d8b933e8cb24f7b5664b7d7`.
- Frozen source: `/nix/store/25fqp5c1hs3r2ypdnwkam4wjww9rxdwd-source`.
- Source NAR: `sha256-VxpQKP12RU1OXMN89Njo3Jg+MVBehoUzbv4EapmJ+yo=`.
- Embedded release: `1.0.0-beta.5`, revision `uncommitted`, NixOS 26.05.

The ISO, shared-contract check and staged-updater VM driver were built from
that same immutable snapshot. This evidence record was written afterwards
and is not bundled in the snapshot. It is a development image, without a
fabricated signed release identity.

## Checks actually exercised

- The ISO build and shared ISO/installed-system contract check passed.
- `scripts/check-image-parity` passed against the completed served ISO and
  the exact frozen source. Extracted source NAR, locked input sources,
  desktop/QML, updater, installer screen/service, machine templates, offline
  payload and boot profiles matched the evaluated outputs. BIOS and UEFI
  boot records are present; both menus show beta.5, and the embedded EFI
  menu matches the ISO menu. BIOS boot was not exercised.
- The completed ISO booted under UEFI in a disposable QEMU VM. Its embedded
  release version and source NAR matched the frozen source; offline Nix
  metadata independently matched the bundled installer source. Both native
  installer services were active. The live updater correctly reported
  `unavailable`; installed-system updating is not offered in the live ISO.
- The same-source staged-updater NixOS VM passed in 122.91 seconds. It used
  actual packaged CLI requests, systemd workers and Nix builds to stage and
  review personal package/policy changes, preserve machine-owned locks and
  personal files, reject a stale apply after a personal edit, discard the
  preview, prepare again, and report a killed worker as interrupted in the
  same boot. No successful candidate activation was performed.
- SHA-256 matched while staging, after placement in the served tree, and
  after a complete HTTP download. The downloadable checksum sidecar also
  matched. Completed files were added without overwriting existing images,
  with readable mode `0644`.
- iVentoy refresh returned `result: success`; the subsequent status was
  `running`. The image tree listed beta.5 alongside every previous image,
  and `iventoy.service` was active. The service did not require a restart.

## Scope and cleanup

This is ready for physical testing through the existing PXE menu or the
download link. A fresh encrypted disk installation, physical PXE boot,
hardware/Secure Boot, successful installed activation, trial reboot,
authenticated login, confirmation and rollback were not qualified by this
build task. Earlier UI/source validation is recorded separately in the
implementation record.

Vendor-channel delivery still requires the release operator's real publisher
keys and signed release metadata/artifacts. The earlier audit found missing
public channel endpoints and an empty trust-key set. This testing image does
not provision a publisher or bypass release verification; independently
available NixOS updates remain selectable.

Retain the requested ISO and its 91-byte checksum in the served tree, plus
this repository record. All task leases are closed after testing; temporary
VM disks, extracted files, copied ISOs, logs and screenshots are removed.
Content-addressed Nix build outputs remain in the normal build cache. All
pre-existing served images and unrelated resources are preserved.
