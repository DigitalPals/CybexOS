# Settings audit — 2026-10-27

The native Settings application was exercised in a disposable, freshly installed
NixOS VM, including real Hyprland, PipeWire, NetworkManager, GNOME Keyring,
Restic, Polkit and staged system deployments. The audit found and fixed several
working-settings defects. This is VM application testing, not physical hardware
or release qualification. The limitations below remain explicit.

## Method

The VM used the existing `cybexos-1.0.0-beta.10.iso`, a new 80 GiB virtual disk,
UEFI/GRUB, virtio graphics, four CPUs and 12 GiB RAM. It was installed with
password login and an unencrypted disk. Connected widgets were initially absent,
then explicitly enabled in a task-owned personal module for the second test phase.
Secure Boot and the encrypted-disk password branch were not exercised. No
running workstation configuration, served ISO or release was changed.

`tests/settings-runtime.py` inventories all 21 pages and drives the real QML
controls and their production signals. `tests/qml/settings-audit-ipc.fragment`
provides introspection only in a private copy of the desktop inside this VM.
It is never installed in the product shell. Most control cases use these signals,
not pointer clicks on every pixel. Authentication and shortcut capture use actual
QMP keyboard events. Assertions check persisted preferences and native service
state; a successful method call alone does not count as a successful deployment.

The explicit `--only late_credentials` case runs without `--prepare`, immediately
after a fresh boot/login and before other tests initialize Secret Service. It
checks bus ownership without activating the service, waits until 180 seconds of
uptime and verifies an unlocked collection plus real credential storage/readback.

The runtime harness requires root, QEMU DMI, hostname `cybexos-qa`, a
`/run/cybexos-settings-audit` marker and the disposable test account `cybexqa`.
It deliberately changes that account's settings. Example inside that VM:

```sh
python3 -B /mnt/qasource/tests/settings-runtime.py --prepare \
  --suite all --report /mnt/qawork/settings-report.json
```

Prepare injects the test fragment into a private source copy and restarts the
managed `quickshell.service`. The guard checks the authenticated user's `qs` and
`.quickshell-wra` processes against its MainPID. Privileged stage/apply/reboot,
Polkit, password and retention-cleanup scenarios are separate from this generic
command; they require the qualification VM driver in `scripts/qualify-installations`.

Initial harness failures involving singleton scope, unsupported JS `flat()`,
asynchronous display reconnection, conditional controls and absent wallpaper
fixtures were corrected and their cases rerun. They are not product defects.
The immediate keyring check passed with a fresh graphical login without a
concurrent serial login as the same user. A later idle test exposed the startup
timeout described below. PAM policy changes were not needed.

## Page coverage

