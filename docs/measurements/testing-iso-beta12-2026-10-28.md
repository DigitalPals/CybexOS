# Beta.12 installation regression and regional Settings — 2026-10-28

Beta.11 failed a fresh installation when the selected timezone or language
differed from UTC/en_US. The OS fallback and installer declaration both used
`mkDefault` (priority 1000), causing a Nix conflicting-definition error. This
was reproduced with the actual served beta.11 ISO in a disposable UEFI VM:
`time.timeZone` conflicted between `UTC` and `Europe/Amsterdam`. Its trace
through `head`, `system.build.toplevel` and `environment.etc` matches the
reported installation failure.

## Fixes

- `f7fad9455e30e1eb8f58c45d309dc259bb1302bf`: OS locale/timezone fallbacks now use priority
  1100. Installer choices (1000), Settings choices (900) and personal module
  declarations (100) retain their precedence. Added actual Nix module-merger
  assertions for Dutch/Amsterdam and English/London installations, Settings
  choices, personal overrides and a complete Dutch system evaluation.
  Removing the fix from a disposable snapshot makes the new check fail.
- `ec667f2c33d32bb66d0674fe3ab5611b7f8a0d57`: language preview compares the same localed DBus
  property used by the Settings snapshot. Localed omits redundant `LC_*`
  entries equal to `LANG`; comparing that snapshot with raw `/etc/locale.conf`
  previously produced a false stale-state error. Added a regression for an
  explicit matching `LC_TIME`, retaining rejection of a real intervening edit.
- `VERSION` advances to beta.12. No machine locks, upstream inputs or personal
  files were changed by the production fixes.

## Artifact and source

- Served image: `/data/pxe/iso/cybexos-1.0.0-beta.12.iso` (7,120,576,512 bytes).
- Download: <http://10.10.0.7:16000/iso/cybexos-1.0.0-beta.12.iso>.
- Checksum: <http://10.10.0.7:16000/iso/cybexos-1.0.0-beta.12.iso.sha256> (92 bytes).
- SHA-256: `b7a697d942eefc2ee95d6e67d50f31af0d10c7276b64832a4229c3c3d2c190f8`.
- Exact build revision: `ec667f2c33d32bb66d0674fe3ab5611b7f8a0d57`.
- Source NAR: `sha256-L6fUOjyhfsbUVAXyxnfw327OF3oDdNHlxfHEGhaTIOY=`.
- Frozen source: `/nix/store/qj93wsjd68bmq1rr16m6w8cpya4jd2wg-source`.
- Version/platform: 1.0.0-beta.12, NixOS 26.05, x86_64-linux.

The ISO, shared installation-contract check and lifecycle check built from an
exact committed Git flake. The lifecycle check passed 669 unittest cases,
its additional runtime/helper checks and 25 Settings helper cases. The completed
ISO passed `scripts/check-image-parity` in 41 sections against that same
revision and NAR, including source, updater, desktop, installer and offline
payload. The lock file was unchanged. This record is a later documentation-only
commit; no signed release or channel publication was performed.

## Final image runtime evidence

The actual final ISO freshly installed the standard application selection onto
a blank disposable UEFI disk with `nl_NL.UTF-8` and `Europe/Amsterdam`. The
plan-driven installer used the bundled development source. The installer
completed, the disk booted, password desktop login succeeded, the
installed regional values matched and `cybexos-health desktop-required` passed.
The installed source NAR matched the medium exactly. The explicit bundled
source used for this development-image installation is a locked path input;
Nix consequently reports the installed revision as `uncommitted` while keeping
the exact source NAR. The test checks and records that metadata distinction.
A guest-only root password allowed separate serial administration; normal
installer output still locks root.

Settings displayed Dutch and Amsterdam. Real Region controls, privileged worker
and password authorization then exercised both staged deployments:

- Timezone to Europe/Berlin: transaction `471ecd079bf24eabb4ab1cb53954c006`,
  build, apply, trial reboot, password desktop login, health and confirmation.
- Language to en_GB.UTF-8: transaction `0ff69a9eac7749a5b896ff76c034b057`,
  build, apply, trial reboot, password desktop login, health and confirmation.
  The desktop and Settings switched to English; Berlin remained selected.

The fixture explicitly kept `LC_TIME=nl_NL.UTF-8`, initially equal to LANG,
and installed the target English locale. Both changes preserved that category's
value. `machine.nix`, the flake and lock, personal module files and a personal
document retained their original hashes. The fixture was private to the
disposable VM.

Only the managed Quickshell service ran throughout the UI tests. After removing
the private test introspection source, the packaged service was restarted,
its MainPID was the sole user shell PID and its current invocation journal had
no QML errors. Final desktop-required health passed.

This exercises the reported installation path and regional Settings lifecycle.
It does not requalify every Settings page, physical hardware/PXE, Secure Boot,
encrypted installation or signed-channel updating. Earlier Settings audit scope
is recorded separately in [the audit report](settings-audit-2026-10-27.md).

## PXE delivery and cleanup

The completed image and correctly named SHA-256 sidecar were copied and verified
outside the served tree, then added without overwriting existing files, with
mode 0644. Served checksum verification and a full HTTP download both matched.
iVentoy refresh returned success, status returned running, the image tree
included beta.12 and all prior images, and `iventoy.service` remained active.
Existing image/sidecar sizes, modification times and inodes were unchanged.
No service restart was needed.

VM leases `bd9365a846cf4f399bc7d2474837891e` (beta.11 reproduction),
`df721a2a369743b99b0ea4ff69ae9cd7` (initial candidate) and `e51741f58c16436cb1084234ee7485d5` (final
image) closed; resource checks found no remaining objects, preserved volumes or
errors. Their disks, firmware state and logs were removed. Task staging
`/data/tmp/cybexos-install-region-20261028-Du1SFa`, including snapshots, temporary copies, reports, logs and screenshots,
was removed after recording this evidence. The superseded candidate ISO was
explicitly deleted from the Nix store. No task-owned VM, process or mount remains.

Retained requested deliverables: the served ISO (7,120,576,512 bytes) and
checksum (92 bytes), plus this small repository record. The final image
output `/nix/store/bh3y0q0i82dqszxdzfsy5gm6nzf6r8sq-cybexos-1.0.0-beta.12-x86_64-linux.iso`
(7,120,576,512 image bytes) and successful check/package outputs remain in the normal
Nix-managed build cache. Existing images, services and personal data were preserved;
no global cache pruning was performed.
