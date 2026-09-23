# CybexOS ownership boundary

CybexOS updates replace vendor runtime and integration files. They do
not merge into user customization trees. This is the machine-enforced boundary
for the transitional, pre-RPM layout.

| Owner | Path | Update behavior |
| --- | --- | --- |
| Vendor | `~/.local/share/fedora-config/runtime/quickshell/` | Reconciled exactly from a verified release |
| Vendor | `~/.local/share/fedora-config/runtime/hypr/` | Reconciled from rendered defaults in a verified release |
| Vendor | `~/.local/share/fedora-config/releases/` and `current` | Staged and atomically selected by the release updater |
| User | `~/.config/fedora-config/shell.json` | Read and written by the shell; never written by Ansible after a one-time, non-overwriting legacy copy |
| User | `~/.config/fedora-config/hypr/` | Optional `user.lua`, `hypridle.conf`, and `hyprlock.conf` overrides |
| User | `~/.local/share/fedora-config/themes/` | Reserved user theme packages; never reconciled or pruned |
| User | `~/.local/share/fedora-config/plugins/` | API 1 widget packages; never reconciled or pruned |
| User | `~/.config/fedora-config/plugins.json` | Separate widget enablement and preferences; never written by Ansible |
| User | `~/.local/share/fedora-config/plugin-data/` | Persistent widget data; retained on update and uninstall |
| State | `~/.local/state/fedora-config/` | Health, update, migration, and shell runtime state |

The session always starts Hyprland with the vendor entry point. Vendor modules
load first; `~/.config/fedora-config/hypr/user.lua`, when present, loads last.
The idle and lock services prefer their same-named user configuration files
and otherwise use vendor defaults. A bad user override may break that component
but is never silently replaced by an update. Without a user `hypridle.conf`,
the idle service applies the timeouts from Settings → System → Idle: the
runtime resolver renders them from `shell.json` into
`$XDG_RUNTIME_DIR/fedora-config/hypridle.conf` at each start (falling back to
the vendor file), and the shell restarts `hypridle.service` after a change is
saved.

Quickshell starts with an explicit `qs -p` path. The legacy
`~/.config/quickshell` and `~/.config/hypr` trees are not runtime inputs after
the transition. On the first layered convergence, their entries are classified
against the previously active release. Customized and unrecognized entries are
copied into a timestamped migration directory, a JSON report is written, and
the legacy trees themselves are left untouched. No ambiguous QML or Lua is
translated automatically.

## Development source switch

`cybex dev enable /absolute/path/to/checkout` selects live Quickshell
sources and static Hyprland modules from a validated, user-owned Git checkout.
Rendered machine modules continue to come from the installed runtime. The
command records only the canonical path and reloads managed desktop components;
it never fetches, resets, merges, commits, or writes inside the checkout.

Use `cybex dev status` to show the active source and
`cybex dev disable` to return to the verified vendor runtime. Internet
updates continue to stage and activate releases while development mode is on;
they do not modify the selected checkout or user-owned paths.

## Enforcement rules

- Deployment may prune only a vendor-owned runtime root.
- Normal convergence must not copy, template, link, or remove children below
  the user-owned roots in the table, except to create an absent directory or
  perform an explicitly non-overwriting legacy migration.
- Uninstall removes vendor runtime and integration artifacts, not user-owned
  Quickshell, Hyprland, theme, or plugin trees.
- The ownership-preservation test runs in the source and release gates and
  simulates an N to N+1 update with byte-for-byte user sentinels.

## Customization compatibility

File ownership and runtime compatibility are separate requirements. The
[user widget API](user-widgets.md) gives personal QML a versioned interface,
independent preferences, and real-engine compatibility fixtures. Agents use
that interface for personal widgets; a distro checkout is for changing the
vendor implementation. A future refactor must retain supported API adapters.

The distro-wide target is vendor defaults followed by explicit user choices.
New defaults apply to settings without an explicit choice; they must not
erase user choices even when those choices equal an old default. Migration
must preserve unknown fields, retain a recoverable original, and avoid
downgrading data on rollback. A new API or schema needs a compatibility plan
and upgrade/rollback fixtures before it is released.

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
- Extend release tests beyond file sentinels: verify settings behavior, an
  enabled API fixture, service overrides, app defaults, failed updates, and
  rollback against supported previous releases. Preserve user-created package
  and service additions when optional distro features change.

Until those changes land, the widget contract does not imply that every
existing application setting already survives distro convergence unchanged.
