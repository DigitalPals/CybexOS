# Omarchy compatibility sources

All 35 `Ui/*.qml` files, `Commons/{Border.qml,BorderGeometry.js,Util.qml,Style.qml}`,
and `bin/{omarchy-notification-send,omarchy-shell}` derive from omacom/omarchy,
commit 60663faf8764253646f1d6166e864b608d4a0fa1 (MIT). The accompanying LICENSE
preserves the upstream notice. `Commons/Color.qml` bridges upstream color roles
and helpers to Cybex's palette; it does not watch Omarchy theme files.
The pinned upstream `loadColors`, `parseShell` and `applyShellValues` functions
are retained for explicit session theme updates through IPC.

Style retains upstream tokens/functions with Cybex font/radius values and
omits Omarchy config watchers and Hyprland polling. UI changes qualify delegate
references and use bound component contexts for strict linting. Dynamic host
properties use `var` for standalone Qt linting. Popup anchors access the
existing grouped property instead of declaring an invalid grouped-property ID.
Controls have accessibility labels/roles; dismissal surfaces declare their
arrow cursor. BorderGeometry omits its state-free library pragma for the
repository's JavaScript syntax gate. The notification helper quotes its D-Bus
signature for ShellCheck. The IPC helper resolves the bundled Cybex runtime
and queries that existing shell rather than `$OMARCHY_PATH/shell`.

The local `Common/Omarchy*.qml` adapter implements all six plugin kinds with
explicit limits described in docs/omarchy-plugin-compatibility.md. It does not
implement the full Omarchy distribution. Byte-for-byte plugin fixtures in
tests/omarchy-plugins have separate provenance and notices.
