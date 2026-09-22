# CybexOS

CybexOS stands for **Cybex Opinionated System**. It is an opinionated Hyprland
and Quickshell desktop for Fedora Linux, installed and
kept current with Ansible. The core configuration is hardware-neutral. A
separate, precisely gated role preserves extra support for the 2026 Dell XPS
14 and 16.

The current release target is Fedora 44 on x86_64. Fedora remains responsible
for the kernel, drivers, SELinux, and base operating system.

The application command is `cybex`. The old `fedora-config` command remains
available for compatibility. Package and service identifiers, configuration
and data paths, and the agent skill name remain stable for existing systems.
The source repository is currently hosted at `DigitalPals/fedora-config`.

## What it installs

- Hyprland, a custom Quickshell menubar, GDM, portals, notifications, and
  desktop services
- a portable Fedora package, Flatpak, shell, font, firewall, and recovery
  baseline
- developer/Android tools, Steam, Docker, Podman/Distrobox, Tailscale,
  connected-service widgets, proprietary applications, and source-built tools
  enabled by default
- automatically detected XPS 2026 speaker, camera, haptic, fingerprint,
  backlight, firmware, and power support
- a persistent installer configuration, verifier, uninstaller, and verified
  GitHub release updater
- one release-scoped CybexOS skill discoverable by compatible coding
  agents for safe installed-system diagnosis and customization
- a user-selectable default AI coding agent with terminal, launcher, and
  keyboard entry points

There is no desktop-preset selection: every installation gets the same core
Hyprland/Quickshell desktop. The installer asks only about the target machine,
security decisions, personal dotfiles, and application opt-outs.

## Install

Start with Fedora 44 and a user that can run `sudo`:

```bash
sudo dnf install -y git
git clone https://github.com/DigitalPals/fedora-config.git
cd fedora-config
./install
```

No inventory or configuration file needs to be edited first. The installer
detects the current desktop user, home directory, hostname, timezone, locale,
and keyboard settings and offers them as defaults. All application groups
are selected by default, including in non-interactive installs; interactive
setup allows explicit opt-outs. Fastfetch is a required baseline package.
The installer explicitly asks whether to enable passwordless sudo, passwordless
local Polkit authorization, and GDM autologin. The two passwordless choices
have no implicit answer.

Answers are saved in `/etc/fedora-config/config.yml`, outside versioned release
trees, and are reused by later installs and updates. Existing explicit
application opt-outs are preserved; missing choices receive the full defaults. Run
`cybex configure` to ask the questions again. `./bootstrap` remains a
compatibility alias for `./install`. The first successful install snapshots
the runtime source under `~/.local/share/fedora-config/releases/`, so the
cloned checkout can then be moved or removed.

That active release also owns the canonical `fedora-config` agent skill.
Installation always links it at `~/.agents/skills/fedora-config`,
`~/.claude/skills/fedora-config`, and `~/.codex/skills/fedora-config`, whether
or not a corresponding agent is currently installed. Invoke it explicitly as
`$fedora-config` in Codex or `/fedora-config` in Claude Code; its focused
description also supports automatic selection.

Before any role adopts configuration, the installer creates a one-time backup
under `~/.local/state/fedora-config/backups/initial/`. Existing Hyprland and
Quickshell trees are always preserved; personal application files are added
when the optional dotfiles integration is selected. Uninstall restores those
pre-existing files. Managed Fish, Kitty, Git, and SSH settings use
fragments/includes where those applications support them. Bundled wallpapers
are installed into `~/Pictures/Wallpapers`, and a mountain wallpaper is selected when no wallpaper is configured. Existing selections and
custom folders are preserved. Change the image in Shell Settings → Wallpaper.
No avatar is imposed.

To install or refresh only the wallpapers using the saved configuration:

```bash
ansible-playbook site.yml -e @/etc/fedora-config/config.yml --tags wallpapers
```

A lone tiled window on an external monitor is centered at 70% of the display's
width, adapting to resolution, scaling, and rotation. Laptop panels and
workspaces with multiple tiled windows use the normal small edge gaps.

Desktop runtime and user customization have a strict boundary. Verified
releases reconcile `~/.local/share/fedora-config/runtime`, while shell
settings, Hyprland overrides, themes, and plugins live in user-owned roots
that updates never prune. An upgrade from the legacy layout emits a migration
report and preserves customized QML/Lua without trying to translate it. See
[the ownership architecture](docs/architecture/ownership.md) for the complete
path and migration contract.

Personal bar widgets use a versioned API and live outside the distro runtime.
Codex/Claude can create a package in
`~/.local/share/fedora-config/plugins/<id>/` and enable it with
`cybex plugin enable <id>`. Its preferences and data survive updates;
no edits to built-in shell modules are needed. See the
[widget contract and commands](docs/architecture/user-widgets.md). The
ownership guide also identifies remaining application-configuration gaps.
The Omarchy compatibility adapter supports widgets, shared services, panels,
overlays, menus, and replacement bars, with representative unchanged plugins tested. See [installation and limits](docs/omarchy-plugin-compatibility.md).

