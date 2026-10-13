# Managed Hyprland and Quickshell changes

Use this guide for persistent behavior owned by CybexOS: Hyprland,
Quickshell source, services, packages, launchers, or provisioning policy.
Personal widgets use [the user widget API](user-widgets.md), and personal
Hyprland overrides use `~/.config/cybexos/hypr/user.lua`. Those changes do
not need a distro fork. Never edit deployed vendor copies.

ISO installations receive vendor files in the `cybexos-desktop` RPM under
`/usr/share/cybexos`; `~/.local/share/cybexos/runtime` points to its runtime.
There is no `~/.local/share/cybexos/current` release link on this installation
type. Persistent vendor changes for an ISO installation must be made in a
source checkout, included in a rebuilt desktop RPM, and delivered through the
RPM update channel. `cybex repair` reapplies policy bundled in the installed
RPM; it does not deploy files from a checkout.

## Find a writable checkout

1. Inspect the current working tree and `~/Code/CybexOS` first. A usable
   checkout must be writable, have this repository's `site.yml`, and identify
   `DigitalPals/CybexOS` (formerly `DigitalPals/fedora-config`) as an expected
   Git remote. Do not mistake
   `~/.local/share/cybexos/current` or a versioned release for a checkout.
2. If needed, search a small set of user source roots such as `~/Code` without
   traversing the whole home directory. Inspect `git status` before choosing a
   tree, and preserve all existing modifications.
3. If no suitable checkout exists, ask before cloning
   `https://github.com/DigitalPals/CybexOS.git` into
   `~/Code/CybexOS`. Cloning is not implied by a customization or
   diagnostic request.
4. Read the repository root `AGENTS.md` and any nearer `AGENTS.md` files before
   acting.

Use the packaged source under `/usr/share/cybexos` read-only to inspect an ISO
installation. On a source-checkout installation, use its active release
read-only when no source change is needed. These are different deployment
paths; do not run checkout Ansible against an ISO installation as a way to
apply RPM-managed files.

## Change and deploy

Keep the edit in the smallest managed source file. Check the worktree before
and after, and do not reformat, delete, stage, or restore unrelated changes.

Run the repository gate before a source-checkout deployment:

```bash
./tests/run
```

For source-checkout installations, preview the machine change with the saved
installer contract when practical:

```bash
ansible-playbook site.yml -e @/etc/cybexos/config.yml --check --diff
```

Deploy to a source-checkout installation through Ansible, choosing only a
documented narrow tag when its prerequisites are already present. Hyprland and
Quickshell are normally in the `desktop` role:

```bash
ansible-playbook site.yml -e @/etc/cybexos/config.yml --tags desktop
```

Do not copy source files directly into `~/.config`. Do not run reconfiguration,
an update, uninstall, reboot, package removal, or reset unless the user
explicitly requested that operation.

## Live Quickshell safety

Every live shell inspection or smoke test must source this checkout's
`tests/lib/quickshell-live` and call `qs_live_begin` before the check and
`qs_live_end` afterward. Ensure `qs_live_end` also runs on failure and signals.
Those functions reconcile `quickshell.service`'s `MainPID` against every
`pgrep -x qs` result, inspect extra processes before terminating only confirmed
developer instances, restore service health, and inspect the current
invocation journal. Never substitute a handwritten shortcut and never run
`pkill qs`.

Prefer deployment followed by testing through `quickshell.service`. If a
source-tree `qs -d` or `qs -p` session is genuinely necessary, stop
`quickshell.service` first and install cleanup that always terminates only that
known developer PID and restores the service. The test is incomplete until
`qs_live_end` confirms the managed service is active and is the sole clean
`qs` process.
