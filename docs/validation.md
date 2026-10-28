# Validation status and release blockers

The NixOS implementation is unreleased and incomplete. There is no qualified
production release, authenticated public NixOS channel or completed physical
hardware/security qualification. This record describes development work on
2026-10-22; results on earlier source snapshots do not qualify later edits.

## Evidence boundaries

| Area | Actually exercised | Remaining work |
| --- | --- | --- |
| Source lifecycle and trust | Python command-boundary fixtures; real isolated Ed25519 signing/verification; input ownership, failed evaluation/build and durable recovery cases | Real signed-delivery/updater matrix on installed machines |
| Desktop source | JavaScript source suites, QML lint, ownership/theme/package tests and C++ notification-image tests passed on development snapshots | Repeat required checks on the final source identity |
| Public plugins | Actual Quickshell engine under isolated headless Sway: API 1 replacement, N/N+1/rollback and all six supported Omarchy kinds | Installed Hyprland session, real player/audio/input and third-party dependency coverage |
| System boot | Real isolated NixOS VM boot; installed password/sudo and SDDM login; Hyprland/titlebars and Quickshell rendering; sole managed shell/current journal health; API 1 personal widget using a machine-added executable; candidate namespace/compositor/QML validation | Repeat on the final source identity; suspend, peripherals and physical authentication |
| Fresh ISO installation | Complete unencrypted and encrypted UEFI ISO installations, LUKS unlock, password login and encryption-gated automatic login in disposable QEMU on development snapshots; exact installed source identity checked | Both cases must pass on the final source identity; actual testing corrected filesystem-type, public mount-ancestor permission and Quickshell IPC path bugs |
| Updates and recovery | Actual local stage/build/apply/trial boot/confirmation; injected activation failure and coherent rollback; real initrd root failure and fallback to the previous EFI default; personal hashes preserved; managed-shell crash safe mode and explicit recovery, on development snapshots | Final same-source runs including upstream-only, Cybex OS-only, combined, unavailable/malicious delivery, failed evaluation/build, interrupted staging/application and explicit rollback |
| Cybex OS Assistant | Service suite against scripted Claude Code/Codex protocol fakes and a fake speech-dispatcher; actual Quickshell engine and service under isolated headless Sway with a scripted agent (composer, working pill, command and apply approvals, Undo, widget hand-off, logo-only character, box placement); a real Hyprland 0.56 session in a NixOS VM driven by QEMU's USB tablet (`checks.x86_64-linux.hyprland-pointer`): drags after the hover-opened box and without it, beside a focused window and in quick steps, a click opening the box and clicks reaching a window afterwards, on one 1280×800 display; QML lint; system and product closures built; feature combinations evaluated | Installed Hyprland session: Super+I tap and hold, focus grab, multi-display drag, physical pointer devices, Voxtype push-to-talk, speech-dispatcher replies, grim screen context, polkit apply; real Claude Code and Codex sessions, sign-in errors and resume. The lifecycle VM booted this source and passed its desktop check, then its offline software preview failed: the staged build needs a stdenv the VM does not register, with or without the assistant |
| Hardware | Pinned Intel camera HAL/GStreamer and PSYS packages built; private-ABI parser self-test passed | Actual kernel/private ABI and processed camera frames, both XPS SKUs, NVIDIA, fingerprint/FIDO2, Secure Boot and peripheral/power matrix |
| Release delivery | Publisher-side signature, asset, qualification, sequence and downgrade regression checks | Protected workflow execution, owner keys, immutable publication, public asset verification, Pages promotion and durable custom cache |

Fixtures simulate command boundaries. They are regression coverage and cannot
establish a successful installation, an applied update or recovery from a real
failed boot. A build proves that a derivation builds; it does not prove that the
resulting compositor, camera, authentication or desktop works.

Development diagnostics are not substitutes for the final qualification report.
The handoff records the exact source NAR identity, image checksum, completed
tests and failures; inspect that evidence before using a particular image.

## Implementation and operational blockers

- Signed installation media, safe Secure Boot enrollment and out-of-tree module
  signing remain unfinished. This includes enforcing kernel module trust and
  authenticating the external installation payload; signing a boot executable
  alone is insufficient. Secure Boot installation refuses before erasure;
  disabling firmware verification is not an accepted workaround.
