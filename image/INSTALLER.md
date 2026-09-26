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
   Language, timezone, and hostname are available under an expandable section.
   The timezone is a dropdown of Anaconda's valid timezones, preselected from
   Anaconda's geolocation (Fedora's GeoIP service) unless the user chose one.
2. **Install location:** choose a disk. The default is automatic Btrfs with
   LUKS2 encryption. The full disk is erased only after the final confirmation.
   The advanced section can disable encryption or open the stock Anaconda Web
   UI for custom storage, dual boot, and existing partitions.
3. **Review and install:** show the target model/path, account, encryption,
   startup behavior, boot keyboard, language/timezone, actual Anaconda disk
   actions, and its validation warnings. An explicit erase checkbox is required.
   Progress thereafter comes from Anaconda's real task signals.

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
the step log. The step log records Anaconda's error text; its installation task
has no parameters, so no request or secret can be part of it. Anaconda's
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
| `inventory` | `{}` | Available disks, layouts, locales, timezones and any detected one, payload space requirement |
| `geolocate` | `{}` | Timezone from Anaconda's geolocation task, or empty; changes no selection |
| `keyboard` | `{"keyboard":"us"}` | Applied live keyboard and boot keymap |
| `plan` | Account fields below | Review token, disk identity, account policy, disk actions, warnings |
| `install` | Token, disk, explicit erase confirmation | Starts the independent worker and returns `phase: installing` |
| `status` | No input required | Secret-free state and actual task progress |
| `reset` / `advanced` | `{}` | Clears the uncommitted plan and account state |
| `reboot` | `{}` | Reboots only when installation state is complete |
| `log` | `{"source":"steps"}` | The end of one allow-listed log (see above) |
| `log-destinations` | `{}` | Writable filesystems on removable drives |
| `export-logs` | `{"device":"sdb1"}` | Saves the log archive to one listed destination |

`plan` fields are `username`, `password`, `confirm`, `keyboard`, `locale`,
`timezone`, `hostname`, `disk`, and optional boolean `encrypted` (default true).
`disk` is an Anaconda disk name such as `vda`, not an arbitrary path.
`install` input is `{"token":"…","confirmed_disk":"vda","erase_confirmed":true}`.
The final record is `{"event":"result","ok":true,"data":{…}}`, or
`{"event":"result","ok":false,"error":"safe display text"}`.
`worker` is an internal systemd entry point and does not accept user settings.

The review token expires after 30 minutes. Before installation, the controller
rechecks disk identity, selected disks, applied partitioning, the exact set of
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
plaintext password is written to the live image or target.

`/run/cybexos-installer/state.json` is root-only, contains no password/hash, and
is replaced atomically. It holds disk identity, user-visible choices, the review
token before commit, task path, and progress. The browser uses a disposable
runtime profile with password saving, form history, and crash-session restore
disabled. Exceptions returned to the UI exclude raw DBus parameters. The welcome
launcher requests `--nosave=all_ks` to avoid saving generated account metadata.

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

The temporary live account has a separate policy with `live: true` and a
root-owned `/run/cybexos-live-session` marker. The login helper accepts this
exception only with the live kernel command-line flag. Target cleanup removes
the marker and prepared SDDM configuration and writes a disabled installed
policy before the final target helper runs. Stock Advanced installations keep
that disabled policy. Boot-local autologin state lives in
`/run/cybexos-login/autologin-used`; it cannot authorize a later boot.

## Tests and remaining qualification

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

Still required before an ISO can be called working: actual Cockpit loading and
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
