# Desktop improvements implementation ledger

Work is isolated on `feat/desktop-improvements-20261021`, starting from
`3b310d106255558ca213c955ef37ee314e8681f2`. The original main checkout remains
clean at `6f4bdca3168d46cc76e8047fa94d172dac3cb696`. No active desktop rollout,
reboot, main merge or public release is authorized or performed.

## Ownership and implementation status

Actual T3 Codex delegates implemented disjoint compositor, desktop UI,
notification and native-titlebar scopes. Fresh independent Codex tasks reviewed
integration and each correction set. Returned selections were verified as
`codex/gpt-6.1-sol`, `reasoningEffort=xhigh`, `serviceTier=priority`. Concurrency
never exceeds four including the parent. The parent owns shared schema 29,
English/Dutch strings, package/installation parity, native integration,
qualification and cleanup.

| Area | Implementation | Qualification |
| --- | --- | --- |
| Shared / Per-monitor workspaces | Complete | Source and isolated native checks pass; physical hardware matrix blocked. |
| Tiled / Scrolling / Floating | Complete | Actual qualified compositor, grouped ownership, placement, minimize and reload checks pass. |
| Floating titlebars | Complete | Fedora build, pointer controls, theme refresh and incompatible-build rejection pass; generic Wayland CSD detection blocked. |
| Notification refinements | Complete | Actual D-Bus actions, replacements, image identity, origins, privacy/restart and repeated output/fullscreen lifecycle checks pass. |
| Installation integration | Complete | Exact-source parity checks pass; final installed ISO/checkout and upgrade qualification in progress. |
| Startup | Evidence tooling and investigation complete | No optimization or speedup claimed. Installed diagnostics do not yet establish comparable observed readiness. |

## Authoritative workspace contract

`require("workspaces")` owns physical monitor identity, assignments, layout and
minimize state. Preferences live in user-owned
`$XDG_CONFIG_HOME/cybexos/workspaces.json`; assignments live under
`$XDG_STATE_HOME/cybexos`; the bounded runtime snapshot is
`$XDG_RUNTIME_DIR/cybexos/workspaces.json`, schema `v:1`.

Snapshot monitor rows contain name, identity, label, activeWorkspace and ordered
workspace **ID arrays**. Workspace rows include localNumber, monitor, layout,
guest, ownerIdentity, layoutOverride, layoutManaged and nativeLayout. The root
includes defaultLayoutManaged and nativeDefaultLayout. Minimized rows preserve
address, original workspace and monitor. The UI consumes this mapping and never
allocates IDs or invents monitor identity. Missing snapshots fall back to Shared
behavior. Disconnected workspaces retain their unique IDs and remain reachable
as guests; there is no transition renumbering or merging.

Public operations are `focus(localNumber,monitorName)`,
`move(address,localNumber,monitorName)`, `focus_id(id)`, `move_id(address,id)`,
`next(direction,monitorName)`, `new_workspace(monitorName)`, `set_mode(mode)`,
`set_default_layout(layout)`, `set_layout(id,layout)`, `cycle_layout(id)`,
`minimize(address)`, `restore(address)`, `activate(address)` and
`move_monitor(direction,address)`. Optional address/monitor arguments use the
focused window/monitor; all input and live destinations are validated.

Shared remains the first-install and existing-user default. No preference file
means `manageDefaultLayout:false`: the effective native layout, including
user.lua overrides, is retained. Only deliberate default selection takes global
ownership. Explicit per-workspace choices persist even when equal to the
default; `set_layout(id,"default")` alone clears an override. Unknown native
layouts display as Custom/Unmanaged and are never sent back as setter values.
Workspace preferences are not duplicated in shell.json. Existing dock opt-outs,
Slack Super+M and lock Super+L remain intact. See [controls](desktop-workspaces.md).

## Provenance and dependencies

- Omarchy `v4.5.0-rc1`: `03ff1eff3812933f7088484533784d2f63eaf19a`.
- Titlebars `v0.2.2`: `379ff910fcce9f0cc9b41f9a87c527997076a417`, with both
  required licenses and reviewed native patch. Installed at
  `/usr/lib64/cybexos/titlebars.so`.
- Qualified Fedora Hyprland `0.56.2-2.fc44.x86_64`, source
  `efb50993780079460b0cbed1363e2166a2de1d9f`, executable ELF ID
  `04b20094d13879e70824418ba363f8dcc3253b34`; Quickshell
  `0.2.1^git20260209.dacfa9d-5.fc44`.
- Declarative plugin load is registered on every config parse; only rendering
  follows Floating mode. Native APIs are used only after registry confirmation.
  Exact SDK/RPM identity, cached source, offline rebuild and the running ELF
  guard prevent loading an Arch or stale Fedora binary.

## Review and revision evidence

Product commits: `66b14a2` initial implementation; `c5b5c96` ownership/origin/
startup/native guard corrections; `9702355` native toast lifecycle fix;
`629219f` offline input admission; `63f7785` constrained package audit;
`78903e9` verified offline qualification dependency transport (tooling only);
`b4dfdf6` titlebar availability/render separation; `00f71b4` fresh-candidate
release-gate dependency binding (tooling only).

