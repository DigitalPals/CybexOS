# Desktop improvement qualification

Snapshot: 2026-10-21. **Tested installed product: `d2037af92cb3a47a08a9755e5996d2c4b0cae28d`.**
Exact source/image gates, four ISO scenarios, English/Dutch checkout fresh/saved parity, pristine
offline upgrade/native rebuild/recovery and scoped native workspace/action regressions passed. **Not
fully qualified:** these are QEMU/fixture results. Actual startup/pixel/performance measurement is
**BLOCKED** after four failed attempts, with zero accepted samples; hardware, generic Wayland CSD,
first-frame and unsampled interaction limits remain.

[PR #21](https://github.com/DigitalPals/CybexOS/pull/21) merged at bee9d722 on
`2026-10-21T14:01:19Z`, after both required hosted checks succeeded; origin/main was verified there.
The later CI-only fix and merge do not change the identity of the d2037af artifacts. This
documentation update is separate from those tested installed-product artifacts.

## Revisions, artifacts and evidence

| Role | Exact revision |
| --- | --- |
| Tested product/artifacts | `d2037af92cb3a47a08a9755e5996d2c4b0cae28d` |
| CI-only PR head: adds `patch` solely to `.github/actions/fedora-source-environment/action.yml` | `9974aaee9cb6160ddce86fe84d4a40fc4a75c055` |
| Merged, verified origin/main | `bee9d722021301875823e6285a6eef2896b283eb` |
| Implementation start | `3b310d106255558ca213c955ef37ee314e8681f2` |
| Original main, clean/unmodified at discovery | `6f4bdca3168d46cc76e8047fa94d172dac3cb696` |
| R15/R16/R18 workspace correction, included in tested product | `607bce226d9f85c4e6307567a75cc5cfbc8b1243` |

Build root: `/home/john/.local/share/cybexos/images/desktop-20261021-d2037af`. Clean build
`20261021T121337Z-87cc6b87`, UTC `2026-10-21T12:13:37.650803+00:00`, binds 1,432 source files to
content SHA-256 `81249a8df4fad7e208c1d6322e0cd609fb71e3fec2523bbc31485389d5a56a1c`. Checkout source
archive SHA-256: `d25860faa4e72d5655474408b03195b128fda6adeba2eff6972c21f613510e7a`.

Artifacts below are under the build root's `artifacts/`. Digests come from its `SHA256SUMS` and
recorded bindings; sizes are recorded stat values.

| Artifact | Bytes | SHA-256 |
| --- | --- | --- |
| `CybexOS-Live-44-20261021T121337Z-87cc6b87.iso` | 8,063,483,904 | `28603ac50e9167f1896d5f0657d171eb8bd3ac429d1a54dbc37540a98b275552` |
| `cybexos-desktop-0.0.0~dev-1.20261021121337.gd2037af92cb3.fc44.x86_64.rpm` | 30,146,729 | `b7cf0a08ff5621f1b661b58ae88bf03551da8cea5cc4c739b9383b7c98930ae7` |
| `cybexos-offline-apps-1.5.1-1.fc44.x86_64.rpm` | 1,639,333,037 | `9d28269b1eec5fbff08d684f5098a8902c22b344f0eb17368dbdd97968b466d9` |
| `build-provenance.json` | 335 | `3c7d904f6bf0fd3a15f23a77ae9debed7481b592f24d8c70b7d4b382e878436d` |

Testing ISO: `/data/pxe/iso/CybexOS-Live-44-20261021T121337Z-87cc6b87.iso`, with the same ISO
bytes/hash. Supported publication completed checksum, iVentoy refresh/list/PXE/service checks. This
is testing publication, not a public release. `pxe-publication.json` is publisher text despite its
suffix; R27 audited that record, not raw API responses or a new live PXE check.

The durable root is `/home/john/.local/share/cybexos/images/desktop-20261021-d2037af/validation`.
Here **V** denotes that root; **E** is its `evidence/final-r15-run/` mirror. Original **MAIN** was
`/var/lib/agent-resources/leases/29c5e2febb054008b06ff08cd794e589/workspace`; **FINAL** was
`MAIN/final-r15-run`; that disposable workspace is now absent. Relative reports resolve under E
unless marked historical, FINAL or V. Original absolute paths are historical identities, not a
runnable environment. Resolve each original path plus expected SHA-256 and byte count through
V/`archive-map.json`, `archive-history.json`, `superseded-archive-map.json` and sealed `maps/`;
never substitute a newer file by name or rewrite hash-bound evidence. Older reports are under
`superseded/`. R30 accepted selected evidence durability within the limits below; future execution
requires a separately reviewed retarget.

`artifact-bindings-d2037af.json` and `dependency-verification.json` bind both candidate RPMs to
`dependency-rpms-d2037af/manifest.json`, SHA-256
`4792413da9a4d624acced296892f0638f428776bc50aea1be195a1cdda9ebefb`: 82 exact RPMs, 40,923,680 bytes.
Offline payload version remains 1.5.1. The historical pristine-upgrade baseline ISO SHA-256 was
`0fdd68f925c64f24323385b40e6383c5f5704fbcdb19581c5d134ee48b945a2d`; its payload was removed
after metadata archival.

Qualified Fedora 44: Hyprland `0.56.2-2.fc44.x86_64`, source
`efb50993780079460b0cbed1363e2166a2de1d9f`, ELF build ID `04b20094d13879e70824418ba363f8dcc3253b34`;
Quickshell `0.2.1^git20260209.dacfa9d-5.fc44`. Earlier GPU fixtures used KVM, virtio-vga, llvmpipe
and disposable virtual outputs, not representative physical displays.

## Completed actual qualification

| Acceptance | Result and reproducible report |
| --- | --- |
| Exact source gate | Passed all 17 stages: 1,451 Node tests/148 files, 46 Python suites, 355 QML files/four harnesses with actual Qt/runtime checks, 233 Lua assertions. `gates-d2037af/results.json`, `source.log`. |
| Exact image gate | Passed: 30 application tests, 559 fixtures with three original skips, 14 installer Node checks. `gates-d2037af/image.log`; all three skips subsequently passed separate supplements below. |
| Four ISO scenarios | Passed within QEMU UEFI/outbound-blocked scope. `qualification-{plain,encrypted}-{us,nl}-evidence/qualification.json` and fresh/saved outcomes. Physical hardware/Secure Boot excluded. |
| Both checkout languages | Passed full graphical install, exact source/content/archive, saved choices and native settings lifecycle. `checkout-plain-{us,nl}-evidence/{checkout-qualification,parity-fresh,parity-saved}.json`: every profile has `differences:{}` and no unreviewed package deltas. English was separately verified by the parent after R27; its lease closed/empty. |
| Pristine offline upgrade/native/recovery | Passed guest signatures, one offline transaction, forced native build, one-line unchanged convergence, candidate runtime and recovery boot/restore. `qualification-offline-upgrade-evidence/{qualification,offline-upgrade-transaction,native-offline-rebuild,native-candidate-runtime}.json`. No SDK preinstallation into pristine baseline. |
| Targeted native workspace/actions | Passed within the stable observations and instrumentation scope below. `qualification-plain-us-evidence/{r15-workspace-rename-native,notification-actions-native}.json`. |
| Core prerequisites / independent audit | `core-qualification-d2037af.json` passed within startup-fixture prerequisite scope. `independent-acceptance-r27.json`: 234 read-only consistency checks, zero failures/findings, no tests executed; English excluded and subsequently parent-verified. Neither grants full project/release acceptance. |
| Main integration | Complete: `main-push-result.json`, `ci-only-revision.json`, `ci-patch-review-r28.json`. Both required checks SUCCESS: Fedora 44 source contract; Image tooling, installer fixtures and account isolation. |

All ISO cases passed graphical installation, unchanged unused disk, boot without ISO, selected
locale/timezone/keyboard, desktop parity, live cleanup, SELinux Enforcing, password-required sudo
and fresh/saved settings lifecycle. Plain cases passed password login/plain Btrfs. Both encrypted
cases passed verified-encryption autologin, initial keyring unlock, synthetic-secret persistence
across cold reboot, authenticated logout/crash/manager recovery, missing-cache locked-keyring
protection, fallback password unlock and consumed failed-autologin attempt followed by
password-login recovery. These are not startup samples. Checkout package exceptions are reviewed
trust-key records versus ISO desktop/offline RPM bookkeeping; outcome parity does not mean
byte-identical inventories.

Upgrade records bind newer desktop EVR, offline-apps 1.4.0→1.5.1 and recovery point
`20261021T125122Z-5063`. Forced output was `CHANGED: native titlebars v0.2.2 for
0.56.2-2.fc44.x86_64`, followed by one-line `UNCHANGED: native titlebars v0.2.2`. Converged plugin
SHA-256: `1142347ed31dcfb67733602b8ec6d88733131e0f8140ad8c3f50c870ef24e878`. The candidate snapshot
proves exact provenance, loaded hyprbars, true Scrolling/titlebar capabilities, empty error and
workspace 1 Floating on Virtual-1; it does not requalify pointer controls or
first-frame/client-configure behavior. Two SSH-255 poweroff diagnostics remain as
`root-failure-{1,2}.json` beside the final passed upgrade report. Offline transport retains bounded
metadata/hash checks, installed-trust signatures, root-only no-follow sealed staging, disabled
repositories and one transaction after recovery creation. Startup's SDK82-prepared baseline is a
separate experiment, not the pristine gate.

| Gate log identity | SHA-256 |
| --- | --- |
| `gates-d2037af/source.log` | `1b917ab451a0de782773114b454556da1cd0d224751df4af9b315dc054406e1c` |
| `gates-d2037af/image.log` | `3f3e54a73b31568c321d209a402b0c612b2e4c864115deaf074a685e3a0b0be1` |
| `gates-d2037af/real-release-signing-supplement.log` | `ef8b3320a9f323eda412e8971af29709aede4f93337a472a8a82288ad499e882` |

The original root run still records three skips. UID1000 reruns in `exact/candidate-r15` passed
publication permission staging and seeded-account keys/server/one-time-key behavior
(`gates-d2037af/unprivileged-supplement.log`). Unchanged RealReleaseSigning then passed one
test/zero skips in 1.464s after adding `rpm-sign`, `createrepo_c`, `createrepo_c-libs`, `drpm` only
inside the leased gate container. Its disposable key/subkey/RPM/repository directories were verified
absent; source stayed clean (`gates-d2037af/real-release-signing-results.json`). All skips have
passing supplements, not waivers or rewritten original results. No actual product
signing/public-release publication occurred or was authorized.

## Native and UI evidence limits

Workspace stable observations passed renamed `research-r15` opening tiled without mode tags,
numbered opening floating with ownership tags, named-group provenance through new
members/original-owner closure/reload/return to numbered Tiled, and manual tiled/floating groups
retaining choices as members joined and reloaded. Preferences/name were restored, test clients
absent, snapshot error empty and terminal fence set. This is not first-frame/client-configure proof.

The instrumented notification test kept `OPEN`/`open` distinct, transferred the lowercase duplicate
to sender 3/count 2, emitted exact ActionInvoked `[1,"OPEN"]` and `[3,"open"]`, and expired only
superseded lowercase sender 2 before cleanup. No settings were written. Normal
`roles/desktop/files/quickshell/shell.qml` bytes/metadata/timestamps were restored;
original/restored SHA-256: `287edb8c3f4d5fb594e7927f1a5d3b79ad36c1012e251bbad2a2c39d89b3804b`.
Recorded boundaries had sole managed qs PID, checked nonempty current journals and zero QML errors;
entries/probe files cleared. Guest-local terminal state was retained until disposable teardown. R20
action-count/length and cleaned-label/accessible-presentation edges remain source/runtime fixtures,
not this native test.

`settings-visual-review.json` records parent's encrypted-US 1280×800 workspace settings,
notification top/grouped-popup/lower history/source-snooze controls and empty overview. Drag frames
covered lower content missed by wheel-only capture. The parent's frame review covers those views;
unsampled interactions, assistive-technology behavior and first-frame qualification remain open.

Earlier native tests covered all layouts, local navigation/moves, guests, minimize/restore/reload,
custom defaults/overrides and manual groups; a 1600×1000 virtual output at scale 1.25/90° kept
geometry inside usable bounds. Historical titlebar compilation/offline convergence, declarative
reload, clear/re-add, drag/maximize/minimize/close and recompiled wrong-build-ID rejection passed.
The earlier byte-edit guard probe was invalid and supplies no acceptance. Historical writer
JSON/0700/ECHILD success required the exact bounded token and four behavioral regressions. Earlier
D-Bus/source/image separation, replacement/snooze/DND/redaction/restart and three
grouped-burst/fullscreen/output create/disconnect matrices passed after the toast-loop fix. These
predate later corrections; they do not requalify this artifact's pointer, mixed-client CSD, full
notification edge or physical/first-frame behavior.

## Startup measurement: blocked

Actual startup/pixel/performance measurement is **BLOCKED**. All four controlled attempts failed
with zero startup samples; no comparison, optimization or speed claim is justified.
Source/helper/bound inputs remained unchanged in each run. No further VM series is planned in this
task.

| Attempt | Observed failure and limit | Retention / lease |
| --- | --- | --- |
| `d2037af-warm-01` | Baseline preparation failed, `actualAcceptanceClaim:false`; both `portal-actions/00000{1,2}-outcome.json` records were `deadline-no-action`, null action hashes, no input. Parent recorded clipped file-picker header/Cancel and SelectSources covered by first-run Welcome; pixels establish no product root cause. | Whole attempt/supplement retained, two restoration attempts passed; lease `ed16ccc887dc40e8a65e12336f66bae3` closed/check empty. |
| `d2037af-warm-02` | Initial onboarding snapshot root command returned 1. Retained diagnostic omits output by design (`include_output=False`); raw output, exact substep and root cause remain unknown. | FINAL/`startup-attempt-warm02-summary.json`: 11 files/2,704,256 bytes, four evidence files duplicated in supplement; lease `cc6a72cf312b44b698b474330909e9da` closed/check empty. |
| `d2037af-warm-03` | Initial snapshot failed at `before.root-boot-policy`. Bounded redacted failed-stage stderr proves `ValueError: Invalid or duplicate GRUB environment variable`; exact offending guest bytes unretained. Outer run output placeholders remain omitted output. | FINAL/`startup-attempt-warm03-summary.json`: 11 files/2,706,700 bytes, four duplicated evidence files; lease `4f6364e98aec411cacd3ea673e04f551` closed/check empty. |
| `d2037af-warm-04` | Initial snapshot including `before.root-boot-policy`, packaged reconciliation and readiness validation passed. Actual Welcome frame showed black background and pointer only; parent could not verify a dialog and returned null: `explicit-observe`, no input. Failed at `review-action` before SSH fixture/warm-up/measured boots; black-frame cause unknown, no proof of product regression. | FINAL/`startup-attempt-warm04-summary.json`: 16 files/2,736,770 bytes; lease `e9114b0a47bf45418ee25de82abb4804` closed/check empty. |

Attempt directories are `startup-controlled-harness/attempt-d2037af-warm-0{1,2,3,4}`. Warm01's
`evidence/fixture-transport.json` and failure-supplement copy restore original SSH/firewall state:
enablement disabled/permanent SSH false, preserving originally active/runtime SSH true. Warm02/03
stopped before reconciliation, Welcome callback, SSH fixture or warm-up: exact 82-dependency
fixtures/staging cleanup passed, no candidate transferred, no input/context/measured boot/sample.

Warm01 launch load 0.95/1.66/2.40, no other task build/install VMs and remote hosted CI are context.
FINAL/`startup-host-context-d2037af-warm02.json` binds R7/core/helpers and launch load
0.828125/0.81640625/1.03125, finished task build/install VMs and running shared persistent
workloads. Neither record proves sustained idle or readiness. Warm01/02 evidence remains unchanged.

Warm03's exact attempt is copied under E/`startup-controlled-harness/attempt-d2037af-warm-03`;
V/`startup-warm03-emergency-copy.json` records all 11 files/2,706,700 bytes; R30 later verified
recoverability of all four attempts. FINAL/`grub-environment-format-probe.json`
records an executable-format reproduction with Fedora `grub2-tools-minimal-1:2.12-66.fc44.x86_64`:
its standard warning line is rejected by the old parser. This proves supported-format rejection, not
the exact guest bytes behind warm03, and supplies no explanation for warm02.

Warm04's exact original directory is FINAL/`startup-controlled-harness/attempt-d2037af-warm-04`.
Summary SHA-256: `0c5d017a9b3b3d143369680d461dc42968d8f53c001908ec15f1e7128ab2b741`; its
`evidence/onboarding-preparation/welcome-review.png` frame SHA-256:
`491f31f9d3c41aed91a5756b818bf8828a2f1c3acd70178be2988aa4485f7907`. The five evidence files,
including the frame, are duplicated in its failure supplement. One Welcome review context, zero
portal sidecar contexts/input/startup samples; dependency preparation/staging cleanup passed, no
candidate transferred. Warm02's cause remains unknown; warm03's offending bytes remain unproven.

| Frozen tooling review | Scoped result / controlled manifest |
| --- | --- |
| R5: `startup-retarget-independent-r5.json` | Three R4 P2s closed; 195 inert/eight help checks, archived failures reproduced. Full-pipe callback/close 9.001s/0.0003s, unchanged flags/workers joined, not boot times. Manifest `6898ed59a0d1efaf9b4b34b2e0bd5f83f280f6df8614cfc0005fbe41271d0739`. |
| R7: FINAL/`startup-onboarding-independent-r7.json` | R6 global `json`/measured `controlledBootPolicy` preparation binding fixed; 237 inert (42 onboarding outside legacy adapters), six adversarial rejections, eight help/80 Python/four payload compiles, old NameError negative reproduced; 271 files unchanged. Synthetic fixture failures/adapter exclusions are not passing coverage. Manifest `9fd45d16597f4df7871fbc85434efda36aeb610dcd56dfc7adcb21aa17ea40ff`. |
| R9: FINAL/`startup-diagnostics-independent-r9.json` | R8 stage-attribution P2 fixed; clean inert review: 260 supplied (65 onboarding/diagnostic outside legacy adapters), 116 independent mocked preparations, eight help/104 Python/five payload compiles. Failed stages preserve original exceptions/causes, passed stages stay unblamed, strict guard/eligibility AST unchanged. Immutable reviewed manifest `92fba8d77a9c35a669c3437ee344b1e788346eef2553a4aa05fa6bf4e694e9c2`. |
| R11: FINAL/`startup-grub-independent-r11.json` | R10 LF-separator P2 fixed after supported-warning support: literal LF boundaries and terminating-LF guard. Clean inert review: 283 supplied, seven independent methods/19 delimiter variants, four negative-control methods, eight help/128 Python/five payload compiles. Policy/hash/authentication/comparison guards preserved. Current reviewed manifest `e8a7f96eb48a972f912d3e0c61628b3451e5ce83ae11445e0f318e5c69194fe0`. |

Standalone observer remains `51eada68b783068e5ac62305dc45381ba7862a20b84f520d2ba63319164ba80a`.
These reviews establish inert tooling contracts, with no startup/pixel/performance acceptance.
Diagnostics remain opt-in, bounded and credential-redacted for named read-only stages, preserve
original exceptions and retain no argv/input/environment. The task's startup attempts are stopped.

Pixel/frame acceptance is blocked: no accepted measured-sample frames or portal readiness.
Comparison/performance is unavailable without a valid equivalent series.

A future separately scoped benchmark must visibly verify Welcome and both portal consumers, then
collect eight fresh equivalent boots with current revalidated source/helper/artifact prerequisites,
distinct boot IDs/auth sequences, six same-boot diagnostic/frame bindings, SDK82/full configuration
equivalence, reviewed settings projection and root GRUB evidence. Preserve all guards. Label any
accepted series sequential host-cache-warm QEMU stop/start readiness upper bounds including
authentication/probe/UI delays; no representative cold-boot or causal-speedup inference. Full
contract is in [startup](desktop-startup.md). No GRUB/binfmt/portal-grace optimization was made.

## Retained review and superseded evidence

Actual fresh T3 Codex tasks used verified `codex/gpt-6.1-sol`, xhigh/priority selections.
Implementers were not sole reviewers. Retained reports distinguish source/inert review, actual
runtime, recorded-evidence audits and release limits.

| Review/history | Material result and retained reference |
| --- | --- |
| R1–R14 | Ownership/defaults, group/origin/UI/image issues, toast loop, offline admission/root sealing, native availability, wrapper cleanup and locale1 keyboard/variant fixes; `completed-review-records.json` and mapped historical/superseded reports. |
| R15/R16/R18/R20/R22 | Renamed opening/manual and named-group provenance corrected in 607bce2; exact IDs, null signatures over 16 actions or 256 code units per ID/cleaned label, shared plain-text visible/accessibility cleanup in d2037af, without source/snooze/group changes. R22 clean: 105 focused Node, 233 Lua/hotplug/margins, 972 notification, 2,317 layout assertions, 24 comparative probes. Host lacked parity prerequisites; later exact Fedora gates supply them. `review-records-r21-r22.json`. |
| R17/R19/R21/R23–R26 | External helper cleanup/metadata, races, exceptions, terminal fence and Kitty `-o confirm_os_window_close=0` fixed. R23: 4 supplied/20 independent/12 compiles; R25: 6/18/3 negative/6 compiles. Preserved Foot absence and unsupported `hl.dsp.window.focus` failures both restored. R26 corrected to `hl.dsp.focus`: 19 pinned dispatch sites, 7 supplied/14 independent/6 Python/10 Lua plus negatives; later actual workspace pass. `review-record-r26.json`, `preserved-plain-us-foot-launch-failure`, `preserved-native-focus-r25-failure`. |
| R27/R28/main | R27 reproduced content hash from 1,432 immutable Git blobs without large-artifact/live rechecks; English excluded then parent-verified. Initial hosted `titlebars.py` failed FileNotFoundError for missing `patch`; narrow R28 sole-path diff clean, then both hosted checks passed/PR merged. `independent-acceptance-r27.json`, `ci-patch-review-r28.json`, `main-push-result.json`. |
| Historical startup tooling | R8: 74 inert/144 terminal/16 stale-context probes. Earlier 3b→75 wrapper R1 fixed five bindings; R2 found replay; R3: 58 wrapper/72 inert-substitute observer checks (two product-dependent checks excluded), 273 compare/32 failure probes. These pins do not qualify retarget/runtime. |
| Historical installed results | b4dfdf6 and 75 passed four ISO cases; 75 pristine upgrade/native/recovery passed. b4 English checkout passed/Dutch keyboard failed; fixed in 75, whose Dutch install then failed SSH255 during outcome capture/cleanup, not parity. English 75 was not rerun after R15. OPPO font TLS, OpenH264 404/retry and initial pristine missing-SDK solver failures remain preserved, not waived. |
| Historical startup failures | Original 3b probes failed inventory/no frames. 63f7785 first encrypted login had 27.949s systemd diagnostics, black bar/launcher/picker failure with authentication/seeding/console setup, not readiness. b4 picker Escape=2 and ScreenCast cleanup failed. 75 inventory/root hashes/two-Escape dismissal passed, but large picker and inspected actions missed 9/10s deadlines; SelectSources rendered, selection/Close/cleanup failed. Backend 1.4.1 opens picker at SelectSources; GTK 1.15.3 Escape=2/Cancel=1 explains observer assumptions, not a product defect. See mapped `superseded/` reports and startup document. |

R22 reviewed `75bc4243134ef93d96f208ab6edbb02e83438d18` plus correction diff SHA-256
`a02af5098c37a48f0aa56950caf6d5f60c1a0909ad02beebf2d014fc902d3fe7`, then committed as
607bce2/d2037af. R26-reviewed native helper/test SHA-256 respectively:
`21eb0c82538e91dfc7b0bff4cc26671cb3a95523be8f6c59467e602939063cee`,
`3db76f20cf2c1c89508ad3350be428327975cfd70a55804996900a49510d446b`. Historical wrapper/R8 manifests
respectively: `0449beffb14af04201854c1ce20361281af25461c4e7e1caddd00d0a507d9649`,
`074746e8cca6909b1e4b0074c65754b5539ab88b0198cd4bae6a01a8a6ed9893`. `progress.json` can lag
completed evidence; preserve originals and use the map.

## Remaining qualification

Blocked/unqualified: representative physical lid/mirrors/docks/two externals, connector identity
ambiguity/scaling/rotation; Secure Boot; first-frame/client configure and new-artifact
pointer/unsampled assistive interactions; generic Wayland negotiated-CSD query (exact Nautilus/Text
Editor exclusions are policy only); full native notification overflow/presentation cases; actual
startup/pixel/performance measurement (blocked). No complete project or release qualification is
claimed.

## Retained evidence and completed cleanup

V/`independent-retention-r30.json` independently accepted selected evidence durability: 14,896
record/assertion checks, no findings, 1,661 mapped non-RPM hashes. These are retention checks, not
product tests or release/runtime acceptance. The 80,789-byte report SHA-256 is
`7c79dd51a1abb1ee1451a99b1ab8412d4e88fa9e5412b483906fccf61a91f0fb`. Its audited
`archive-map.json` has 1,438 current records/193,372,721 payload bytes and SHA-256
`f27ac95d8015900f6960baff3878047b7cd5479fb2edee9b8571daeb0a8c6002`.

R30 independently verified both R29 findings corrected in V/`retention-r29-fixes.json`; R29 and
its hash-bound originals remain unchanged.

| Retention correction | Exact retained binding under V |
| --- | --- |
| R29-1, P2: missing R27-bound nine-record ledger snapshot, 1,344 bytes; later ledger was 11 records/1,642 bytes, not a teardown failure | SHA-256 `7ea3038a25d250c89dd412db70de72073ec62c64dc3971a1188aba0a1485af36`, recovered at `history/7ea3038a25d250c89dd412db70de72073ec62c64dc3971a1188aba0a1485af36/final-r15-run/completed-lease-checks.json`; current ledger and R27 unchanged |
| R29-2, P3: missing late native terminal supplement, 1,111 bytes | `evidence/final-r15-run/native-terminal-inventory-binding.json`, SHA-256 `a3506c2f7560a980f2eb8ddd00ecb3fbe00a3e4b68b20882d59344d87c1d6795`; Kitty included/Foot absent, not new native qualification |

R29's audited map remains at
V/`maps/8832a1321bcffad93bcbf84500dfa33c5ca281e03fbbbf714103d75d43e647b0.json`, with SHA-256
matching its basename. R30 verifies current/frozen sources and all four failed-attempt inputs are
recoverable, including version-specific preserved helper aliases. Ten older pre-R3/pre-R8 precursor
source bodies were already absent before the MAIN audit; their metadata does not establish complete
transitive historical source preservation. Bounded text/privacy checks do not prove secrets absent
from PNG pixels or RPMs; ISO/RPM payloads were not rehashed by the audit. R30 preceded MAIN teardown;
the subsequent cleanup records below establish resource removal.

Own b4dfdf6/75bc424 roots and PXE copies were removed after archival
(`superseded-root-cleanup.json`, `superseded-pxe-cleanup.json`, `pxe-after-superseded-removal.json`
under V). V/`baseline-final-cleanup-plan.json` and `baseline-final-cleanup.json` record removal of
`/home/john/.local/share/cybexos/images/desktop-20261021-baseline-3b310d1`: 17 files/10,088,530,860
bytes, plus its 8,027,873,280-byte PXE ISO and 112-byte sidecar, after 11 metadata hash checks.
V/`pxe-after-baseline-removal.json` records refresh success, PXE running/service active, final
candidate present and baseline absent, without restart. The historical 3b baseline ISO is unavailable.

V/`parent-lease-final-cleanup.json` records MAIN lease `29c5e2febb054008b06ff08cd794e589` released
at `2026-10-21T16:33:05Z`, return 0, check closed with `remaining:[]`/`errors:[]`, workspace absent;
idle container `6d814bcad464`, network and workspace removed. V/`final-resource-verification.json`
confirms all 53 recorded CybexOS leases closed, no task QEMU/developer Quickshell processes, mounts
or MAIN containers, and shared services untouched. No temporary VM/container is retained. The
ordinary documentation Git worktree `/home/john/Code/CybexOS-desktop-qualification-20261021` remains
until protected PR merge, then removal through Git.

| Retained path | Cleanup-time count/bytes | Reason |
| --- | --- | --- |
| Build root's `artifacts/` | 18 files/10,123,452,292 bytes | Requested exact d2037af testing deliverables/provenance |
| Testing ISO under `/data/pxe/iso` named above | 8,063,483,904 bytes plus 112-byte sidecar | Requested PXE test image/checksum |
| V | 1,774 files/274,027,350 bytes | Bounded qualification/reviews, helper lineage and unresolved startup diagnostics; private VM state excluded |

These are the `2026-10-21T16:33:43Z` cleanup-time snapshot in
V/`retained-inventory-cleanup-snapshot.json`, excluding itself and later documentation/review/PR
records; they are not final totals. Final handoff recomputes retained totals.

User may `git pull --ff-only` then `./install` for own-machine testing with the limits above; no
completed user-machine test is claimed. Agent rollout/restart/reboot and public release remain
unauthorized/unperformed. This documentation update remains separate from tested d2037af artifacts.
