# Managed Hyprland and Quickshell changes

Use this guide for persistent behavior owned by CybexOS: Hyprland,
Quickshell source, services, packages, launchers, or Ansible policy. Personal
widgets use [the user widget API](user-widgets.md), and personal Hyprland
overrides use `~/.config/cybexos/hypr/user.lua`. Those changes do not need
a distro fork. Do not edit deployed vendor copies or the active release tree.

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

Use the active release read-only when no source change is needed. It contains
the exact deployed command and schema sources and is safer evidence than
memory.

## Change and deploy

Keep the edit in the smallest managed source file. Check the worktree before
and after, and do not reformat, delete, stage, or restore unrelated changes.

Run the repository gate before deployment:

```bash
./tests/run
```

Preview the machine change with the saved installer contract when practical:

```bash
ansible-playbook site.yml -e @/etc/cybexos/config.yml --check --diff
```

Deploy through Ansible, choosing only a documented narrow tag when its
prerequisites are already present. Hyprland and Quickshell are normally in the
`desktop` role:

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
