# CybexOS installation experience

The live image opens a small CybexOS page in Anaconda's existing local Cockpit
service. It uses Fedora's Anaconda storage and installation backend. It does not
format devices itself, generate an unattended live Kickstart, or replace
Anaconda's partition validation.

The complete installation has **not been qualified by an ISO boot**. The SDDM
implementation has source, fixture and disposable desktop-RPM build checks;
ISO creation and publication were deferred at the user's request. No real
installation or host login-manager switch was performed. Do not label an image
qualified until the opt-in installation tests pass.

## Boot entries

The ISO menu (UEFI GRUB and BIOS isolinux) offers each generated live entry
twice. **Install CybexOS** is first and the default; it adds `cybexos.install`
to the kernel command line. **Try CybexOS live** is the unchanged live desktop.
The basic graphics troubleshooting entry has the same pair.

With `cybexos.install`, `cybexos-live-setup` creates `/run/cybexos-install-mode`
and the session launcher starts `cybexos-install-session.target` instead of
`hyprland-session.target`. That target starts only the Polkit agent and the
welcome window in `--install-mode`, which opens the installer immediately.
There is no menubar, dictation, idle daemon, Hermes bridge, input method or
background offline-application seeding. The window cannot be closed; it can
reopen the installer, restart, power off, or start the full live desktop.
Both entries boot the same image, so this saves startup time and memory, not
download size or installation time: Anaconda installs by copying the live
root filesystem, which must therefore contain every installed application.

## User flow

Usernames are lowercase. Capital letters are lowercased while typing, so
"John" creates the account `john`; the backend still rejects anything else.

1. **Your setup:** select a keyboard, test it, and enter username/password twice.
   Language, timezone, hostname and **Prepare this computer for a new owner**
   are under **More options**. The timezone is a dropdown of Anaconda's valid
   timezones, preselected from Anaconda's geolocation (Fedora's GeoIP service)
   unless the user chose one.
