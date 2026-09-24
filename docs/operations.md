# Operating and diagnosing this configuration

This is the authoritative operator contract for repository commands, Ansible
tags, source checks, update logs, and deliberate reboots. The short command
table in the README links here instead of duplicating these details.

## Command behavior

| Command | Behavior |
| --- | --- |
| `./install` | Detects machine defaults, asks first-run questions, saves `/etc/cybexos/config.yml`, installs `ansible-core` when needed, and applies `site.yml`. Later runs reuse the saved answers. |
| `./bootstrap` | Compatibility alias for `./install`. |
| `./tests/run` | Runs all required source-tree checks without inspecting or changing the live machine. |
| `./verify` | Runs complete source and non-destructive installed-system checks. Use `--source`, `--system`, or `--quick` for a narrower scope and `--json` for automation. |
| `./update` | Resolves and verifies the selected GitHub release channel without a GitHub login, applies a newer compatible release, then starts the durable Fedora/Flatpak worker. With no published release it only updates packages and succeeds; if a release cannot be checked, verified, or staged, it still updates packages and exits 69. |
| `./update --system-only` | Skips the project release check and updates Fedora packages and system Flatpaks only. |
| `cybex agent` | Launches the selected AI coding agent in the current directory; an unset interactive session opens the picker. |
| `cybex agent --pick` | Selects, persists, and launches an installed OpenCode, Claude Code, or Codex CLI. |
| `cybex dev enable PATH` | Selects a validated checkout for live desktop source without changing it. |
| `cybex dev status` | Reports the active development or vendor runtime. |
| `cybex dev disable` | Returns desktop components to the verified vendor runtime. |
| `./uninstall` | Removes CybexOS-owned services and configuration, restores first-adoption backups, and retains installed applications. Pass `--keep-user-data` to retain backup/updater state after restoration. |

`./install` and `./uninstall` pass `--ask-become-pass` to Ansible unless sudo
works without a terminal. Ansible's workers detach from the terminal, so the
ticket that `sudo -v` caches there cannot authorize their privileged tasks.
Both take the durable updater's lock before changing the machine and exit
with status 75 while an update is running, so a playbook never interleaves
with an update's DNF transaction or configuration run.

For repository development, run Ansible directly after the source gate. The
saved installer configuration is deliberately supplied explicitly:

```bash
./tests/run
ansible-playbook site.yml -e @/etc/cybexos/config.yml --check --diff
ansible-playbook site.yml -e @/etc/cybexos/config.yml --tags desktop,dotfiles
```

`ansible.cfg` pipelines modules to the Python interpreter instead of writing
a temporary file for every task, and sets `force_handlers`. A handler notified
before a later task failed (an initramfs rebuild, a daemon-reload, a service
restart) therefore still runs; a retry would see its triggering task as
unchanged and never notify it again.

The public release updater applies a candidate through the lower-level durable
worker with `--full --skip-tests --repo <verified-stage>`. That internal path
always supplies `--skip-tags boot`; public updates therefore do not rebuild
Plymouth or initramfs unexpectedly. Apply reviewed boot-role changes directly
with Ansible, then allow its handler to finish before rebooting.

New installations select the Cybex Plymouth theme, including the LUKS unlock
screen. To apply the boot theme and Fish defaults to an existing installation
after running the source gate:

```bash
ansible-playbook site.yml -e @/etc/cybexos/config.yml --tags boot,shell-defaults
```

The `shell-defaults` tag requires the existing installation's Fish configuration
directory. New Fish shells launch `codex` with
`--dangerously-bypass-approvals-and-sandbox` (YOLO: no approval prompts or sandbox).
Use `command codex` to bypass that alias. This terminal default does not change
the `cybex agent` dispatcher or the user's Codex configuration.

`./verify --help` is the authoritative verification interface. Scope flags are
mutually exclusive, unknown arguments fail before any check runs, and
`--require-hyprland` is accepted only when system checks are in scope.
The installed `cybex verify` and `doctor` commands default to
`--system`; pass `--source` explicitly when the developer lint toolchain is
installed.

