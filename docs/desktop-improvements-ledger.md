# Desktop improvements implementation ledger

Starting revision: `3b310d106255558ca213c955ef37ee314e8681f2` (current origin/main,
2026-10-21). The original main checkout remains at
`6f4bdca3168d46cc76e8047fa94d172dac3cb696`. Work is isolated on
`feat/desktop-improvements-20261021`; no active desktop rollout or reboot is
authorized. Final tested revision and evidence will be recorded below.

## Ownership and interfaces

- Workspace/compositor agent: `roles/desktop/files/workspaces.lua`,
  `bindings.lua`, `hyprland.lua`, `roles/desktop/templates/monitors.lua.j2`,
  workspace/layout behavioral tests, and `docs/desktop-workspace-architecture.md`.
- Desktop UI agent: workspace singleton and pure UI helpers, bar, overview,
  dock, launcher workspace consumers, workspace settings UI, and
  `docs/desktop-workspaces.md`. No shared settings schema or translation edits.
- Notifications agent: existing notification service and UI, notification
  persistence helper, behavioral tests, and `docs/desktop-notifications.md`.
  No shared settings schema or translation edits.
- Lead: shared settings schema, translations, deployment/package integration,
  startup analysis and measurement tooling, installation parity, integration,
  and independent Codex review/qualification.

One compositor-owned module, `require("workspaces")`, owns monitor identity,
mapping, layout and minimize state. Its bounded runtime JSON snapshot is
`$XDG_RUNTIME_DIR/cybexos/workspaces.json`, schema `v:1`, with `mode`,
`defaultLayout`, `monitors` (name, identity, label, activeWorkspace, workspaces),
`workspaces` (id, localNumber, monitor, label, layout, guest, ownerIdentity), and `minimized`
(address, workspace, monitor) arrays. The UI reads this snapshot and never
allocates IDs or independently computes physical identity. Missing snapshots
fall back to existing shared workspace behavior.

Public operations: `focus(localNumber, monitorName)`,
`move(address, localNumber, monitorName)`, `focus_id(id)`,
`move_id(address, id)`, `next(direction, monitorName)`,
`new_workspace(monitorName)`, `set_mode(mode)`,
`set_default_layout(layout)`, `set_layout(id, layout)`, `cycle_layout(id)`,
`minimize(address)`, `restore(address)`, `activate(address)`, and
`move_monitor(direction, address)`. Optional address/monitor arguments select
the focused window/monitor; implementations validate all inputs. UI command
builders quote constrained values and check window existence before dispatch.

Shared defaults: `mode: "shared"`, `titlebarsEnabled: true`. With no
preference file, `manageDefaultLayout:false` preserves the effective native
layout (normally dwindle, including explicit user.lua overrides). Only a
deliberate default-layout selection takes ownership in workspaces.json;
these are deliberately not duplicated in shell.json. Existing dock preferences
stay unchanged. Existing users keep Shared mode.
Layout IDs are `dwindle`, `scrolling`, `floating`. Native scrolling and
decoration support must be checked against the qualified Hyprland build;
unavailable dependencies are explicit qualification blockers.

Notification setting additions are defined in docs/desktop-notifications.md and integrated in shell schema 29. Persistence defaults off. All new
UI strings are returned for English/Dutch integration by the lead.

## Progress and evidence

- Discovery: clean base and remote verified; applicable AGENTS.md read.
- Pinned Omarchy reference checkout: `/tmp/cybexos-desktop-20261021-upstream`
  at tag `v4.5.0-rc1`, revision `03ff1eff3812933f7088484533784d2f63eaf19a`.
- Three actual Codex tasks implemented compositor, desktop UI and
  notifications with explicit disjoint ownership. A fourth native packaging
  task and four fresh independent review rounds cover integration. All use the requested Codex
  provider and inherited gpt-6.1-sol/xhigh/priority selection.
- Baseline Fedora 44 source gate passed all 17 stages, including 1,380 Node
  checks and 43 Python fixtures. Image source gate also passed (519 image fixtures plus 27 application and 14 installer Node tests) after supplying the missing gvfs schema dependency. Initial container
  /root traversal permissions were corrected before the successful rerun;
  this was an environment setup issue, not a waived source failure.
- Runtime test packages: hyprland-0.56.2-2.fc44 and
  quickshell-0.2.1^git20260209.dacfa9d-5.fc44. Native scrolling is present.
- Titlebar reference tag v0.2.2 resolves to
  `379ff910fcce9f0cc9b41f9a87c527997076a417`; native ABI/CSD qualification
  and packaging are implemented with an exact Fedora ELF build-ID guard. Generic CSD detection remains blocked; see native-titlebars.md. Never load an Arch binary on Fedora.
- Implementation and source installation-parity checks pass. Native runtime
  and independent review are in progress; installed-image, physical hardware
  and startup qualification remain outstanding.

## Resources

Task-owned upstream checkout above is temporary and must be removed after
provenance findings are recorded. Host workloads require `agent-resource`;
the installed `ci-platform` CLI currently lists other projects and does not
offer a CybexOS job. Disposable Fedora container is owned by interactive lease
`29c5e2febb054008b06ff08cd794e589`, including all temporary test logs under its
workspace. Release and verify this lease before handoff. A second temporary
source checkout is `/tmp/cybexos-desktop-20261021-titlebars`; remove it too.

## Integration checkpoints

