# CybexOS installation experience

The live image opens a small CybexOS page in Anaconda's existing local Cockpit
service. It uses Fedora's Anaconda storage and installation backend. It does not
format devices itself, generate an unattended live Kickstart, or replace
Anaconda's partition validation.

This implementation has **source and fixture validation only**. The work that
introduced it was explicitly limited to source changes: no ISO build, ISO boot,
real installation, disk change, or host deployment was performed. Do not label
an image containing it qualified until the opt-in installation tests pass.

## User flow

1. **Your setup:** select a keyboard, test it, and enter username/password twice.
   Language, timezone, and hostname are available under an expandable section.
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
enabling GDM autologin. Unencrypted and stock Advanced installations retain the
normal login screen. EFI and boot partitions follow Anaconda's platform rules;
“encrypted installation” does not mean the firmware boot partition is encrypted.

The app keyring remains protected. Automatic login does not transmit the boot
passphrase to PAM or unlock a separately encrypted keyring, so an application
may request a keyring password on first use. The UI states this; the installer
does not blank a keyring password or weaken the PAM configuration. The disk and
account passwords start equal, but later changes are independent. There is no
automatic synchronization or new password-changing helper in this change.

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
| `inventory` | `{}` | Available disks, layouts, locales, timezone, payload space requirement |
| `keyboard` | `{"keyboard":"us"}` | Applied live keyboard and boot keymap |
| `plan` | Account fields below | Review token, disk identity, account policy, disk actions, warnings |
| `install` | Token, disk, explicit erase confirmation | Starts the independent worker and returns `phase: installing` |
| `status` | No input required | Secret-free state and actual task progress |
| `reset` / `advanced` | `{}` | Clears the uncommitted plan and account state |
| `reboot` | `{}` | Reboots only when installation state is complete |

`plan` fields are `username`, `password`, `confirm`, `keyboard`, `locale`,
`timezone`, `hostname`, `disk`, and optional boolean `encrypted` (default true).
`disk` is an Anaconda disk name such as `vda`, not an arbitrary path.
`install` input is `{"token":"…","confirmed_disk":"vda","erase_confirmed":true}`.
The final record is `{"event":"result","ok":true,"data":{…}}`, or
`{"event":"result","ok":false,"error":"safe display text"}`.
`worker` is an internal systemd entry point and does not accept user settings.

The review token expires after 30 minutes. Before installation, the controller
rechecks disk identity, selected disks, applied partitioning, exact pending
actions, and storage validation. It never retries a started install. A failed
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
before setting GDM policy. `/etc/cybexos/installation.json` records only the
nonsecret account/encryption/autologin/keyring policy.

## Tests and remaining qualification

`image/test_installer.py` covers input/locale validation, disk identity changes,
confirmation/replay, plan failures and retries, durable worker outcomes, monitor
loss, strict Anaconda proxy members and ordering, password separation, keyboard
commands, target autologin conditions, executable permissions, and browser URL
validation. Node fixtures cover UI state, confirmation, navigation locks, and
failure recovery. Existing image tests load the welcome QML offscreen. The
headless browser fixture exercises the three pages with a mocked backend.

Still required before an ISO can be called working: actual Cockpit loading and
authorization, Fedora DBus behavior, UEFI/BIOS boot, encrypted and unencrypted
installation, keyboard input at LUKS unlock, autologin, post-script ordering,
offline payload completeness, driver/hardware behavior, and clean installed
services. The test harness must use its own isolated disks and require explicit
opt-in. Source fixtures cannot establish those results.
