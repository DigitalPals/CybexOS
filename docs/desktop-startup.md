# Startup investigation and measurement

The tested installed product remains `d2037af92cb3a47a08a9755e5996d2c4b0cae28d`.
Source/image gates, exact artifacts/testing PXE publication, four ISO scenarios, both checkout
parity cases, pristine offline/native/recovery and scoped native tests pass within their separate
scopes. **Actual startup/pixel/performance measurement is BLOCKED:** warm01–04 all failed with
zero startup samples, no comparison and no justified optimization/speed claim. No further VM
series is planned in this task. Hardware, first-frame and generic CSD limits remain;
the product is not fully qualified. This documentation update is separate from
the tested installed-product artifacts.

Reference inspection uses Omarchy `v4.5.0-rc1`, commit
`03ff1eff3812933f7088484533784d2f63eaf19a`, specifically Limine configuration
and its two binfmt overrides. CybexOS retains GRUB, Plymouth, authentication,
encryption, recovery and Docker socket activation. No GRUB/binfmt/portal-grace
optimization has been made.

## Investigation and unchanged policy

Omarchy's one-second Limine value is a menu timeout, not complete boot time.
CybexOS live media's five-second menu does not establish installed GRUB delay.
Installed saved environment, failed-boot behavior, dual-boot detection, menu
access and recovery must be observed before changing policy.

The actual Fedora 44 systemd-binfmt package orders after the mount and automount
without pulling in the mount. Omarchy's eager-mount hypothesis is structurally
relevant, but a container cannot establish this installed system's critical
path or a repeatable benefit. Binfmt remains enabled for tools and emulation.

`hyprland-session-start` publishes the complete session environment and starts
the session target before the one-second portal-restart grace. Quickshell
starts through that target before the sleep. Removing it would not by itself
prove a one-second improvement to the first usable desktop. A socket or active
unit also does not establish file-picker/screen-sharing readiness. The grace
remains until a reliable bounded alternative and fallback are measured with
actual portal consumers.

## Evidence contract

`python3 scripts/startup-evidence.py capture --help` describes the read-only
capture command on an authorized installation. Capture never reboots, stops
services or changes boot configuration. It retains system/user systemd-analyze
time, blame and critical-chain, selected monotonic unit milestones, session
journals, GRUB environment, binfmt unit text, kernel and exact desktop packages.
Failed or unavailable firmware/loader diagnostics remain failures; missing
values are not zeroes. A long unit duration alone does not prove a desktop
critical-path delay.

Desktop-ready requires a rendered bar and a successful launcher interaction
with a responsive compositor. Portal-ready separately requires an exercised
file picker and screen-sharing selection/Start with valid streams and confirmed
session cleanup. Retain boot-relative observer times, protocol results and
reviewed frames. Human/automated authentication, diagnostic/probe scheduling
and deliberate UI delays must be reported with their timing meaning; do not
silently subtract them from a different milestone.

The ordinary comparator needs at least three distinct boots per revision on
the same hardware/configuration, exact kernel/dependencies and genuinely
observed milestones. It rejects repeated boot IDs, missing observations and
mixed dependencies even if labels match. Label cold/warm and first/normal
login separately; first-login seeding cannot stand in for normal login. Exact
source, package, monitor, encryption, power and bootloader state belong in the
evidence. Caller-supplied observations still require retained independent
review; the comparison command cannot prove their truth alone.

## Preserved failed observations