- Integrated Fedora source gate passed all 17 stages: 1,415 Node tests, 45
  Python fixtures, 354 QML files plus four harnesses, real-engine QML lifecycle
  checks, compositor behavioral fixtures, packaging and installation contracts.
  These are an intermediate source snapshot, not final-revision qualification.
- Managed isolated GPU VM uses Hyprland 0.56.2-2.fc44 (ELF build ID
  `04b20094d13879e70824418ba363f8dcc3253b34`) and Quickshell
  0.2.1^git20260209.dacfa9d-5.fc44. Actual tests passed Floating window launch,
  minimize metadata/special workspace, activation restore, Scrolling retiling,
  cross-monitor move, disconnected-owner guest reachability and three reloads.
- The isolated shell loads through quickshell.service. Its MainPID was the sole
  qs process and the current invocation passed tests/lib/quickshell-live journal
  checks. This VM is a provisioned Fedora Cloud fixture, not an installed
  CybexOS product or a representative physical device.
- Native tests found and fixed two issues hidden by mocks: Hyprland's SIGCHLD
  causes successful popen close to report ECHILD, and declarative plugin loads
  must remain stable on every config parse. The latter otherwise recursively
  loads/unloads/reloads and starves IPC. Stable declarations now pass reloads.
- Independent Codex review round 1 found five issues: explicit native layout
  overrides overwritten; opening float tags overriding manual tiling; Shared
  allocation colliding with named IDs; positive-ID named UI routing; and unique
  qsimage handles preventing identical image-content deduplication. All five are fixed with focused regressions; round 2 is reviewing the
  integrated implementation. A later full-config native run also found/fixed
  nonempty floating-exclusion signature encoding (147 compositor assertions).
- No startup speedup is claimed. Read-only capture/comparison tooling and
  GRUB/binfmt/session-ordering source analysis are implemented; installed-system
  boot/unlock/portal/screensharing/recovery measurements remain outstanding.
- Second supervised resource lease `6494f7f7250b4f8da62baee029cbfa9b` owns the
  GPU VM and all of its private disk/key/media. Stop via the parent lease's
  native-vm-stop file, wait for supervisor exit, then check absence at handoff.

- Final integrated working-tree source gate passed all 17 stages: 1,426 Node
  tests, 46 Python fixtures, 355 QML files and four harnesses. QML lint builds
  the real native image module in scratch and runs its 11 Qt cases first.
  Image source gate passed 27 application tests, 520 image tests (three existing
  skips) and 14 installer Node tests. These are source gates, not an installed
  product qualification.
- Full generated compositor config native review checks pass: nonempty app
  float exclusions, unmanaged master preservation through mode/titlebar edits,
  workspace override/reset/cycle, new Floating window manually tiled through
  refresh/reload, positive-ID named navigation, deliberate default ownership
  and three stable plugin reloads. configerrors and snapshot.error are empty.

- R2 corrections preserve explicit layout ownership (`layoutOverride`), apply
  manual float ownership to all group members, separate website scheme/port
  identities, and reject startup kernel/dependency drift. Actual group and
  origin regressions pass. A properly recompiled incompatible titlebar plugin
  fails its running ELF guard without changing the good plugin registry or
  APIs; the guard now precedes shared handle assignment. Fresh R3 review of
  c5b5c96 completed without actionable findings (62 Node, four startup, 161 Lua
  checks and native optimized guard isolation).

- Native grouped-toast/output lifecycle testing found a screenGroups binding
  loop despite passing visible behavior assertions. Notification owner is
  correcting it; the journal failure is not waived. Stopped the superseded
  c5b5c96 ISO build and verified lease 61012ebf5d4b48778778691793472495 closed
  with no remaining resources. No ISO was published from that attempt.
- Baseline image build uses exact 3b310d1 in a disposable local clone, owned by
  supervised lease 51e5828e0d7c4684b99d264e531b1ac7. Build cache, disks and media
  are private to that lease. This prepares installed startup evidence; it does
  not establish a measured speedup.
- Native experiment isolated the remaining toast cycle: screenGroups used the
  live PanelWindow screen, while screenGroups also controlled visibility.
  Using the authoritative Variants output model passed a full D-Bus matrix
  and three fullscreen/output lifecycle matrices with clean invocation
  journals. Product correction and fresh independent review are in progress.
- Final product source (not just the diagnostic experiment) now passes the
  full actual D-Bus matrix plus three repeated grouped-burst/fullscreen/output
  create/disconnect matrices, with invocation journals clean after each. Normal
  product shell and sole service-owned qs were restored. Fresh R4 review and
  full source/image gates precede the candidate rebuild.
- Independent R4 review of the final toast correction found no actionable
  correctness/security findings, with 53 focused Node checks, packaging-path
  inspection and read-only final native journal inspection. Full source/image
  gates are rerunning in the configured Fedora container account. An earlier
  invocation used an absent UID and is excluded as an invalid environment run.
- Final toast correction passes all 17 Fedora source stages (1,440 Node tests,
  46 Python fixtures, 355 QML files/four harnesses, actual Qt/runtime fixtures)
  and image source parity (27 application, 520 image with three existing skips,
  14 installer Node checks). R4 is clean.
- Baseline build reached desktop/offline RPM creation; compose failed on an
  official Fedora OpenH264 metadata HTTP 404. Lease 51e5828e0d7c4684b99d264e531b1ac7
  closed cleanly. The endpoint subsequently returned HTTP 200 with exactly the
  checksum advertised by MirrorManager, so the unchanged build can be retried.
