# Testing ISO beta.18 — 2026-10-29

## Exact source and image

- Version: `1.0.0-beta.18`.
- Build revision: `06ce2cbea3c306dd51d9670d7dc8a55a6997c4c5`.
- Source NAR: `sha256-GmQGj5bHOfmwtke3l8caJjnqpuQRlIWXiQrPXWWHog0=`.
- ISO SHA-256: `fc5d20b8432e87bfca7ec47a01e6743bc623a4456c4c9942e3a5db5d08a16b9d`.
- Served ISO: `/data/pxe/iso/cybexos-1.0.0-beta.18.iso`.
- ISO size: 7,120,576,512 bytes (6.632 GiB).
- Checksum: `/data/pxe/iso/cybexos-1.0.0-beta.18.iso.sha256`
  (92 bytes).

The image was built from an exact committed Git flake after increasing only
`VERSION` from beta.17 to beta.18. This report is a subsequent documentation-only
commit; its own revision is not the image's source identity.

## Repository consolidation

All 13 non-main local branch heads were already ancestors of `main`; no new
source merge was needed. Both additional worktrees had no tracked changes or
untracked source. Removed their generated Ruff/Python caches, removed the two
worktrees with `git worktree remove`, and deleted the merged branches with
`git branch -d`.

Removed worktrees:

- `/home/john/.t3/worktrees/CybexOS/feat-desktop-improvements-20261021`
- `/home/john/.t3/worktrees/CybexOS/feat-settings-redesign`

GitHub already contained only `main` and no open pull requests. Fetched and
pruned remote tracking references, then pushed the beta.18 version commit to
`origin/main`. There were no stashed changes. The final repository check is
recorded below.

## Build and static verification

The exact source passed:

- `nix build EXACT-SOURCE#iso`, with two build jobs and eight cores per job.
- The installer package's 32 Rust tests (20 unit, eight interaction, four
  presentation).
- `checks.x86_64-linux.lifecycle`: 723 Python unit cases, the standalone
  Hermes bridge/runtime/authentication, default-agent and camera checks,
  and 25 system-settings cases.
- `checks.x86_64-linux.parity`, the shared installation contract.
- All 41 completed-image/source parity checks, including the embedded source
  NAR, release identity, retained input sources, packaged desktop/updater,
  installer, offline payload and boot menus.

## Installation and staged-updater verification

- **plain-install: passed.** Real tty1 Slint installation with the full default
  application selection; 190 seconds in the installer worker (203.372 seconds
  observed by the harness).
- **encrypted-install: passed.** Real tty1 Slint installation with the full
  default application selection; 215 seconds in the installer worker (223.533
  seconds observed by the harness).

Both cases passed installed source identity, UEFI boot/menu and quiet boot,
serial password login, desktop health, welcome/keyboard-shortcut runtime,
polkit authorization and real packaged password-worker/PAM checks. Each case
changed the password and changed it back, rebooting and verifying the unlocked
login keyring. The plain case used SDDM password login. The encrypted case also
rejected the old disk key and verified
automatic desktop login after unlocking the disk with the changed password.

Both cases passed all nine lifecycle scenarios:

- Automatic background preparation.
- Independent upstream discovery and full staging with an unpublished vendor
  channel, preserving the Cybex OS identity and working machine lock.
- A staged, applied and confirmed personal baseline.
- Deliberate evaluation failure, retaining the working system and lock.
- Deliberate build failure, retaining the working system and lock.
- Killed staging worker, reboot recovery and preserved personal state.
- Unconfirmed trial boot falling back to the previous generation.
- Local staging, activation, trial boot and automatic confirmation after login.
- Explicit rollback, reboot and unchanged personal modules, VPN secret path,
  service state, widget code/preferences and plugin data.

Upstream staging advanced Nixpkgs from
`da6dc0e7b26060f2f71ce3ef7088fb56ee44fa36` to
`08d3a97586f6b6343b3b5e799980773629432610` in both disposable guests.
Those upstream candidates were built and validated but left unapplied; the
application/recovery tests used local configuration candidates. No signed
public-channel or physical hardware/security qualification was exercised.

The host's `ci-platform run` has no CybexOS target. Source checks used the normal
Nix build sandbox; the real QEMU tests ran in supervised `agent-resource` lease
`3aa4ec673ec04f39b25f6f5e708fb178`, with a CI host-capacity reservation of
20 GiB and eight CPUs. Each guest used four vCPUs and 12 GiB RAM.

## PXE delivery

The completed image was copied outside the served tree, hashed against the
parity-verified build, and moved into `/data/pxe/iso`. Its checksum then verified
again in the served directory. After observing no active PXE connections,
removed beta.14, beta.15, beta.16 and beta.17 and their checksum files, freeing
28,482,306,048 bytes of old ISO data. No other operating system's image was
changed.

`refresh_img_list` returned `result: success`. iVentoy retained a stale image
count after refreshing, so the existing `iventoy.service` was restarted through
systemd while no client was connected. A subsequent refresh returned success;
`query_status` reported `running`, `get_img_tree` listed exactly beta.18,
`get_img_summary` reported `count: 1`, and the service was `active`.

The PXE client at `10.10.1.64` disconnected before replacement; the user also
confirmed it was shut down. Physical PXE installation was not exercised by this
task.

## Cleanup and retained deliverables

The supervised lease closed and `agent-resource check` reported no remaining
resources, preserved volumes or errors. Both VMs stopped; their private
workspace and disks were removed. The peak observed workspace usage was
117 GiB. The CI capacity reservation was released with its holder's stdin.

Removed the duplicate task-owned Nix ISO output
`/nix/store/7k01fgq7vds9ka3ck6c3wxv52bdmfwy3-cybexos-1.0.0-beta.18-x86_64-linux.iso`
with targeted `nix store delete` (one store output; 6,790.71 MiB freed).
Removed `/data/tmp/cybexos-beta18-main-cleanup-qzEJSk`, including temporary logs,
parity extraction/output, qualification JSON, helper scripts and build/profile
links. Verified those output paths and the VM workspace were absent. Normal
Nix build dependencies and check outputs remain in the shared build cache.

The retained test deliverables are the 7,120,576,512-byte PXE ISO and its 92-byte
SHA-256 file listed above. This repository record retains the useful evidence.
The final checks found one clean `main` worktree, only `main` among local and
remote branches, and an up-to-date `origin/main` after pushing this record.
