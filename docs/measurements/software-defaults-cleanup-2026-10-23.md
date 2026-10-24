# Software, default applications and cleanup: development checks

These checks ran on 2026-10-23 in a disposable Nix 2.35.4 Podman environment
on the Debian development host. They are development evidence, not release or
physical hardware qualification. The running workstation was not deployed,
reconfigured or rebooted. No ISO was built or published.

- `tests/run`: 450 Python discovery tests, 1,344 JavaScript tests passed, 19
  JavaScript tests skipped; the remaining helper, ownership, theme, plugin and
  model-usage checks also passed. After the final status/recovery refinements,
  the focused lifecycle, Software, default-app and maintenance run passed 89
  tests, including 12 cleanup cases.
- `tests/qml-lint`: 363 product files and four test harnesses passed, with only
  the existing Qt/Quickshell type warnings.
- `nix flake check --no-build`: all declared derivations, product/hardware
  configurations and templates evaluated. The desktop and updater packages
  built with their install checks. The final `checks.lifecycle` rebuild passed
  all 454 discovery tests and its additional integration helpers.
  `checks.parity` passed the shared installation contract without building an ISO.
- Real Nix evaluation indexed the machine's effective locked package set,
  including nested package sets while skipping throwing Nixpkgs attributes.
  Selected-package inventory correctly distinguished Software ownership from
  the same package also declared elsewhere.
- Default-app tests used real GIO, desktop-entry registration and
  `xdg-terminal-exec` in disposable XDG directories, with capture applications.
  Browser/private/web-app routing, terminal arguments, terminal editors with
  file URIs, external MIME choices, missing applications and unrelated MIME
  preservation passed. They do not qualify real browser or terminal rendering.
- The actual Quickshell engine rendered Software, Applications and Storage
  offscreen using fixture backend snapshots. This was not a live desktop test.
  Background-request errors, concurrent selection edits and cleanup-policy
  draft baselines also have executable regression coverage. The final focused
  Settings/UI run passed 40 tests and the Dutch translation catalogue check
  passed. Abrupt worker exits release the cleanup UI and expose the durable
  recovery journal; automatic and boot-recovery workers are distinguished.
- `tests/nixos-native` passed real Nix root registration, system-profile
  generation deletion, stale-review rejection, shared-root/pin preservation
  and garbage collection in a private store. Saved personal edits and records
  survived. Bootloader and health commands in that test are fixtures.
- `checks.vm` passed in a booted NixOS VM under TCG (536 seconds). The real
  authenticated request/supervised worker path staged `hello`, built its system,
  ran the desktop checker and closure diff, and produced a reviewable preview.
  The candidate contained `hello`; the working declarations, personal sentinel
  and locks stayed unchanged. A second real preview staged an opt-in cleanup
  policy and preserved those same files. An unprivileged account could observe
  both requests through completion. This exercised staging and review, without
  applying either candidate. The final declaration-status, stopped-worker and
  draft-discard refinements followed that VM source snapshot and passed the
  relevant checks above; they were not rerun in the VM.

Full package apply/trial-boot/confirmation/removal/rollback qualification and
cleanup across an interrupted real bootloader operation remain required on the
release source identity. Secure Boot, hardware and actual weekly timer/recovery
behavior are not qualified by these checks. These original checks used an
off-by-default cleanup policy; the subsequent default change is recorded below.

Disposable containers, stores, VM disks, logs and screenshots are removed after
recording the results. Source tests and this record remain in the repository.

## Follow-up: weekly cleanup enabled by default

At the user's request, fresh installations now enable weekly cleanup in the
shared NixOS module, personal template and Settings defaults. Retention remains
five confirmed deployments and 30 days; explicit personal opt-outs are retained.

- The 12 focused maintenance tests and three Settings state tests passed.
  Automatic cleanup now has coverage with the enabled default, an explicit
  opt-out, an occupied operation lock, unresolved recovery, an unhealthy system
  and an unconfirmed first boot.
- `tests/nixos-native` passed automatic cleanup using the default policy in a
  private real Nix store. Pins, shared roots, retained profile generations and
  personal edits survived. Bootloader and health commands remain fixtures.
- QML lint passed 363 product files and four harnesses, with the same existing
  warnings. The expanded ISO/installed-system parity check passed the enabled
  policy, weekly schedule and disabled generic Nix automatic GC.
- The booted NixOS VM read the enabled five-deployment/30-day policy from its
  installed system, found the weekly timer active and manually invoked its
  worker. The worker skipped its unconfirmed initial boot as intended.
  Its source NAR was `sha256-yzd3bnD8giRjw/69DIdPAOHKpop09p26UiZLUJek+lI=`;
  all five product default files matched the final working tree. Later changes
  expanded parity assertions and documentation, without changing those defaults.
- The complete VM staged-updater check passed in 532 seconds. A real supervised
  request built a cleanup opt-out with increased retention. The candidate policy
  disabled automatic cleanup while the active policy stayed enabled. The working
  policy, personal sentinel and locks retained their original checksums. The
  package preview also passed. Neither preview was applied.

These follow-up checks do not exercise a scheduled weekly firing or an
interrupted real bootloader cleanup. Those and physical qualification remain
separate launch requirements.
