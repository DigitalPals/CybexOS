# Desktop improvements implementation ledger

Snapshot: 2026-10-21. Exact source/image gates, all four ISO scenarios, both English/Dutch checkout
fresh/saved parity cases, pristine offline/native/recovery and scoped native workspace/action regressions
passed for **tested product `d2037af92cb3a47a08a9755e5996d2c4b0cae28d`**. Actual
startup/pixel/performance measurement is **BLOCKED**: four failed attempts, zero accepted samples.
Physical hardware, generic Wayland CSD, first-frame and unsampled interaction limits remain;
**not fully qualified**.

[PR #21](https://github.com/DigitalPals/CybexOS/pull/21) merged at
`bee9d722021301875823e6285a6eef2896b283eb` on `2026-10-21T14:01:19Z` after both required hosted checks
succeeded; origin/main was verified there. The intervening CI-only head
`9974aaee9cb6160ddce86fe84d4a40fc4a75c055` changes no installed payload. Tested artifacts retain d2037af
identity; this documentation update is separate from the tested installed product.

Implementation started on `feat/desktop-improvements-20261021` at
`3b310d106255558ca213c955ef37ee314e8681f2`; original main was clean/unmodified at discovery,
`6f4bdca3168d46cc76e8047fa94d172dac3cb696`. The workspace correction is
`607bce226d9f85c4e6307567a75cc5cfbc8b1243`; d2037af corrects notification equivalence. Historical results
are never transferred to the new revision.

## Ownership, controls and contracts

Actual disjoint T3 Codex delegates implemented compositor, UI, notifications and native titlebars; fresh
independent tasks reviewed integration/corrections with verified `codex/gpt-6.1-sol`, xhigh/priority
selections. Parent owns schema 29, English/Dutch strings, shared install/package policy, qualification
and cleanup.

| Workstream / owner | Delivered behavior and remaining qualification |
| --- | --- |
| Workspace delegate | Shared/default and Per-monitor local slots 1–10, unique explicit IDs, physical identity, guest reachability and reversible transitions. Exact renamed/numbered opening, named/manual groups, owner closure/reload/restoration passed; physical matrix and first-frame remain unqualified. |
| UI delegate | Bar/overview/launcher/dock consume compositor mapping and restore before focus; Tiled/Scrolling/Floating controls and saved settings lifecycle. Parent's encrypted-US settings/empty-overview pixels reviewed; unsampled interaction/assistive technology and new-artifact pointer behavior unqualified. |
| Native delegate + parent | Pinned Fedora titlebars, themed controls, runtime ELF guard, offline forced rebuild/unchanged convergence and recovery passed. Historical pointer/clear-readd/wrong-build-ID evidence retains earlier source scope; generic negotiated Wayland CSD blocked. |
| Notifications delegate | Source snooze, exact bounded dedupe/count, explicit safe code/link actions, grouped popups and optional private history. Native OPEN/open separation/duplicate transfer/ActionInvoked/restoration passed; overflow/cleaned-label edges remain source/runtime fixtures. |
| Parent | One ISO-authoritative installation/security/recovery contract shared with checkout, migrations, upgrade and owned-file uninstall. Actual captures have exact source/content binding and no unreviewed package deltas; reviewed trust-key versus RPM bookkeeping differences are not byte-identical inventories. |
| Startup delegate + parent | R11 scoped inert review clean; actual startup/pixel/performance measurement BLOCKED after warm01–04, zero accepted samples/comparison/speedup. All leases closed/empty. No further VM series planned; future acceptance requires visibly verified Welcome/portals and eight fresh equivalent boots with current prerequisites. |

`require("workspaces")` alone owns monitor identity, ordered ID assignments, layouts and minimize state;
UI never allocates IDs. Shared remains the first-install/existing-user default, managed base dwindle.
Per-monitor guests remain reachable; transitions never renumber/merge live workspaces, mirrors own no
assignments, and indistinguishable panels with changed connectors use the recorded deterministic
fallback. Native `user.lua` custom layouts remain owned by the user when `manageDefaultLayout:false`;
only deliberate default selection takes ownership. Explicit equal-default overrides persist until
`set_layout(id,"default")`; named/renamed destinations suspend numbered choices and preserve native state
and mode/manual group provenance through reload.

Personal choices: `$XDG_CONFIG_HOME/cybexos/workspaces.json`; assignments:
`$XDG_STATE_HOME/cybexos/workspace-assignments.json`; schema-v1 runtime snapshot:
`$XDG_RUNTIME_DIR/cybexos/workspaces.json`. No duplicate shell preference owner or startup push. Settings
→ Workspaces controls mode/layout/titlebars; Bar owns existing dock opt-outs/pins/auto-hide. Super+Ctrl+L
cycles layout; Super+Ctrl+Alt+M minimizes; Super+Ctrl+M restores, including with dock disabled;
Super+Ctrl+Shift+arrows moves displays. Super+L lock/Super+M Slack remain intact. Overview/launcher/dock
restore hidden windows before focus; keyboard/mouse fallback works without titlebars. Full
API/storage/ownership contracts remain in [architecture](desktop-workspace-architecture.md) and
[controls](desktop-workspaces.md).

Notifications retain one D-Bus owner and existing DND/quiet settings. Session snoozes keep suppressed
arrivals in history without replay. Exact action IDs retain case/whitespace; over 16 actions or 256 code
units per exact ID/cleaned label disables dedupe without altering source/snooze/groups. Visible and
accessible labels share plain-text cleanup. Persistence defaults off, uses bounded atomic private
storage, redacts codes across alternate fields and restores no live actions. Copy/link activation is
explicit, URI-constrained, never automatic or shell-interpolated. See [notification
security/controls](desktop-notifications.md).

## Provenance and artifact binding

| Component | Pin and retained contract |
| --- | --- |
| Omarchy | `v4.5.0-rc1`, `03ff1eff3812933f7088484533784d2f63eaf19a`; selected adaptations retain MIT notices; no moving-branch fixes imported. |
| Native titlebars | `v0.2.2`, `379ff910fcce9f0cc9b41f9a87c527997076a417`; patched source plus BSD-3-Clause/MIT licenses, fixed `/usr/lib64/cybexos/titlebars.so`. |
| Fedora compositor | Hyprland `0.56.2-2.fc44.x86_64`, source `efb50993780079460b0cbed1363e2166a2de1d9f`, ELF ID `04b20094d13879e70824418ba363f8dcc3253b34`; Scrolling built in, no compositor upgrade. |
| Shell | Quickshell `0.2.1^git20260209.dacfa9d-5.fc44`; bounded public Qt image-provider identity. |

Both install paths share recipes, payload admission, personal-data preservation,
authentication/firewall/recovery policy and owned-file uninstall boundaries. Exact Fedora SDK/RPM and
running mapped-ELF identity gate native loading; checksum-cached bounded offline builds remove stale
loadable artifacts on failure. Declarative load persists on each parse; registry-gated callbacks,
independent availability/rendering status and exactly-three-button theme setup remain intact. Exact
Nautilus/Text Editor exclusions are policy, not generic CSD detection. See [native
lifecycle/security/licenses](native-titlebars.md).

Build root: `/home/john/.local/share/cybexos/images/desktop-20261021-d2037af`, clean build
`20261021T121337Z-87cc6b87`. Testing ISO: `/data/pxe/iso/CybexOS-Live-44-20261021T121337Z-87cc6b87.iso`
(8,063,483,904 bytes). Supported checksum/iVentoy refresh/list/PXE/service checks passed. Exact RPM
filenames/bytes/digests and bounded report paths are in [validation](desktop-validation.md).

| Binding | SHA-256 |
| --- | --- |
| Clean source content | `81249a8df4fad7e208c1d6322e0cd609fb71e3fec2523bbc31485389d5a56a1c` |
| Testing ISO | `28603ac50e9167f1896d5f0657d171eb8bd3ac429d1a54dbc37540a98b275552` |
| Actual-candidate dependency manifest: 82 RPMs/40,923,680 bytes | `4792413da9a4d624acced296892f0638f428776bc50aea1be195a1cdda9ebefb` |
| Converged installed native plugin | `1142347ed31dcfb67733602b8ec6d88733131e0f8140ad8c3f50c870ef24e878` |

## Evidence, corrections and historical scope

Current evidence is mirrored under
`/home/john/.local/share/cybexos/images/desktop-20261021-d2037af/validation/evidence/final-r15-run/`.
Here E denotes that path and V its validation root. MAIN/FINAL paths are historical identities; resolve
expected path/hash/size through the durable maps/history described in validation. `superseded/` retains
older reports. R30 accepted selected evidence durability, not release/runtime acceptance. Current/frozen
and all four failed-attempt inputs are recoverable; ten older precursor source bodies were already
absent before audit, so no complete transitive historical source claim is made. Future execution requires
a separately reviewed retarget.

Exact Fedora source/image gates passed; validation records counts and log identities. The original
three root skips remain recorded, with two UID1000 reruns and unchanged RealReleaseSigning
(1 pass/0 skips, 1.464s, disposable key/RPM/repo) passing supplements; no waiver or actual product
signing. Signing log SHA-256: `ef8b3320a9f323eda412e8971af29709aede4f93337a472a8a82288ad499e882`.
E/`core-qualification-d2037af.json` aggregates prerequisites, not full release acceptance. R27's 234
read-only checks excluded English, later parent-verified; no tests/live/PXE/large-artifact rechecks.

| Retained reports | Material disposition |
| --- | --- |
| `completed-review-records.json`, mapped superseded reports | Early layout/default/group/UI/image/origin issues, toast lifecycle, sealed offline admission/native availability and keyboard/variant correction fixed. Earlier runtime/layout/titlebar/D-Bus/output evidence retains its source scope. |
| `review-records-r21-r22.json` | R15 renamed opening and action-ID alias, R16 manual groups, R18 named provenance, R20 overflow/presentation corrections committed as 607bce2/d2037af; R22 clean within final 13-file scope. Focused/comparative counts and hashes are in validation. |
| `review-record-r26.json`, preserved Foot/focus failures | External restoration/race/metadata/exception/fence and Kitty close-confirmation fixes; corrected unsupported `hl.dsp.window.focus` to `hl.dsp.focus`. R26 clean against all 19 pinned dispatch sites, then actual workspace pass. Earlier failures remain restored/preserved, not converted into passes. |
| `independent-acceptance-r27.json` | Clean completed-evidence audit; English separately verified. Recorded first-frame/hardware/CSD/action-edge/startup limits retained; subsequent teardown documented below. |
| `ci-only-revision.json`, `ci-patch-review-r28.json`, `main-push-result.json` | Hosted `titlebars.py` initially failed FileNotFoundError for absent `patch`; exact sole-path CI environment addition reviewed clean, both required hosted checks SUCCESS, PR #21 merged. No installed payload or gate/security change. |
| Durable-root `independent-retention-r29.json`, `retention-r29-fixes.json`, `independent-retention-r30.json` | R29's missing R27 nine-record/1,344-byte ledger snapshot (P2) and 1,111-byte native terminal supplement (P3) recovered; R30 independently verified both repairs, 14,896 scoped retention checks/1,661 mapped non-RPM hashes, no findings. Not new runtime/release acceptance; validation gives exact paths/hashes and historical-source limits. |
| Mapped historical installation/startup reports | b4dfdf6/75 four ISO and 75 pristine upgrade/native/recovery passes remain historical. b4 English checkout passed/Dutch keyboard failed; R14-cleared `75bc4243134ef93d96f208ab6edbb02e83438d18` fixed locale1 discovery, but 75 Dutch outcome capture/cleanup failed SSH255 and is not parity; English 75 was not rerun after R15. Failed inventory/black-bar/launcher/portal observations remain failed; pixels never establish a product portal defect. |

Historical implementation sequence: 66b14a2, c5b5c96, 9702355, 629219f, 63f7785, 78903e9, 00f71b4,
b4dfdf6, 75bc424, 607bce2, d2037af. Validation records exact native opening/group and OPEN/open
ownership/count/ActionInvoked/restoration scopes, sole PID/current QML0 journals and limits:
first-frame/configure and full R20 bounds/label cases remain unqualified.

## Startup: measurement blocked

Actual startup/pixel/performance measurement is **BLOCKED**: four failed attempts, zero startup
samples/comparison. No optimization/speed claim is justified; no further VM series is planned.

| Inert tooling snapshot | Scoped result / controlled manifest |
| --- | --- |
| Frozen R5 | 195 inert/eight help, three R4 P2s closed; `6898ed59a0d1efaf9b4b34b2e0bd5f83f280f6df8614cfc0005fbe41271d0739`. Standalone observer remains `51eada68b783068e5ac62305dc45381ba7862a20b84f520d2ba63319164ba80a`. |
| R7 | R6 `json` import/measured `controlledBootPolicy` binding fixed; 237 inert (42 onboarding outside legacy adapters), six adversarial rejections, eight help/80 Python/four payload compiles, old NameError negative; 271 files unchanged. Synthetic failures/adapter exclusions are not passing coverage. `9fd45d16597f4df7871fbc85434efda36aeb610dcd56dfc7adcb21aa17ea40ff`; FINAL/`startup-onboarding-independent-r7.json`. |
| R9 | R8 stage-attribution P2 fixed; 260 supplied inert/116 independent mocked preparations/eight help/104 Python/five payload compiles. Clean inert diagnostic scope only; immutable reviewed manifest `92fba8d77a9c35a669c3437ee344b1e788346eef2553a4aa05fa6bf4e694e9c2`; FINAL/`startup-diagnostics-independent-r9.json`. |
| R11 | R10 LF-separator P2 resolved with literal LF/terminating-LF guard after supported-warning support; 283 inert, seven independent methods/19 delimiter variants, four negative-control methods, eight help/128 Python/five payload compiles. FINAL/`startup-grub-independent-r11.json`; current manifest `e8a7f96eb48a972f912d3e0c61628b3451e5ce83ae11445e0f318e5c69194fe0`. Inert scope only. |

| Attempt | Observed result / evidence / closed-empty lease |
| --- | --- |
| warm01 | Two deadline-no-action/null-hash outcomes, no input; parent recorded clipped/Welcome-covered picker frames, no product root cause established. Two restoration attempts restored actual SSH/firewall/pre-existing active runtime state. E/`startup-controlled-harness/attempt-d2037af-warm-01` and supplement retained; `ed16ccc887dc40e8a65e12336f66bae3`. |
| warm02 | Initial snapshot root command returned 1; diagnostic omitted output by design, raw output/substep/root cause unknown. R7/core/helper-bound; FINAL/`startup-attempt-warm02-summary.json`: 11 files/2,704,256 bytes, four duplicated evidence files; `cc6a72cf312b44b698b474330909e9da`. `startup-host-context-d2037af-warm02.json` retains exact prerequisites/truthful shared-host context. |
| warm03 | `before.root-boot-policy` bounded stderr proves `ValueError: Invalid or duplicate GRUB environment variable`; offending guest bytes unproven. FINAL/`startup-attempt-warm03-summary.json`: 11 files/2,706,700 bytes; `4f6364e98aec411cacd3ea673e04f551`. Exact E/`startup-controlled-harness/attempt-d2037af-warm-03` copy recorded by durable-root `startup-warm03-emergency-copy.json`. |
| warm04 | Initial snapshot/root policy, packaged reconciliation/readiness validation passed. Parent saw black background/pointer only, could not verify Welcome dialog, returned null: `explicit-observe`, no input. Failed `review-action` before SSH fixture/warm-up/measured boots; cause unknown, no product-regression proof. FINAL/`startup-attempt-warm04-summary.json`: 16 files/2,736,770 bytes; exact `startup-controlled-harness/attempt-d2037af-warm-04`; `e9114b0a47bf45418ee25de82abb4804`. Summary/frame SHA-256 identities are in validation. |

All source/helper/bound inputs remained unchanged. Warm02/03 stopped before reconciliation/Welcome/SSH
fixture/warm-up; warm02–04 dependencies/staging cleanup passed, no candidate transferred.
FINAL/`grub-environment-format-probe.json` reproduces old-parser rejection of Fedora
`grub2-tools-minimal-1:2.12-66.fc44.x86_64`'s standard warning, not specific guest offending bytes or
warm02's cause. Validation owns full stage/privacy/provenance and R30 retention scope.

Pixel/readiness acceptance is blocked and comparison/performance unavailable. A future separately scoped
benchmark must visibly verify Welcome/portals, revalidate current exact prerequisites and collect eight
fresh equivalent boots: distinct boot IDs/auth sequences, six bound diagnostic/frame samples, SDK82/full
configuration equivalence and root GRUB evidence. Preserve strict privacy/authentication/configuration
guards; label host-cache-warm QEMU readiness upper bounds including auth/probe/UI delays, no
cold-boot/causal-speedup claim. GRUB/binfmt/portal grace unchanged.

Representative physical lid/mirrors/docks/two externals/connector ambiguity/scaling/rotation and Secure
Boot, generic negotiated CSD, first-frame/new-artifact pointer/unsampled assistive interaction and full
native notification edges remain unqualified. User may `git pull --ff-only` then `./install` for
own-machine testing; no completed user-machine test or agent rollout is claimed.

## Cleanup and final documentation

V/`parent-lease-final-cleanup.json`: MAIN lease `29c5e2febb054008b06ff08cd794e589` released at
`2026-10-21T16:33:05Z`, return 0, closed/remaining empty/errors empty, workspace absent; idle container
`6d814bcad464`, network and workspace removed. V/`final-resource-verification.json`: all 53 recorded
CybexOS leases closed, no task QEMU/developer Quickshell/mounts/MAIN containers, shared services untouched;
no temporary VM/container retained. Ordinary documentation worktree remains until protected PR merge,
then Git removal. This documentation update is separate from tested d2037af artifacts.

Own b4/75 and baseline 3b roots/PXE copies were removed after archival. Baseline cleanup removed
17 files/10,088,530,860 bytes plus PXE ISO 8,027,873,280 bytes/112-byte sidecar after 11 metadata hash
checks. V/`baseline-final-cleanup.json` and `pxe-after-baseline-removal.json`: iVentoy refresh success,
PXE running/service active, candidate present/baseline absent, no restart.

V/`retained-inventory-cleanup-snapshot.json` records artifacts 18 files/10,123,452,292 bytes, requested
PXE ISO 8,063,483,904 bytes/112-byte sidecar and V archive 1,774 files/274,027,350 bytes. Reasons and
exact paths are in validation. This cleanup-time snapshot excludes itself and later docs/review/PR
records; final handoff recomputes totals. No completed user-machine test is claimed. Active desktop
rollout/restart/reboot and public release remain unauthorized/unperformed.
