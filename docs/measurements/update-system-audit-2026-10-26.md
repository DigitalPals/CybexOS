# Software update audit, 2026-10-26

Recommendation: replace the update UI and refactor its command/state integration.
Repair the shared backend defects and complete release delivery. Retain the
staged NixOS deployment, authentication, personal-configuration protection and
recovery engine. A cosmetic cleanup cannot resolve the confirmed failures; a
complete replacement of the deployment engine is not justified by this audit.

The intended experience is one update indicator when an update is confirmed,
one shared review screen from the menubar and Control Center, and one primary
action at a time. Users must see what will change before activation. Source
errors, a completed deployment and a request for boot confirmation must have
their own meanings rather than masquerading as available updates.

## Scope and evidence

Audited revision: `eec5d96bd7506665624113d6cd330f458bbc765d`.
The audited update files were unchanged during the investigation. Unrelated
concurrent edits elsewhere in the checkout were left alone.

Work included both native update entry points, panel routing, the shared QML
client, CLI authentication/request boundaries, supervised workers, discovery,
input validation, build/review/apply, boot confirmation, recovery, native
software inventory and the existing validation records. The `web/` desktop
prototype is not the installed Quickshell update path.

This was an investigation on the Debian development server, not a live test
on the affected installed desktop. No workstation configuration, deployment,
boot selection or running desktop service was changed. No ISO was built and
no release was published. Findings below distinguish executed reproductions
from conclusions drawn from the source. They do not qualify an installation,
real update, authenticated desktop interaction or physical hardware.

The user subsequently identified the affected installation as the "latest
version" and reported that clicking Update produces no visible response at
all, rather than an authentication prompt or an error. An exact installed
version/revision and device identity were not supplied. This reported symptom
is consistent with the disconnected review flow and invisible request failures
in findings 2 and 5; it does not establish which dispatch, authentication or
worker path failed on that device.

## Current paths

| Entry point or operation | Current behavior |
| --- | --- |
| Menubar update chip | Opens the dedicated `UpdatesPopover.qml` through `PanelRegistryData.js`. It does **not** currently route to Control Center Overview. |
| Control Center Update | Calls `Updates.run()`, which calls `stage("both")`. It neither opens the review panel nor applies a generation. |
| Dedicated Updates panel | Exposes three preview scopes, raw source states, release notes, a built closure diff, a separate apply button, checking, history, rollback, confirmation, logs and firmware. |
| Check | Unprivileged `cybex update check`: validates the machine lock, looks up the Nixpkgs revision, then authenticates vendor channel/release metadata. |
| Stage | Authenticated `cybex update stage SCOPE`: starts a systemd worker, snapshots personal configuration, updates selected inputs, builds and checks a candidate, then publishes `ready` and a review token. |
| Apply | Authenticated `cybex update apply ID TOKEN`: applies that reviewed candidate, validates health and prepares a trial boot. It does not reboot automatically. |
| Confirm | After the actual candidate boot and desktop login, `cybex update confirm` checks health and commits the boot default. |
| Software, region and maintenance changes | Also use the deployment engine and global deployment status. Software and maintenance use request identifiers; direct update operations do not have the same request tracking. |

