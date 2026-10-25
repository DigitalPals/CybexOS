`bindings-6f4aa2d.lua` is an unmodified snapshot from commit
6f4aa2dc5a406dfbcf6fc696817ec01b4a9c3d85. The parity test executes both this
snapshot and the current catalog, invokes callback dispatchers against a stub
and compares keys, descriptions, dispatcher arguments, registration order and
flags across four feature combinations. It never needs the compositor.

`normalize.json`, `same.json` and `resolution.json` are shared by the actual
Lua helper and the JS draft preview. Empty arrays and sparse documents are
intentional; do not turn them into objects when adding vectors.

`keymap-us.xkb`, `keymap-fr.xkb` and `keymap-us-fr.xkb` are the `xkb_keycodes`
and `xkb_symbols` sections of real `xkbcli compile-keymap` output (libxkbcommon
1.13.2) for `--layout us`, `--layout fr` and `--layout us,fr --variant ,azerty
--options grp:alt_shift_toggle`; the other sections are dropped. The Python
parser tests read them. `keymap-us.json` and `keymap-fr.json` are the parser's
group-1 maps, which the Node recorder tests use; regenerate them from the `.xkb`
files with `system_settings_keymap.parse` if the parser changes.
