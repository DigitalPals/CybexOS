# Desktop improvement qualification

This report separates source checks, isolated native runtime evidence, and
installed-product/hardware acceptance. It does not qualify a release merely
because fixtures pass. Starting revision:
`3b310d106255558ca213c955ef37ee314e8681f2`. Initial integrated implementation:
`66b14a22dcc691851ed5ba87c57d88c7f98df8ef`. Reviewed correction set:
`c5b5c96d284654bf9eb31766aaff09b098fbb574`. The latest built desktop payload is
`b4dfdf68cc324e4b209294b4d9bbafa73357cfa8`; subsequent commit
`00f71b4b66bf740798d90384a21cff35fed29feb` changes qualification tooling,
tests and release documentation only. The real Dutch checkout test then found
an unsupported keyboard-discovery command. The checkout correction is under
review and requires a new exact-source artifact and installation cycle; b4dfdf6
results below are historical evidence, not acceptance of that correction.

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
| Integrated source/image gates | Passed | Exact b4dfdf6: all 17 source stages, 1,440 Node tests, 46 Python suites, 355 QML files/four harnesses and 178 compositor assertions; image gate 30 application tests, 538 image fixtures (three existing skips), 14 installer Node checks. Native Qt image tests and lifecycle fixtures pass. Qualification-tooling commit 00f71b4 also passes all 17 stages and 554 image fixtures, with the same three skips. |
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
| Installation parity fixtures | Passed | Shared role/image recipes, payload/deployment fixtures, schema migrations and uninstall contracts pass source checks. End-to-end checkout results are recorded separately. |
| Generic Wayland CSD avoidance | Blocked | Qualified compositor has no supported public negotiated-decoration query. Exact Nautilus/Text Editor exclusions work as policy; arbitrary GTK/Firefox/Electron decoration combinations need supported native work and mixed-client qualification. See native-titlebars.md. |
| Physical display matrix | Blocked | No authorized representative laptop/docks/physical displays are attached. Actual lid, mirrors, connector changes, duplicate-monitor reconnect and physical fractional scaling need that hardware. Synthetic fixtures do not replace it. |
| Installed-product startup | Blocked | No equivalent baseline/candidate installed boot samples yet. Capture/comparison tooling is implemented, with no speedup claimed or speculative boot-policy changes. See desktop-startup.md. |
| Same-revision RPM/ISO build | Passed | Clean b4dfdf6 ISO/RPM set built, checksum verified and published to testing PXE; iVentoy refresh/list/PXE/service checks pass. Build provenance and exact checksum are below. |
| Final ISO installation matrix | Passed | All four b4dfdf6 plain/encrypted English/Dutch scenarios passed graphical installation, installed boot, locale/security, saved-choice reconfiguration and native settings lifecycle. Encrypted cases also passed keyring cold-reboot, logout/crash/manager-restart authentication and failed-autologin recovery. |
| End-to-end checkout parity | Failed | b4dfdf6 English checkout passed fresh/saved outcome parity, graphical boot and native lifecycle. Dutch checkout completed installation and matched packages and other captured contracts, but keyboard layout was US instead of the selected Dutch layout. Unsupported localectl show discovery also exists in the baseline; it must be fixed in the checkout path and retested. No difference was auto-approved. |
| Offline upgrade/rebuild/recovery | Pending | Exact baseline and both final RPMs are bound to a verified 82-RPM Fedora dependency fixture. The original missing-dependency failure is preserved. A diagnosed retry completed upgrade/reconciliation and forced native compilation, then its external assertion rejected CMake output preceding the final CHANGED line. The corrected retry has passed actual rebuild and unchanged convergence. Candidate boot and recovery remain unqualified until it finishes. |

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

R5/R6 reviewed the offline-manifest and constrained-package corrections without
finding a remaining defect. R7 found that the ordinary guest account could
replace verified RPM staging; fresh root-owned copies now protect both
first-party RPMs and dependencies through DNF. R8 independently passed 71
targeted fixtures with no actionable findings. R9 reviewed the installed
titlebar-availability correction: 178 behavioral assertions plus four additional
failure/recovery probes passed. R10 reviewed the optional release-gate fixture
snapshot/binding path with no actionable findings (38 scoped tests plus eight
adversarial fixtures). R11 found two external qualification-wrapper defects: shutdown exception
conversion and watcher restoration after partial stop failure. Both were fixed;
fresh R12 passed 45 inert probes with no actionable findings. R13 found that
keyboard discovery could carry a layout-specific variant into a changed layout;
changed layouts now reset the offered variant and an explicit empty choice is
available. Twenty-one parity, 16 reconfiguration and eight application fixtures
pass; fresh R14 review is pending. These reviews establish
their stated scopes, not live upgrade or installation acceptance.

## Latest built artifact identity

The ISO is `/data/pxe/iso/CybexOS-Live-44-20261021T093227Z-1d8dc20c.iso`:

```text
5f2f91cd99acc2a002b153fded8c116861e1bde371f82440ec916450714224d0
```

Build provenance records clean source b4dfdf6 and source-content digest
`7a6d9ce79054932b06cc72db5aa6c43d64f284bef62c7b3676658328c395cb20`.
Desktop RPM SHA-256:
`f7bcb1f372afbef1f65f75c9ea8d634fc9ea1580146e32806102494a3d4a3ca7`;
offline-apps RPM SHA-256:
`475b8f9fdd260f733f7cbb7e2e9e2436833180d1f1eea2441eb36b4fbf36a282`.
Artifacts and bounded review evidence are retained under
`~/.local/share/cybexos/images/desktop-20261021-b4dfdf6/`.

The offline dependency manifest digest is
`c9af9312527864e3b636f5da040fae1a8b09d6bd3a192b51e23eb83c5667ab42`.
It binds the original 3b310d1 baseline ISO and both final RPMs to 82 unchanged
Fedora downloads (40,923,680 bytes). Actual RPM metadata, file hashes and
signatures were reverified against Fedora's installed trust keys. Guest
verification and the live transaction remain separate checks; no dependencies
were preinstalled to hide the original solver failure.

## Remaining qualification

The native toast binding loop is corrected and journal-clean retesting passes.
Installed visual review of 63f7785 found a false titlebar-unavailable warning
when the native component was loaded but hidden in Tiled mode; b4dfdf6 corrects
availability/render separation. Its four installed scenarios pass; fresh and saved snapshots report titlebars=true, scrolling=true and an empty error, and reviewed English/Dutch settings frames no longer show the false warning. The notification top/style controls were visually reviewed; the attempted advanced-settings capture did not scroll to the lower controls, so those pixels remain unreviewed.
The c5b5c96 build was stopped before publication after the toast defect; its
lease was released and verified empty. The baseline's initial OpenH264 metadata
HTTP 404 was retried with the original repository/checksum/signature policy;
the successful baseline is used for upgrade testing.

Representative hardware must exercise lid/mirrors, two
physical externals, connector/identity ambiguity and mixed CSD applications.
Installed baseline/candidate startup evidence requires at least three equivalent
boots each, actual launcher and portal/file-picker/screen-sharing observations,
and separate authentication, cold/warm and first/normal-login accounting.
No active user desktop was deployed, restarted or rebooted for this task.
