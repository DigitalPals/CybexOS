# Update flow implementation and validation, 2026-10-26

The implementation replaces the update presentation and request/state
integration while retaining the staged NixOS deployment, authentication,
release verification, personal-input protection and recovery engine.
The preceding [audit](update-system-audit-2026-10-26.md) describes the original
failures; it is a historical investigation, not evidence for the new behavior.

Changes were developed on the Debian `thebeast` host from repository base
`3c2db021ce25505200686daed4ad270787063461`, in the working tree. The implementation
validation below used `1.0.0-beta.4`, before the later request for a testing
ISO. The subsequent [beta.5 build record](testing-iso-beta5-2026-10-26.md)
documents the frozen image, additional checks and PXE delivery. No workstation
configuration was changed, host rebooted, or public release published. These
changes have not been deployed to the user's affected installation.

## Resulting behavior

- The menubar contains one icon only for confirmed available updates. Source
  counts, empty badges, failure icons and completed-update icons are removed.
- Menubar and Control Center open the same review. Control Center no longer
  stages a combined update behind its button. Its checked-time property is
  accessed correctly. Pending changes and errors remain reachable there.
- Available sources are selectable. An unavailable vendor channel does not
  force a combined update or prevent a confirmed upstream-only update.
- One primary action progresses from preparation to reviewed installation.
  Preparation builds/checks without activation. The exact built software
  manifests supply names and before/after versions; additions, removals,
  same-version rebuilds and multiple installed versions are represented.
  The package review contributes to the review token. The full closure diff,
  logs and recovery tools are under system details.
- New edits/current-system changes invalidate an apply review; no personal
  change is overwritten. A preview can be explicitly discarded without
  deleting transaction evidence or changing a pending generation.
- Each update operation has a private payload, public durable request ID and
  UUID systemd worker. Preflight failures survive subsequent status polls and
  shell reloads. Failed starts and cancelled authorization have visible errors.
  Dead preparation workers become interrupted in the same boot; interrupted
  activation/recovery requires restoration. Unknown worker liveness blocks
  duplicate requests. State reads do not modify privileged deployment state.
- New transactions clear old notes/review/recovery fields. Discovery is bound
  to the exact machine lock read and invalidated when the installed lock changes.
  An old in-flight status read cannot erase a newly accepted request.
- Restart-before-trial and confirmation-after-login are distinct actions.
  Settings and Assistant changes open the shared review before application.
- Canonical `DigitalPals/CybexOS` release locks pass validation; incorrect
  original or locked publisher/repository identities remain rejected.
  Invalid machine locks return structured unavailable discovery.
- Diagnostic bundles and the installation qualification script follow the new
  worker units. Dutch catalog entries match the changed interface.

## Executed validation

| Check | What it establishes |
| --- | --- |
| `nix develop -c tests/run` | Complete supported source/fixture suite passes: 643 NixOS unit tests, additional Python/helper suites, and 1,452 passed / 16 skipped Node tests (zero failures). Includes lifecycle, requests, manifests, input ownership, diagnostics, desktop behavior helpers and translations. |
| `nix develop -c tests/qml-lint` | 423 production QML files and four existing harnesses pass. Eight existing warnings remain in unrelated components. The native image module builds and passes CTest as part of this command. |
| `nix develop -c python3 -B tests/update-flow.py` | Real packaged Quickshell under private headless Sway, loading a private copy of the full production shell. A scripted `cybex` boundary supplies discovery/request/status responses; no system update is performed by this UI test. |
| Updater package build | The actual updater/desktop packages build and the updater's installation/dispatch check passes. |
| `checks.x86_64-linux.parity` | Shared ISO-payload/installed-system contract evaluation, now including the update worker configuration. This is not an ISO boot test. |
| `checks.x86_64-linux.vm.driver` | Actual booted NixOS, packaged CLI/authenticated request boundary, systemd workers, real Nix archive/build, candidate desktop check, manifest comparison and durable status. Driver runs outside the Nix build daemon, inside an `agent-resource` task. |

The UI regression exercises a real pointer click on the menubar indicator,
Control Center's actual review action, preparation, readable package review,
exact transaction/token application once despite repeated triggers, cancellation
persisting across polling/reopening, worker rejection surviving shell restart,
partial upstream availability, zero/error badge suppression, and the distinct
restart, confirmation and recovery presentations. Boot/confirmation/recovery
responses in this test are scripted; they do not qualify those backend paths.

The NixOS runtime test stages an actual personal software addition and
maintenance policy, verifies a readable added-package record, retains the
machine lock and personal sentinel, rejects applying a candidate after a
personal edit, observes the durable rejection as the unprivileged user,
discards the stale preview, and prepares the edited machine through the new
UUID update worker. The extended VM run completed successfully in 148.55 seconds. It also kills a real preparation worker and requires a
same-boot interrupted/failed-request report with no pending activation and the
personal edit retained.

The test driver needs `QEMU_OPTS=-no-user-config` on this host because its
provider-owned `/etc/qemu/qemu.conf` is unreadable to the test user. Its runtime
and disks use `AGENT_RESOURCE_WORKSPACE`; one early failed launch left a disk
and two sockets in `/run/user/1000/vm-state-machine`. Those exact task-created
objects were removed and absence verified before the managed rerun. This was
a test-host setup failure, preceding any guest update operation.

## Qualification and delivery limits

This task's real NixOS runtime coverage stops at staging, rejection, discard
and preparation interruption. Successful activation/trial reboot/authenticated
login/confirmation/rollback, encrypted fresh installation, actual Polkit GUI
interaction and physical hardware were not requalified here. Existing fixture
coverage of deployment/recovery remains source evidence. The updated
`scripts/qualify-installations` retains the full installation lifecycle scenario
for qualifying a release ISO with the exact same source identity.

The audit found both public channel endpoints returning HTTP 404, no public
GitHub releases, and an empty publisher trust-key set. Fixing the desktop cannot
supply a publisher's real signing identity or publish an authenticated release.
No trust bypass, invented key, moving-branch fallback or unauthorized release
was introduced. Vendor delivery still needs the release operator's provisioned
public keys and qualified signed metadata/artifacts. Independent NixOS updates
can be selected when their source check succeeds. Flatpak and firmware retain
their separate existing update paths.

All task-managed runtime resources and intermediate logs/screenshots/disks are
disposable and removed after their checks. Build products remain in Nix's
normal content-addressed store. The retained review deliverables are this
record, the original audit, updated documentation, implementation and tests.