The default-agent dispatcher stores only an allowlisted command name under
`$XDG_CONFIG_HOME/cybexos/defaults/agent`, or
`~/.config/cybexos/defaults/agent` when `XDG_CONFIG_HOME` is unset. It
changes that file atomically only after confirming the selected command
exists. Agent login tokens, API keys, models, permissions, and configuration
are deliberately not copied into CybexOS. A desktop launch begins in
`~/Code`; an invocation from an existing terminal keeps its working directory.
Use `cybex agent unset` to clear the preference.

The development-source switch stores one canonical path at
`~/.config/cybexos/dev-source`. The resolver accepts only a user-owned,
non-world-writable Git worktree with the required desktop sources. Enabling or
disabling it restarts the managed Quickshell service and reloads Hyprland when
one is active. Rendered machine-specific Hyprland modules still come from the
installed vendor runtime. See [the ownership architecture](architecture/ownership.md).

## Supported Ansible tags

The definitive list for the current checkout is generated by Ansible:

```bash
ansible-playbook site.yml --list-tags
```

The stable role boundaries are `base`, `desktop`, `apps`, `xps-2026` (also
`hardware`), `dotfiles`, `private-hooks`, `boot`, and `finalize`. Narrow tags
currently exist for `browser`, `onepassword`, `fonts`, `font-defaults`, `packages`, `quickshell`,
`quickshell-lint`, `shell-defaults`, `user-tools`, `camera`, `fingerprint`,
`speaker`, and `touchpad`. The
narrow tags are development tools, not independent installation profiles;
their prerequisites can live in an earlier role.

The `quickshell` tag compares the deployed shell tree with the managed sources
in one read-only pass and writes only the files that differ. An unchanged
tree skips qmllint, and with an unchanged Quickshell unit also the live
snapshot and the verified restart; `--tags quickshell-lint` still runs qmllint
on its own. Bytecode caches written by the running shell's Python helpers do
not count as a change; the next real deployment clears them.

