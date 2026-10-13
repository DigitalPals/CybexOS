---
name: cybexos
description: Operate and customize an installed CybexOS Hyprland/Quickshell workstation. Use for CybexOS diagnostics and commands, personal widgets, shell or bar settings, managed desktop changes, screenshots, recording, OCR, reminders, or LocalSend; not for unrelated Fedora systems.
---

# CybexOS

Use this skill for an installed [CybexOS](https://github.com/DigitalPals/CybexOS)
desktop (Cybex Opinionated System). Codex can invoke it as `$cybexos`; Claude
Code exposes the same skill as `/cybexos`. Its description also supports
automatic selection.

## Identify the installation

Check `rpm -q cybexos-desktop` first. On ISO installations, packaged vendor
files are under `/usr/share/cybexos`; the user's
`~/.local/share/cybexos/runtime` is a compatibility symlink to the packaged
runtime. These systems do not use `~/.local/share/cybexos/current`.

If the desktop RPM is absent, check whether this is a source-checkout
installation. Its active release is selected by
`~/.local/share/cybexos/current`; inspect it read-only for diagnostics and
schemas. Do not assume a missing RPM means an incomplete installation.

## Choose the ownership layer

- User shell preferences belong in `~/.config/cybexos/shell.json`. Read
  [Quickshell settings](references/quickshell-settings.md) before editing it.
- Personal bar widgets belong in user-owned plugin packages. Read
  [User widgets](references/user-widgets.md); use the versioned plugin API and
  `cybex plugin` commands.
- Personal Hyprland changes belong in `~/.config/cybexos/hypr/user.lua`.
- Changes to distro defaults, built-in Quickshell code, services, packages,
  and other vendor behavior belong in a writable source checkout. Read
  [Managed configuration](references/managed-configuration.md).

For supported operator commands and desktop actions, read
[Commands and desktop helpers](references/commands.md).

## Boundaries

- Never edit packaged files under `/usr/share/cybexos` or files below the
  source installation's `~/.local/share/cybexos/current` or
  `~/.local/share/cybexos/runtime` directly.
- Do not treat `cybex repair` as a way to deploy checkout changes. On ISO
  installations it reapplies the policy bundled with the installed RPM; make
  vendor changes in source, rebuild/update the desktop RPM, and then use the
  supported package update path.
- Never add personal plugin IDs or settings to `shell.json`'s built-in `mods`
  or `modOpts`. Preserve plugin packages, preferences, and state across
  updates and rollbacks.
- Preserve unrelated checkout changes. Read every applicable `AGENTS.md`
  before modifying or testing a checkout.
- Require explicit user intent before reconfiguration, updates, uninstall,
  cancellation, reboot, shutdown, reset, package removal, or another
  destructive operation. A diagnostic request authorizes inspection, not a
  repair or upgrade.
- Never use `pkill qs`. Every live Quickshell check must use the checkout's
  `tests/lib/quickshell-live` start and end functions, including their PID,
  service, and current-invocation journal checks.

Prefer the least invasive diagnostic that answers the request. Report what was
observed, what was changed, the verification performed, and anything that
still needs manual confirmation.