R1 found five issues; R2 found four; all were corrected with focused regressions
and affected native retesting. Fresh R3/R4 reviews found no remaining actionable
findings in their correction scopes. R5 independently proved the offline
manifest admission regression; R6 verified constrained package normalization
without weakening RPM/source/native minimums. Native tests additionally fixed
Hyprland ECHILD handling, recursive declarative plugin registration, nonempty
float-exclusion serialization and toast native-screen binding feedback.

Exact product revision `b4dfdf68cc324e4b209294b4d9bbafa73357cfa8` passes all 17
source stages: 1,440 Node tests, 46 Python suites, 355 QML files/four harnesses,
actual native Qt and lifecycle cases, and 178 compositor assertions plus XPS/
hotplug/margin fixtures. Image source checks pass 30 application tests, 538 image
fixtures (three existing skips) and 14 installer Node tests. These checks ran in
a real Git clone of that commit in Fedora, not an unversioned copied tree.
Qualification-tooling commit 00f71b4 also passes all 17 stages and 554 image
fixtures with the same three skips. Its changes do not alter the installed
payload.

The exact 63f7785 ISO/RPM set completed build and signed-package audits and was
published to testing PXE with checksum and iVentoy verification. All four
plain/encrypted English/Dutch installation scenarios passed. Its checkout run
failed downloading the pinned OPPO font archive (TLS handshake timeout), which
remains recorded. Visual review caught a titlebar availability warning when the
component was loaded but no Floating workspace was active. The b4dfdf6 fix
passes a clean independent R9 review (plus four reviewer failure/recovery
probes). A clean b4dfdf6 ISO/RPM set is now built and published with verified
checksum/iVentoy checks. All four final installed scenarios pass, including saved-choice lifecycle, and encrypted authentication/keyring recovery. The Dutch checkout completed but failed parity: unsupported localectl show falls back to US keyboard despite the Dutch selection; the same discovery bug exists in the baseline. A checkout correction and exact-source retest are required. Offline-upgrade validation remains in progress. Final artifact identity is in the validation report.

An actual baseline 3b310d1 install passed installed/application audits, but the
earlier 629219f two-RPM offline upgrade failed because new Fedora SDK dependencies
were unavailable with all repositories disabled. That failure is preserved.
78903e9 adds a bounded, artifact-bound dependency fixture and one offline
transaction after recovery creation. Independent R7 found account-writable
staging could race verification; fresh root-owned copies now protect both
candidates and dependencies through DNF. Fresh R8 found no actionable issues
(71 targeted tests). 00f71b4 additionally snapshots optional release-gate raw
inputs before building and binds them to the actual new candidate hashes.
Independent R10 found no actionable issues (38 scoped tests plus eight
adversarial fixtures). The final 82-RPM fixture was reverified for metadata,
checksums and installed Fedora trust-key signatures, then bound to both final
RPMs and the original baseline ISO. Actual upgrade/native rebuild/recovery
testing is running; requirements were not weakened and dependencies were not
preinstalled.

Earlier baseline startup probes failed before collecting UI frames; these are
diagnostics, not readiness samples. A separate final observation helper retains
bounded redacted errors and fixed-path privileged hashes. Four independent
helper rounds corrected JSON type equality, output argument validation and stat
error handling. Actual 63f7785 observations subsequently exposed launcher
dismissal and portal lifecycle problems in that helper; those failures remain
preserved. Its final b4dfdf6 copy now passes fresh R6 review, 61 inert tests and
18 independent portal-race fixtures, with exact revision guards. The actual final encrypted observation passed inventory/root hashes, launcher dismissal and normal-shell restoration, but file Escape returned error 2 and ScreenCast stalled at SelectSources with unresolved cleanup. Pinned backend source confirms the observer incorrectly expected the source picker only during Start; GTK dialog-close also differs from explicit Cancel. Those failures remain preserved and cannot establish readiness. Equivalent three-boot comparisons and speedup remain unqualified.

## Resources and remaining gates

All temporary workloads use agent-resource. The isolated native GPU VM lease
`6494f7f7250b4f8da62baee029cbfa9b` is closed and verified empty. Diagnostic
installed VM lease `de986d746416429ca45ea8de98b34100` is closed and verified empty;
its temporary SSH fixture was restored before teardown. Parent lease
`29c5e2febb054008b06ff08cd794e589` owns the Fedora container/helpers/evidence;
image build lease `4b9db6f753b34936b2fc593393f7ce97` is closed and verified empty.
Installed qualification runs use separate supervised leases. Temporary
upstream checkouts were removed after recording provenance.

Remaining work: checkout keyboard discovery/variant correction, fresh review
and exact-source artifact rebuild/requalification; final checkout parity;
verified offline upgrade/rebuild/recovery,
startup observations, final evidence consolidation and resource cleanup. Generic
Wayland CSD detection needs a supported compositor API. Physical lid/mirror/
dock/two-external/connector-identity tests require representative hardware.
These are explicit acceptance limits, not waived gates. See
[validation](desktop-validation.md), [startup](desktop-startup.md),
[titlebars](native-titlebars.md) and [notifications](desktop-notifications.md).
