# ISO lifecycle qualification, 26 September 2026

Status: implementation, source checks and generic Fedora VM checks passed.
Graphical installation, RPM upgrade and recovery qualification is still in
progress. This report does not qualify a public release.

## Candidate and evidence

The candidate was built from clean source
`a1713ff0a45f6c7ddabfd67afb6edbf4b6d5ee1a` (`source_dirty=false`). Its source
archive SHA-256 is
`4fcf4af109fd6d4afd0213da7ab508aeb2e38db941eae9ec84c69b5c61ab2f5a`.
Later commits correct qualification tooling only; they do not change this
ISO's runtime payload. Each final report records its harness revision.

Artifacts on `john@10.10.0.7`:

| Artifact | Path | Bytes |
| --- | --- | ---: |
| Private testing ISO | `/data/pxe/iso/CybexOS-Live-44-20260926T123305Z-901ef7db.iso` | 7,633,059,840 |
| Matching unsigned testing RPM | `/data/cybexos-candidate-rpm-20260926-a1713ff/cybexos-desktop-0.0.0~dev-1.20260926123305.ga1713ff0a45f.fc44.x86_64.rpm` | 1,720,396,312 |

Each has an adjacent SHA-256 sidecar. Digests:

```text
ISO  dfc118250a2bf40e8c765332ad1d94f22e6ae861d3d0642fe028d6fd8ec6e975
RPM  5b006d8d627ed80396d9bcdc3ec50e44b872a3a00686577291e56231bdd87cb8
```

Build and served-copy checksums passed. iVentoy refresh returned success,
the new filename was listed, PXE reported running, and the service was active.

| Final UEFI scenario | Status |
| --- | --- |
| Unencrypted US | Rerun running after shell-audit correction |
| Encrypted Dutch | Rerun pending after console OCR correction |
| Encrypted US | Installed boot reached; audit failure under investigation |
| Unencrypted Dutch | Pending |
| Older-ISO RPM upgrade and GRUB recovery | Diagnostic rerun running |

Every scenario uses disposable serial-identified installation and guard disks,
with outbound guest networking blocked. The guard disk must remain unchanged.
A pass requires installed boot without the ISO, desktop/application checks,
selected locale/timezone/keyboard, enforcing SELinux, and removal of live-only
privileges. Fresh installs must require a sudo password. Encrypted scenarios
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
| Local repository suite | All 17 stages passed, including 1,157 JavaScript tests. The opt-in live Quickshell stage was skipped. |
| GitHub checks | Both required Fedora source/image checks passed through `37dbdad`; final-head results pending. |
| Real RPM signing integration | Disposable RPM signed using a signing-subkey-only keyring; independent RPM/repository signatures, metadata binding, and tamper rejection passed. Nothing was installed or published. |
| Generic Fedora 44 VM at `86f185f` | First convergence: 135 changes. Second convergence: zero changes (`ok 220`). Uninstall: 22 changes; adopted files restored and project state removed. |
| Ephemeral PXE runner service | Actual transient user-service startup and cleanup passed. No GitHub runner was registered. |
| Reference workstation shell | Updated guard passed its start/end checks: active managed MainPID 41596 was the sole Quickshell process, with a clean current-invocation journal. |
| Harness regressions | Sequential Quickshell IPC clients, unknown/persistent extras, localized console prompts, browser preflight, and bounded redacted audit failures passed focused tests. |

The generic VM predates later archive, installer and harness corrections;
it does not substitute for final ISO qualification. Its 1.2 GiB staging was
removed.

## Findings resolved during qualification

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
  created. Installed-audit failures retain bounded, password-redacted details.

Modified diagnostic guests and superseded images cannot count as final proof.
Their useful findings are recorded here instead of retaining large artifacts.

## Release configuration and limits

The signed repository destination, public key, protected branch checks,
immutable-release setting, Pages configuration, signing environment, and
baseline variable are configured. Signing runs on a separate hosted Fedora
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

Final cleanup and retained-artifact inventory are pending qualification.
Pre-existing baseline and Alpine PXE images must remain intact.
