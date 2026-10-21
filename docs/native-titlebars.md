# Native Fedora titlebars

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
before plugin state/event hooks are created. Upstream's source/library ABI hash
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

## Validation

On 2026-10-21, the patched source built successfully against actual Fedora
`hyprland-0.56.2-2.fc44.x86_64` and matching `hyprland-devel`. Compositor source
commit: `efb50993780079460b0cbed1363e2166a2de1d9f`; ELF build ID:
`04b20094d13879e70824418ba363f8dcc3253b34`. A second offline invocation reported
unchanged. These builds used the parent's leased Fedora environment; no active
desktop was modified.

The parent also confirmed native load, capability discovery and `clear_buttons`
without config errors in its isolated GPU VM. Stack inspection of an initial
post-unload IPC stall found recursive `reload → postConfigReload →
handlePluginLoads → reload`, caused by changing the configuration declaration
between parses. The parent owns the stable-declaration integration fix and its
runtime retest; this observation is not a qualified unload/reload result.

`python3 tests/titlebars.py` exercises real CMake/C++ fixture builds, offline
convergence and repair, same-source Fedora release rebuilds, checksum/traversal
rejection, build failures, SDK mismatch and concurrent update rejection. A
native shared-library probe tests the running executable ELF guard with matching
and mismatching build IDs. Package recipe parity and absent-artifact rejection
are separate from a complete installed-system test.

The parent records integrated source/image parity, RPM/ISO qualification and
isolated real compositor load/reload/unload, button actions/theme changes,
drag/maximize, and mixed CSD clients in the desktop ledger. Compilation and
fixtures alone do not qualify those runtime or physical-display requirements.
