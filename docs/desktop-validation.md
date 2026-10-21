# Desktop improvement qualification

This report separates source checks, isolated native runtime evidence, and
installed-product/hardware acceptance. It does not qualify a release merely
because fixtures pass. Starting revision:
`3b310d106255558ca213c955ef37ee314e8681f2`. Initial integrated implementation:
`66b14a22dcc691851ed5ba87c57d88c7f98df8ef`. Reviewed correction set:
`c5b5c96d284654bf9eb31766aaff09b098fbb574`. Later runtime corrections and
artifact qualification revisions are recorded below as they finish.

## Environment and passed evidence

Disposable Fedora 44 container and KVM GPU fixture: Hyprland
`0.56.2-2.fc44.x86_64`, source `efb50993780079460b0cbed1363e2166a2de1d9f`,
executable ELF build ID `04b20094d13879e70824418ba363f8dcc3253b34`;
Quickshell `0.2.1^git20260209.dacfa9d-5.fc44`. GPU rendering uses llvmpipe,
virtio-vga and disposable virtual outputs. This is a configured Fedora Cloud
fixture, not an ISO-installed CybexOS machine or physical display qualification.

| Acceptance area | Status | Evidence and limit |
| --- | --- | --- |
| Baseline source/image gates | Passed | Exact base: 17 source stages, 1,380 Node checks, 43 Python fixtures; image gate 27 application, 519 image and 14 installer Node checks. |
| Integrated source/image gates | Passed | Final toast correction: all 17 source stages; 1,440 Node tests, 46 Python fixtures, 355 QML files and four harnesses; image gate 27 application, 520 image tests (three existing skips), 14 installer Node checks. Native Qt image tests and lifecycle fixtures pass. Exact source revision recorded with artifact results. |
| Native dependencies | Passed | Actual pinned Fedora titlebar compilation, offline rebuild convergence, payload admission and executable build-ID mismatch probe. Native notification image module compiles, loads in real QML, and passes 11 public-provider cases. |
| Workspace mapping and layouts | Passed | Behavioral fixtures cover identity ambiguity/collisions/full slots, XPS policies, modes, gestures, assignments and margins. Native checks cover Floating/Scrolling/Tiled, minimize/restore, cross-output move, guest reachability and reload. |
| User layout ownership | Passed | Full generated config with user.lua master and no preferences preserves master through mode/titlebar edits. Explicit override/reset/cycle and deliberate managed-default selection pass. |
| Groups and explicit layouts | Passed | R2 native regression: grouped manual tiling survives refresh/reload; minimize/restore preserves both members. Explicit equal-default Tiled remains selected when global default changes; Default clears it. |
| Floating titlebars | Passed | Actual pointer maximize/restore, drag, minimize/restore and close; theme clear/re-add works without config errors. Stable declarative plugin loads pass repeated reloads. |
| Scaled/rotated output | Passed | Native 1600×1000 virtual output, scale 1.25, rotation 90°: floating geometry remains inside usable bounds; disconnect retains reachable guest workspace. Physical placement remains unqualified. |
| Notifications over D-Bus | Passed | Identical text/image content deduplicates; different bodies/images/sources remain separate. Replacements retain one slot/count. Actual sender ActionInvoked succeeds. Snooze/DND arrivals stay in history without replay. |
| Notification restart/privacy | Passed | Actual shell restart restores inert history without code/link/live actions; persisted verification code is redacted. Dynamic image URLs/fingerprints are absent from stored history. |
| Grouped toast output lifecycle | Passed | Final product source passed the full actual D-Bus matrix and three grouped-burst/fullscreen/output-create/output-disconnect matrices, with clean invocation journals after each. Selection uses the authoritative output model; deferred owner/focus claims avoid reactive teardown writes. Normal product shell restored and service MainPID is the sole qs PID. |
| Shell lifecycle | Passed | Tests use quickshell.service; its MainPID is the sole qs PID; tests/lib/quickshell-live checks the current invocation journal after restoring product shell source. |
| Installation parity | Passed | Shared role/image recipes, payload/deployment fixtures, schema migrations and uninstall contracts pass source checks. This does not establish an end-to-end install. |
| Generic Wayland CSD avoidance | Blocked | Qualified compositor has no supported public negotiated-decoration query. Exact Nautilus/Text Editor exclusions work as policy; arbitrary GTK/Firefox/Electron decoration combinations need supported native work and mixed-client qualification. See native-titlebars.md. |
| Physical display matrix | Blocked | No authorized representative laptop/docks/physical displays are attached. Actual lid, mirrors, connector changes, duplicate-monitor reconnect and physical fractional scaling need that hardware. Synthetic fixtures do not replace it. |
| Installed-product startup | Blocked | No equivalent baseline/candidate installed boot samples yet. Capture/comparison tooling is implemented, with no speedup claimed or speculative boot-policy changes. See desktop-startup.md. |
| Same-revision RPM/ISO install | Pending | Build and end-to-end qualification follow final code review. Older served ISOs are unrelated revisions and provide no acceptance evidence. |