2. **Install location:** choose a disk. The default is automatic Btrfs with
   LUKS2 encryption. When the disk already holds another system, the step
   offers **Install alongside** (the default) or **Erase disk**; see
   [Installing alongside another system](#installing-alongside-another-system).
   The advanced section can disable encryption or open the stock Anaconda Web
   UI for several disks, reusing existing partitions or a custom layout.
3. **Review and install:** show the target model/path, account, encryption,
   startup behavior, boot keyboard, language/timezone, exactly what is erased,
   resized, created and kept, actual Anaconda disk actions, and its validation
   warnings. An explicit checkbox is required: erase the disk, or (alongside)
   resize the named partition. Progress thereafter comes from Anaconda's real
   task signals.

An attached seed volume replaces these questions with an
[unattended installation](#unattended-installation) and its countdown.

The password is applied to the LUKS slot and hashed separately for the created
administrator account. Root is locked. The post-install helper verifies that
the target root filesystem has an encrypted block-device ancestor before
requesting SDDM autologin. The shared login helper rechecks root encryption at
boot and permits automatic login only on the first SDDM start in that boot.
Unencrypted and stock Advanced installations retain the
normal login screen. EFI and boot partitions follow Anaconda's platform rules;
“encrypted installation” does not mean the firmware boot partition is encrypted.

The app keyring remains encrypted. SDDM's autologin PAM stack uses systemd's
`pam_systemd_loadkey` and GNOME Keyring's normal PAM integration to unlock it
with the briefly cached boot passphrase when the passwords match. The cache
retention is not extended. If the cache is absent or expired, or the keyring
password differs, an application requests the keyring password normally. The
installer never writes the passphrase to a file or creates a passwordless
keyring. Disk, account and keyring passwords are not kept synchronized after
installation; changing one later can require a separate keyring unlock.

The RPM packages the same login preparation helper, PAM template and SDDM
service drop-in as workstation deployment. Its post-transaction step installs
the PAM template with an initial backup; the SDDM package retains ownership of
`/etc/pam.d/sddm-autologin`. The helper prepares `/etc/sddm.conf` before SDDM
starts. There is no permanently enabled autologin stanza in the image.

## Installing alongside another system

When the selected disk has partitions whose file system suggests another
operating system (NTFS or BitLocker for Windows; ext4, XFS, Btrfs, LUKS or LVM
for Linux; APFS or HFS+ for macOS), the location step offers **Install
alongside** it. The backend's `alongside` command asks Anaconda, never the
browser, how much space is available:

- **Enough free space** (at least the larger of 64 GiB and Anaconda's payload
  requirement): CybexOS uses it. Nothing is resized.
- **Not enough free space:** only the **largest partition Anaconda can shrink**
  is offered. A slider chooses the space for CybexOS, from the minimum up to
  what the partition can give while keeping its file system minimum plus
  5 GiB of working space. Anything Anaconda cannot shrink (for example
  BitLocker) is never offered; choose **Erase disk** or the full installer.

The sequence mirrors anaconda-webui 68's reclaim dialog: the disk is selected,
`InitializationMode` is `CLEAR_PARTITIONS_NONE` with no drives to clear and no
new disk label, an `AUTOMATIC` partitioning is created, its resizable device
tree (`GetDeviceTree()`, interface `DeviceTree.Resizable`) receives one
`ShrinkDevice(partition, size)` call, and then the normal request, passphrase,
configure, apply and validate steps run. NTFS resizing uses `ntfsresize`
from `ntfsprogs`, a mandatory package of the image's `@anaconda-tools` group.

Before review, the backend refuses any plan that touches an existing device
other than the shrunk partition: a `destroy` action, a resize of anything
else, or a format or label created on an existing partition or the disk. The
existing EFI system partition is reused and shared; Anaconda's automatic
partitioning assigns it `/boot/efi` without formatting it. The review states
the resized partition with its old and new size, the space CybexOS receives
and the partitions kept unchanged, and the confirmation names the partition.
The installation confirmation is `alongside_confirmed`, not `erase_confirmed`.

**Boot menu.** Fedora 44's `grub2-tools` (2.12) requires `os-prober`, and its
`/etc/grub.d/30_os-prober` runs unless `GRUB_DISABLE_OS_PROBER=true`.
Anaconda 44.30 does not set that variable on x86 and runs `grub2-mkconfig` in
the target, so the generated `grub.cfg` lists Windows Boot Manager (UEFI) and
other Linux installations. BLS kernel updates do not regenerate `grub.cfg`;
the os-prober entries remain. The target hook clears `menu_auto_hide` in the
installed grubenv so the menu is visible at every start, and records in
`/etc/cybexos/installation.json` whether `grub.cfg` contains an os-prober
entry (`otherSystemsInBootMenu`). The firmware boot menu remains a fallback.
Another Fedora-based system on the same EFI system partition shares
`EFI/fedora`; CybexOS's boot loader then manages both.

## Unattended installation

A volume labelled `CYBEXOS-SEED` (or cloud-init's `CIDATA`/`cidata`) with a
`cybexos-seed.yml` at its top installs without questions. The live welcome
opens the installer when such a volume is attached (it checks for 30 seconds
after login). The installer page asks the backend's `seed` command, which
mounts the volume read-only (`ro,nosuid,nodev,noexec`), reads only the YAML
and the files it names (regular files, no symlinks, size-limited), unmounts it
and validates everything strictly. Every problem is listed on screen; nothing
is planned until the seed is valid. A volume without `cybexos-seed.yml` is not
a seed.

A valid seed is planned with Anaconda exactly like an interactive installation
(`plan` with the seed's digest; a changed seed is refused). The page then shows
the matched disk's identity, the account, storage and access, and a visible
countdown (`countdown`, 10–600 seconds) with **Cancel installation**. The
backend also refuses to start before the countdown has ended, so a page that
skips it cannot shorten it. Cancelling resets Anaconda's plan; nothing was
written, and a reloaded page does not offer the same seed again until it
changes or the live system restarts. The outcome is that of an interactive installation: the same
Anaconda storage, account, keyboard, language, timezone and hostname calls,
target hooks, `/etc/cybexos/config.yml`, login policy and factory point.

```yaml
# cybexos-seed.yml at the top of a volume labelled CYBEXOS-SEED.
version: 1
disk:
  match:
    serial: S6B0NL0W123456        # `lsblk -o NAME,MODEL,SERIAL,SIZE` shows it
  erase: true                     # required: the matched disk is erased
encryption:
  enabled: true
  passphrase_file: disk-passphrase   # a file beside this one; see below
account:
  username: alice
  full_name: Alice Example
  # mkpasswd -m yescrypt (or openssl passwd -6). Never a plain password.
  password_hash: "$y$j9T$SKre8868v2XV1NXxxycxM/$klea7p1t8995H5ER2f8JnqFUUOtu1t24e8W3qRBPIU3"
  passwordless_sudo: false
system:
  keyboard: us                    # an Anaconda layout, e.g. "de (nodeadkeys)"
  locale: en_US.UTF-8
  timezone: Europe/Amsterdam
  hostname: alice-laptop
ssh:
  authorized_keys:
    - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyOnlyReplaceWithYourOwnPublicKey0 alice@desktop
  server: false                   # true enables sshd; the firewall still applies
tailscale:
  auth_key_file: tailscale-auth-key  # joins once at first start, then deleted
config:                           # /etc/cybexos/config.yml choices
  manage_personal_dotfiles: true
  features:
    steam: false
    local_network_services: false
countdown: 30
```

| Setting | Rules |
| --- | --- |
| `version` | Must be `1`. Unknown settings anywhere are errors. |
| `disk.match` | One or more of `serial`, `wwn` (exact; WWN case-insensitive), `model` (case- and space-insensitive), `path` (a `/dev` path; `/dev/disk/by-id/…` links are resolved), `min_size`/`max_size` (`500GB`, `465GiB`). All given keys must match. A size alone is refused. Exactly one disk must match; zero or several matches are errors listing the available disks. The seed volume's own disk and the live medium are never candidates. |
| `disk.erase` | Must be `true`. Unattended installation always erases the matched disk; install alongside interactively. |
| `encryption` | `enabled` defaults to `true` and then requires `passphrase_file`. |
| `account` | Required unless `oem: true`, which forbids it. `username` follows the interactive rules, `full_name` is optional (no colons), `password_hash` must be a yescrypt (`$y$`) or SHA-512 (`$6$`) crypt hash; a `password` key is an error. `passwordless_sudo` defaults to `false`. |
| `oem` | `true` installs for a new owner; see below. |
| `system` | `keyboard`, `locale` and `timezone` must be in Anaconda's lists; defaults `us`, `en_US.UTF-8`, `UTC`. `hostname` defaults to `cybexos`. |
| `ssh` | Up to 32 OpenSSH public keys for the account's `~/.ssh/authorized_keys`, and `server` (default `false`) to enable `sshd`. The CybexOS firewall zone still drops SSH except on interfaces it trusts (Tailscale when that feature is on). Not allowed with `oem: true`. |
| `tailscale.auth_key_file` | A file holding a `tskey-…` auth key. Requires the Tailscale feature. |
| `config` | Only `manage_personal_dotfiles`, `passwordless_local_polkit`, `docker_sudoless` and `features.*` booleans, validated by the shared `installation_policy.choices`. Absent keys keep the ISO defaults. Automatic login, identity and passwordless sudo are decided by the installer as in an interactive installation. |
| `countdown` | Seconds before the disk is erased, 10–600, default 30. |

Check a prepared seed folder before writing it to a volume (everything except
the disk match, which needs the target machine):

```bash
python3 image/live-rootfs/usr/libexec/cybexos-installer-seed check /path/to/seed-folder
```

**Secrets and their trade-off.** The account takes only a password hash. LUKS,
however, needs the passphrase itself, so a fully unattended encrypted
installation must read it from the seed volume (`passphrase_file`). Anyone
who can read the volume can unlock the installed disk until the passphrase is
changed (`sudo cryptsetup luksChangeKey` on the LUKS partition, or the
interactive Settings for the account password). Keep the volume offline and
physically controlled, write it shortly before use, remove it after
installation and wipe it. The passphrase is never copied to the target, logged
or written to `/run`; it is passed to Anaconda's `SetPassphrase` in memory.
The account and disk start with different secrets unless you use the same
one; with different secrets, automatic login still works but the keyring asks
for its password once. The Tailscale key is staged in root-only, memory-backed
`/run/cybexos-installer/staged`, copied by the target hook to a root-only
`/var/lib/cybexos/first-boot/` file, moved to `/run` at the first start before
the factory recovery point is taken, used once with
`tailscale up --auth-key=file:…` (never on a command line) and deleted whether
or not it worked. On an unencrypted disk the deleted bytes can remain on the
device until overwritten; use a pre-approved, short-lived or ephemeral key.

## New-owner (OEM) installations

**Prepare this computer for a new owner** (or `oem: true` in a seed) installs
without an account. Anaconda creates no user; root stays locked. The target
hook verifies that no desktop account exists, writes a disabled login policy
and `/etc/cybexos/oem.json` (`{"version": 1, "passwordless_wheel": …}`), and
keeps any seed `config` choices in `/etc/cybexos/install-choices.json`.

At the first start, `cybexos-new-owner.service` runs on the first console
before the login screen (`Before=display-manager.service`). It shows a
graphical setup in [cage](https://github.com/cage-kiosk/cage) (the RPM
requires the `cage` package) with four steps, one primary action each:

1. **Welcome:** language (the installed UTF-8 locales, the installer's list,
   labelled in their own language; the setup's own text is Dutch for `nl_*`
   and English otherwise) and keyboard layout (xkeyboard-config's layouts and
   variants), each a searchable list, with a field to try the keyboard;
2. **Your account:** full name, username (suggested from the first name and
   editable), password and confirmation with the console's rules; on an
   encrypted disk it explains that the password also unlocks the disk and asks
   for the temporary passphrase used at this start;
3. **Time zone:** a searchable list, preselected with the installation's time
   zone;
4. **Finishing:** the provisioning stages while they run, then **Ready** and a
   restart (automatic after 15 seconds).

Everything works from the keyboard alone, with a visible focus ring, and
sizes scale with the screen.

**Privilege separation.** The root service never runs the window. It starts
`cage -d -- /usr/bin/python3 -I /usr/libexec/cybexos-new-owner-gui` with
`systemd-run --pipe --wait` as the transient unit
`cybexos-new-owner-gui.service` with `DynamicUser=yes` (a fresh unprivileged
user: read-only system, private `/tmp`, no new privileges, Unix and netlink
sockets only), the `video`, `input` and `render` groups and a private 0700
runtime directory. There is no login session yet, so libseat's `noop` backend
opens the screen and input devices; the root service switches the first
console to graphics mode with its keyboard off for the duration (so nothing
typed reaches the console's input buffer) and restores it afterwards. The
window gets every list in one `init` message on standard input and returns
JSON lines on standard output: `ready`, `active` (first key press),
`keyboard`, `submit` and `restart`. The root service accepts only those
types with exactly their fields as strings of bounded length and lines up to
32 KiB; anything else ends the window. Every answer is checked again as root
(the same rules module the window imports), and the password travels only on
that pipe: never on a command line, in the environment, a file or a log.

**Keyboard.** cage reads `XKB_DEFAULT_LAYOUT`/`XKB_DEFAULT_VARIANT` when it
starts. Choosing a layout applies it to the system with `localectl
set-x11-keymap` (localed converts it to the console keymap) and restarts cage
with it, back on the first step with the test field focused, so the password
is always typed with the chosen layout. On an encrypted disk a layout without
a console keymap is refused, as in the installer. Before the re-key, the
running kernel's initramfs keymap (`lsinitrd`) is compared with
`/etc/vconsole.conf` and `dracut --regenerate-all --force` runs when they
differ, so the unlock prompt reads the new password with the same layout.

**Fallback.** The text-mode questions on the same console (keyboard, language,
account, password, time zone, then a confirmation) take over when
`cybexos.new-owner=console` is on the kernel command line; when cage,
systemd-run, the window, its QML or PySide6 is missing; when there is no
`/dev/dri/card*` or `/dev/input/event*`; when the console is not a virtual
terminal; when the window does not draw within 60 seconds (after one more
attempt); when no key press reaches it within five minutes; when it breaks
the protocol; or when it closes or crashes before the account exists.

Either way the service then:

1. creates the account in `wheel` and sets its password with `chpasswd`;
2. runs `cybexos-configure-installed --offline --user NAME` and
   `cybexos-seed-installed-users`, the same fresh-account provisioning as
   Anaconda's in-target hook, so `config.yml` is recorded from the saved
   choices through the shared installation policy;
3. applies the saved sudo choice;
4. on an encrypted disk, refreshes the initramfs keymap when needed and
   re-keys every LUKS device of the root file system (see below), then enables
   automatic login only on a verified encrypted root, exactly as the
   installer does;
5. updates `installation.json`, removes `oem.json` and restarts.

Any failure removes the half-created account and restores the saved choices;
the window says what failed and offers to try again, and the console starts
again. Before creating the account the service records it in
`/etc/cybexos/new-owner-pending.json` (no secrets); a crash or power loss in
the middle is undone at the next start, and the unit runs again on every
start until `oem.json` is gone.

**Encryption.** An encrypted OEM installation uses a temporary passphrase
chosen in the installer (or the seed's `passphrase_file`). The person handing
over the computer gives it to the new owner, who types it at the first unlock
and once more in the setup. The setup adds the new password as a passphrase
(`cryptsetup luksAddKey`, both secrets through stdin and a pipe, never argv),
removes every other key slot (`luksKillSlot`) and every LUKS2 token, and
verifies that the temporary passphrase no longer opens the disk. Re-running
after an interruption is safe. The restart then unlocks with the owner's
password, logs in automatically and lets the keyring unlock with the same
password. Changing a passphrase does not change the LUKS volume key: someone
who saved a copy of the header with the old key slot, or the volume key while
the disk was unlocked, could still decrypt it. A new owner who does not trust
the previous holder should run `sudo cryptsetup reencrypt` on each LUKS device
(online LUKS2 re-encryption; slow, keep the computer on mains power).

## Factory reset

Every guided installation leaves `/var/lib/cybexos/factory-point.pending`.
`cybexos-first-boot.service` runs at the first start, before any login, and
takes one **factory recovery point** with
`cybexos-system-snapshot create --factory`: the normal read-only root snapshot
and `/boot` archive, marked by `metadata/ID.factory`. It is outside the
five-point rotation and never pruned, and only one can exist.

`cybex factory-reset` (ISO installations; a checkout installation explains
that it is unavailable) runs `/usr/libexec/cybexos-factory-reset reset` with
sudo, so it needs administrator authentication. It refuses in a recovery boot,
with a restore waiting for a restart, with an unfinished update transaction,
or without a factory point. It shows what is erased, suggests
`cybex backup now`, and requires typing the computer name or `erase`. On an
encrypted disk it asks for the current passphrase and a temporary passphrase
for the next owner, and re-keys the disk to that passphrase alone (as above).
It then restores the factory point with the normal restore and records the
reset inside the restored root. **Settings → Recovery points → Factory
reset…** explains the same and opens it in a terminal.

At the next start, `cybexos-first-boot` completes the reset before any login:
it deletes every other recovery point, every set-aside root and the update
checkpoints (they contain the previous owner's system and files), removes every
desktop account and everything in `/home` (nested Btrfs subvolumes included;
other mounts are refused), SSH host keys and the sudo rule, converts the
installation's `config.yml` choices into `install-choices.json`, writes
`oem.json`, and the new-owner setup follows. The system is at the factory
point's package versions; the new owner updates as usual. Hostname and machine
ID are kept.
## Installation details and logs

An **Installation details** panel at the bottom of every page follows one
allow-listed log, refreshed every two seconds while open:

| Choice | Files |
| --- | --- |
| Installation steps | `/run/cybexos-installer/worker.log`: timestamped Anaconda steps and the error that stopped them |
| Anaconda | `/tmp/anaconda.log` |
| Commands | `/tmp/program.log` |
| Storage | `/tmp/storage.log` |
| Software | `/tmp/packaging.log` |
| Post-installation scripts | `/mnt/sysroot/var/log/anaconda/cybexos-cleanup.log` (chroot `%post`) and `/var/log/anaconda/cybexos-target-policy.log` (`--nochroot`) |

The page shows at most the last 96 KiB of each. A failed installation names the
step it stopped in and opens the log most likely to explain it: the
post-installation scripts for "Running post-installation scripts", otherwise
the step log. Public status and saved state use only fixed step labels. The
log panel records Anaconda's free-form task and error text, which can include
paths and personal data; review exported logs before sharing them. Anaconda's
`/tmp/sensitive-info.log` is never read.

**Save logs** writes `cybexos-install-logs-DATE-TIME.tar.gz`, with all of these
logs, the secret-free state file and this boot's journal, to a writable
filesystem (FAT, exFAT, ext2/3/4, Btrfs or XFS) on a removable drive. The live
medium, the selected target disk and fixed disks are never offered. An
unmounted drive is mounted `nosuid,nodev,noexec` only for the copy.

## Keyboard behavior

Before password entry is enabled, the backend validates the selected layout
against Anaconda's available layouts, obtains its virtual-console equivalent,
and applies the XKB layout/variant to the live user's single Hyprland session.
Changing layout clears the password fields and invalidates an earlier review.
The test input is for ordinary characters, not the password.

The adapter accepts ordinary `layout` and `layout (variant)` identifiers.
Layouts it cannot map to a boot keymap fail before password entry and can use
the full installer. Anaconda writes the installed keyboard configuration; the
desktop launcher reads locale1 on login. Physical non-US keyboards, dead keys,
non-ASCII passwords, and accessibility input require later actual boot tests.
Early-boot Bluetooth input support is not promised.

## Integration and source contract

The interface was checked against **Anaconda 44.30** (tag `anaconda-44.30`,
commit `2353f519077c7fc9c8d6fe7712adc141cad2b649`) and **anaconda-webui 68**.
These are the Fedora 44 versions used as the source reference.

- [Anaconda's live launcher](https://github.com/rhinstaller/anaconda/blob/anaconda-44.30/data/liveinst/liveinst)
  owns backend startup, authorization, required modules, and the live payload.
  It explicitly rejects Kickstart-based live installations.
- [Web UI customization](https://github.com/rhinstaller/anaconda-webui/blob/68/docs/customization.rst)
  documents the `webui_web_engine` hook. Our browser wrapper accepts only the
  loopback Anaconda URL, preserves its port, and substitutes the CybexOS page.
- [Anaconda's web launcher](https://github.com/rhinstaller/anaconda-webui/blob/68/webui-desktop)
  starts its Cockpit service and passes the local page URL to that browser.
- [Storage API sequence](https://github.com/rhinstaller/anaconda-webui/blob/68/src/apis/storage_partitioning.js):
  configure automatic partitioning, apply the in-memory layout, run its
  validation task, then review. CybexOS sets both selected disks and
  `DrivesToClear` to the one chosen disk. It obtains candidate disks from
  `GetUsableDisks` and excludes protected/non-disk devices.
- [Storage scan interface](https://github.com/rhinstaller/anaconda/blob/anaconda-44.30/pyanaconda/modules/storage/storage_interface.py)
  provides `ScanDevicesWithTask` for an explicit rescan. A rescan invalidates
  the prior review token. Existing partition details come from read-only
  `lsblk`; Anaconda remains the authority for disk selection.
- [Disk initialization interface](https://github.com/rhinstaller/anaconda/blob/anaconda-44.30/pyanaconda/modules/storage/disk_initialization/initialization_interface.py)
  defines the clearing scope. [PartitioningRequest](https://github.com/rhinstaller/anaconda/blob/anaconda-44.30/pyanaconda/modules/common/structures/partitioning.py)
  supplies Btrfs scheme `1`, LUKS2, and encryption policy.
- [Task interface](https://github.com/rhinstaller/anaconda/blob/anaconda-44.30/pyanaconda/modules/common/task/task_interface.py)
  defines `Start`, `Stopped`, `Finish`, `GetResult`, and progress. `Finish` is
  checked after stopping; stopping alone does not count as success.
- [Upstream installation progress](https://github.com/rhinstaller/anaconda-webui/blob/68/src/components/installation/InstallationProgress.jsx)
  starts the same Boss `InstallWithTasks` task. The CybexOS worker runs under
  systemd so a browser or SSH disconnect does not terminate its monitor.
- [UserData](https://github.com/rhinstaller/anaconda/blob/anaconda-44.30/pyanaconda/modules/common/structures/user.py)
  provides the account record; [localization](https://github.com/rhinstaller/anaconda/blob/anaconda-44.30/pyanaconda/modules/localization/localization_interface.py)
  provides layout selection and virtual-console conversion.

There is no claim of a stable third-party installer-plugin API. A Fedora or
Anaconda version update requires reviewing this adapter and re-running the
installation qualification, alongside normal source tests.

## Backend protocol

`/usr/libexec/cybexos-installer-backend COMMAND` reads one JSON object on stdin
and emits newline-delimited JSON. Input is capped at 16 KiB. Requests require
root, `/run/cybexos-live`, and `rd.live.image` on the running kernel command
line. Operations that need Anaconda also require its `backend_ready` marker.
Fixture tests import the controller/adapter; they do not bypass these runtime
guards or invoke a real installation.

| Command | Input | Result |
| --- | --- | --- |
| `inventory` | `{}` | Available disks with model, capacity, serial, WWN and existing partitions; layouts, locales, timezones and payload space requirement |
| `rescan` | `{}` | Invalidates any review, asks Anaconda to scan again, and returns a fresh inventory |
| `diagnostics` | `{}` | Allowlisted installer phase, progress, worker service state and backend readiness; no raw logs or personal data |
| `geolocate` | `{}` | Timezone from Anaconda's geolocation task, or empty; changes no selection |
| `keyboard` | `{"keyboard":"us"}` | Applied live keyboard and boot keymap |
| `seed` | `{}` | `{"found": false}`, or a display-safe seed summary with the matched disk, or every validation error |
| `cancel-seed` | `{"seed":"DIGEST"}` | Stops an unattended installation and resets the plan; that seed is not offered again in this live session |
| `alongside` | `{"disk":"vda"}` | Free space, or the one shrinkable partition with its floor and the CybexOS size range |
| `plan` | Account fields below, or `{"seed":"DIGEST"}` | Review token, disk identity, account policy, layout (`erase`/`alongside` with resize, space and kept partitions), disk actions, warnings; a seed plan adds its countdown |
| `install` | Token, disk, explicit erase or alongside confirmation | Starts the independent worker and returns `phase: installing` |
| `status` | No input required | Secret-free state and actual task progress |
| `reset` / `advanced` | `{}` | Clears the uncommitted plan and account state |
| `reboot` | `{}` | Reboots only when installation state is complete |
| `log` | `{"source":"steps"}` | The end of one allow-listed log (see above) |
| `log-destinations` | `{}` | Writable filesystems on removable drives |
| `export-logs` | `{"device":"sdb1"}` | Saves the log archive to one listed destination |

`plan` fields are `username`, `password`, `confirm`, `keyboard`, `locale`,
`timezone`, `hostname`, `disk`, optional boolean `encrypted` (default true),
optional boolean `passwordless_wheel` (default false), optional boolean `oem`
(default false; no `username`, and `password` is the temporary disk
passphrase), optional `layout` (`erase` or `alongside`) and, for `alongside`,
an optional `shrink` of `{"device": ID, "size": BYTES}` that must name the
partition `alongside` offered.
`disk` is an Anaconda disk name such as `vda`, not an arbitrary path.
`install` input is `{"token":"…","confirmed_disk":"vda","erase_confirmed":true}`,
or `"alongside_confirmed":true` for an alongside plan. A seed plan is refused
before its countdown has ended.
The final record is `{"event":"result","ok":true,"data":{…}}`, or
`{"event":"result","ok":false,"error":"safe display text"}`.
`worker` is an internal systemd entry point and does not accept user settings.

The review token expires after 30 minutes. Before installation, the controller
rechecks disk identity and existing partitions, selected disks, applied partitioning, the exact set of
pending actions, and storage validation. The set is compared without order:
`GetActions()` re-sorts blivet's list on every call, and its topological sort
reverses independent actions each time. A rejected confirmation returns to disk
selection. It never retries a started install. A failed
worker or interrupted task requires diagnosis, and the state continues to
block a replacement storage transaction. Status reads never overwrite worker
progress or completion. The startup grace prevents a queued service from being
mistaken for a lost monitor.

## Credentials, state, and target finalization

The UI passes the password through Cockpit stdin; it is never a command-line
argument. The helper uses Anaconda's own password-hashing function, provides the
plaintext only to its LUKS method, and drops its request copies. Python and
JavaScript do not guarantee immediate memory erasure. No disk key file or
plaintext password is written to the live image or target. A seed's account
arrives as a hash only; its disk passphrase is read from the seed volume into
memory for `SetPassphrase`. The only credential the installer moves to the
target is a seed's one-time Tailscale key (see above).

`/run/cybexos-installer/state.json` is root-only, contains no password/hash, and
is replaced atomically. It holds disk identity, user-visible choices, the review
token before commit, task path, and progress. The browser uses a disposable
runtime profile with password saving, form history, and crash-session restore
disabled. Exceptions returned to the UI exclude raw DBus parameters. The welcome
launcher requests `--nosave=all_ks` to avoid saving generated account metadata.
Status and exported diagnostics expose only allowlisted phase, progress and
service fields. Anaconda's free-form task messages and journals are never
copied into the browser export because they may contain personal data. A failed
installation stays blocked pending diagnosis; the page never retries disk writes.

The existing post-install hook removes the live account, temporary permissions,
live installer page/helpers/browser configuration, and live services. It calls
`cybexos-seed-installed-users` in the target before declaring success. A final
initramfs regeneration happens after live-only dracut configuration is removed.
The shipped CybexOS firewall zone is restored after Anaconda's firewall task,
which otherwise adds an SSH exception by default. A final
non-chroot post hook invokes `cybexos-installer-target`, which checks the actual
`/mnt/sysroot` mount, root encryption ancestry, created user, and locked root
before writing `/etc/cybexos/login.json`. This versioned nonsecret policy names
the installed user, requested autologin and `live: false`.
`/etc/cybexos/installation.json` records installation and keyring policy metadata.
The target hook removes any wheel sudo rule inherited from the live image.
Fresh offline configuration also defaults `passwordless_wheel` to false, so a
stock Advanced installation requires an administrator password. The guided
installer changes that policy and installs a mode-0440 sudoers rule only after
the user explicitly selects passwordless sudo and confirms the review.

Before that, the first post hook (`cybexos-installer-target --stage`, ordered
before the in-target hook) writes a seed's explicit choices to
`/etc/cybexos/install-choices.json`; `cybexos-config` applies them through the
shared `installation_policy.apply_choices` when it records `config.yml` for a
fresh account and then removes the file. The final hook also handles the other
guided paths: for a new-owner installation it requires that no desktop account
exists and writes `oem.json` and a disabled login policy; for a seed it adds the
authorized keys (owned by the account, `0700`/`0600`), enables `sshd` only when
asked, and moves the staged Tailscale key; for an alongside installation it
clears `menu_auto_hide` and records whether os-prober added another system.
Every guided installation gets `/var/lib/cybexos/factory-point.pending`.

The temporary live account has a separate policy with `live: true` and a
root-owned `/run/cybexos-live-session` marker. The login helper accepts this
exception only with the live kernel command-line flag. Target cleanup removes
the marker and prepared SDDM configuration and writes a disabled installed
policy before the final target helper runs. Stock Advanced installations keep
that disabled policy. Boot-local autologin state lives in
`/run/cybexos-login/autologin-used`; it cannot authorize a later boot.

## Tests and remaining qualification

`image/test_installer_seed.py` validates the documented seed example and every
seed rule, disk matching (zero/several matches, the seed's own disk), read-only
discovery with symlink refusal and unmounting, secret separation, the
backend-enforced countdown and the target hook's keys, SSH server, one-time
Tailscale key, OEM and alongside records. `image/test_installer.py` checks the
alongside, OEM and seed storage/account sequences against strict anaconda-44.30
proxies (`CLEAR_PARTITIONS_NONE`, one `ShrinkDevice` on the partitioning's tree
before configuration, no account and a locked root for OEM, a seed hash used
as-is) and the controller's refusal of plans that touch other partitions.
`image/test_new_owner.py` covers LUKS re-keying against a fake LUKS2 header,
the new-owner questions and provisioning order with rollback and crash
recovery, the initramfs keymap refresh, the graphical setup's root side (the
window protocol with malformed, unknown and oversized messages, the
unprivileged `systemd-run` command, console handover, fallback selection, a
scripted end-to-end conversation with keyboard restart, wrong passphrase and
failed provisioning, and that no secret reaches a log or command line), the
factory reset guard rails and next-start cleanup, and the first-start
factory point. `image/test_new_owner_window.py` loads the window offscreen and
drives its pages, validation, live Dutch/English switching, translation
completeness, finishing states, and checks that every message it sends passes
the root service's parser.
`image/test_installation_parity.py` compares seed-style explicit choices on
the ISO and checkout paths. The browser fixture (`image/browser-smoke.cjs`)
drives the alongside slider and review, new-owner mode, and the seed
countdown, cancel and error screens with a mocked backend.

None of these establishes a real installation. The following still need ISO
and VM (and some real hardware) qualification before they can be called
working: Anaconda 44.30 accepting an installation without any user;
`GetDeviceTree`/`ShrinkDevice` and free-space automatic partitioning on real
NTFS (including `ntfsresize` and a Windows that boots afterwards), ext4 and
already-full disks; the ESP being reused unformatted; os-prober entries in the
generated `grub.cfg` on UEFI and BIOS and the visible menu; seed discovery for
vfat, ISO9660 `cidata` and ext4 volumes and the welcome auto-start; the
countdown, cancel and unattended end-to-end result, including SSH and one-time
Tailscale enrollment at the first start; the graphical new-owner setup on tty1
before SDDM (Plymouth hand-off, cage with the `noop` seat backend as a
`DynamicUser` on real Intel, AMD and NVIDIA graphics, input devices, the
console mode handover, cage restarting with a new layout, HiDPI scaling) and
its console fallback (localed keyboard, `chpasswd`, initramfs keymap refresh,
LUKS re-key on a real LUKS2 header, restart into autologin and keyring);
taking the factory point
at the first start; and a complete factory reset of an encrypted installation
through to the new owner's first login.
Every image build runs the chroot `%post` of `90-cybexos.ks` against the
composed root filesystem before packaging (`image/post_install_check.py`). It
uses a throwaway overlay with an Anaconda-like administrator account, the live
`/run` layout Anaconda binds into the target, and no network, then applies the
target helper and checks the resulting policy. A failure stops the build and
prints the script's output. This is how the 2026-09-26 failure (a missing
`/var/lib/systemd/linger` directory aborting every installation after the boot
loader step) would have been caught.

`image/test_installer.py` covers input/locale validation, disk identity changes,
confirmation/replay, plan failures and retries, durable worker outcomes, monitor
loss, strict Anaconda proxy members and ordering, password separation, keyboard
commands, target autologin conditions, rejection of mixed encrypted/plaintext
backing devices, live-policy cleanup, executable permissions, and browser URL
validation. Node fixtures cover UI state, confirmation, navigation locks, and
failure recovery. Image tests load the welcome QML offscreen in both modes and
drive its wallpaper row against a scripted shell. The
headless browser fixture exercises the three pages with a mocked backend.
`image/test_qualification.py` checks URL and disk identity guards without
starting a VM.

The opt-in `image/qualify` harness drives the guest's actual Cockpit page
through a local SSH tunnel and host Playwright. It discovers the guest URL from
the live browser command line, selects only the disk with the fixed disposable
serial, and verifies that a second attached disk's image hash is unchanged.
`--scenario` selects encrypted/plain storage and US/NL (or DE) keyboard and
locale. A `--candidate-rpm` must have a newer installed RPM version; the
optional `--recovery-check` creates a point before upgrade, boots its GRUB
entry, restores it and verifies the baseline RPM returned. The report at
`OUTPUT/qualification.json` records the exact ISO and candidate RPM SHA-256,
scenario, checks and final status. Credentials are passed to the browser driver
on stdin and excluded from its output. Source tests do not establish a
successful VM installation.

Still required before an ISO can be called working: execution and observation
of actual Cockpit loading and
authorization, Fedora DBus behavior, UEFI/BIOS boot, encrypted and unencrypted
installation, keyboard input at LUKS unlock, autologin, post-script ordering,
offline payload completeness, driver/hardware behavior, and clean installed
services. The SDDM migration additionally needs real boot-cache/keyring handoff,
logout/relogin, compositor-crash and SDDM restart checks. The guest qualification
harness also injects an early first-autologin launcher failure, verifies that
the boot attempt remains consumed, and tests password-login recovery after a
manager restart. It restores the original launcher in cleanup. These checks
must run on isolated test disks with explicit opt-in; their presence in the
harness and passing source fixtures do not establish a boot result.
