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
| User | `~/.config/cybexos/fusebox/` | The Fusebox widget's private management key (0600); written only from its settings |
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

The Hyprland startup hook must also work when the development checkout is
selected on an ISO installation. Checkout installs place the ordered session
starter in `/usr/local/libexec`; ISO/RPM installs place it in `/usr/libexec`.
`autostart.lua` resolves an executable helper at login, including when the
checkout is loaded verbatim without the image packager's path rewriting.
Otherwise Hyprland can start with `hyprland-session.target` inactive, leaving
Quickshell, wallpaper, idle handling and desktop portals unavailable. The
session startup fixtures exercise checkout, packaged and ISO development
layouts in both source gates.

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

Shell settings now use a sparse schema-27 document: the presence of a known
key records an explicit choice, including a choice equal to the current
default. Reset removes the override; Undo restores its ownership as well as
its value. Legacy stored values are conservatively treated as explicit. Visual
redesigns no longer infer an untouched preference from equality with an old
default. Unknown JSON fields survive edits and resets, and a newer schema is
read-only on an older shell.

The asynchronous settings writer merges independent external edits, rejects
conflicting writes, and confirms fsync and atomic publication before reporting
success. A rejected edit is retained in a `shell.json.conflict-*` sidecar before
the form reloads the external values. The first schema migration retains the
exact original in `shell.json.before-migration-*`. These files live beside the
user's settings and are retained for recovery; the shell never prunes them.
The production Qt document component has real-engine lifecycle tests for
queued changes, retries and unknown data, alongside filesystem transaction tests.

Personal application stores (Fastfetch, Voxtype, Oh My Posh, MIME associations,
XDG directories and npm configuration) are seeded only when absent. Shared
Fish, Kitty, Git and SSH fragments use the same ownership ledger on checkout
and ISO paths. A fragment advances only if it still matches its last installed
bytes; conflicting edits, symlinks and explicit deletions survive. Adopted
bytes are backed up before replacement. Unknown legacy fragments remain
user-owned instead of being guessed at from their filename.

Managed includes follow each application's precedence: Git/Kitty defaults
come first, while SSH fallbacks come last in an explicit `Host *` scope.
Git credential helpers accumulate instead of overriding, so vendor credential
helpers are omitted when personal configuration provides its own chain. The
SSH vendor fragment lives outside `.ssh/config.d` so wildcard includes cannot
accidentally give it priority over a personal host. Moving an old unedited
include retains its original file; edited include blocks are left intact.

Remaining release coverage should exercise service overrides, optional package
and service additions, and supported previous releases across failure and
rollback, beyond file sentinels. Application ownership is scoped to these
managed fragments; independent application databases remain the application's
responsibility.

The widget contract does not imply ownership of unrelated application state.