| Run | Observed evidence | Qualification |
| --- | --- | --- |
| Original baseline 3b310d1 probes | Three probes failed inventory capture and retained no usable UI frames. | Failed/unqualified; preserved. |
| Superseded 63f7785 first encrypted login | systemd reported 27.949s: kernel 0.626s, initrd 18.853s, userspace 8.469s; graphical.target at 8.442s of userspace. Authentication, first-login work and console test-access bootstrap were present. The initial bar frame was black; launcher typing rendered a responsive bar. One Escape cleared its query without dismissing it, obscuring the picker. | Diagnostic only; no desktop-ready or normal-login sample. Picker/ScreenCast did not complete. A long ldconfig unit did not prove recurring delay. |
| Historical b4dfdf6 encrypted observer | Inventory and fixed-path root hashes passed, launcher dismissal and normal-shell audit passed. File picker rendered but Escape returned error 2. ScreenCast reached CreateSession=0, then SelectSources remained pending with unconfirmed cleanup. | Failed/unqualified; no readiness sample or UI attestation. |
| Historical 75bc424 encrypted US observer | Inventory/root fixed-path hashes and two-Escape launcher dismissal passed. File picker rendered large. Inspected actions exceeded the 9/10-second deadlines. SelectSources/source-picker pixels rendered, but selection and Session.Close failed and cleanup was not accepted. | Failed/unqualified; partial visible UI is not portal readiness. |
| Exact d2037af controlled attempt `d2037af-warm-01` | Failed during baseline preparation. Two deadline-no-action outcomes, no input sent. File-picker header/Cancel clipped offscreen; SelectSources covered by first-run Welcome. | Failed/unqualified with zero accepted samples; no readiness timings/comparison/speedup. Pixels do not establish a product root cause. Restoration passed; lease closed/empty. |
| Exact d2037af controlled attempt `d2037af-warm-02` | Initial onboarding snapshot failed before reconciliation/Welcome/SSH fixture/warm-up. Root command returned 1; retained diagnostic omits command output by design, raw output unavailable. Exact substep/root cause unknown. | No input/context/measured boot/accepted sample/comparison/readiness timing. Candidate not transferred; source/helpers/bindings unchanged; lease closed/empty. |
| Exact d2037af controlled attempt `d2037af-warm-03` | Initial snapshot failed at `before.root-boot-policy`; bounded stderr proves `ValueError: Invalid or duplicate GRUB environment variable`. Exact offending guest bytes unretained. | No input/context/samples/timing/comparison; no candidate transferred, source/helpers/bindings unchanged, lease closed/empty. Warm02's cause remains unknown. |
| Exact d2037af controlled attempt `d2037af-warm-04` | Initial snapshot including root boot policy, packaged reconciliation and readiness validation passed. Parent's Welcome frame review saw black background/pointer only; dialog unverified, null response produced `explicit-observe` and no input. | Failed `review-action` before SSH fixture/warm-up/measured boots; zero startup samples. Black-frame cause unknown; no product-regression proof. Lease closed/empty; final measurement blocked. |

Pinned backend inspection explains the observer assumptions: Hyprland portal
1.4.1 opens its source picker during SelectSources, rather than only Start;
GTK portal 1.15.3 maps Escape/dialog-close to code 2 and explicit Cancel to code
1. The observed failures do not classify a product portal defect. A corrected
observer must interact at SelectSources within its deadlines, use deliberate
file selection or explicit Cancel, complete successful Start/streams and
confirm Close/cleanup. It cannot relabel timeout, code 2 or missing cleanup as
success. All previous failed evidence remains intact.

The external observer now enforces request/frame context, two-step launcher
dismissal, partial-failure preservation, cleanup gating and no input after
terminal events. Its inert review evidence and historical wrapper findings
are centralized in [desktop validation](desktop-validation.md); they establish
tooling behavior, not portal pixels or actual startup samples.

## Controlled experiment and failed attempts

The original baseline and candidate inventories differ by 82 native SDK
packages. Historical pristine offline-upgrade success does not make those
inventories equivalent for performance comparison. The retained controlled
wrapper specifies preparation with only the exact verified 82-package closure
before baseline observations; the pristine upgrade/recovery gate remains a
separate test.

After 155 phase-1 inert tests, the d2037af startup retarget's fresh independent
R5 review is clean: all three R4 P2s in standalone idle/config validation,
stdout-lock deadline handling and stale standalone-pass handling are closed.
The review passed 195 inert tests and eight help checks, and independently
reproduced the archived failures. `startup-retarget-independent-r5.json` and
the frozen R5 controlled/observer manifest pins are recorded in validation.
These tooling results do not approve subsequent onboarding changes. The completed core aggregate passes all four
ISO scenarios, both checkout cases, pristine offline/native/recovery and
targeted native prerequisites. R27's 234 consistency checks cover completed
evidence excluding English, subsequently verified by the parent. These records
remain separate from readiness qualification.

Actual attempt `startup-controlled-harness/attempt-d2037af-warm-01`, in the
durable evidence mirror defined in validation, failed during baseline
preparation before any accepted sample. Its two
sidecar outcomes are `deadline-no-action`, with null action hashes and no input
sent. The parent recorded offscreen file-picker header/Cancel controls and a
SelectSources picker covered by first-run Welcome. These failed fixture pixels
do not establish a product root cause or portal defect. R5's clean review and
unchanged source/helper/bound inputs retain their separate scope.