- The desktop requires Hyprland 0.56.2 and native titlebars. The stable Nixpkgs
  compositor is older; the narrow compatibility overlay and its dependent native
  libraries and titlebars build. Real native configuration verification accepts
  the product configuration and rejects an invalid declaration. It also exposed
  an upstream verifier/event-loop interaction, now handled without scheduling
  runtime timers during parsing. Installed startup/rendering and runtime health
  passed on a development snapshot; repeat against the final source identity.
- Mandatory access control coverage remains incomplete. AppArmor enablement
  and the exact Chromium namespace exception do not reproduce the prior
  enforcing policy. Qualify enforced native service/application confinement
  and negative access tests, alongside packet-level firewall tests.
- Production publisher trust is deliberately empty. An owner must provision
  real public keys, publish an authenticated exact revision and configure
  protected GitHub environments and immutable Releases. Do not substitute a
  development key or a moving branch.
- T3 Code's native wrapped AppImage builds but remains runtime-unqualified.
  Cisco IKEv1/IPsec uses the maintained Nixpkgs Libreswan plugin rather than the
  archived, vulnerable vpnc plugin. Real gateway authentication/routing/DNS and
  all declared product/hardware features still require qualification.
- GRUB boot selection pins exact systems through labelled menu identifiers and
  GRUB's environment block. `nix/tests/boot.nix` boots real GRUB in OVMF from a
  disk installed through `installBootLoader` with an installer-sized ESP. It
  exercises the theme, quiet boot, persistent selection, a one-shot trial, its
  fallback and commit. Physical firmware remains unqualified.
- Type 2 UKI/Lanzaboote entries for Secure Boot keep systemd-boot selection
  support with source regression coverage. Actual UKI trial boots, signing,
  failed-boot recovery and rollback remain unqualified.
- No application-data migration engine ships. Reviewed transaction-root pruning
  and weekly cleanup enabled by default are implemented; real bootloader
  interruption and timer qualification remain outstanding (see the
  [development checks](measurements/software-defaults-cleanup-2026-10-23.md)).
  Persistent state requires backups; retained Nix generations do not
  roll back documents, VPN credentials, plugin data or service databases.
- No durable public Cybex OS binary cache is configured. Public cache hosting,
  explicit cache trust and redistribution review remain release work.
- PXE delivery uses the Beast (`10.10.0.7`), independently of the development
  host. A copied ISO is not advertised as PXE-ready until checksum verification,
  refresh, running service and image-list checks succeed there.

1Password CLI/Polkit integration, connected-account services, the Hermes bridge, encrypted-backup timer,
external-monitor lid handling, Voxtype and the required offline dictation model
have native declarations. Their installed interactions still require testing.

The native Linux ChatGPT derivation builds with strict ELF dependency checks;
its version command and bundled Codex/Node commands ran in the isolated build
container. This does not qualify interactive sign-in, Chromium sandbox startup,
remote control or application use on NixOS. The official upstream distributions
do not include NixOS in their formal preview support list.

The desktop package also checks its actual wrapped Python and GI dependencies
under an empty environment: network/account/calendar/firmware libraries, schemas,
GIO TLS, Pillow, D-Bus and WebSockets. This caught and corrected plain-Python
shadowing and missing typelibs before installation qualification.

## Qualification procedure

Run `nix develop -c tests/run`, `nix develop -c tests/qml-lint` and
`nix develop -c python3 -B tests/user-plugins.py` in an isolated environment,
then evaluate/build the relevant flake checks and ISO. Run desktop engines
sequentially and obey [the Quickshell safeguards](../AGENTS.md).

`scripts/qualify-installations` boots the built ISO and exercises the actual
fresh installer, installed boot/login and local staged updater in disposable
UEFI VMs. Its evidence is intentionally labelled
`isolated-installation-evidence`; it cannot satisfy complete release
qualification. Exercise both `--case plain` and `--case encrypted`, retain source
revision/NAR and image hash, and report a failure as a failure.

Extend real installed-system testing through all independent update scopes,
unavailable and malicious delivery, failed evaluation/build, interrupted
application, trial boot, explicit confirmation and coherent rollback. Keep
sentinels for personal packages, VPNs, services, widget code/placement/preferences,
plugin state and service data, and check them after updates and rollback.
Hardware/security checks require representative physical machines.

Only a complete same-revision `installation-update-and-physical-qualification`
report containing every check required by `release/manage.py` passes the release
gate. See [release operations](releasing.md) for trust and publication. Do not
promote the development evidence in this document to a production-readiness claim.