The `font-defaults` tag installs Liberation Sans/Serif/Mono, the full Noto
collection, Noto CJK Sans/Serif/Mono, Noto Color Emoji, and Font Awesome
(desktop and web fonts),
then applies [Omarchy's font mappings](https://github.com/omacom/omarchy/blob/8f324c90b82790d31ab33565441e07cbdb8d2308/default/fontconfig/conf.avail/50-omarchy.conf)
in `/etc/fonts/conf.d/49-cybexos-defaults.conf`. Sans-serif and system UI
aliases use Liberation Sans, serif uses Liberation Serif, and monospace uses
JetBrainsMono Nerd Font. Strong UI aliases preserve these choices against
Fedora's generic rules, and the system UI rule replaces Fedora's pre-expanded
Cantarell preference. `ui-sans-serif` and `-apple-system-body` also map
to Liberation Sans, and `ui-monospace` maps directly to JetBrainsMono Nerd Font.
The latter must already be installed by the upstream
application tasks. Personal Fontconfig files remain separate and load afterward.
Apply just these defaults on an installed machine with:

```bash
ansible-playbook site.yml -e @/etc/cybexos/config.yml --tags font-defaults
```

Font coverage mirrors [Omarchy's base manifest](https://github.com/omacom/omarchy/blob/8f324c90b82790d31ab33565441e07cbdb8d2308/install/omarchy-base.packages)
checked on 2026-09-21. Fedora splits Noto into many packages; the required
`google-noto-fonts-all` metapackage supplies its language, symbol and math
families, with CJK and emoji installed separately. Our full JetBrainsMono Nerd
Font includes the coverage of Omarchy's basic variant. The `fonts` tag also
installs all 16 iA Writer static faces (Mono, Duo, Quattro and legacy Duospace),
using Omarchy's upstream commits with SHA-256 pins and bundled OFL notices.
Omarchy's private branding icon font is shell artwork; CybexOS uses its own
bundled Tabler interface icons and product icons. Existing additional font choices remain.
Arabic and Urdu fallback ordering follows Omarchy, including Chromium requests
without a language hint.

Restart existing browsers to clear their cached font selection. These system
defaults are separate from the Quickshell Appearance settings.

The `onepassword` tag installs the Wayland launcher under the upstream
`com.onepassword.OnePassword.desktop` ID and removes the legacy user launcher
so the application appears only once. New image seeds use the same desktop ID.

The proprietary application group installs Brave Origin (`brave-origin`) from
Brave's signed release repository. The `browser` tag updates the package,
keyboard shortcut, launcher, default URL handlers, and managed policies, and
removes standard Brave's package and old managed launcher. Browser profiles are
preserved: Origin uses `~/.config/BraveSoftware/Brave-Origin`, while standard
Brave uses `~/.config/BraveSoftware/Brave-Browser`. Existing profiles are not
moved automatically; close both browsers before migrating profile data.

`user-tools` deploys and runs the CLI updater on an existing developer-tools
installation. Codex resolves npm's `latest` release each time this updater runs;
it validates the downloaded version before activating it and retains the working
installation if resolution or download fails. Claude Code's inventory pin is a
minimum: an older or missing Claude Code is installed at the pin, while a newer
one (Claude Code updates itself) is left alone rather than downgraded. OpenCode
retains its exact inventory pin. System verification checks Codex locally
without requiring the npm registry; freshness is checked by the updater.

Every invocation still executes tasks tagged `always`. That includes fresh
fact gathering, the feature contract, Fedora/architecture/user validation,
and precise XPS-role detection. A partial tag run is therefore not a way to
bypass the Fedora 44 and architecture support contract. Do not add
`--skip-tags always`; it removes the checks that make a targeted run safe.

## Agent skill lifecycle

CybexOS ships one canonical skill in the active release at
`~/.local/share/cybexos/current/agent-skills/cybexos`. Provisioning
always creates these discovery links, independently of whether each agent is
installed:

- `~/.agents/skills/cybexos`
- `~/.claude/skills/cybexos`
- `~/.codex/skills/cybexos`

The internal `scripts/manage-agent-skills` helper adopts only those three
named slots. Before first replacement it records each existing file,
directory, symlink, or absence separately under
`~/.local/state/cybexos/backups/agent-skills/`. If any backup or
replacement fails, the invocation restores every affected slot. Later runs
treat an adopted slot as project-owned and converge it without rewriting the
first-adoption record; unrelated skills and parent directories are untouched.

Release activation swaps `current` and then reconciles all three links through
the new canonical skill. A reconciliation failure rolls back the links, the
active-release symlink, and the migrated installer configuration. Uninstall
uses the same helper before removing project state and unconditionally
restores each recorded original. `--keep-user-data` retains those records only
after restoration; it does not leave the CybexOS links installed.

## Migrating from fedora-config

The project was called `fedora-config` before it became CybexOS. An
installation made under that name moves to the CybexOS names when `./install`
runs from a CybexOS checkout; releases published under the old name cannot
update it. `scripts/migrate-legacy-names` runs first in `install`, `uninstall`,
and every playbook, and is idempotent. It:

- moves `/etc/fedora-config`, `/var/lib/fedora-config`, the
  `fedora-config-upstream` cache and state, `/opt/fedora-config-apps`, and
  `/opt/fedora-config-builds` to their `cybexos` paths, keeping install
  markers and retargeting `/usr/local/bin` links so nothing is rebuilt;
- renames the `fedora-config` firewalld zone to `cybexos`, including the
  default zone and NetworkManager profile bindings, and replaces the Btrfs
  scrub timer;
- moves the `fedora-config` directories in `~/.config`, `~/.local/share`,
  `~/.local/state`, and `~/.cache` to `cybexos`, plus the user-tool
  directory, and retargets `~/.local/bin` links;
- restores the former `fedora-config` agent skill slots so that provisioning
  adopts the `cybexos` slots afresh.

The `legacy-names` role then removes the remaining `fedora-config` helpers,
units, fragments, and managed include blocks after their replacements are in
place, and restarts a running Quickshell and hypridle. Links at the three
former home paths keep the current desktop session working. The next Hyprland
login removes them. If both an old and a new path already exist, the
migration leaves the old one for manual review and says so.

## Release updater lifecycle

`cybex update` follows the channel saved in
`~/.local/share/cybexos/channel` (`stable` by default, or `beta` after
`--channel beta`). It reads `DigitalPals/CybexOS` releases through GitHub's
public API without credentials; no GitHub account, `gh auth login`, or token
is needed. A project release is accepted only when GitHub marks it immutable,
the downloaded SHA-256 matches GitHub metadata, its provenance attestation
verifies, and its manifest supports the current Fedora release, architecture,
configuration schema, and updater version.

The release workflow publishes the Sigstore bundle of that attestation as
`cybexos-VERSION.tar.zst.sigstore.jsonl` beside the archive. The updater
downloads it and runs `gh attestation verify --bundle` offline, pinned to this
repository's `.github/workflows/release.yml`, the release tag's
`refs/tags/vVERSION`, and a GitHub-hosted runner. `gh` is always installed;
one without offline bundle verification is reported as too old before
anything is downloaded.

While a channel has no published release (stable: GitHub reports no latest
release for an existing repository; beta: no published prerelease), that is
not an error. `--check` prints `No CybexOS release has been published on the
stable channel yet (installed: VERSION).` and exits 0; `--check --json` reports
`"status": "no-release"`, `"available": false`, and an empty `projectError`.
An update then runs only the package phase and exits with its status, and
the Updates panel shows the neutral note "No CybexOS release published yet".
A missing repository is an error, not an unpublished channel.

Fedora and Flatpak updates never depend on GitHub: when a release cannot be
checked (offline, an API error, or the anonymous API rate limit), verified, or
staged, the updater says why, removes any partial stage, and runs the
package-only update. The terminal command then exits 69 after a successful
package run; `--start --json` returns the started run with a `projectError`
field, and `--check --json` reports an available release together with a
`projectError` when this machine cannot verify it yet. A failed check exits
nonzero with the reason as its last stderr line. A request with
`--no-packages` has nothing to fall back to and fails.

The verified archive is extracted into a new versioned directory. A dedicated
durable system worker owns configuration migration, candidate application,
agent-skill reconciliation, rollback, and the atomic `current` symlink change.
Detaching the terminal cannot split those steps, and an unrelated active
update is never accepted as the candidate transaction. Apply failure restores
the pre-migration configuration; activation failure also restores the prior
`current` target and every agent-skill slot. Files that Ansible had already
deployed from the candidate are not rolled back, so after a failed or
abandoned apply the run's `status.json` records `mixedState: true`: the
machine runs the previous release with some newer managed files. Retry
`cybex update` once the cause is fixed, or converge the active release again
with `~/.local/share/cybexos/current/install`. The active release plus two
recent release directories are retained as recovery material; filesystem
rollback remains the supported way to reverse system package changes.

Useful release commands are:

```bash
cybex update --check
cybex update --check --json
cybex update --channel beta
cybex update --channel stable
cybex update --no-packages
cybex update --system-only
```

## Durable updater lifecycle

The package/configuration worker is a transient service. It has no terminal,
and sudo's default ticket (`timestamp_type=tty`) is tied to the terminal that
authenticated, so a terminal invocation uses a user service only when sudo
works without any terminal (for example passwordless sudo). Otherwise it
authenticates once and starts a system service. Quickshell explicitly requests
a system service; when authorization is needed, systemd's own Polkit action is
handled by the graphical session agent, so no terminal is opened and progress
remains in the Updates view.
Release transactions also use a system service because their configuration
migration and activation must outlive the client. Closing the view or pressing
Ctrl+C while attached only detaches the observer. At most one worker can own
the update lock. The worker runs at nice 10 with a CPU and I/O weight of 20,
so the desktop stays responsive while it works.

Use the installed backend to inspect or control it:

```bash
cybexos-update-run status
cybexos-update-run status --json
cybexos-update-run attach
cybexos-update-run log-dir
cybexos-update-run cancel
cybexos-update-run dismiss
```

Each command accepts a run ID where documented by `cybexos-update-run --help`.
`cancel` is explicit; Ctrl+C during `attach` never cancels. The stop request
reaches only the worker process (`KillMode=mixed`), because interrupting
DNF/RPM midway can leave duplicate or half-upgraded packages. A running
package transaction, firmware update, repository check, or Ansible play
therefore finishes first, and the worker records `cancelled` at the next step
boundary; `status --json` reports `cancelRequested: true` meanwhile. Once
Ansible has started, the run completes or fails instead, so installed files
and the active release stay coherent. A worker still running 30 minutes after
the request is killed. A package phase started by an updater without this
contract is not cancellable. `dismiss` only changes the completed status shown
by the UI and does not delete its logs.

`--firmware` (also accepted by `cybex update`) installs available fwupd device
firmware in the same worker after the package phase, through
`cybexos-firmware-update`. A firmware failure never fails the run; the final
message notes the helper's status, and a capsule staged for the next boot
recommends a restart for the rest of that boot. With `--no-packages`,
`cybexos-update-run --firmware` is a firmware-only run.

Run state lives under `~/.local/state/cybexos/update/`. Each run has a private
directory under `logs/<run-id>/` containing:

- `status.json`: atomic machine-readable phase, result, component exit codes,
  timestamps, transient unit name, the pre-update `snapshotId` when one was
  created, and `mixedState` when a release apply stopped after Ansible began
  changing files;
- `run.log`: the complete combined stream with `dnf`, `flatpak`, `firmware`,
  `tests`, and `ansible` prefixes;
- component logs such as `dnf.log`, `flatpak.log`, `firmware.log`,
  `tests.log`, and `ansible.log`, plus their exit-code files when that phase
  ran;
- `firmware-events.log`: one JSON object per line (`plan`, `device`,
  `progress`, `request`, `installed`, `skipped`, `failed`, and a final
  `summary`) that the Updates view renders.

The twenty newest valid run directories are retained. For a worker that looks
stuck, start with `cybexos-update-run status --json`, inspect `run.log`, then use
the `unit` field with `systemctl --user status <unit>` and
`journalctl --user -u <unit>` (without `--user` when `systemUnit` is true). If
the unit disappeared without final status, the next status read marks the run
failed with phase `abandoned` instead of blocking all future updates.

## Update recovery points

Before package work starts, the updater requires
`/usr/local/libexec/cybexos-system-snapshot` on the managed Btrfs layout. It saves a
read-only snapshot of the `root` subvolume and a matching archive of `/boot`
(including the mounted EFI tree), records the default kernel, then retains the
five newest points. `/home` is a separate subvolume and is intentionally
outside system rollback; on the standard layout `/var` (logs, containers,
system Flatpaks) is inside `root` and rolls back with it. A snapshot failure
stops the update before DNF changes anything. On a non-Btrfs root the step
records that no filesystem recovery point was required.

```bash
sudo cybexos-system-snapshot list           # ID and description
sudo cybexos-system-snapshot list --json    # also kernel and boot-menu status
cybexos-update-run status --json | jq -r .snapshotId
```

### Trying a recovery point from the boot menu

GRUB shows a **CybexOS recovery points** submenu with one entry per retained
point whose kernel and initramfs are still in `/boot`. Fedora hides the menu
after a successful boot: hold **Shift** (BIOS) or press **Esc** (UEFI) while
the machine starts, or simply let a failed boot bring it up. An entry boots the
read-only snapshot with its own kernel; the `cybexos-recovery` dracut module
lays an in-memory overlay over it, so the system runs normally but nothing is
written to the snapshot and every change disappears at the next restart.
`/home` is the live one. The real `/boot` and EFI partitions are mounted
read-only, so nothing installed during a recovery boot can leave a kernel
behind without its modules. The desktop announces the recovery boot and offers
to restore it; new recovery points, and therefore updates, are refused while it
runs.

Nothing here regenerates `grub.cfg` per snapshot. `/etc/grub.d/42_cybexos_recovery`
makes `grub.cfg` source `/boot/grub2/cybexos-recovery.cfg`, which the helper
rewrites atomically after every create, prune and restore, from a kernel-install
hook when kernels change, and at boot (`cybexos-recovery-refresh.service`, which
also publishes `/run/cybexos-snapshots/recovery-points.json` for the desktop).
Entry titles and kernel arguments are reduced to a safe character set, so a
description cannot inject GRUB commands. A kernel whose initramfs lacks the
overlay module gets no entry; Ansible rebuilds initramfs images when the module
or helper changes.

### Restoring

Restore from **Settings → About → Recovery points** (two presses; systemd asks
the desktop's Polkit agent, as for updates) or from a terminal, in a normal or
a recovery boot:

```bash
sudo cybexos-system-snapshot restore ID
# From a recovery point older than this feature, use the helper the
# initramfs provides instead:
sudo /run/cybexos-recovery/cybexos-system-snapshot restore ID
```

Restore never reboots. It makes a writable copy of the point, puts back any of
the point's kernels that `/boot` no longer has (from its archive), exchanges the
copy with `root` in one atomic rename, and keeps the previous system as
`root.replaced-TIMESTAMP`. It then retires kernels that the restored root has no
modules for into the store and makes the point's kernel the GRUB default. The
bootloader itself (GRUB, shim and the EFI tree) is left at its current version.
Nested subvolumes such as `/var/lib/machines` are never part of a point and move
to the restored root. An interrupted restore is finished or undone by the next
`cybexos-system-snapshot refresh`, which runs at every boot.

Restart to use the restored system, then review and reclaim space:

```bash
sudo cybexos-system-snapshot replaced
sudo cybexos-system-snapshot discard root.replaced-TIMESTAMP
```

Discarding is refused while that root is still the running system.

### Last resort: live media

If neither the default entry nor a recovery entry boots, boot Fedora
rescue/live media, unlock the LUKS device, identify the root Btrfs filesystem
and the separate `/boot` and EFI partitions with `lsblk -f`, then use the
reviewed snapshot ID below. Device names are placeholders and must be replaced
with the values from `lsblk`:

```bash
mount -o subvolid=5 /dev/mapper/ROOT_CRYPT /mnt
ID=20260903T120000Z-1234
test -d "/mnt/cybexos-snapshots/root/$ID"
test -f "/mnt/cybexos-snapshots/boot/$ID.tar"
btrfs subvolume snapshot "/mnt/cybexos-snapshots/root/$ID" /mnt/root.recovered
mv /mnt/root "/mnt/root.failed-$ID"
mv /mnt/root.recovered /mnt/root
mount /dev/BOOT_PARTITION /mnt/root/boot
mount /dev/EFI_PARTITION /mnt/root/boot/efi
tar --acls --xattrs --selinux --numeric-owner \
  --extract --file "/mnt/cybexos-snapshots/boot/$ID.tar" --directory /mnt/root
sync
```

Reboot into the default entry and run `sudo restorecon -RF /boot` followed by
`./verify --system --require-hyprland`. Keep `root.failed-$ID` until the system
and user session are confirmed healthy; deleting it is a separate, explicit
space-reclamation decision. These recovery points do not replace backups:
they share the same physical Btrfs filesystem and cannot survive device loss.

`tests/system-snapshot` covers the helper against fixtures (retention, menu
generation and escaping, kernel selection, restore ordering and interruption,
the overlay hook). Booting a recovery entry and restoring from it on real
hardware have not yet been qualified end to end; test them in a disposable VM
before relying on them.

Ansible's `cybexos` callback is intentionally compact: unchanged and skipped tasks
are quiet, changes are one line, and failures include a bounded diagnostic.
Pass `-v` to use the stock verbose callback behavior. A full updater run keeps
the callback's complete emitted stream in `ansible.log`; it does not recreate
details that the compact callback intentionally never emitted. Pass `-v` on a
diagnostic run when those details are needed. `tests/callback-smoke.py` checks
compatibility with callback event objects.

## Shutdown and reboot expectations

Do not shut down or reboot while `cybexos-update-run status` reports `queued` or
`running`. A durable transient service survives a terminal or shell restart,
not a machine power cycle. Wait for a terminal state (`done`, `failed`, or
`cancelled`), or cancel deliberately and confirm the terminal state first.

While it runs, the worker holds a logind block inhibitor for shutdown and
sleep (`systemd-inhibit --list` shows `CybexOS`), so ordinary power-off,
reboot, and suspend requests, including idle suspend, are refused until it
finishes. `systemctl poweroff -i` overrides it deliberately. Closing a laptop
lid still suspends, because logind's default `LidSwitchIgnoreInhibited=yes`
ignores inhibitors; keep the lid open during an update. The protection is
complete for a system-service worker (Quickshell and release updates). logind
does not apply a user's own inhibitor to that user's requests, and Polkit may
refuse it to a user-service worker altogether; `run.log` then records an
`[inhibit]` line and the update continues unprotected.

No repository command automatically reboots or powers off the machine.
Ordinary package updates can install a new kernel for the next boot. A direct
bootstrap can rebuild initramfs through the `boot` role. The IPU7 camera role
can also leave `/var/lib/xps-hardware/ipu7/reboot-required` when new signed
DKMS modules must be loaded in a clean boot. Let the play finish, inspect its
result, then perform one normal reboot. `./verify` reports this camera state.

## Idle, power, and background services

hypridle runs the idle timeline from **Settings → Power → Idle**, unless a
regular file at `~/.config/cybexos/hypr/hypridle.conf` replaces it. A new
installation locks after five idle minutes, turns the screen off after ten,
and suspends after 30 minutes only on battery, so a machine on mains power,
including every desktop, stays awake. A laptop that reaches the suspend
timeout on mains power checks again every minute until the next input, and
suspends if it is unplugged meanwhile. Existing installations keep their
stored values: the shell writes every key to `shell.json`, so a stored Never
cannot be told apart from a deliberate one.

A locked screen turns off about a minute after the last input, whether it was
locked by hand or by the idle lock; a Screen off setting of Never keeps it lit.
Every suspend waits for the lock. For a lid close or any other sleep request,
hypridle's `inhibit_sleep = 3` holds the sleep until the compositor reports
the session locked, for as long as logind allows a delay. The shell's Suspend
and idle suspend call `systemctl suspend` only after `hyprctl locked`
confirms the lock. Without that confirmation within eight seconds the machine
stays awake, and a lock screen that is still starting is left running rather
than stopped.

hypridle reads its configuration only when it starts. A converge that changes
its configuration, its unit, the runtime resolver, or the timeout renderer
restarts a running hypridle, so new timeouts apply without logging in again.
hypridle only tracks idle time, so the restart neither locks nor unlocks the
session.

Docker is socket-activated: `docker.socket` starts dockerd, and with it
containerd, on the first client request instead of at boot. Containers with a
`restart=always` policy therefore wait for the first `docker` command after
boot. A converge leaves a daemon that is already running alone.

Docker commands need `sudo` unless the saved `docker_sudoless` answer is
`true`. Membership in the `docker` group controls a root daemon, so it is
root-equivalent; the installer asks for it explicitly and defaults to no.
Earlier releases granted the group without asking: a converge revokes it from
a CybexOS-managed Docker installation whose saved configuration has not
accepted sudoless use. The revocation applies to new login sessions. Run
`cybex configure` to opt in again. `Super+D` starts lazydocker directly with
socket access and through `sudo` otherwise.

The weekly Btrfs scrub runs only on AC power and reads at most 200 MiB/s per
device. A run skipped on battery is not caught up when the charger returns; it
waits for the next weekly trigger.

Dictation requires the `developer_tools` feature, which also downloads its
model and binds its keys. Without it the Voxtype user unit is not installed,
and a converge stops and removes one left by an earlier run. The daemon loads
the model when a recording starts and releases it when idle, so the first
dictation after an idle period has a short load delay.

mpv prefers hardware decoding: a managed block at the top of
`/etc/mpv/mpv.conf` sets `hwdec=auto-safe`, which uses only the decoders mpv
considers reliable and falls back to software otherwise. Lines below the block
and a personal `~/.config/mpv/mpv.conf` override it; uninstall removes only
the block.

## The strict source gate

`tests/run` executes every stage even after a failure and returns nonzero when
any stage failed. Missing Node, Python, Ansible, qmllint, or QML runtime tools
are failures rather than silent skips. The exact stage order and count come
from the executable itself:

```bash
./tests/run --list
```

The stages cover whole-source/Ansible syntax, ShellCheck, ansible-lint,
yamllint, Ruff, Node unit tests, Hyprland workspace fixtures, QML static
analysis, offscreen helper contracts, real-Quickshell component lifecycle
coverage in CI, Quickshell deployment integration, callback and Python
fixtures, transactional agent-skill lifecycle coverage, XPS hardware
integration, Plymouth layout, the durable updater, screenshot/brightness
workflows, Btrfs snapshot retention, and the fedora-config name migration.
QML static analysis also lints the three real-engine test harnesses, each over
a scratch copy of the tree, so a harness that drifted from the components it
drives fails locally even while the managed shell keeps the real-engine run
itself CI-only. The deploy's own lint (`tests/qml-lint --shell-only`) checks
the shell alone.

Independent stages run side by side, longest first, and their results print
in the fixed order with the verdict last. `--jobs N` bounds the concurrency
(`--jobs 1` runs serially) and `--only STAGE` runs a single stage. Every stage
has a time limit (300 seconds; 600 for static lint and the Python fixtures),
and a stage that exceeds it fails with whatever it printed rather than holding
the gate open.

The GitHub workflow runs the same `./tests/run` command in a Fedora 44
container. The lower-level worker stops before Ansible if this gate fails or
does not finish within 30 minutes.
`--skip-tests` is reserved for an already verified release candidate and is
not part of the public command interface.

The weekly and manually dispatchable `Fedora VM convergence` workflow adds a
slower system boundary: it checksum-verifies the pinned official Fedora 44
Cloud image, boots it under QEMU, applies every role twice, requires a
zero-change second pass, checks preserved user collisions and firewall state,
and then verifies uninstall restoration. Run the same test locally with
`./tests/fedora-vm-convergence`; set `FEDORA_VM_TAGS` to a comma-separated role
subset only for a deliberately narrower development run.

## Reduced motion

Quickshell treats `QS_REDUCED_MOTION=1`, `true`, `yes`, or `on`
(case-insensitive) as a request to remove shared transitions, movement,
stagger, and press animation. Qt does not currently supply this preference to
the shell automatically. Make it durable with a user-service drop-in:

```ini
# ~/.config/systemd/user/quickshell.service.d/reduced-motion.conf
[Service]
Environment=QS_REDUCED_MOTION=1
```

Then run `systemctl --user daemon-reload` and restart the managed
`quickshell.service` at a safe time. Remove the drop-in and repeat those two
commands to restore motion. Repository runtime tests set the variable only in
their isolated offscreen process.

The power saver profile is a reduced-motion request too, for as long as it is
on; it changes neither this variable nor **Settings → Appearance → Reduce
motion**. The compositor follows it as well: blur drops to one pass and
Hyprland animations turn off, and the values it replaced return when power
saver ends.
