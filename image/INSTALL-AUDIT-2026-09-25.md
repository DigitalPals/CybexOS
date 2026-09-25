# Installed XPS audit — 2026-09-25

The application payload was installed, but the ISO does not reproduce the
workstation's complete baseline, account policy, or hardware configuration.
There is also a session dependency cycle that prevents three desktop services
from starting. These are image/configuration defects, rather than evidence of
an interrupted application seed.

This records the initial read-only investigation followed by the authorized
repair and validation. The findings below describe the original installation;
the applied-repair section records the resulting state.

## Build and checks

- Computer: Dell XPS 14 DA14260, SKU 0DB9, Fedora 44, kernel
  `7.2.7-200.fc44.x86_64`.
- Original installed build: `20260925T140839Z-5f33cb32`, clean source revision
  `a2d31c2c13b5ab92491a8650991c519a223d10bb`.
- Read-only SSH inspection of `john@10.10.0.7` matched that build to
  `/data/pxe/iso/CybexOS-Live-44-20260925T140839Z-5f33cb32.iso` and the
  builder's provenance. That original ISO remains unchanged.
- All **166 explicit RPM selections** in the installed `applications.json`
  are present, along with all **three declared Flatpak applications**.
- Offline application seeding reports `ready`. No broken symlinks were found
  in the user's `.local/bin`, `.npm-global/bin`, or `.cargo/bin`.
- Claude, OpenCode, Cargo, Node, Bun, awww, wayfreeze and voxtype version
  commands succeed. This does not qualify every application's interactive use.
- Quickshell is active with its MainPID as the sole `qs` process. Hyprland
  reports no configuration errors. Its current journal confirms the missing
  PowerProfiles service and contains existing portal/property warnings.
- System and user `--failed` lists are empty; that check misses the startup
  jobs systemd discarded to resolve the dependency cycle below.

## Reported problems

| Problem | Evidence and cause | Required correction |
| --- | --- | --- |
| Nano missing after installation | Neither the required application list nor the image kickstart selects `nano`. The local RPM was installed at 17:22 CEST by a later `dnf install nano`, confirmed in the journal and DNF log. | Add `nano` to the shared required package contract so both installation paths include it. |
| Updates widget error | The original Quickshell warning at 17:01 CEST is `Cache-only enabled but no cache` for the Hyprland COPR. The widget only runs `dnf --quiet --cacheonly check-update`; the image runs `dnf clean all`. The makecache timer starts after 10 minutes plus up to 60 minutes of randomized delay, and its service requires AC power. | Bootstrap verified metadata on the first online boot and make the widget handle an uninitialized cache explicitly. |
| Signing-key prompts and incomplete update checks | The manual root DNF run encountered missing repository metadata keys, then verified signatures after acceptance. The unprivileged check still logs missing keys and skips `openai-chatgpt` and `tailscale-stable`, even while returning exit status 0. | Initialize trust in the context used by update checks, using the reviewed pinned keys. Treat skipped enabled repositories as an incomplete check. Keep signature verification enabled. |
| LocalSend cannot communicate normally | Flatpak 1.18.2 is installed and starts; it binds TCP and UDP port 53317. The active network interfaces use the `cybexos` zone. Its shipped definition has target `DROP` and no allowed ports because `features.local_network_services` defaults to false. A connection from the PXE host to the laptop's listening port timed out. | Include the intended LocalSend TCP/UDP rules in the active and permanent policy. Test discovery and a transfer in both directions. |
| Codex/Claude do not default to YOLO | The user's login shell is `/bin/bash`. The Codex alias exists and resolves correctly in interactive Fish, but Bash does not source it. No Claude alias exists in the shared Fish configuration. The image seeds Fish files but never sets the installed account's shell. | Apply the intended Fish login-shell policy during installed-account setup and add the Claude alias. Verify the aliases in a newly opened terminal. |
| Passwordless sudo missing | `sudo -n true` requires a password. The repository default is explicitly `passwordless_wheel: false`; its sudoers task belongs to the base role, which the image application playbook does not run. | Record the requested enabled policy and apply a validated, mode-0440 sudoers entry during image installation. Updating only the Ansible default would not fix the image path. |
| Tailscale click does not open login | The UI first opens a setup view; `Continue in browser` calls `signIn()`. When unprivileged Tailscale needs permission, it retries through `pkexec`. The Polkit agent was never started because of the session cycle. Tailscale is now logged in following the user's manual `sudo tailscale up`. | Repair the Polkit agent startup. If the desired initial click must open the browser directly, route that action to `signIn()` rather than only `showSetup()`. Verify with a fresh unauthenticated test account/device. |