Sources: [panel registry](../../desktop/quickshell/Common/PanelRegistryData.js#L45),
[Control Center row](../../desktop/quickshell/Popovers/Drawer/DrawerOverview.qml#L247),
[QML client](../../desktop/quickshell/Common/Updates.qml#L41),
[CLI](../../lifecycle/cybexos/cli.py#L144),
[workers](../../nix/modules/lifecycle.nix#L3), and
[deployment engine](../../lifecycle/cybexos/engine.py#L204).

The stale comments about an Updates deep link in `DrawerPopover.qml` do not
describe the current registry. The dedicated route is intentional and has a
passing source test. The actual disconnect is the Overview button's action.

## Confirmed findings

### 1. Correct release repository identities are rejected

**Priority: blocking backend defect. Executed with the production validator.**

`inputs.validate_machine()` requires the vendor input's repository to equal
`"Cybex OS"`. The actual repository, machine template, authenticated source URL
and staging substitution all use `DigitalPals/CybexOS`.

The existing lifecycle fixture repeats the incorrect repository name in both
`original` and `locked`. Its lock passes validation. Changing only those two
repository fields to the canonical `CybexOS` makes the same lock fail:

```text
Cybex OS must be pinned to an exact release revision and content identity
```

Calling the production `Engine.check()` with that canonical lock raises before
any runner/network call. Validation occurs outside its independent-source
error handling. This prevents discovery for an otherwise conforming
GitHub-source installation and affects staging too. The fresh installer also
uses this validator. Development `path:` sources take a different validation
branch, so prior development-image tests do not establish that the release
GitHub-source path works.

Fix the repository identity and add positive canonical-lock coverage plus
negative owner/repository, revision, NAR and moving-reference cases. Generate
or obtain a real Nix lock in installed qualification rather than trusting only
a hand-written fixture.

Sources: [validator](../../lifecycle/cybexos/inputs.py#L17),
[fixture](../../tests/nixos/test_lifecycle.py#L32),
[machine template](../../templates/machine/flake.nix#L6), and
[installer validation](../../installer/cybexos-install#L653).

### 2. The Control Center button starts the wrong user journey

**Priority: high. Executed production JavaScript methods; checked UI wiring.**

The button labelled `Update` issues exactly:

```text
cybex update stage both
```

It starts preparation, not installation. When preparation succeeds, the
Overview has no built-change list or apply action. The user must independently
find the dedicated Updates panel or another applicable review surface.

Worse, `both` always authenticates the vendor channel. With upstream updates
available and vendor discovery unavailable, this route fails although an
upstream-only preview can succeed. Existing test
`test_channel_unavailable_does_not_block_upstream` explicitly proves that
distinction at the fixture command boundary; the Overview does not use it.

Both entry points should open the same review flow. Select the scope from
explicitly reviewed, successfully discovered sources. Never silently retry a
failed combined deployment as an upstream-only deployment: that changes what
the user selected and needs an explicit revised review.

Sources: [button](../../desktop/quickshell/Popovers/Drawer/DrawerOverview.qml#L327),
[run method](../../desktop/quickshell/Common/Updates.qml#L43),
[stage authentication](../../lifecycle/cybexos/engine.py#L224), and
[scope regression](../../tests/nixos/test_lifecycle.py#L528).

### 3. Public vendor update delivery is not operational

**Priority: blocking delivery prerequisite, separate from the UI defects.**

Read-only public HTTPS checks during this audit returned:

| Endpoint | Result |
| --- | --- |
| `https://digitalpals.github.io/CybexOS/channels/beta.json` | HTTP 404 |
| `https://digitalpals.github.io/CybexOS/channels/stable.json` | HTTP 404 |
| `https://api.github.com/repos/DigitalPals/CybexOS/releases?per_page=3` | HTTP 200, empty release list |

The repository's `release/keys/trust.json` also contains `"keys": {}`. Machine
configuration can override trust, so this is not a claim about the affected
device's private configuration. It does mean the default source cannot
authenticate a production vendor update even if an endpoint becomes reachable.

These are documented prerequisites, not something a redesigned button can
repair. Provision real publisher trust and qualified immutable releases through
the existing release process. Do not substitute a development key, skip
verification or update from `main`. Upstream-only updates must remain
independent of vendor delivery.

Sources: [trust file](../../release/keys/trust.json),
[delivery contract](../releasing.md#L1), and
[current qualification limits](../validation.md#L1).

### 4. The menubar indicator does not mean “an update is available”

**Priority: high. Executed the current visibility expression.**

`Bar.autoRule("updates")` includes any error, any non-idle run state and a reboot
recommendation. Results with zero confirmed source updates:

| State | Current menubar result |
| --- | --- |
| Vendor channel error, idle deployment | Visible |
| Completed deployment (`done`) | Visible indefinitely while that status remains |
| Ready local candidate, no source differences or errors | Hidden |

The number is a count of source groups: at most one for Nixpkgs and one for
Cybex OS. It is not a count of packages or applications. A vendor-only error
can produce a red chip labelled `0`, because the alert includes vendor errors
but the label's `!` branch only checks the upstream error.

The earlier installed-image evidence also records an update alert caused by an
unavailable development vendor channel. That is consistent with this source,
but was not re-exercised in a desktop session during this audit.

Sources: [visibility](../../desktop/quickshell/Bar/Bar.qml#L234),
[chip labels](../../desktop/quickshell/Bar/Modules/Updates.qml#L38),
[source-group count](../../desktop/quickshell/Common/Updates.qml#L19), and
[prior observation](welcome-onboarding-2026-10-25.md#L135).

### 5. Failed checks and requests can look like nothing happened

**Priority: high. Executed JavaScript state handling and Engine preflight cases.**

There are several separate failure gaps:

- The check process logs stderr but does not publish an error to the view. If
  the command fails without usable stdout, it retains empty or old discovery
  data. The initial empty state says `No updates reported`, although no check
  has succeeded. The canonical-lock failure in finding 1 reaches this path.
- The request process puts raw stderr, potentially a JSON error envelope, into
  `deployment.error`. The next two-second status poll replaces the entire
  deployment object. Executing those assignments shows the request error
  disappearing when the durable status has no corresponding error.
- The client does not validate the request exit status or accepted response,
  track a request identifier, or handle a failure to start as a durable user
  result. It silently ignores another request while `requester.running`.
- A stage rejected because boot/recovery is pending raises before publishing
  a transaction status. Executing this precondition left status unchanged.
- An apply rejected because personal configuration changed after preview also
  raises before a public transition. Executing it left the deployment `ready`
  with no new error. Its worker journal contains the failure, but this UI
  does not observe that result.

The request boundary starts workers using `systemctl start --no-block`.
`accepted: true` means the job was submitted, not that staging or application
completed. A worker failure is not automatically returned in the request
process's stderr.

Source inspection also shows no direct-update worker-liveness reconciliation
in `cybex update status`. If a worker dies without publishing a terminal state,
the QML client can continue to consider it busy until recovery runs. Boot
recovery handles interrupted states; it is not a same-session request monitor.
Abrupt worker death was not injected in a real systemd deployment here.

Use a persistent request result separate from deployment state, observe process
exit/startup failures, and correlate each accepted request with its actual
worker. Reuse and extend the existing software/maintenance request pattern and
finite-command infrastructure instead of adding another update execution path.

Sources: [QML processes](../../desktop/quickshell/Common/Updates.qml#L54),
[direct requests](../../lifecycle/cybexos/cli.py#L239),
[stage preflight](../../lifecycle/cybexos/engine.py#L204),
[apply preflight](../../lifecycle/cybexos/engine.py#L426),
[request monitoring precedent](../../lifecycle/cybexos/cli.py#L22), and
[finite JSON commands](../../desktop/quickshell/Common/JsonCommand.qml).

### 6. Available-update information is insufficient for the requested review

**Priority: high. Confirmed by the data contract and rendering path.**

Discovery reports a Nixpkgs revision, not application/package changes. The panel
mostly exposes raw source state words and a Cybex OS version. Exact package
changes arrive only after a complete candidate build and compatibility check,
as unstructured `nix store diff-closures` text.

There is no structured review list of application names and old/new versions,
additions/removals, or a separate count of dependency changes. A newer Nixpkgs
revision does not establish that a specific installed application changes.
The current engine must prepare a candidate before it can provide its exact
closure diff. A simpler UI must preserve that distinction rather than imply
that a cheap source check already knows the exact install plan.

There is useful infrastructure to retain: both installed and candidate systems
contain `/etc/cybexos/software.json`, with package paths, names, versions and
ownership. Compare those manifests for the user-facing package list, and keep
the full closure diff as secondary technical detail. Not every environment
package is a graphical application; use desktop metadata where available and
keep system/dependency changes separately expandable. A package rebuilt at the
same version can still change its store identity and must not disappear from
the complete review.

Sources: [discovery](../../lifecycle/cybexos/engine.py#L142),
[candidate diff](../../lifecycle/cybexos/engine.py#L300),
[review rendering](../../desktop/quickshell/Popovers/UpdatesPopover.qml#L37), and
[software manifest](../../nix/modules/software.nix#L27).

### 7. Action gates and deployment state disagree

**Priority: high. Executed current visibility expressions.**

With a stale positive source count, the Overview Update button remains visible
in `ready`, `awaiting-boot`, `awaiting-login` and `recovery-failed`. It is only
gated by `!runActive`, so it keeps dispatching `stage both` when the correct
next step is review, reboot, confirmation or recovery. The backend properly
rejects several of these actions; finding 5 explains why that rejection can
appear inert.

In `ready`, another stage can replace the active review. This is especially
confusing when a Software or configuration preview owns the shared status.
The normal update action must not silently supersede another reviewed or
in-progress system change.

The dedicated panel is more careful about pending boot/recovery, but still
offers all three preview scopes regardless of which source actually has an
update. Recovery history is printed in a terminal, and its unqualified Rollback
button provides no retained-deployment picker. Those are expert tools crowded
into the main update task rather than a coherent normal-user flow.

Sources: [Overview action](../../desktop/quickshell/Popovers/Drawer/DrawerOverview.qml#L327),
[panel controls](../../desktop/quickshell/Popovers/UpdatesPopover.qml#L21),
[shared review](../../desktop/quickshell/Settings/DeploymentReview.qml), and
[rollback selection](../../lifecycle/cybexos/engine.py#L586).

### 8. Old information survives into new transactions

**Priority: medium. Executed the production status publisher.**

`Engine.status()` merges fields into the previous public object. Starting a new
transaction does not clear its previous phase, changes, notes, review token,
recovery or restart text. A reproduction starting with `ready` and then
publishing a new `discovering` transaction retained the old notes, closure diff,
token and recovery text under the new transaction ID. Apply has additional
validation, so this reproduction does not demonstrate an application bypass;
it demonstrates misleading public state.

The QML `projectNotes` property prefers deployment notes over fresh discovery
notes, compounding this. Source discovery is refreshed on its interval, not
in response to deployment completion. Its default interval is an hour, and
opening the Updates panel does not itself call `check()`, despite the IPC
comment suggesting it refreshes stale data.

Start each transaction with a complete fresh schema and publish explicit
transitions. Bind notes, package changes and review identity to the same
candidate. Invalidate/recheck discovery when the installed identity changes,
and refresh stale discovery on opening the review screen.

Sources: [status merge](../../lifecycle/cybexos/engine.py#L119),
[new transaction](../../lifecycle/cybexos/engine.py#L217),
[notes preference and timers](../../desktop/quickshell/Common/Updates.qml#L23), and
[IPC entry](../../desktop/quickshell/shell.qml#L270).

### 9. Other contract and scope gaps contribute to confusion

**Priority: medium. JavaScript reproduction and source review.**

- Overview calls `Updates.checkedLabel()` but this is a string property.
  Executing the call produces `TypeError: Updates.checkedLabel is not a
  function`. This breaks that binding; it is not evidence that the entire
  panel or click handler fails to instantiate.
- `runPercent` is always `-1`; `runElapsed` is elapsed time since the last
  status write, not total transaction duration. Prefer honest phase progress
  and separate timestamps over apparent installation percentages.
- `awaiting-login` shares the generic “reboot when ready” recommendation even
  though that state is reached after a successful trial boot. It needs a
  confirmation/health message rather than another reboot instruction.
- Flatpak is enabled by the system module, but the shared update client and
  lifecycle discovery do not check or install Flatpak updates. The current
  result cannot mean “all software is up to date.” Initially label the scope
  accurately as system updates. A future shared Flatpak presentation requires
  its own explicit update adapter and results; it must not promise that a Nix
  generation rollback also undoes those app/data changes.
- Applications such as T3 Code, ChatGPT and Brave Origin have exact recipes in
  vendor source. Their selected versions can require a vendor release; a
  Nixpkgs-only refresh does not mean every such app advances. Personal inputs
  also deliberately remain under their owners' control.
- Firmware already has a separate fwupd review/confirmation flow. Keep that
  transaction separate and move its launcher out of the primary software
  update action group.

Sources: [Overview time binding](../../desktop/quickshell/Popovers/Drawer/DrawerOverview.qml#L256),
[client properties](../../desktop/quickshell/Common/Updates.qml#L28),
[application module](../../nix/modules/applications.nix#L62),
[vendor recipes](../../nix/packages/t3-code.nix), and
[firmware flow](../../assets/scripts/cybexos-firmware-update#L631).

## Recommended replacement experience

Both the menubar indicator and Control Center's update entry should open the
same review component and observe the same coordinator. The entry point must
not independently start a different update workflow.

| Condition | Menubar | Shared review / Control Center behavior |
| --- | --- | --- |
| Initial or checking | No available-update badge | Explicit checking/unknown state; no install action |
| Successfully checked, no changes | Hidden | Up to date, scope and last successful check; secondary check action |
| Failed check, no confirmed update | Hidden | Identify the source that could not be checked; retry without claiming current or offering Update |
| One or more confirmed updates | One indicator, without the source-group number | Show source/version summary and release notes; open the common review |
| One source available, another failed | One indicator for the confirmed update | Clearly state the partial result; review the available scope explicitly while preserving the other installed input |
| Preparing a candidate | Treat as the already selected update operation, not another available-update count | Visible build/check phases; no activation and no duplicate preparation |
| Exact candidate ready | Reflect a pending selected update if appropriate | Show package/app old → new versions, additions/removals, full details, selected scope and candidate identity; one primary `Update` action |
| Activating | Progress for the selected update, if retained in the bar | Disable duplicate actions; show the actual supervised operation |
| Reboot or boot confirmation required | No new-available-update claim | Persistent pending-system-change state in Control Center and the review; explicit restart or health confirmation as appropriate |
| Completed | Hide after discovery is reconciled unless another update exists | Record success/history and refresh installed/discovery identities |
| Failed/interrupted/recovery pending | Do not turn the error into an available update | Persistent explanation and state-appropriate retry/recovery action |

Preparation and activation must stay distinct. With the present engine, an
exact package review requires building the candidate first. Make preparation
visible and use a plainly named preparation action while no exact plan exists;
replace it with `Update` once the built changes are reviewable. There should be
one primary action for the current step, not Upstream/Cybex OS/Both buttons
alongside a different install action. If preparation is later optimized, retain
the final exact-build review requirement and token binding.

The normal screen should contain readable changes and the installation action.
Keep source selection as a clear reviewed scope, and put detailed input
identities, logs, history and recovery in secondary views. Do not offer
per-package selection as if a NixOS generation were a collection of unrelated
transactions. Changing personal package choices remains the existing Software
configuration workflow.

## Refactor boundary and implementation order

| Approach | Assessment |
| --- | --- |
| Rename buttons and hide some controls | Insufficient: leaves repository validation, forced combined staging, lost errors and request liveness unresolved. |
| Replace presentation and refactor the existing client/request/state contract | Recommended: resolves the observed failures while retaining the installation and lifecycle contract. |
| Replace the full deployment, trust and recovery engine | Unnecessary scope: discards existing protection and recovery work without evidence that a new engine would solve the UI/delivery problems. |

Implement in this order:

1. **Repair backend correctness.** Correct repository validation and fixtures;
   make direct update requests report durable correlated outcomes, including
   rejection before transaction creation and apply preflight failures. Reconcile
   worker death in the same session. Reset transaction-specific public fields.
   Preserve all current authentication, exact-identity, lock-ownership and
   recovery checks.
2. **Replace the QML client contract.** Use the existing finite-command helper
   pattern. Keep discovery, request acceptance/outcome, active deployment and
   persistent recovery separate in the data model. Derive capabilities such
   as prepare/apply/confirm/recover centrally, then let every surface use them.
   An empty result is unknown; a process failure must settle visibly. Keep the
   request's error until acknowledged or successfully retried.
3. **Provide a structured review.** Publish installed/candidate software
   manifest changes alongside the complete closure diff. Bind scope, notes,
   source identities and package changes to the exact ready transaction. Reuse
   the existing review token; personal edits still invalidate application.
4. **Replace both presentations together.** Make the Overview action navigation
   into the shared review. Remove misleading counts, three competing preview
   buttons and automatic `stage both`. Correct the time property access and
   boot-confirmation copy. Account for Software, region and maintenance
   transactions so opening Updates cannot silently replace their review.
5. **Complete vendor delivery separately.** Owner-provisioned trust, immutable
   qualified release artifacts and signed channel promotion are required for
   a successful vendor update. Keep upstream-only operation available when
   vendor delivery is unavailable, subject to explicit scope review.
6. **Qualify the actual integrated path.** Use the existing installer and staged
   updater in isolated installed NixOS guests. Do not substitute source tests,
   a build, direct `nixos-rebuild`, or a mock worker for this evidence.

Primary files are `Common/Updates.qml`, `Common/UpdatesHelpers.js`,
`Bar/Modules/Updates.qml`, `Bar/Bar.qml`, `Settings/ModulesPage.qml`,
`Popovers/UpdatesPopover.qml` and `Popovers/Drawer/DrawerOverview.qml`; backend
work belongs in `lifecycle/cybexos/{cli,engine,inputs}.py` and the corresponding
worker definitions where necessary. Reuse the existing software manifest,
request infrastructure and Settings deployment review rather than maintaining
another independent lifecycle. Revisit stale drawer comments and translated
copy with the replacement.

Retain `Engine`'s configuration snapshots, exact candidate/review binding,
personal-input preservation, supervised activation, health checks, trial boot,
confirmation, failed-system quarantine and resumable restoration. This audit
does not establish that all those paths are production-qualified; they remain
mandatory behavior to preserve and test.

## Validation required before implementation handoff

Regression coverage must establish observable behavior, not just the presence
of method names or matching QML text:

- Canonical GitHub-source locks work; malformed or unauthenticated identities
  are rejected before evaluation. Include the real fresh-installer lock path.
- Initial, successful, partial, offline, malformed-output, timeout and
  failure-to-start checks settle correctly. Only confirmed available updates
  create the available-update indicator.
- Drive both entry points in the actual QML engine: they open the same review,
  preparation shows progress, the exact package list appears, and the final
  Update action applies precisely its reviewed transaction once.
- Exercise authentication cancellation/failure, concurrent requests, rejected
  stage/apply preconditions and worker startup/death. The original request
  result must survive polling, closing/reopening the panel and shell reload.
- A local Software/configuration preview is not superseded or mislabelled as
  discovered software updates. Failed combined previews require an explicit
  new scope and review to retry only upstream.
- The installed source/discovery state is refreshed after apply/confirmation;
  success, reboot and confirmation are distinct. No automatic host reboot.
- Run actual upstream-only, vendor-only and combined staged updates with exact
  source identities, signed local test delivery, unavailable/malicious delivery,
  failed builds, interrupted application, trial boot, confirmation and rollback.
  A development test key belongs only to the isolated test installation and
  cannot satisfy production publisher trust.
- Preserve sentinels for personal packages, inputs, VPNs, services, widgets,
  preferences, skills and persistent data. Test installed ISO/source parity and
  required hardware health. Physical/security qualification remains separate.
- End each live Quickshell test with exactly the user-service-owned shell and
  check its current journal. Use disposable managed test resources and remove
  task-created images, disks, mounts and intermediate outputs.

## Checks actually completed for this audit

The CI controller's `run --help` exposes no CybexOS target, so no CI job or
worker was created. Existing source/fixture suites ran in a supervised
`agent-resource` task with temporary fixture data, without containers or VMs:

| Suite | Result |
| --- | --- |
| `python3 -B -m unittest discover -s tests/nixos -p test_lifecycle.py` | 67 passed |
| `python3 -B -m unittest discover -s tests/nixos -p test_release.py` | 12 passed |
| `python3 -B -m unittest discover -s tests/nixos -p test_software.py` | 5 passed |
| `python3 -B -m unittest discover -s tests/nixos -p test_maintenance.py` | 12 passed |
| Node tests: `update-recovery.test.cjs`, `panel-registry.test.cjs`, `control-panel.test.cjs` with `--test-concurrency=1` | 34 passed |
| **Total existing checks** | **130 passed** |

Additional executed probes used current production JavaScript expressions and
the production Python validator/status publisher/Engine with isolated temporary
configuration and fake command execution. They reproduced the canonical-lock
rejection, zero-update visibility, string-called-as-function error, forced
`stage both`, wrong action visibility in pending states, premature no-updates
summary, erased request error, cross-transaction stale fields and invisible
stage/apply preflight rejections. They did not execute a real build or activation.

The green suites do not contradict these findings. The lifecycle fixture
contains the same incorrect repository identity as the validator. The UI
suites verify routing/recovery expressions but do not drive the complete
Control Center → prepare → review → apply user journey or its asynchronous
request failures. Add that missing behavior coverage as part of the refactor.

All probe temporary directories were automatically removed. The supervised
lease `123e94e3bdba4da0bc1bcb58f4d09497` completed; `agent-resource check`
reported `closed`, no remaining resources, no preserved volumes and no errors.
Its intermediate logs/workspace were disposable. The only retained audit
deliverable is this document. The user reports the latest installed version
and no visible response to Update. No affected installed device was accessed,
so its exact build/revision, device identity, custom trust configuration and
live journal remain unverified.