Two restoration attempts report restored; `fixture-transport.json` in the
main evidence and failure supplement restores the actual original SSH/firewall
state, including pre-existing active/runtime state. The parent verified lease
`ed16ccc887dc40e8a65e12336f66bae3` closed/check empty. The whole attempt and
failure supplement remain retained. Validation centralizes the bounded record
paths and restoration detail. This failed run supplies no readiness timings,
comparison or speedup. Overall teardown is recorded separately in validation.

Fresh scoped R7 closed R6's missing top-level `json` import and measured
`controlledBootPolicy` preparation binding. Its 237 inert tests include 42 onboarding
tests outside legacy adapters; six adversarial cases were rejected, eight help
checks and 80 Python/four generated-payload compiles passed, and the old NameError
negative control reproduced. All 271 inventoried files were unchanged. Synthetic
fixture failures and adapter exclusions supply no passing coverage. This is
inert tooling review only; exact manifests/report are in validation.

The fresh R7/core/helper-bound warm02 attempt failed at the initial onboarding
snapshot, before reconciliation, Welcome callback, SSH fixture or warm-up.
The root command returned 1. Its retained diagnostic omits command output by
design (`include_output=False`); raw output is unavailable, so the exact snapshot
substep/root cause is unknown. No product root cause is established. The exact
82-dependency fixture and staging cleanup were prepared; candidate payload was
not transferred. No input, sidecar context, measured boot, accepted sample,
comparison or readiness timing resulted. Source/helper/bound inputs were unchanged.
`startup-attempt-warm02-summary.json` records 11 files/2,704,256 bytes, including
four evidence files duplicated in the failure supplement; lease
`cc6a72cf312b44b698b474330909e9da` is closed/check empty. The truthful host-context
record and exact prerequisites are centralized in validation; shared workloads
and launch load are context, not sustained-idle proof. Warm01 remains unchanged.

R8's diagnostic stage-attribution P2 is fixed; fresh R9 is scoped clean with
260 supplied inert tests, 116 independent mocked preparations, eight help checks,
104 Python/five payload compiles. FINAL/`startup-diagnostics-independent-r9.json`
pins the immutable reviewed manifest recorded in validation. This is inert
diagnostic review only; original exceptions and strict guards remain preserved.

Actual warm03 failed at `before.root-boot-policy` during initial onboarding
snapshot, before reconciliation/Welcome/SSH fixture/warm-up. Failed-stage bounded
redacted stderr proves `ValueError: Invalid or duplicate GRUB environment variable`;
exact offending guest bytes were not retained. Outer run omitted-output placeholders
do not contradict the nested captured diagnostic. Dependencies/staging cleanup
passed; no candidate transferred or input/context/measured boot/sample. Source/helper/bound inputs stayed unchanged. FINAL/`startup-attempt-warm03-summary.json`
records 11 files/2,706,700 bytes; lease `4f6364e98aec411cacd3ea673e04f551` closed/check
empty. Its exact attempt is copied under the durable validation root's
`evidence/final-r15-run/startup-controlled-harness/attempt-d2037af-warm-03`;
`startup-warm03-emergency-copy.json` there records it.

FINAL/`grub-environment-format-probe.json` reproduces old-parser rejection of
a standard warning line from Fedora `grub2-tools-minimal-1:2.12-66.fc44.x86_64`.
This is supported-format reproduction, not proof of particular guest bytes.
Warm02's actual cause remains unknown; warm01/02 evidence is unchanged.

R10 found an LF-separator P2 after supported-warning support. Literal LF
boundaries and a terminating-LF guard fixed it; fresh R11 is clean: 283 supplied
inert tests, seven independent methods/19 delimiter variants, four negative-control
methods, eight help/128 Python/five payload compiles. FINAL/
`startup-grub-independent-r11.json` pins current controlled manifest
`e8a7f96eb48a972f912d3e0c61628b3451e5ce83ae11445e0f318e5c69194fe0`.
Strict policy/hash/authentication/comparison guards remain. This is inert review only.

Actual warm04 passed the baseline initial snapshot including `before.root-boot-policy`,
packaged reconciliation and readiness validation. The parent reviewed a Welcome
frame containing black background and pointer only, could not verify a dialog
and explicitly returned null. Its outcome was `explicit-observe`; no input was sent.
The run failed at `review-action` before SSH fixture, warm-up or measured boots.
One Welcome review context, zero portal contexts/startup samples; dependencies/staging cleanup passed, candidate not transferred, source/helpers/bound inputs
unchanged. Black-frame cause is unknown; no product regression is established.

