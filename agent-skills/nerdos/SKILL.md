---
name: nerdos
description: Customize or maintain a NerdOS NixOS Hyprland/Quickshell desktop, including personal packages, services, VPNs, widgets, settings, staged updates and recovery. Use on supported NerdOS installations; not for unrelated NixOS hosts.
---

# NerdOS

Read `/etc/os-release` and `/etc/nerdos/release.json` before making changes.
The supported machine configuration is `/etc/nixos/flake.nix` and its
`flake.lock`; `/etc/nixos` is the machine-owned working-configuration symlink.
Read its modules and applicable repository instructions. A checkout is vendor
source, not the personal configuration of the running desktop.

Choose the owner before editing:

- Vendor: `/nix/store`, `/etc/nerdos/runtime` and
  `/run/current-system/sw/share/nerdos`. Inspect read-only. Personal changes
  never require editing these files or forking NerdOS.
- Machine/personal declarations: `/etc/nixos/local/*.nix`, imported by
  `local/default.nix`. Add packages, services and VPN definitions here.
  Normal Nix definitions override vendor `mkDefault` values. Preserve unrelated
  declarations and inputs; do not replace entire files with a small example.
- Desktop preferences: `~/.config/nerdos/shell.json`, `displays.json` and
  `hypr/user.lua`. Preferences apply without rebuilding the operating system.
  Read [Quickshell settings](references/quickshell-settings.md) before edits.
- Plugins: personal code, preferences, placement and data are separate from
  the vendor runtime. Read [User widgets](references/user-widgets.md), use the
  API 1 contract and `nerd plugin` for native or Omarchy plugins. Personal QML
  must not import private shell types. Plugins are trusted code, not sandboxed.
- Secrets/state: `/var/lib/nerdos/secrets` (root `0700`, files `0600`),
  persistent service directories, and the person's home. Use `privateKeyFile`,
  `LoadCredential` or the service's documented runtime secret API. Never put
  secret values or `builtins.readFile` of a secret in a flake, Nix string,
  source archive, command argument, log, or public repository.

For packages, services or a VPN, read
[Personal declarations](references/managed-configuration.md). NetworkManager
profiles and credentials may instead use its persistent system D-Bus APIs;
do not copy a credential into a Nix declaration.

Preview a requested system change through `nerd update stage local`. This
builds the complete configuration and checks the candidate desktop. Inspect
`nerd update status`, including actual package changes and errors. Apply only
the reviewed `transaction` and `reviewToken` using
`nerd update apply TRANSACTION REVIEW_TOKEN`. An authorized request to make
and apply a customization covers this workflow; a diagnostic request does not.
Never substitute a direct `nixos-rebuild switch` or manual lock refresh for the
supported lifecycle. Explain required administrator authentication.

For updates, select `upstream`, `nerdos` or `both` explicitly. Personal inputs
are updated only on a separate explicit request. A combined failure offers an
explicit upstream-only retry retaining installed NerdOS; never remove modules
or widgets to make a build pass. Keep `system.stateVersion` unchanged. Read
[Commands and recovery](references/commands.md) when applying or recovering.

All live Quickshell tests must source the installed
`/run/current-system/sw/share/nerdos/lib/quickshell-live` and run `qs_live_begin`
and `qs_live_end`. In a checkout use `tests/lib/quickshell-live`. The managed
service's MainPID must be the sole `qs` PID and its current journal must be
clean. Never use `pkill qs` or launch a second menubar. Preview personal plugin
code in an isolated test environment, or use the managed service under these
guards when the user has authorized a live test.

Report what changed, the preview/build and health results, persistent data
impact, and any required user-selected restart. Never reboot without an
explicit preference or instruction. Generation rollback restores system code
and configuration; it does not roll back credentials or application databases.
