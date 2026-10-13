# ISO lifecycle qualification, 26 September 2026

Status: the corrected replacement ISO passed all five UEFI QEMU scenarios
(88 checks), is checksum-verified, and is listed in iVentoy. This report does
not qualify a public release.

## Candidate and evidence

The candidate was built from clean source
`a991a97d099936298edfa7ad4c1747a3d0261f74` (`source_dirty=false`). Its source
archive SHA-256 is
`a0f0462f828f637c68c5dcb8233a78e5f32541223aef1b76f60cdc0d040bb1cc`.
The [build manifest](qualification-results/2026-09-26/build.json) binds the
source and artifacts. Each final report's `source_revision` records its
qualification harness revision.
The later `bd04954` change only fixes qualification-tool socket paths; it does
not change the installed ISO runtime.

Artifacts retained on `john@10.10.0.7` for private installation and upgrade review:

| Artifact | Path | Bytes |
| --- | --- | ---: |
| Private testing ISO | `/data/pxe/iso/CybexOS-Live-44-20260926T150946Z-99900b99.iso` | 7,633,059,840 |
| Matching unsigned testing RPM | `/data/cybexos-candidate-rpm-20260926-a991a97/cybexos-desktop-0.0.0~dev-1.20260926150946.ga991a97d0999.fc44.x86_64.rpm` | 1,720,330,844 |

Each has an adjacent SHA-256 sidecar (112 bytes for the ISO; 139 bytes for
the RPM). Six compact JSON files in `image/qualification-results/2026-09-26/`
retain 8,929 bytes of build provenance and final qualification evidence. Digests:

```text
ISO  7b192a15375fd5f6132ce82626dbbce9171d6f297d4bbc4defee32340303d635
RPM  e42fa8fdab34eab40d32e93fea9b8c9399abdff1c5be40d8f60207984c41ed8b
```

Build and served-copy checksums passed. iVentoy refresh returned success,
the new filename was listed, PXE reported running, and the service was active.

| Final UEFI scenario | Status |
| --- | --- |
| Unencrypted US | Passed: [12 checks](qualification-results/2026-09-26/plain-us.json), harness `bd04954` |
| Encrypted Dutch | Passed: [25 checks](qualification-results/2026-09-26/encrypted-nl.json), harness `bd04954` |
| Encrypted US | Passed: [25 checks](qualification-results/2026-09-26/encrypted-us.json), harness `a991a97` |
| Unencrypted Dutch | Passed: [12 checks](qualification-results/2026-09-26/plain-nl.json), harness `bd04954` |
| Older-ISO RPM upgrade and GRUB recovery | Passed: [14 checks](qualification-results/2026-09-26/upgrade-recovery.json), harness `bd04954` |

Every scenario uses disposable serial-identified installation and guard disks,
with outbound guest networking blocked. The guard disk must remain unchanged.
A pass requires installed boot without the ISO, desktop/application checks,
selected locale/timezone/keyboard, enforcing SELinux, and removal of live-only
privileges. Fresh installs must require a sudo password. Fresh encrypted scenarios
also exercise login/keyring recovery. Upgrade/recovery checks must preserve
user Kitty edits, shell preferences and a home-directory marker.

The prior-image baseline is
`/data/pxe/iso/CybexOS-Live-44-20260926T055804Z-dbdd33d6.iso`.
It deliberately uses an installer-only session target. Its explicit legacy
qualification path starts the full desktop only after checking that target
and its marker; fresh candidates retain strict normal-startup requirements.

Physical PXE client boot, Secure Boot, and this laptop's post-upgrade hardware
behavior are outside the QEMU qualification scope.

## Reference workstation

The reference is a Dell XPS 14 DA14260 running Fedora 44 from the ISO/RPM path.
Its runtime is under `/usr/share/cybexos`, without a source-checkout `current`
symlink. It uses encrypted Btrfs and enforcing SELinux; Secure Boot is disabled.
The battery was plugged in and paused at its 75–80% preservation thresholds.

These observations informed the RPM channel, account migrations, hardware
continuation, diagnostics, and charge-limit status changes. The workstation
was inspected but was not upgraded, reconfigured, or rebooted for these tests.

## Other verification