| Page | Exercised in the installed VM | Limit |
| --- | --- | --- |
| Appearance | All nine built-in themes; light/dark; fonts, scales and density; glass, contrasts, reduced motion; accent/hue bounds; border/corner options; custom theme save/apply; persistence and reset/undo | Visual rendering checked on virtio graphics |
| Wallpaper | Two local image fixtures, picker, rotation choices, shuffle, invalid-folder preservation, wallpaper-palette layout | External online search/download service not qualified |
| Menubar | Position, style, custom height/gap/radius, color, autohide/exclusive/dock; three presets; all 21 built-in module memberships; 66 widget option rows across 17 modules; Control Center tabs, overview sections, ordering/commit/cancel and dimensions | Remote SSH and Fusebox endpoint/credential fields need their own service fixtures; external integrations are not claimed |
| Workspaces | Per-monitor/shared modes, dwindle/scrolling/floating, per-workspace layout, titlebars and persisted native configuration | No physical multi-monitor desktop |
| Notifications | DND, custom quiet-time boundaries, four corners, display duration/density/icons/progress/body/fullscreen/burst/history options, real notification delivery | External application notification diversity not exhaustive |
| Assistant | Agent/model, voice/context/character preference choices and persistence | No signed-in external AI provider; real inference/voice service not qualified |
| Displays | Resolution/scale trials; all rotation/flip/VRR enum choices; keep/revert, timeout and page-exit rollback; second headless output, mirror, disable and arrangement | Physical VRR, EDID/hotplug, HDR and GPU hardware not qualified |
| Sound | Two real PipeWire virtual outputs and a microphone; volume/mute/balance/default output | Advanced Volume Control launch passed; physical speakers, microphone quality and hardware profile changes not qualified |
| Network | Active wired checkpoint keep/revert/discard; inactive profile IPv4/IPv6 manual addresses/gateway/DNS/autoconnect/metering and validation; WireGuard import/activate/disconnect/remove confirmation; simulated kernel Wi-Fi hotspot start/rename/join card/stop | Advanced connection-editor launch passed; physical Wi-Fi, Bluetooth pairing and external VPN peer handshake not qualified |
| Touchpad | Apply/discard/navigation persistence; actual Hyprland tap/natural-scroll/swipe/sensitivity configuration | No physical touchpad or gesture feel |
| Keyboard | Layout addition/reordering, US international and Dutch, switch shortcuts, next-layout action, apply/discard and restoration | VM keyboard only |
| Keyboard shortcuts | 95 actions/100 native binds; remap browser, custom URL shortcut, compositor reload/reset, 478-entry keymap; personal user.lua preserved | Real QMP capture, accept/apply and native reset also passed |
| Power | All idle timeout/battery-only preferences, actual hypridle configuration, stay-awake choices and inhibitors | Real battery discharge, lid behavior, suspend/resume and firmware not qualified |
| Applications | Every installed choice for browser/terminal/editor/PDF/image/video, readback through XDG defaults | Not a general test of the selected applications |
| Storage | All retention draft choices and discard; actual supervised policy stage/review/apply/reboot/effective policy; pin/unpin and reviewed Nix GC | Retention safety also covered by lifecycle fixtures |
| Region | Clock/temperature preferences; installed locale enumeration; timezone effective after staged reboot; stronger personal override refused; language stage preserves category-specific locale preferences | Fresh installer default change checked with generator tests and an explicitly aligned VM fixture; no new ISO installation was claimed |
| Accounts | Missing optional GOA service is an unavailable state, not a broken page; connected-widget installation includes GOA; actual Add account window opens/closes | No external OAuth login or real calendar account removal |
| Security | Missing-reader/key states; real SSH Polkit cancel/enable/disable; real password worker/PAM/keyring round trips; visible native form validation, Polkit, password change/restoration; delayed keyring startup; simulated fprintd enrol/progress/cancel/release | No physical fingerprint reader/FIDO key; encrypted-disk password branch not runtime-qualified here |
| Plugins | Local Git package install, enable/disable, update preview/apply, removal cancel/confirm, retained preferences and reinstall regression | Third-party plugin code not generally qualified |
| Backup | Real encrypted Restic repository, login-keyring credential storage, recovery-key confirmation, automatic toggle, snapshot and restore to a new directory with original preserved | Local fixture destination; remote storage outage/provider behavior not qualified |
| About | Health refresh, reset-all/undo preserving unknown keys, Welcome and Software launch; native account/audio/network/password window launch/close; configuration-file browser handoff | Diagnostic health is not hardware qualification |

The scalar inventory covered 60 direct preference keys, with conditional gap,
bar radius and quiet-time controls rerun after enabling their prerequisites.
Enums use every offered choice; numerical controls use boundaries and an interior
value. This does not claim exhaustive combinations of every preference.

## Defects fixed

1. **Optional accounts service:** a fresh installation without connected widgets
   previously showed a generic backend error. Missing GOA now returns an explicit
   unavailable snapshot and disables Add account. Other D-Bus failures still
   propagate instead of being hidden.
2. **Narrow layout binding loops:** slider/volume track widths depended on their
   own position, and the wallpaper palette used an implicit-size feedback path.
   Independent width calculations and an explicit-width container remove them.
3. **Reduced-motion animation:** switching motion settings could produce a negative
   ripple fade duration. The duration is clamped to zero.
4. **Removed plugin ghosts:** retained plugin preferences were interpreted as a
   broken installed package after removal. Missing disabled packages disappear;
   preferences survive reinstall and missing enabled packages remain diagnosable.