Each pre-existing `fedora-config` skill slot is backed up independently before
first adoption. Updates retarget all three paths through the atomic active
release link, and uninstall restores the exact original file, directory, or
symlink without changing neighboring skills.

## Default AI agent

Developer tooling installs pinned Claude Code, OpenCode, and Codex CLI
versions. CybexOS does not silently prefer one provider: the first
interactive invocation asks which installed agent to use and stores that
per-user choice at `~/.config/fedora-config/defaults/agent`.

```bash
cybex agent                 # launch the default in this directory
cybex agent --pick          # choose, remember, and launch another
cybex agent set opencode    # change the default without launching
cybex agent list            # show supported and installed agents
cybex agent prompt "review this change"
```

`Super+Ctrl+Shift+A` opens the default agent in a Kitty window rooted at
`~/Code`. The Quickshell Actions tab can launch or choose it as well. Managed
Fish configuration provides the short alias `a`.

The dispatcher passes no automatic-approval or permission-bypass flags and
never stores credentials. Authentication, model selection, permissions, and
provider-specific settings remain owned by each agent. The preference survives
updates and uninstall because it is user data rather than Ansible policy.

## Update

After the first install, use:

```bash
cybex update
```

The updater follows the saved `stable` channel by default (`--channel beta`
selects and saves prereleases). It resolves an immutable GitHub release,
verifies GitHub's release and asset attestations, checks the API SHA-256
digest, validates Fedora/architecture/config-schema compatibility, and
extracts into a versioned staging directory. One durable system worker owns the
saved-answer migration, candidate application, rollback, and atomic `current`
symlink change, so detaching the terminal cannot split the transaction. A
failed apply restores the previous configuration. The active release and two
recent fallbacks are kept.

The same durable worker updates Fedora packages and system Flatpaks. From the
Quickshell panel, systemd requests authorization through the desktop's native
Polkit agent and progress remains in the Updates view; the worker then runs in
a transient system unit, so a Quickshell restart does not interrupt package
work. Terminal invocations retain their sudo-compatible path. On Btrfs,
package work first creates a paired read-only root snapshot and `/boot`
archive.

Useful commands:

| Command | Purpose |
| --- | --- |
| `cybex update --check` | Check the configured GitHub channel |
| `cybex update --system-only` | Update Fedora and Flatpak only |
| `cybex agent` | Launch or choose the per-user default AI coding agent |
| `cybex dev status` | Show whether the verified or a development runtime is active |
| `cybex plugin list` | Inspect personal widgets and API compatibility |
| `cybex verify` | Check the installed system (`--source` opts into developer checks) |
| `cybex doctor` | Alias for `verify` |
| `cybex configure` | Re-run the installer questions |
| `cybex uninstall` | Remove project-managed configuration; retain applications |

Detailed updater status, logs, cancellation, Btrfs recovery, and advanced
Ansible tags are documented in [the operations guide](docs/operations.md).

## Hardware support

Generic systems skip every XPS workaround. The `xps-2026` role activates only
for Dell vendor/product identifiers, supported SKUs `0DB9` or `0DBA`, and the
expected Panther Lake CPU family; individual devices are gated again before
their configuration is installed. See
[Dell XPS 2026 hardware support](docs/xps-2026-hardware.md).

## Development and releases

```bash
./verify --source
./tests/fedora-vm-convergence
cybex dev enable "$PWD"
cybex dev disable
```

Development mode reads live Quickshell and static Hyprland modules from the
validated checkout. It never fetches, resets, merges, or writes to that
checkout, and normal internet updates remain enabled in parallel.

CI runs the complete source contract in Fedora 44 and converges all roles on a
generic Fedora Cloud VM twice to enforce idempotence. A `vX.Y.Z` tag publishes only
after both gates pass. Repository release immutability must be enabled before
the first public tag.

Key documentation:

- [Operations and recovery](docs/operations.md)
- [Runtime and user ownership](docs/architecture/ownership.md)
- [Release process](docs/releasing.md)
- [Dependency and pinning policy](docs/dependency-policy.md)
- [Fedora major upgrades](docs/fedora-major-upgrade.md)
- [Licensing and asset provenance](docs/licensing.md)
- [Quickshell development notes](docs/quickshell-notes.md)

> [!IMPORTANT]
> The repository does not yet contain a repository-wide software license.
> Select one before calling the project open source or publishing a public
> release. Undocumented bundled raster assets were removed from the release
> payload; `assets/PROVENANCE.json` enforces that boundary.
