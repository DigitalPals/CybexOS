# Testing ISO — 2026-10-23

The requested internal test image contains Software, Settings → Applications,
Settings → Storage & cleanup, and automatic weekly cleanup enabled by default.
It was built in an isolated Nix 2.35.4 Podman environment. The workstation was
not deployed, reconfigured or rebooted, and no release was published.

## Artifact and source

- Beast: `10.10.0.7:/data/pxe/iso/nerdos-1.0.0-beta.1-20261023-ec5fa706073a.iso`
- Size: 6,179,346,432 bytes (5.75 GiB).
- Download: <http://10.10.0.7:16000/iso/nerdos-1.0.0-beta.1-20261023-ec5fa706073a.iso>
- Checksum: <http://10.10.0.7:16000/iso/nerdos-1.0.0-beta.1-20261023-ec5fa706073a.iso.sha256>
- SHA-256: `fe2b8739bd0b2ef030cd80d99716810f29fbec35e94a9969a78aee35bf305f1b`.
- Exact source NAR: `sha256-7F+nBgc6ux6YKtSI6jwCB7KI5PO6KDiNqbzNoQ31fNM=`.
- Release metadata: NerdOS 1.0.0-beta.1, revision `uncommitted`, NixOS 26.05.
- Pinned Nixpkgs revision: `da6dc0e7b26060f2f71ce3ef7088fb56ee44fa36`.

The frozen snapshot contains all 1,272 tracked and untracked source files,
including the existing workspace changes. This handoff record is written after
freezing the source and is not inside that snapshot. The complete source is
bundled in the ISO and checked against its NAR identity.

## Checks actually exercised

- The ISO build and shared ISO/installed-system parity check passed.
- `scripts/check-image-parity` passed against this exact frozen source and the
  completed ISO: source NAR, locked input sources, runtime/QML, installer,
  templates, updater and boot menu system identities matched.
- The completed ISO booted under UEFI in a disposable QEMU/TCG VM. Its source
  identity, normal managed desktop health, sole shell process, current shell
  journal, desktop configuration, enabled five-deployment/30-day cleanup policy
  and active automatic-cleanup timer passed (136.1 seconds).
- The same-source staged updater VM passed in 644.57 seconds. It read the
  enabled cleanup default, found the timer active and observed its worker skip
  an unconfirmed initial boot. Real supervised requests staged a package and a
  cleanup opt-out, built and reviewed both candidates, and preserved the working
  declarations, personal sentinel and machine-owned locks. Neither was applied.
- All three focused JavaScript state tests passed. The real Qt/Quickshell engine
  constructed the production Storage page and passed its default-policy,
  draft-isolation and discard checks in an isolated offscreen harness.
- QML lint passed 363 product files and four harnesses, with existing warnings.
- The broader offscreen lifecycle harness did not pass: its Revealer timing and
  recovery-search-anchor checks failed, and its hard-coded `/usr/bin/printf`
  commands are absent in the Nix container. Those failures remain unresolved;
  this is not a claim that the complete QML lifecycle harness passed.
- Both the transferred file on the Beast and a complete HTTP download matched
  the recorded SHA-256. The downloadable checksum file matched too.
- iVentoy 1.0.41 refresh returned `result: success`, completed from `refreshing`
  to `running`, and listed this filename with the failed intermediate absent.
  `iventoy.service` was active; its existing LAN firewall was preserved.

The first ISO exposed a real startup failure: `StoragePage.baseline` overrode
Qt's final Item anchor property. Renaming it to `policyBaseline` fixed startup;
the stored lifecycle harness now constructs the real page to catch this class
of error. The failed image is removed and is not a testing deliverable.
The initial iVentoy restart loop was caused by its empty ISO directory. Its
missing log directories were restored for diagnosis; placing the verified ISO
allowed the saved PXE configuration to run normally.

## Scope and retained artifacts

This is an unreleased testing image. The live installer offers the bundled
development build when started interactively. No disk installation, installed
trial boot/apply/confirmation/rollback, physical hardware, Secure Boot or actual
weekly timer firing was qualified by this task. The source VM stages and reviews
candidates without applying them.

Retain only the requested ISO and its 112-byte checksum on the Beast, plus this
small repository evidence record. Task-owned build containers, images, source
snapshots, local ISO copies, VM disks, extracts, logs and screenshots are removed
before handoff. No pre-existing images or unrelated workspace files are removed.
