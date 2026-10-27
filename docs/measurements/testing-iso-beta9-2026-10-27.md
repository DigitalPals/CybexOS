# Beta.9 testing ISO — 2026-10-27

Beta.9 fixes the authorization failure reported when enabling SSH Server or
preparing updates in beta.8. It retains beta.8's Settings SSH switch, neutral
initial release-channel HTTP 404 handling, and readable update-source labels.

## Cause and change

A disposable beta.8 NixOS VM reproduced exit 127 and `pkexec must be setuid
root`: the desktop PATH selected `/run/current-system/sw/bin/pkexec`, an
unprivileged Nix-store executable. NixOS provides the privileged executable at
`/run/wrappers/bin/pkexec`. The failure happened before a password prompt.

The SSH bridge, lifecycle CLI, password dialog and privileged Tailscale commands
now select the absolute NixOS wrapper. Packaged desktop launchers also put
`/run/wrappers/bin` ahead of their tools. Password packaging no longer prepends
the raw Polkit executable. CLI regression tests cover the privileged updater,
history, software, maintenance and region branches with a hostile PATH.

The installation qualifier now exercises real desktop authorization. Its
read-only Polkit status IPC exposes prompt readiness; passwords are typed
through the VM keyboard into the actual dialog, never submitted through IPC.

## Artifact and source

- PXE host: `thebeast` (`10.10.0.7`).
- Image: `/data/pxe/iso/cybexos-1.0.0-beta.9.iso`.
- Size: 7,120,576,512 bytes (6.63 GiB).
- Download: <http://10.10.0.7:16000/iso/cybexos-1.0.0-beta.9.iso>.
- Checksum: <http://10.10.0.7:16000/iso/cybexos-1.0.0-beta.9.iso.sha256> (91 bytes).
- SHA-256: `cfc9238d9e083e864c0295f36100d2174ee7db770777a2ec4957c9c35e876e67`.
- Frozen source: `/nix/store/556icv58nw4dqccr3cnqkp45x5s3j3qy-source`.
- Source NAR: `sha256-iabhrkhOaSjr20pOq8g8iXISMCL80DxVGSUCY4aKmDc=`.
- Embedded release: `1.0.0-beta.9`, revision `uncommitted`, NixOS 26.05.
- ISO output: `/nix/store/y2dmwin141npzx77pdfgfaj5nhmlrffk-cybexos-1.0.0-beta.9-x86_64-linux.iso`.
- Shared contract: `/nix/store/xr049dm2bdgk684g4x0rphd7kylh5v4z-cybexos-shared-installation-contract.json`.

The ISO, installed-system qualification and image/source parity used this exact
immutable source identity. This record was written after the source freeze and
is not bundled in the ISO. No signed public release was published.

## Checks actually exercised

- The ISO build and shared installation-contract check passed.
- `tests/run` passed: 655 NixOS/helper unit tests, additional native-helper
  suites, and 1,453 Node tests passed with 16 skipped and no failures.
  `tests/qml-lint` passed for 424 QML files and four harnesses, with eight
  existing warnings. These source tests ran on an earlier snapshot with
  identical production code and tests; only the installation qualifier's
  cancellation assertion and failure diagnostics changed afterward.
- `scripts/check-image-parity` passed all 41 source/image/package comparisons,
  including the exact bundled source NAR and installed release identity.
- A disposable UEFI VM installed the completed ISO using the JSON-plan
  installer and minimal applications. Installed identity, quiet boot, GRUB,
  desktop password login, desktop health, onboarding and shortcut editing
  passed. The current shell journal contained no QML errors in the runtime
  shortcut check.
- The installed Settings SSH backend ran as the normal desktop user with the
  managed shell's PATH. The real Quickshell Polkit/PAM prompt appeared.
  Canceling returned the expected failure JSON and left SSH disabled.
  Approving with the QA password enabled the actual SSH service; approving
  again disabled it. The switch's mouse click was not exercised in this run.
- The unprivileged packaged `cybex update stage local` command displayed a
  real password prompt. Approval started the actual systemd/Nix worker,
  built and checked a candidate, and reached `ready` for review in about
  seven seconds. The candidate was discarded afterward. This was a local
  configuration stage, without application or a changed upstream input.
- Two packaged password-worker changes, installed reboots, desktop password
  logins and unlocked login-keyring round trips passed.

The earlier installation attempt stopped at a welcome IPC timeout before the
new authorization checks. The qualifier now includes command exit status and
bounded IPC diagnostics in failures; the final exact-source run passed all
milestones. Its cancellation assertion checks JSON `success: false` because
the Settings dispatcher intentionally exits zero for handled errors.

## Limits

This run did not qualify encrypted installation, physical hardware, Secure
Boot, physical PXE boot, physical SSH LAN reachability, or signed release
channel delivery. It did not repeat beta.8's upstream-only candidate build or
full application/trial-boot/rollback tests; see the
[beta.8 record](testing-iso-beta8-2026-10-27.md). The password dialog and
Tailscale sign-in have source regression coverage but were not authorized
interactively in this run.

## Delivery and cleanup

The staged, served and fully HTTP-downloaded ISO hashes matched, as did the
checksum URL. iVentoy refresh returned `result: success`; status returned
`running`, the image tree listed beta.7, beta.8 and beta.9, and
`iventoy.service` was active. Beta.7 and beta.8 were preserved.

All three beta.9 reproduction/installation leases were checked closed with no
remaining resources. Their VM workspaces, disks and logs were removed. The
20 MiB task scratch directory, extracted parity files, validation source copy,
intermediate ISO links and logs were deleted; the empty PXE staging directory
was removed. These output directories were verified absent (zero retained
bytes). No task-owned mounts or host developer Quickshell process remained.
Existing contents of `~/.local/share/cybexos/images` were preserved; this task
created no outputs there. Normal content-addressed Nix build-cache outputs
remain under Nix's management.

Retained deliverables are the requested beta.9 ISO (7,120,576,512 bytes) and its
91-byte checksum at the paths above, plus repository changes and this evidence
record for review.
