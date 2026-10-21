# Native Fedora titlebars

The exact tested product revision is
`d2037af92cb3a47a08a9755e5996d2c4b0cae28d`; source/image gates, the exact-source
ISO/RPM build and testing PXE publication pass. All four ISO scenarios, both
English/Dutch checkout parity cases, pristine offline/native/recovery and scoped
native workspace/notification checks pass. The core aggregate and R27 evidence
audit pass within their recorded scopes; English was verified separately by
the parent. The product is **not fully qualified**: startup measurement is blocked;
first-frame acceptance remains open, and representative hardware and generic
Wayland CSD detection remain blocked. This documentation update is separate
from the tested installed-product artifacts.
Main integration is complete at `bee9d722021301875823e6285a6eef2896b283eb`;
the intervening CI-only fix 9974aaee changes no installed-product payload.
The titlebar artifacts and installed qualification remain bound to d2037af.

The optional Floating layout titlebars are built from
`omacom/omarchy-hyprland-titlebars` tag `v0.2.2`, full commit
`379ff910fcce9f0cc9b41f9a87c527997076a417`. The authorized codeload archive
SHA-256 is `a453ae6b0a39f75e9a559a0258746e7df24a9432d5571ce505501cd0a333aa72`.
Inventory records all three values. No Arch binary is installed on Fedora.
The fixed library path is `/usr/lib64/cybexos/titlebars.so`; the native plugin
name and Lua namespace remain `hyprbars`.

`roles/desktop/tasks/titlebars.yml` and `image/titlebars` use the same source
pin, patch, native installer and rebuild units. The image builder stages a
complete build before assembling the desktop RPM. `image/titlebars_payload.py`
rejects missing builds, changed source/recipe/patch, damaged binary, source
archive or license files. The image's desktop RPM must require the exact
Hyprland EVR recorded in `titlebars.json`, so repository changes between native
build and image composition cannot silently select another compositor build.
Every released Hyprland update therefore needs a rebuilt desktop RPM from the
same source revision as its image and qualification report.

The native build requires CMake >=3.27, C++23, pkg-config `hyprland`, `libdrm`,
`libinput`, `libudev`, `pixman-1`, `wayland-server`, and `xkbcommon`. The Fedora
dependency task is also the image builder's dependency source. The upstream
`-fno-gnu-unique` option is retained for clean unload/reload; whole-library
hidden visibility is deliberately avoided because Hyprland shares inline state.
The original BSD-3-Clause `LICENSE` and Omarchy MIT `LICENSE.MIT` are installed
under `/usr/share/licenses/cybexos-titlebars/` on both paths.

## ABI and update lifecycle

`/usr/libexec/cybexos-titlebars-install` verifies identical installed Fedora
`hyprland` and `hyprland-devel` EVR/architecture, verifies their RPM-owned files,
and compares the headers' ABI string with the installed compositor's
`Hyprland --version` output. This version query does not start a compositor.
It records the binary digest, header version digest and GNU ELF build ID in
`/usr/lib64/cybexos/titlebars.json`, along with the verified source pin, recipe,
patch and output/license digests. Identical healthy builds converge offline;
damaged output or changed inputs require a rebuild.

The patch embeds that exact compositor ELF build ID. During plugin
initialization it reads the **running process's mapped ELF notes**, so replacing
`/usr/bin/Hyprland` during an update cannot fool an old compositor into loading
a plugin built for the new executable. Missing or different build IDs fail
before assigning the plugin handle or creating plugin state/event hooks.
Upstream's source/library ABI hash
check remains in place too. The ELF guard also detects Fedora rebuilds that
retain the same source commit and upstream API hash.

`cybexos-titlebars-build.path` watches the compositor, installed SDK identity and
managed recipe. `cybexos-titlebars-build.service` also checks at boot, rebuilding
from the checksum-verified cached source archive without network access. Builds
are locked, bounded to four compiler jobs and a 15-minute service timeout.
The service retries up to three times to cover an update transaction replacing
the binary and SDK separately. It never restarts the compositor or shell.
The native guard covers the interval before the asynchronous rebuild completes.

