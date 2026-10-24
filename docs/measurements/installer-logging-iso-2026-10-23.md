# Installer failure logging test ISO

The installer now opens its persistent installation-log dialog automatically
when its worker fails. The failure message appears above selectable plain-text
output, which refreshes every two seconds. The dialog remains available after
the worker exits and explains that the live-session log must be copied before
restarting or powering off. **Show installation details** also remains
available during installation. The full private log is
`/run/nerdos-installer.log`; the dialog reads its most recent 256 KiB.

This follows the earlier
[installer and assistant checks](installer-assistant-2026-10-23.md). The
original powered-off machine's `nixos-install` failure is still undiagnosed;
this image makes the next attempt's diagnostics accessible.

## Exact source and validation

- Frozen source: `/nix/store/hkp9835w76h3bpaal4cryphv0p044hl5-source`.
- Source NAR: `sha256-Ue7EnecNzOwd8Bv5eIlshAZCc+RYtHKMfvsf2uU0b8A=`.
- Revision: `uncommitted`, version `1.0.0-beta.2`. This is a development
  testing image and includes the checkout's pre-existing work.
- All 34 installer Python tests passed. The actual native Qt/controller test
  passed automatic log opening on failure, visible failure context, failed
  diagnostic reads and recovery, persistent selectable output, timezone
  behavior, account validation and the close guard. No disk worker ran in
  that UI test.
- The ISO built from this source. The shared installation-contract check and
  all 36 completed-image/source parity checks passed, including source,
  packages, installer frontend/QML, worker, release identity and boot profiles.
- The actual staged updater passed the complete original VM test script in
  143.05 seconds with temporary guest-only internet access. Software and
  maintenance candidates reached `ready`; configuration hashes, locks,
  personal content and the running policy remained intact. Nothing was
  applied. Driver:
  `/nix/store/ddy1hjzck9jvkl6hxnrp57cabvpk95qa-nixos-test-driver-nerdos-lifecycle`.
  Test-script SHA-256:
  `184891bfefc2dd3aa930f51bcfeb119caa4a060e5cb85c1d5a61e17acdf5c736`.
- The runner verified the unchanged original test script. The writable
  snapshot still had the same NAR afterward. The checkout matched the frozen
  source before writing this evidence record. `git diff --check` passed.

The completed ISO was not booted or used for a fresh installation in this
task. Package/UI, parity and staged-preview checks do not qualify physical
hardware, a successful fresh installation, Secure Boot or an applied update.
No running workstation was deployed, partitioned or rebooted.

## Retained testing deliverable

On **thebeast (`10.10.0.7`)**:

- ISO:
  `/data/pxe/iso/nerdos-1.0.0-beta.2-20261023-installer-logs-51eec49de70d.iso`
  (10,241,521,664 bytes; 9.54 GiB).
- Checksum: the same path plus `.sha256` (127 bytes).
- SHA-256:
  `7434c4ac8ee8986cc3779a8956c6d0dfda4d8bccf8aaeb608d246f5e63ebfdb6`.

The complete image was copied and checksum-verified outside the served ISO
directory, then linked into place atomically. Its served checksum was checked
again before refreshing iVentoy. The first status poll timed out during the
new-image scan; the subsequent refresh explicitly returned
`{"result":"success"}`, with status moving from `refreshing` to `running`.
`get_img_tree` contained the new filename and both existing images, and
`iventoy.service` was active. No service restart or existing-image replacement
was needed. The ISO and checksum are retained for the next diagnostic
installation attempt.

## Cleanup

Cleanup removed `/tmp/nerdos-installer-logging-EWEThf` on the Beast (339 MiB)
and `/scratch/tmp/john/nerdos-installer-logging-5ar2hvt0` locally (11 MiB),
including source copies, VM disks, screenshots and logs. Parity extraction
cleaned itself up. The duplicate task-built ISO output
`/nix/store/p7hbzn7amjkv5lssjhh6mab2s5wpn100-nerdos-1.0.0-beta.2-x86_64-linux.iso`
was deleted through Nix after verifying the served copy, freeing 9.5 GiB.
Shared Nix dependencies stay cached.

Checks found no remaining task processes or mounts and confirmed both source
staging directories and the separate copy staging directory absent. Neither
host had a `~/.local/share/nerdos/images` directory. The only retained task
artifacts are the testing ISO and checksum listed above.