## Independent Codex review

All delegated implementation and review used the live T3 Codex provider,
`gpt-6.1-sol`, `reasoningEffort=xhigh`, `serviceTier=priority`; each independent
review was a fresh delegated task. Implementers did not review their own work
as the sole reviewer.

Round 1 found five defects: native custom layouts overwritten, manual tiling
undone by opening tags, named ID allocation collisions, positive-ID named UI
routing, and image-handle deduplication. All were corrected with regressions.
Actual full-config native testing additionally found strict JSON encoding of
nonempty floating exclusions and corrected it without weakening validation.

Round 2 reviewed `66b14a2` and found four P2 edge cases: group toggle ownership,
explicit layout inheritance, website origin/port source collisions, and startup
comparison dependency drift. All four are corrected with regression coverage; fresh round 3 independently reviewed c5b5c96 with no actionable findings
(62 Node checks, four startup fixtures, 161 Lua assertions and the optimized
native guard/unchanged-handle probe). This predates the toast binding loop
found by a later native output-lifecycle test. Actual compositor tests cover the group/override fixes, and
actual D-Bus tests confirm effective-port equivalence and source/snooze
separation. A recompiled mismatched native plugin is rejected while the
original loaded registry and button/theme API remain functional. Its 43 focused Node checks passed; it found no additional defect
in native image identity or its installation wiring.

Round 4 reviewed the final toast lifecycle correction over c5b5c96 with no
actionable findings. It independently passed 53 focused Node checks and
whitespace validation, verified recursive packaging of the new JS helper, and
read the final native journal window without finding toast binding loops. The
parent production-source run passed the actual D-Bus matrix and three output/
fullscreen matrices with journal checks after each. Source tests exercise both
owner/focus churn and the production output-selection expression; no native
window-screen dependency is allowed in the latter.

## Remaining qualification

The native toast binding loop is corrected and journal-clean retesting passes;
complete exact-source image build/install. The final source and image gates
passed in the configured Fedora container. The c5b5c96 image build was stopped
before publication when this runtime defect was found; its supervised lease
was released and verified empty. An exact 3b310d1 baseline build reached RPM creation, then compose failed
when the official Fedora OpenH264 metadata endpoint returned HTTP 404. A later
fetch returned HTTP 200 and matched the checksum advertised by Fedora
MirrorManager. Retry keeps the original repository/signature policy. Representative hardware must exercise lid/mirrors, two
physical externals, connector/identity ambiguity and mixed CSD applications.
Installed baseline/candidate startup evidence requires at least three equivalent
boots each, actual launcher and portal/file-picker/screen-sharing observations,
and separate authentication, cold/warm and first/normal-login accounting.
No active user desktop was deployed, restarted or rebooted for this task.