A stale binary/manifest is removed before rebuilding. Missing headers, a failed
compiler, invalid source, or a compositor update during compilation leaves the
optional component unavailable instead of retaining a stale loadable plugin.
The next successful build restores it. Existing keyboard and mouse controls
remain available. A plugin already mapped by a running compositor stays mapped
until its normal unload/session end; no updater forces live desktop changes.

Hyprland 0.56 Lua's `hl.plugin.load(path)` is a **configuration declaration**.
Keep it present on every config parse when the optional file exists, including
when the plugin is already in the native loaded registry. Omitting it on the
next parse removes a config-owned plugin, triggering another reload. Alternating
the declaration based on native loaded state causes recursive load/unload/reload
and starves IPC. Check `hl.get_loaded_plugins()` before invoking native options
and functions; use `enabled=false` to hide decorations outside Floating layouts.
An optional plugin can remain loaded while drawing no bars.

To inspect a failed rebuild, use
`journalctl -u cybexos-titlebars-build.service`. After repairing the matching SDK
or restoring cached source through checkout convergence, use
`sudo systemctl reset-failed cybexos-titlebars-build.service` and
`sudo systemctl start cybexos-titlebars-build.service`. The cached archive and
patch live in `/usr/share/cybexos/titlebars/`. Uninstall removes only these
managed files, the helper/units, build cache and fixed plugin/manifest/licenses;
user titlebar settings and independently installed plugins are user-owned.

## Theme API and client decorations

The CybexOS patch adds `hl.plugin.hyprbars.clear_buttons()`. It clears the native
button vector, marks every existing bar's buttons dirty and damages the bars.
The compositor theme hook can clear then add exactly three themed buttons
without accumulating duplicate hit targets or retaining old icon textures.
Upstream `add_button`, `workspace_tag` and explicit `hyprbars:no_bar` rules keep
their existing behavior.

**Generic automatic Wayland CSD detection is blocked on the inspected Hyprland
0.56.2 API.** `CWindow` exposes X11 border hints, but no negotiated per-window
Wayland decoration mode. `CXDGDecorationProtocol` keeps its toplevel-decoration
map private. The pinned `XDGDecoration.cpp` always configures server-side mode,
including when a client requests client-side mode. Clients such as GTK and
libadwaita applications can draw their own titlebars without using that protocol
at all. Absence of an xdg-decoration object consequently proves neither that a
client has a titlebar nor that it needs a server titlebar.

Use explicit `hyprbars:no_bar` class rules for applications known to draw CSD,
for example exact `org.gnome.Nautilus` and `org.gnome.TextEditor` classes.
Confirm the actual class with `hyprctl clients` before adding an exclusion;
Firefox and Electron classes/settings vary. Keep these exclusions in the shared
compositor configuration on both installation paths. This is an explicit class
policy, not automatic CSD detection. Native `decorate=false`, explicit no-bar
rules, upstream X11 border opt-outs and missing-component fallback remain
supported. A future automatic solution needs a supported compositor API or
protocol-aware compositor patch and real mixed-client qualification.

## Validation and scope

The native source pin and qualified Fedora compositor identity are unchanged:
Hyprland `0.56.2-2.fc44.x86_64` plus matching `hyprland-devel`, source
`efb50993780079460b0cbed1363e2166a2de1d9f`, executable ELF build ID
`04b20094d13879e70824418ba363f8dcc3253b34`. The exact d2037af ISO/RPM set is
built and published for testing; artifact paths, sizes, hashes and source
provenance are in [desktop validation](desktop-validation.md).