5. **Ignored regional changes:** normal-priority installer timezone/language choices
   overrode the Settings declarations. New fresh installs use `lib.mkDefault`.
   The updater also evaluates the effective regional option and rejects a stronger
   personal declaration without preparing a misleading deployment. No migration
   or personal-module rewrite was introduced.
6. **Empty language picker:** `localectl list-locales` did not enumerate the NixOS
   locale archive. Both UI backend and updater now use `locale -a` and canonicalize
   UTF-8 names. The desktop/updater explicitly include glibc's locale executable;
   the actual systemd worker test caught the otherwise missing dependency.
7. **Fingerprint enrolment startup:** the GLibUnix introspection API exposes
   `signal_add_full`, not `signal_add`. Correcting it restores enrolment and
   cancellation on the real Gio/private-bus fixture.

8. **Hidden external tools:** native account/audio/network tools and the password
   dialog could be tiled behind the floating Settings window. Settings now closes
   before launching those tools, its configuration file, the wallpaper folder or
   external Settings links.
   The VM audit checks both the launch and the dismissal of the covering window.

9. **Login keyring timed out before first use:** PAM started the waiting
   `gnome-keyring-daemon --login`, but the Hyprland session did not complete its
   startup. On a clean staged boot the daemon disappeared within 150 seconds,
   and the next credential request found the login collection locked. Session
   startup now initializes its secrets component before starting the desktop
   target. The desktop package explicitly includes that executable.

## Staged source and build evidence

The vendor input stayed at its original beta.10 source. The test explicitly added
one task-owned `settingsAudit` flake input, following the machine Nixpkgs and
existing Lanzaboote inputs, to override the desktop and updater packages. Other
lock nodes were compared and preserved. This is not an authenticated release
publication or a signed-channel test.

Final tested task source NAR identity:
`sha256-CIDrfJ10F2wGzXwlkuyYiTuh3IaHnq0wb66UfnZtFlg=`.
The snapshot includes all production fixes; later audit-only documentation and
harness refinements do not change those production files.

- Desktop: `/nix/store/rl5c2pfdxrmwjs47pljbjbj202bk1yiv-cybexos-desktop-1.0.0-beta.10`
- Updater: `/nix/store/98vss6cag7ksr0fqv5k32r3i68y40rjg-cybexos-updater-1.0.0-beta.10`
- Shared installer/ISO contract parity check: `/nix/store/xqs77yr7namvns2wf2c0anqhhc6fz3j7-cybexos-shared-installation-contract.json`
- Final package deployment transaction: `88c5039b9c584f6ab38634106c0e2052`
- Stronger timezone override correctly refused: `e24d65c634c34492ab8c2367948ba875`

Application used the real updater's review token, GRUB one-shot trial selection,
password desktop login, desktop-required health and automatic confirmation.
Confirmation cleared the pending deployment and made the trial the boot default.
The first Amsterdam deployment was also checked with `timedatectl`, rather than
assuming the desired JSON represented the effective timezone.

The final source checks and live checks are recorded below.

## Source verification

The final production fixes passed `tests/run` and `tests/qml-lint` in the Nix
development environment:

- 668 NixOS Python tests, all passed.
- 25 system-settings backend tests and five settings-ownership tests, all passed.
- 1,476 Node tests: 1,460 passed, 16 explicitly skipped, zero failures.
- Plugin Git transaction, restoration and source-identity checks passed.
- 23 theme/model tests, native notification image tests, and Model Usage live
  QML lifetime/hotplug/idle/refresh/credential checks passed.
- 432 QML files and four QML test harnesses: no lint errors; eight existing
  warnings (three property-override, three missing-type, two incompatible-type).
- Final desktop/updater derivations and shared installation-contract parity
  derivation built successfully.

The 16 skipped Node cases are not counted as passing runtime cases. A host-only
Python attempt was superseded by the complete Nix-environment run because the
host interpreter lacks application dependencies such as websockets.

## Additional live evidence

- Retention transaction `464afafd8b0b4e63b1f322a8099b096d` applied automatic
  cleanup off, keep-count 10 and keep-days 60; the booted policy matched all three.