The original Tailscale interaction was not replayed by logging out the user's
working connection. The missing agent and extra setup step are confirmed;
the exact button sequence used in the failed attempt is unknown.

LocalSend was launched briefly with `--hidden` and the task-owned Flatpak
instance was stopped afterward. No files were transferred. The inbound timeout
is consistent with the shipped host firewall; routed-network filtering could
also contribute. The permanent `/etc/firewalld` configuration and live ruleset
could not be fully read without authentication. A loopback HTTPS probe did
not return a successful response, so complete protocol/transfer functionality
has not been established.

[LocalSend's upstream requirements](https://github.com/localsend/localsend/blob/main/README.md#setup)
specify incoming TCP and UDP 53317.
[DNF5 documents](https://dnf5.readthedocs.io/en/latest/dnf5.conf.5.html#repo-gpgcheck)
that repository metadata keys are separate from package keys and are stored
separately for each repository. Importing an RPM key alone is insufficient.

The requested alias arguments are supported by the installed CLIs and their
official references: Codex
[`--dangerously-bypass-approvals-and-sandbox`](https://learn.chatgpt.com/docs/developer-commands?surface=cli)
and Claude
[`--dangerously-skip-permissions`](https://code.claude.com/docs/en/cli-reference).

## Additional defects to fix first

### 1. Session startup: authentication, automatic locking, dictation

The current boot journal explicitly records an ordering cycle for each of
`hyprpolkitagent.service`, `hypridle.service` and `voxtype.service`, followed by
deletion of its start job. All three are inactive, with no corresponding process.

`image/rootfs/usr/lib/systemd/user/hyprland-session.target` wants these units
and orders itself before `graphical-session.target`. Their vendor units order
themselves after `graphical-session.target`. Systemd's target dependency
ordering closes the cycle. The image's drop-ins do not reconcile that ordering.
The workstation uses its own service templates instead.

Repair the image session ordering and verify the installed vendor units and
drop-ins together. A successful login and a running menubar do not verify that
authorization prompts, automatic idle locking, or dictation are operational.
The inactive idle daemon makes this the first repair priority.

### 2. Missing baseline packages and services

`image/applications` reads application packages and selected desktop/Docker
tasks. It omits the `Install Fedora baseline packages` task. Compared with that
task, this computer is missing:

| Missing package | Affected feature |
| --- | --- |
| `tuned-ppd` | Desktop power-profile backend; Quickshell explicitly reports PowerProfiles unavailable. Neither this nor `power-profiles-daemon` is installed. |
| `cups` | Printing service; the printer settings application is installed without its intended local print server. |
| `avahi` | Local service discovery. |
| `bolt` | Thunderbolt authorization management. |
| `gvfs-fuse` | Filesystem access to GVfs mounts. |
| `acl` | ACL administration tools. |
| `bash-completion` | Bash command completion. |
| `powertop` | Power diagnostics. |

The separately selected workstation desktop package `fuzzel` is also absent.
The firmware refresh timer is disabled, while the base role enables it.
Baseline services must be installed and activated together, rather than merely
adding their client applications to the manifest.

### 3. Update delivery and omitted integration files

- `1password` and `openai-chatgpt` are each defined twice: once by their vendor
  files and once in `cybex-applications.repo`. DNF logs duplicate-ID errors.
  `image/compose` writes the combined file after vendor packages have created
  their own files. Reconcile the definitions and preserve the reviewed policy
  across vendor RPM scriptlets; use DNF overrides where appropriate.
- `cybexos-firmware-update` is omitted from `image/package`'s helper list.
  The installed update runner expects it beside itself and records firmware
  status 127 when it is absent. `fwupdmgr` itself is installed.
- `/usr/share/cybexos/update-channel.json` contains `enabled: false`.
  Fedora/vendor updates can work, but there is no enabled repository delivering
  new CybexOS desktop RPMs. A signed desktop update channel remains a separate
  release requirement.
- The image omits the workstation's LocalSend Nautilus extension and three
  share launcher desktop files. The basic LocalSend command is installed.
  Its file/clipboard share helpers also need actual Flatpak transfer testing;
  command existence alone does not establish that those integrations work.

### 4. The XPS hardware role is not applied

The image package renders desktop configuration with `cybexos_xps_2026=False`
and does not run the detected-hardware role for the installed computer.
This machine has the matching XPS SKU, Panther Lake IPU7 PCI function and a
Synaptics `06cb:0701` SVP7500 camera USBIO bridge. This is not a fingerprint
reader; the hardware role explicitly excludes it from fingerprint detection.

Compared with the repository's XPS package tasks, missing packages include:

- `alsa-sof-firmware`, `cirrus-audio-firmware`, `intel-audio-firmware` and
  `intel-vsc-firmware`;
- `libva-intel-media-driver` and `intel-vpl-gpu-rt`;
- `pipewire-utils`, `pipewire-module-filter-chain-lv2` and `lsp-plugins-lv2`;
- Fingerprint packages are conditional on detecting a real supported reader;
  their absence on this laptop is not an established installation defect.

The intended camera setup, audio processing, touchpad/backlight configuration
and thermal/power configuration are therefore not established by this ISO.
The initial `/dev/video*`/sysfs inventory exposed only the external Studio
Display camera, not the laptop's internal camera. No supported fingerprint
reader was detected; the existing role probes support before enabling
fingerprint authentication.

Hardware repair needs the role's model gates and physical testing. Do not
blindly install an IPU camera stack or apply laptop-specific tuning to every ISO
installation.

## Repair and qualification order

1. Correct the session dependency cycle; verify Polkit, idle locking and
   dictation after a fresh login, with exactly one service-owned Quickshell.
2. Bring the image's baseline packages/services into the shared contract,
   including nano and the firmware-update helper.
3. Reconcile repository definitions, bootstrap trusted metadata, and require
   complete update-check coverage for every enabled repository.
4. Apply the requested installed-account defaults: Fish, both CLI aliases and
   passwordless sudo. Test from a new terminal and with `sudo -n true`.
5. Correct LocalSend firewall/integration defaults and exercise bidirectional
   transfers. Exercise Tailscale browser login from an unauthenticated state.
6. Apply and validate the detected XPS hardware configuration; qualify internal
   camera, audio, power profiles and fingerprint support independently.
7. Run first-boot tests with empty DNF caches and no accepted user-side keys
   before building/publishing another testing ISO. Add service and behavior
   checks; repeating the current manifest-presence test will miss these defects.

The initial audit was read-only apart from this document and a temporary
LocalSend launch, which was stopped. The authorized repair below followed it.

## Applied repair and physical-machine validation

The repair uses shared package, account, service, firewall, Fish and hardware
sources. Anaconda runs the offline account configuration; a first-boot service
runs model-gated hardware setup. Firmware and ALSA UCM profiles are included
in the ISO before the first physical boot. The latter were also missing:
without `alsa-ucm`, the newly detected internal sound card exposed only a
generic stereo fallback instead of its speaker, headphone and microphone paths.

Validated on the installed laptop:

- The package-contract preview reports no missing packages. Nano was already
  manually installed; it is now also in the source package contract.
- `john` has `/usr/bin/fish`; an interactive Fish session defines both requested
  YOLO aliases. `sudo -k -n true` succeeds using the validated wheel policy.
- Polkit, hypridle, voxtype, TuneD PPD, thermal management and the haptic service
  run. Exactly one Quickshell is owned by its service; its current invocation
  passes the repository's live-shell journal check.
- Root and user DNF checks succeed with unavailable-repository failures enabled.
  There are no duplicate repository IDs. Repository reconciliation is idempotent.
  A separate empty-cache user check also succeeds: DNF automatically imports
  the bundled Codex, Tailscale and 1Password metadata keys without prompting.
- LocalSend's TCP/UDP 53317 ports are open. A protocol-compatible HTTPS request
  with a disposable client certificate from `10.10.0.7` successfully retrieves
  the laptop's device information. Plain curl without a client certificate is
  rejected by LocalSend's mutual TLS; that is not a firewall failure. The
  file wrapper now uses Flatpak document forwarding and the installed version's
  supported file/text arguments. John subsequently confirmed that a real
  LocalSend transfer with another device works.
- Tailscale remains connected to the user's existing account. Login routing,
  duplicate-click prevention and browser handoff pass the behavioral fixtures;
  the active account was not logged out for testing.
- Loading the newly installed audio firmware exposed the internal sound card.
  With ALSA UCM installed, the internal speaker/headphone/microphone nodes appear.
  The speaker-tuning check verifies its 26 biquads, limiter and physical output.
  John subsequently confirmed audible output through the internal speakers.
  Internal microphone capture has not been physically verified.
- A repeat baseline/account configuration finishes with `changed=0`, `failed=0`.

The camera setup exposed an additional Fedora-specific bug: its generic relay
configuration is a dangling symlink into `/run`. Backup and restoration now
preserve the symlink rather than dereferencing it, with a regression fixture.
The subsequent hardware check reaches the existing ABI guard and refuses the
optional camera bundle on `7.2.7-200.fc44.x86_64`: Fedora now ships `intel_cvs`
in-tree. No conflicting DKMS module was installed. The diagnostic remains at
`/var/lib/xps-hardware/ipu7/abi-failed.log`; `cybex doctor` reports it. Automatic
retry avoids rebuilding the same incompatible kernel/payload combination.
This needs a separate camera compatibility change, not a reinstall.

The signed CybexOS desktop RPM update channel is still unconfigured. This is
separate from the now-working Fedora/vendor/Flatpak update checks.

Repair backups are retained under `/var/lib/cybexos/backups/`:
`install-repair-20260925T160403Z` (212 KiB) and
`install-repair-20260925T160524Z` (24 KiB). They preserve replaced system files
and account/Fish configuration for review or rollback.

## Rebuilt delivery and regression verification

Build `20260925T162842Z-f71bbab0` completed successfully from a task-specific
worktree. Its live audit verifies all 209 explicit RPM selections, all three
Flatpaks and the bundled user toolchains. The laptop was upgraded to its matching desktop RPM,
`1:0.0.0~dev-1.20260925162842.gfe1179ea114a.dirty.fc44.x86_64`.
Repeating shared configuration after the RPM upgrade reports `changed=0`,
`failed=0`. The post-upgrade package audit reports no missing packages, and the
live Quickshell check confirms one service-owned process with no matching QML
errors in the current invocation.

The ISO is published on `john@10.10.0.7` at
`/data/pxe/iso/CybexOS-Live-44-20260925T162842Z-f71bbab0.iso`
(6,927,169,536 bytes), with a companion `.iso.sha256` file. SHA-256:
`412509d7013d636e9a62ddae7a46a233f4434de60cc679aff244ec75ff199b63`.
The publisher verified the copied checksum, successful iVentoy refresh, image
listing, running PXE status and active `iventoy.service`. Existing ISOs remain.

The full repository test suite passed all 17 stages, including 1,146 JavaScript
tests across 122 files. Source checks, shared Ansible policy fixtures and
static analysis also passed. A disposable Fedora 44 container applied the
account/firewall policy successfully; its second application made no changes.
The final image source check passes 20 image fixtures, 102 additional Python
fixtures and four installer JavaScript fixtures.

The installation VM runner initially failed before boot because it supplied a
disk serial number as a block-backend option. The corrected runner attaches
the serial number to `virtio-blk-pci`, preserving the disposable-disk identity
check. QEMU documents the separate
[drive and device arguments](https://github.com/qemu/qemu/blob/master/docs/qdev-device-use.txt).
The original 21-byte serial was also truncated by Virtio's
[20-byte identifier limit](https://github.com/torvalds/linux/blob/master/include/uapi/linux/virtio_blk.h).
The runner and installer guard now share a shorter constant, with a protocol
length regression check; the guard continues to require an exact match.
This host-side runner change does not alter the built ISO payload.

The bootstrap now waits for the first-run desktop before sending terminal
shortcuts or commands, uses a separate workspace, and closes failed terminal
attempts. It still requires a freshly computed shell-output marker before
typing private fixture input. This prevents boot-menu editing and unreadable
stacks of tiled terminals during automated qualification; regression fixtures
cover both conditions that gate private input.

The first completed encrypted-installation run booted without the ISO and
passed the new account/service checks, then exposed a test-only permissions
mistake: Fedora restricts traversal of `/etc/firewalld`. The installed audit
now queries both runtime and permanent LocalSend ports through
`sudo -n firewall-cmd`, instead of reading that directory as an ordinary user.

Live qualification also exposed a process-audit bug: `qs ipc -p ...` clients
were classified as developer menubars because they contain `-p`. The shared
test helper now waits for IPC clients to finish naturally and only uses the
existing termination path for actual developer instances. A regression fixture
verifies that IPC clients receive no termination signal.

The final UEFI qualification **passed** with guest outbound networking blocked.
It verified the live applications, a fresh encrypted installation, boot without
the ISO, Btrfs encryption, SELinux enforcing, desktop settings and removal of
live-only access. The installed account passed Fish, both YOLO aliases,
passwordless sudo, session services, enabled baseline timers and both runtime
and permanent LocalSend firewall checks.

All 21 named qualification stages passed, including cold reboot with an
encrypted keyring, logout/compositor-crash/display-manager-restart recovery,
missing boot-password-cache fallback and a deliberately failed first autologin.
These are VM results, not physical GPU, Secure Boot or camera certification.

## Retained artifacts and cleanup

On `john@10.10.0.7`:

| Path | Size | Reason retained |
| --- | --- | --- |
| `/data/pxe/iso/CybexOS-Live-44-20260925T162842Z-f71bbab0.iso` | 6,927,169,536 bytes (6.45 GiB) | Completed and qualified testing ISO, visible in iVentoy. |
| Same ISO path with `.sha256` appended | 112 bytes | Verified ISO checksum. |
| `~/.local/share/cybexos/images/install-policy-20260925-2200/deliverables/cybexos-desktop-0.0.0~dev-1.20260925162842.gfe1179ea114a.dirty.fc44.x86_64.rpm` | 1,720,229,107 bytes (1.60 GiB) | Matching repair package already installed on the laptop; retained for review/reuse. |
| Same `deliverables/` directory: `applications.json`, `packages.txt`, `build-provenance.json`, `qualification.json`, `SHA256SUMS` | Under 70 KiB combined | Package selections, exact RPM inventory, provenance, passed qualification report and checksums. |

The task's failed/superseded VM runs, all disposable disks, credentials,
screenshots, duplicate build ISO, intermediate RPMs, temporary logs and build
worktree were removed. Only `deliverables/` remains in the task staging root.
The original installation ISO and unrelated images were preserved. Small
laptop rollback backups and the camera diagnostic described above remain
intentionally. Repository changes remain uncommitted in both checkouts.
Final cleanup checks found no task-owned VM processes or mounts. The remote
staging root uses 1.6 GiB for the retained deliverables; local temporary repair
files, package staging and task bytecode caches are gone. All retained package
checksums pass, and iVentoy still reports the expected ISO and running PXE.

## Recommendation

Keep and repair the current installation. Its original application payload
was complete for the old manifest; the problems came from missing shared
configuration and several independent image defaults. Reinstalling the old
image would repeat those defects, and reinstalling the new image would not
resolve the camera's current kernel incompatibility.

Reboot once after this repair to load the firmware, hardware environment and
new login-shell defaults cleanly. John has confirmed a real LocalSend transfer
and internal speaker output. Internal microphone capture remains unverified;
service and device-node checks alone do not establish its physical operation.