The exact pristine-upgrade fixture passed forced native compilation, one-line
unchanged convergence, candidate boot/runtime snapshot and recovery boot/restore. `native-offline-rebuild.json` in the recorded offline-upgrade evidence
binds the converged plugin SHA-256
`1142347ed31dcfb67733602b8ec6d88733131e0f8140ad8c3f50c870ef24e878`.
`native-candidate-runtime.json` confirms exact clean d2037af provenance, loaded
hyprbars, Scrolling/titlebar capabilities, empty error and a Floating workspace.
The separate exact-source native workspace report now passes renamed/numbered
opening, named/manual group provenance, original-owner closure, reload and
restoration. Those stable observations do not establish first-frame behavior
or requalify titlebar pointer controls on this artifact.

Historical isolated native tests passed compilation/offline convergence,
load/capability discovery, stable declarations/reloads, themed clear/re-add,
pointer drag/maximize/minimize/close and an actually recompiled wrong-build-ID
rejection. Those results retain their earlier product scope. Detailed native
failure/correction evidence, helper reviews, gate skips and resource history
are centralized in validation and the ledger.

`python3 tests/titlebars.py` covers CMake/C++ fixture builds, offline convergence
and repair, same-source Fedora rebuilds, checksum/traversal rejection,
compiler/SDK failures and concurrent updates. A release-optimized native probe
checks the running-executable ELF guard and unchanged handle state after
rejection. These and payload-parity/admission checks establish local contracts;
they do not complete installed-session or mixed-client/hardware qualification.

| Exact d2037af acceptance | Current status |
| --- | --- |
| ISO/RPM build and testing PXE publication | Passed; exact identities and publisher checks in validation |
| Installed forced native build/offline unchanged convergence, boot and recovery | Passed within the exact pristine-upgrade fixture; runtime evidence is the limited plugin/capability/Floating snapshot described above |
| Renamed opening and named/manual group lifecycle | Passed within the exact plain-US native fixture; stable observations, not first-frame/configure proof or a new titlebar pointer test |
| Settings pixels and remaining interaction coverage | Recorded encrypted-US settings/empty-overview frame review passed within scope; unsampled interactions, assistive technology and first-frame behavior remain unqualified |
| Generic negotiated Wayland CSD detection | Blocked on a supported qualified compositor API and mixed-client tests |
| Physical lid/dock/mirror/two-external/scaling placement | Blocked on representative hardware |

The exact-class no-bar policy and keyboard/overview fallback controls remain
supported. First-frame, new-artifact pointer and unavailable hardware/CSD
acceptance remain open; general duplicate-decoration avoidance must not be
advertised as complete. [PR #21](https://github.com/DigitalPals/CybexOS/pull/21)
merged at bee9d722 on `2026-10-21T14:01:19Z` after both required hosted checks
succeeded; origin/main was verified at that merge. The missing-`patch` CI
failure, exact sole-path correction and clean R28 review are recorded in
validation/ledger, separately from d2037af artifact qualification. Startup/pixel/performance measurement is **BLOCKED** after four failed attempts,
zero accepted samples/comparison. R11 is scoped inert tooling review only.
Warm04 passed root-policy/reconciliation validation but its Welcome frame
showed black background/pointer only; null review response sent no input.
Failure preceded SSH fixture/warm-up; cause unknown, no product-regression proof.
Warm02's cause and warm03's exact offending bytes remain unknown. All leases
closed/empty. No further VM series is planned; any future benchmark needs
visibly verified Welcome/portals, a reviewed retarget and eight fresh equivalent
boots with current prerequisites. Detailed identities and guards are in validation.
Validation records R30 scoped retention acceptance, both independently verified
R29 repairs and completed teardown: all 53 recorded leases closed, MAIN absent,
no temporary VM/container retained, shared services untouched. Baseline/intermediate
payloads were removed; final testing deliverables and bounded evidence remain.
Original evidence paths are historical identities resolved through durable maps;
R30 is not runtime/release acceptance. Its historical-source limits and cleanup-time
inventory snapshot are documented in validation.
Active user desktop rollout/restart/reboot and public release remain unauthorized.
