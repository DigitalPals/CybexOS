# Personal configuration and extensions

Put package, service, hardware and VPN declarations in `/etc/nixos/local/` and
import each from `local/default.nix`. The machine template includes a WireGuard
example with `privateKeyFile`; put the key at a private runtime path. Use the
service's persistent D-Bus API for NetworkManager profiles. Vendor code and
assets in the Nix store remain read-only. Preview/apply changes through the
same lifecycle as updates, using `cybex update stage local`.

A regular Git repository in `/etc/nixos` keeps its history, index, remotes and
hooks as persistent personal metadata. Selected working configurations reference
the retained original `.git` directory; snapshots and Nix source archives omit
it. The updater never invokes Git or hooks. Do not remove a retained working
directory that is the target of an active `.git` reference. Linked worktrees,
pointer files, unmanaged `.git` symlinks, `core.worktree` overrides and included
Git configuration are refused before application because moving their worktree
would require changing user metadata. Use a regular repository without these
layouts, or manage a separate personal repository and copy declarations into
the supported machine configuration before previewing them.

Cisco IKEv1/IPsec uses NetworkManager's maintained Libreswan backend. Keep
connection secrets in the keyring or NetworkManager's private persistent
connection files. Libreswan's NSS database lives in root-private
`/var/lib/ipsec/nss`; it is persistent state, outside the Nix store and system
generation rollback. Do not put PSKs, passwords or private keys in
`services.libreswan.connections` or `configSetup` text. Use root-private
runtime files and the service's supported secret-loading configuration.

Desktop preferences use sparse `~/.config/cybexos/shell.json`; monitor choices
use `displays.json`; personal Hyprland Lua loads last from `hypr/user.lua`.
They apply without rebuilding the OS. Unknown preference fields, explicit
choices and conflict/migration sidecars are retained. Older shells treat a
newer unsupported preference schema as read-only.

With developer tools enabled, first login seeds a writable LazyVim starter only
when `~/.config/nvim` is absent. The reviewed starter revision is pinned in the
desktop package; update that pin when qualifying new initial editor defaults.
Existing Neovim configuration is always personal. LazyVim downloads its plugins
on first use and manages their lock/state independently of OS updates.

Personal widget code lives in `~/.local/share/cybexos/plugins/ID`, placement and
preferences in `~/.config/cybexos/plugins.json`, and state in
`~/.local/share/cybexos/plugin-data/ID`. Theme packages have their own personal
data directory. Use `cybex plugin` and `cybex theme`; no personal package is
copied into the vendor runtime or deleted during an OS rollback.

[Widget API 1](architecture/user-widgets.md) and
[Omarchy compatibility](omarchy-plugin-compatibility.md) are public contracts.
The preserved native interface injects `pluginApi`; all six supported Omarchy
plugin kinds use the existing adapters. Plugins are trusted code and may access
the session's privileges. File survival alone does not prove runtime compatibility;
release qualification must run actual engine/plugin tests.

Claude Code and Codex discover the same packaged `cybexos` skill through their
user-scoped discovery directories. Only absent slots gain a stable system-profile
symlink. A vendor update/rollback updates its skill target automatically; an
existing user-authored skill is preserved and reported. Other skills are never
modified. [The skill](../agent-skills/cybexos/SKILL.md) documents ownership,
secrets, local declarations, previews, application and recovery.

Regional Settings previews write the machine-owned `desktop-settings.json` in
an isolated candidate through `cybex config region`. The template's `settings.nix`
imports it. Timezone and system language become persistent declarations after
the normal reviewed apply; they do not use mutable localed/timedated writes that
would disappear on rebuild. Existing locale categories remain separate. This
small typed file is not a place for secrets or arbitrary module expressions.
