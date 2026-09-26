# CybexOS ownership boundary

CybexOS has two supported installation paths. ISO installations receive vendor
files through the `cybexos-desktop` RPM, installed under
`/usr/share/cybexos`; source-checkout installations use versioned releases and
may opt into a writable development checkout. In both paths, user preferences
and personal packages remain in user-owned locations.

| Owner | Path | Update behavior |
| --- | --- | --- |
| Vendor, ISO | `/usr/share/cybexos/` | Owned by `cybexos-desktop`; replaced by RPM upgrades |
| Vendor, ISO | `~/.local/share/cybexos/runtime` | Compatibility symlink to `/usr/share/cybexos/runtime` |
| Vendor, source checkout | `~/.local/share/cybexos/runtime/` | Reconciled from the selected verified release |
| Vendor, source checkout | `~/.local/share/cybexos/releases/` and `current` | Staged and atomically selected by the source updater |
| User | `~/.config/cybexos/shell.json` | Shell preferences; preserved by package/release updates |
| User | `~/.config/cybexos/hypr/` | Optional `user.lua`, `hypridle.conf`, and `hyprlock.conf` overrides |
| User | `~/.config/cybexos/displays.json` | Settings → Displays choices per physical monitor |
| User | `~/.local/share/cybexos/themes/` | User theme packages; not reconciled or pruned |
| User | `~/.local/share/cybexos/plugins/` | API 1 widget packages; not reconciled or pruned |
| User | `~/.config/cybexos/plugins.json` | Widget enablement and preferences; not written by Ansible |
| User | `~/.local/share/cybexos/plugin-data/` | Persistent widget data; retained on update and uninstall |
| State | `~/.local/state/cybexos/` | Health, update, migration, and shell runtime state |
| State, machine | `/var/lib/cybexos/` | Reconciliation state, backups, and hardware setup status |

On the RPM path, package upgrades defer versioned account and machine policy
updates to `cybexos-reconcile.service` and its timer. Reconciliation preserves
existing edits by backing up files before updating them; inspect status with
`sudo /usr/libexec/cybexos-reconcile --status` and request a retry with
`sudo /usr/libexec/cybexos-reconcile --retry`. The user initialization payload
uses versioned defaults, separately from unversioned tool-seed data. Hardware
setup status is recorded at `/var/lib/cybexos/hardware-status.json` as
`pending`, `completed`, or `failed`; a pending camera setup resumes after a
same-kernel reboot. The welcome window displays this status.

On the source-checkout path, the session starts Hyprland with the vendor entry
point. Vendor modules load first, then saved Settings → Displays choices, and
`~/.config/cybexos/hypr/user.lua`, when present, loads last. Bindings it adds
with a `Group: Label` description appear in the Super+K cheatsheet
([keyboard shortcuts](../keyboard-shortcuts.md)). The idle and lock services
prefer their same-named user configuration files and otherwise use vendor
defaults. User overrides are not silently replaced by release updates.

Quickshell starts with an explicit `qs -p` path. The legacy
`~/.config/quickshell` and `~/.config/hypr` trees are not runtime inputs after
the transition. On the first layered convergence, their entries are classified
against the previously active release. Customized and unrecognized entries are
copied into a timestamped migration directory, a JSON report is written, and
the legacy trees themselves are left untouched. No ambiguous QML or Lua is
translated automatically.

## Development source switch

`cybex dev enable /absolute/path/to/checkout` selects live Quickshell sources
and static Hyprland modules from a validated, user-owned Git checkout on the
source-checkout path. Rendered machine modules continue to come from the
installed runtime. The command records only the canonical path and reloads
managed desktop components; it never fetches, resets, merges, commits, or
writes inside the checkout.

Use `cybex dev status` to show the active source and `cybex dev disable` to
return to the verified vendor runtime. Internet updates continue to stage and
activate releases while development mode is on; they do not modify the selected
checkout or user-owned paths. ISO installations use RPM updates instead of this
release switch.

## Enforcement rules

- ISO package upgrades own files under `/usr/share/cybexos`; do not edit those
  deployed vendor files in place.
- Source deployment may prune only its vendor-owned runtime root.
- Normal convergence must not copy, template, link, or remove children below
  user-owned roots, except to create an absent directory or perform an
  explicitly non-overwriting legacy migration.
- Uninstall removes vendor runtime and integration artifacts, not user-owned
  Quickshell, Hyprland, theme, or plugin trees.
- Ownership-preservation checks simulate updates with user data sentinels.

## Customization compatibility

File ownership and runtime compatibility are separate requirements. The
[user widget API](user-widgets.md) gives personal QML a versioned interface,
independent preferences, and real-engine compatibility fixtures. Agents use
that interface for personal widgets; a source checkout is for changing the
vendor implementation. A future refactor must retain supported API adapters.

The distro-wide target is vendor defaults followed by explicit user choices.
New defaults apply to settings without an explicit choice; they must not erase
user choices even when those choices equal an old default. Migration must
preserve unknown fields, retain a recoverable original, and avoid downgrading
data on rollback. A new API or schema needs a compatibility plan and
upgrade/rollback fixtures before it is released.

That target is not yet enforced for every application. Remaining work:

- Shell settings currently normalize to known keys and have visual migrations
  that infer an untouched value from equality with a previous default. Replace
  that inference with explicit override tracking; treat legacy stored choices
  conservatively. Keep unsupported future schemas read-only on older hosts.
- Personal-dotfile deployment still replaces files such as Fastfetch,
  Voxtype, MIME associations, and XDG user directories. Move defaults into
  vendor fragments where supported, or seed only absent user files. Migrate
  adopted files using a last-installed baseline and preserve conflicting edits.
- Includes need application-specific precedence tests. Git and Kitty commonly
  use later values; SSH commonly uses the first obtained value. The current
  SSH include at the beginning can take precedence over personal choices.
- Extend release checks beyond file sentinels: verify settings behavior, an
  enabled API fixture, service overrides, app defaults, failed updates, and
  rollback against supported previous releases. Preserve user-created package
  and service additions when optional distro features change.

Until those changes land, the widget contract does not imply that every
existing application setting already survives distro convergence unchanged.
