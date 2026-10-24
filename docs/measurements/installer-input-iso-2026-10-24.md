# Testing ISO: installer input fixes — 2026-10-24

Historical handoff. The subsequent [KMS latency work](installer-kms-latency-2026-10-24.md)
records the newer image, measured rendering improvement and current PXE status.

This requested development image includes the cursor, keyboard accessibility,
key-repeat and responsiveness changes from the
[installer input audit](installer-input-2026-10-24.md). It was built on the Beast
from a frozen snapshot of all 1,364 tracked and untracked source files, including
the new Slint dependency patch and interaction tests. No lock was refreshed.
This record was written after freezing the source and is outside that snapshot.

## Testing deliverable

On **thebeast (`10.10.0.7`)**:

- ISO: `/data/pxe/iso/nerdos-1.0.0-beta.2-20261024-installer-input-9aff22041052.iso`.
- Size: **7,120,576,512 bytes (6.63 GiB)**.
- Checksum: the same path plus `.sha256` (128 bytes).
- [Download ISO](http://10.10.0.7:16000/iso/nerdos-1.0.0-beta.2-20261024-installer-input-9aff22041052.iso).
- [Download checksum](http://10.10.0.7:16000/iso/nerdos-1.0.0-beta.2-20261024-installer-input-9aff22041052.iso.sha256).
- SHA-256: `9b3f1d992250e7127e294f9d6b941517958dfea7725b999a8de9afc235d0e8a5`.
- Frozen source: `/nix/store/rfvjp5cb94h3hh9gz95zg2dj0fpxqlmi-source`.
- Source NAR: `sha256-mv8iBBBSBCPqSFKrH1aTE20odRS8nlyA3f2D7sL/+j4=`.
- Release identity: `1.0.0-beta.2`, `uncommitted`, NixOS `26.05`.

## Verification actually exercised

- The ISO and shared installation-contract builds passed. All **26 Rust tests**
  passed in the release package build (20 unit and six rendered interaction tests).
- All **39 completed-image/source parity checks** passed against this exact
  source, covering source NAR, locked input sources, installer screen and service,
  desktop, updater, offline payload, and UEFI/BIOS boot-menu identities.
- The completed ISO booted directly in a disposable QEMU/KVM UEFI guest with
  virtio KMS, a USB tablet and PS/2 keyboard. No package injection or guest unit
  override selected a different installer. The guest release NAR matched above.
- Five pointer moves each drew **188 cursor pixels**, with old bounds clean on
  every move, including revisits. Tab/Enter opened Installation details through
  the menu; another Tab/Enter activated Close. Actual display captures were
  inspected. Closing correctly restored focus to the menu button.
- Holding `a` for 850 ms produced **17 characters**; holding Backspace for
  650 ms deleted **11 characters**. Release stopped repeat. Both installer
  services remained active, the UI warning journal was empty, and the service
  ended in `phase: setup`, `diskTouched: false`.
- The same-source actual staged updater test passed in **116.07 seconds**.
  Software and maintenance candidates reached `ready`, preserving declarations,
  machine locks, personal sentinel and the running maintenance policy. Nothing
  was applied. Driver: `/nix/store/zz808syw0a3hcjybxhx5rx4iw05sxwxr-nixos-test-driver-nerdos-lifecycle`.
  The unchanged original test script was `/nix/store/hc8ls47i7gr37sh2qzliwnjis77jvwsm-test-script`, SHA-256
  `7cc4f941f5131537236be571bbed8e00ea7533d52eaeb56a5f27d91487726bc7`. The harness supplied temporary guest-only NAT
  and DNS after the network-profile assertions.
- The finished ISO was copied and checksum-verified outside the served tree,
  then linked into place atomically. The served file and a complete HTTP download
  matched SHA-256; the downloaded checksum file matched as well.
- iVentoy 1.0.41 refresh explicitly returned `result: success`, changed from
  `refreshing` to `running`, and listed the new image. `iventoy.service` remained
  active; no service restart was performed.

Initial harness attempts required two corrections: the Nix VM driver needed
`-no-user-config` to avoid reading the host's restricted QEMU configuration,
and the smoke test needed to select Get started after Close restored menu focus.
The final checks above passed after those harness corrections. The driver retry
used a private task-specific runtime directory.

This is an unreleased testing ISO. No full disk installation, applied updater,
installed login/encryption, physical hardware, Secure Boot or end-to-end PXE boot
was qualified. The workstation was not deployed, partitioned or rebooted, and
no release was published.

## Older PXE images

The user explicitly requested removing all older ISOs. Removed all five images
and their checksums (**47,766,061,056 ISO bytes**):

- `nerdos-1.0.0-beta.2-20261023-google-dns-c0684a50bfcc.iso` and its `.sha256` file.
- `nerdos-1.0.0-beta.2-20261023-gui-9bc2f93e7e83.iso` and its `.sha256` file.
- `nerdos-1.0.0-beta.2-20261023-installer-logs-51eec49de70d.iso` and its `.sha256` file.
- `nerdos-1.0.0-beta.2-20261023-pxe-gfx-7a36d3d7ccea.iso` and its `.sha256` file.
- `nerdos-1.0.0-beta.2-20261024-installer-kiosk-6421fc1ac80f.iso` and its `.sha256` file.

The last image was initially kept available because client `10.10.1.64` had an
established NBD connection to it. The user confirmed that no installation was
running and interruption was safe, after which it and its checksum were removed.
The final refresh returned `result: success` and completed to `running` without
a restart. Both the served directory and image tree contain only the new ISO
(plus its checksum in the directory); all older filenames are absent.
`iventoy.service` is active, final checksum verification passed, and the served
directory uses 6.7 GiB according to `du -sh`.

## Cleanup

Removed task staging at `/data/tmp/nerdos-input-iso-20261024-ajiLzz` on the Beast
and `/tmp/nerdos-input-iso-20261024-4_snmxkz` locally, including source archives,
VM disks, extracted files, logs, test captures and harnesses. The first driver's
disposable state and the retry's temporary socket directory were removed too.
No task VM or host mount remains; neither host has a NerdOS image output directory.
The duplicate task-built ISO output
`/nix/store/cbrpk8xpmygnxqymdwiiglbzvi4kh57v-nerdos-1.0.0-beta.2-x86_64-linux.iso`
was deleted through Nix (**6,790.71 MiB freed**) after verifying the served copy.
Normal shared dependency/source caches remain. Retained task deliverables are
only the requested ISO and checksum listed above, plus this evidence record.