- Language transaction `c4b009c6e6b34e2e814dd92e86310f98` applied
  `LANG=nl_NL.UTF-8` while preserving the personal `LC_TIME=en_GB.UTF-8` category.
  The real shell used Dutch (`I18n.language == "nl"`).
- Timezone transaction `b88f279d38f844aa8a1904a115b07768` began through the
  actual Region page's Apply timezone action and real Polkit prompt. After review,
  apply, reboot and confirmation, `timedatectl` reported `Europe/Berlin`.
- Both automatic update policies passed off/on authorization and persisted
  readback. Preparation was restored to off and confirmation to on in the fixture.
- The packaged password worker completed two password changes and two reboots,
  with graphical login and keyring readback after each. The native form separately
  rejected a short password, changed the account through its real Polkit prompt,
  restored the original fixture password, and preserved a stored keyring item.
  Shadow-password verification and the displayed success message were checked.
- The shortcut recorder captured real QMP Super+Alt+B while inhibiting compositor
  shortcuts. Use shortcut and Apply saved it; native reset/apply restored Browser.
- Recovery-point pin/unpin persisted correctly. Reviewed cleanup reported zero
  eligible recovery points under the chosen retention policy, then ran actual Nix
  GC and reported 2,199,212,912 bytes reclaimed. The current deployment remained
  protected. Checksums of the personal flake, local audit module and user-data
  sentinel were unchanged; desktop-required health still passed. Retirement of an
  eligible historical recovery point is covered by fixtures, not claimed as this
  VM's runtime cleanup outcome.
- Clean staged baseline `9bdb8a6eca314b87b677986f955cbf34`
  left the PAM login daemon waiting; it disappeared within 150 seconds without
  credential access and the next request reported a locked collection. The final
  staged fix kept the keyring unlocked through 180 seconds without credential
  access; a subsequent real credential store/read/clear passed.

- Final administration rerun passed all 12 retention draft choices/discard,
  health refresh, reset/undo, Welcome/Software, and visible file/folder/browser,
  account, audio, network and password windows. The browser correctly honored
  the configured JSON MIME handler. A reused Firefox window initially defeated
  the test's new-window assertion; the final clean-boot rerun passed. Closing an
  audio window during initial mapping aborted its startup; a separate ready-state
  test rendered the real mixer and closed it with Ctrl+Q without a Settings error.
- Normal layout and the 480×400 minimum window with the largest text setting
  were visually inspected, including the stacked wallpaper palette and volume
  slider. Scrolling and compact icon navigation remained available.
- The test source was removed from the session configuration and the managed
  service restarted into the exact final desktop store path above. Final
  `quickshell.service` MainPID was 6679 and was the sole user-owned shell PID;
  invocation `593b4ead121048b9aa24306098ac6aab` contained no TypeError,
  ReferenceError, binding-loop or negative-duration messages. The test-source
  invocation had none either. No test application windows remained.
  `cybexos-health desktop-required` passed, the login keyring was unlocked,
  and updater status remained confirmed (`done`).

## Teardown and retained review material

The leased VM was stopped and lease
`59b0ce8831044994a01e68e7f9f67b8f` released. `agent-resource check` reported
`closed`, no remaining resources, no preserved volumes and no errors. The
31 GiB allocated VM workspace and its QMP temporary directory were removed.
The task-owned `/data/tmp/cybexos-settings-audit-20261027` directory (153 MiB),
including all intermediate source snapshots, logs, fixture data and screenshots,
was deleted after recording these findings. The task-created runtime-harness
bytecode was also removed. Existing user image directories were preserved.

Retained repository review material is this report (about 18 KiB),
`tests/settings-runtime.py` (64 KiB), and
`tests/qml/settings-audit-ipc.fragment` (5 KiB), plus the production and regression
changes listed by Git. These let reviewers understand and repeat the VM audit.
No test disk, test ISO, screenshot or temporary service is retained.

The final derivations remain in the ordinary Nix-managed build cache for review:
the desktop above (9.4 MiB), updater above (736 KiB), shared-contract result
above (16 KiB), and frozen source
`/nix/store/wc6l3hlgf647zsplxhxqr02c7b075svl-source` (20 MiB). Nix controls the
cache and its dependencies; no global pruning was performed.