FINAL/`startup-attempt-warm04-summary.json` records 16 files/2,736,770 bytes;
summary SHA-256 `0c5d017a9b3b3d143369680d461dc42968d8f53c001908ec15f1e7128ab2b741`.
The exact directory is `startup-controlled-harness/attempt-d2037af-warm-04`;
its `evidence/onboarding-preparation/welcome-review.png` SHA-256 is
`491f31f9d3c41aed91a5756b818bf8828a2f1c3acd70178be2988aa4485f7907`.
Lease `e9114b0a47bf45418ee25de82abb4804` closed/check empty. Warm02's cause
remains unknown; warm03's exact offending bytes remain unproven. All failed
attempts retain their distinct scope; no later tooling pass converts them to samples.

Startup attempts are stopped. No further VM series is planned in this task.
Actual startup/pixel/performance measurement remains **BLOCKED**. Diagnostic
privacy, named read-only stages, bounded credential-redacted output, original
exceptions and no retained argv/input/environment remain required.

A future controlled experiment requires one unmeasured warm-up plus three measured
boots on each side: eight distinct actual boot IDs with strictly increasing
positive integer start sequences. Authentication records must match their
captured boot ID, expected role and exact input/transport record. All six
measured samples must bind to their captured diagnostics and reviewed frame
results; replayed authentication or relabelled captures fail closed. Console
SSH bootstrap on a measured boot invalidates it.

The complete package/configuration comparator remains in force, with only the
two reviewed first-party package exemptions and the reviewed schema 28→29/nine-default settings projection. The prepared SDK inventory and recorded
SSH/firewall fixture must match all observations exactly. All ten root-hash
paths must be present, with required files retained. Supplemental same-boot
root GRUB evidence includes environment bytes, configuration and bounded BLS
entries; pending menu/previous/next/recovery choices block comparison even if
identical across all samples. The reader never clears or edits those choices.
Original unavailable diagnostics remain visible.

Preparation uses verified, root-sealed dependency-only transport, no trust-key
import and disabled repositories. No candidate payload is transferred before
baseline observations. The unchanged upgrader runs once with candidate-bound
inputs and recovery creation, then candidate observations and recovery checks
follow. SSH/firewall restoration and managed teardown remain required on
success, failure and interruption. An unverified restoration remains a failure.

## Final blocked result and future acceptance

If accepted, the experiment must be labelled **sequential host-cache-warm QEMU
stop/start observed readiness upper bounds**, normal login, SDK82-prepared
baseline, explicit SSH fixture. Bounds include authentication, probes and UI
delays. Report median/minimum/maximum and the actual idle test window/host load.
This does not establish representative cold boot, earliest usable frame,
physical-hardware behavior or a causal speedup. Unchanged startup policy alone
does not prove equal boot behavior. An equivalent series can still fail.

Final disposition: observations failed with zero accepted startup samples across
four attempts; pixel/readiness acceptance is blocked; comparison/performance
results are unavailable. There are no pending startup measurement slots to fill
in this task and no further VM series is planned.

A future separately scoped benchmark must visibly verify Welcome and both portal
consumers, then collect eight fresh equivalent boots with revalidated current
source/helper/artifact prerequisites and a separately reviewed retarget. Preserve the
authentication, package/configuration, GRUB and six measured-sample diagnostic/frame bindings above.
Representative physical timing and lid/dock/display coverage remain blocked.

The [validation report](desktop-validation.md) records exact installed/native status,
failed-evidence identities, R30 scoped retention acceptance and completed teardown.
Both R29 repairs were independently verified. Current/frozen sources and all four
failed-attempt inputs are recoverable; ten older precursor source bodies were
already absent before audit, so complete transitive historical source is not claimed.
Original absolute paths are historical map-resolution identities, not a runnable
environment. Baseline 3b and b4/75 payload roots/testing ISOs were removed after
archival; final d2037af testing deliverables and bounded diagnostics remain.
All 53 recorded leases are closed, MAIN's workspace absent and no temporary VM/container
retained; shared services untouched. Validation qualifies the cleanup-time inventory
snapshot, which excludes later documentation/review/PR records.

[PR #21](https://github.com/DigitalPals/CybexOS/pull/21) merged at
`bee9d722021301875823e6285a6eef2896b283eb` on `2026-10-21T14:01:19Z`, both
required hosted checks successful and origin/main verified. CI-only head
9974aaee adds `patch` to the Fedora CI action; tested installed artifacts remain
d2037af. Active user desktop rollout/restart/reboot and public release remain
unauthorized. This documentation update is separate from the tested artifacts.