| Check | Result |
| --- | --- |
| Initial local repository suite (historical) | All 17 stages passed, including 1,157 JavaScript tests. The opt-in live Quickshell stage was skipped. Later GTK and harness corrections have focused regression checks and current hosted CI coverage. |
| GitHub checks | Both required Fedora source/image checks passed at runtime/harness head `bd04954`. Checks for the final documentation and evidence commit are attached to [PR #1](https://github.com/DigitalPals/CybexOS/pull/1/checks). |
| Real RPM signing integration | Disposable RPM signed using a signing-subkey-only keyring; independent RPM/repository signatures, metadata binding, and tamper rejection passed. Nothing was installed or published. |
| Generic Fedora 44 VM at `86f185f` | First convergence: 135 changes. Second convergence: zero changes (`ok 220`). Uninstall: 22 changes; adopted files restored and project state removed. |
| Ephemeral PXE runner service | Actual transient user-service startup and cleanup passed. No GitHub runner was registered. |
| Reference workstation shell | Final guard passed its start/end checks: active managed MainPID 41596 was the sole Quickshell process, with a clean current-invocation journal. |
| Harness regressions | Sequential Quickshell IPC clients, unknown/persistent extras, localized console prompts, browser preflight, and bounded redacted audit failures passed focused tests. |
| GTK provisioning at `a991a97` | 26 focused tests passed, including real Ansible offline skipping and inherited-descriptor regressions. The actual task also passed against installed gsettings/dconf in private HOME/XDG directories and a private dconf profile: first run applied dark defaults, second made no changes, and explicit light/custom-theme choices survived. Temporary files and private processes were removed; workstation settings were untouched. |

The generic VM predates later archive, installer and harness corrections;
it does not substitute for final ISO qualification. Its 1.2 GiB staging was
removed.

## Findings and qualification corrections

- Source archives omitted the bundled agent skill. The archive and an
  extracted-tree packaging regression now include it.
- Anaconda's common-locales shortlist omitted Dutch. The installer now
  enumerates its full API inventory: 180 available locales across 85 languages.
- Offline provisioning assumed `/var/lib/systemd/linger` existed. It now
  creates the root-owned directory before the account marker; a real Ansible
  regression covers a missing parent and a second idempotent run.
- A controlled backend lock reproduced the visible initialization-busy error.
  The browser driver retries only that initial state through the UI, within
  the original deadline and before any disk action. Other failures stop.
- Console bootstrapping now distinguishes echoed commands from output,
  confirms Bash before Bash-specific setup, and recognizes the observed Dutch
  sudo OCR error only with the sudo prefix and disposable account name.
- Welcome can start another Quickshell IPC client while the audit waits for
  an earlier one. The guard now rescans and inspects every observed extra PID,
  with a bound and the same final sole-managed-PID requirement. The historical
  extra PID from the failed US run could not be classified retrospectively.
- Missing browser dependencies now fail before a VM/output directory is
  created. Installed-audit failures retain bounded, password-redacted details
  without echoing whole Python heredocs over the useful traceback.
- The US installed audit reported `Installed timezone differs` even though
  Anaconda had selected UTC correctly. This Fedora workstation uses hardlinks
  for `UTC` and `Etc/UTC`; the audit now compares file identity rather than
  resolved path names. A generated-code regression covers hardlink and symlink
  aliases and rejects a different zone.
- Recovery verification now requires the exact requested snapshot ID, matching
  the snapshot tool's `recoveryBoot` string. Its regression uses the actual
  index producer. The user-preference fixture also handles an omitted bar
  position as the desktop's effective `top` default.
- Recovery uses an in-memory root overlay, whose encryption ancestry cannot be
  verified by normal login policy. The real older-ISO run upgraded successfully
  and preserved user choices, then its harness incorrectly expected autologin
  on recovery boot. Recovery qualification now unlocks the encrypted disk,
  waits for the SDDM greeter, signs in with the fixture password, and requires a
  working desktop before restore. Session readiness precedes VT discovery,
  because SSH can become available before SDDM has created a login session.
- A later recovery run verified the exact snapshot and completed its restore
  command, then SSH disconnected during poweroff. The harness failed before
  waiting for QEMU to exit. Shutdown now accepts SSH exit 255 only after a
  guest marker confirms successful preparation and QEMU exits with status 0
  within the existing deadline. Sync, temporary-access cleanup, authentication,
  timeout and abnormal-exit failures remain fatal.
- An earlier encrypted-US run timed out waiting for SSH after its first cold
  reboot. The retained logs did not establish a cause. Readiness failures now
  record bounded, password-redacted SSH and screen diagnostics and remove the
  temporary screenshot. A standalone retry passed all 25 checks,
  including SSH readiness and keyring recovery after that cold reboot.
- A replacement test launch failed before boot because its QMP socket path
  exceeded Linux's Unix-socket pathname limit; normal nested release-runner
  paths could do the same. The harness now allocates a short private socket
  directory, records its actual location in `vm.json`, and removes it after
  confirmed guest exit. Real socket-bind regressions cover long output paths,
  repeated boots, retained diagnostic logs, and startup failures. The ISO
  payload is unaffected.

Modified diagnostic guests and superseded images cannot count as final proof.
Their useful findings are recorded here instead of retaining large artifacts.

A later baseline run established a runtime provisioning defect: the GTK-default
task used `dbus-run-session -- gsettings` inside Bash command substitution.
An activated `gvfsd-fuse` inherited the output pipe, keeping Bash and offline
Ansible provisioning blocked after the settings command returned. The guest's
pipe holders were verified before terminating that one daemon to continue
diagnosis. That modified guest is excluded from final qualification. The first
`a1713ff` candidate had passed four fresh scenarios but packaged the same
defective task; it was superseded by the candidate above, which passed a new
complete qualification matrix. The fix skips GTK bus initialization
offline, leaving appearance defaults to the first desktop session. Live
provisioning uses a bounded private bus and separate regular-file captures for
each call, so a surviving service cannot hold Ansible's pipes open or corrupt
the next settings read. The modified diagnostic guest subsequently completed
the RPM upgrade, exact recovery boot and restore, baseline-version check, and
user-choice preservation; it remains excluded from final qualification.

## Release configuration and limits

The signed repository destination, public key, protected branch checks,
immutable-release setting, Pages configuration, signing environment, and
baseline variable were independently verified through the GitHub API. No
repository runners are registered. Signing runs on a separate hosted Fedora
container; the PXE runner receives no private signing key. See
[the release guide](../docs/iso-releases.md) for on-demand runners and gates.

No production desktop RPM or public repository metadata has been published.
Project code is MIT; bundled third-party software and artwork retain their own
terms. Their redistribution/provenance review remains a public-release gate.

This private qualification build explicitly includes the pinned stable channel
with its repository enabled. Because Pages has no metadata yet, ordinary DNF
operations on an installation of this candidate can fail on that repository.
For private testing before publication, disable only this repository:

```bash
sudo sed -i 's/^enabled=1$/enabled=0/' /etc/yum.repos.d/cybexos-desktop.repo
```

This preserves signature checks and the pinned key. After publication, verified
channel enrollment re-enables it. `cybex update-channel status` checks local
configuration, not remote availability. Ordinary builds without
`--update-channel` ship a disabled desktop channel.

The protected primary signing keyring is retained locally at
`/home/john/.local/state/cybexos/release-signing/DigitalPals-CybexOS`
(76 KiB, owner-only directory). Only its signing subkey was uploaded to the
GitHub environment secret. The public fingerprint is
`16C60642B7278AECE3A933C354220839FDF7099E`.

## Cleanup

All task build/cache/dependency staging (29 GiB), disposable VM disks, logs,
screenshots, temporary harness worktrees, and QMP socket directories were
removed after the five scenarios finished. The superseded task ISOs
`CybexOS-Live-44-20260926T114433Z-a107c90a.iso` and
`CybexOS-Live-44-20260926T123305Z-901ef7db.iso`, their checksums, and old RPM
directories `/data/cybexos-candidate-rpm-20260926` and
`/data/cybexos-candidate-rpm-20260926-a1713ff` were removed. Superseded local
results and diagnostic traces were removed after recording their findings.

The final retained artifacts and signing keyring are listed above. The original
baseline ISO/checksum, Alpine ISO, unrelated remote checkout, and pre-existing
remote image outputs were preserved. The local image-output directory is
absent. Final process, mount, temporary-directory and worktree checks found no
task leftovers; directory inventory and disk usage were verified.

After removing the last superseded ISO, iVentoy refresh returned
`result: success`. PXE reported `running`, `iventoy.service` was `active`, and
the image tree contained exactly the qualified candidate, original baseline,
and Alpine. The removed image was absent. Candidate ISO, baseline ISO, and
matching RPM checksum verification all passed again. No service restart was
needed.
