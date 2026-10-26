pragma Singleton
import QtQuick
import Quickshell
import "KeybindingsModel.js" as Model

// No startup request. A visible consumer holds a Claim; refresh() also works
// once without a claim, for the welcome guide's short-lived keycap reads.
Singleton {
    id: root
    readonly property bool loaded: { root.revision; return root.model.loaded; }
    readonly property bool busy: backend.busy || backend.loading
    readonly property string error: {
        root.revision;
        return root.localError || (backend.error ? I18n.tr(backend.error)
            : root.model.state.error ? root.preferencesError : "");
    }
    // Why keybindings.json is not in effect, "" when it is: a sentence for
    // people. Lua's technical reason (a parser position) is preferencesDetail,
    // shown after it in a quieter style. Lua's rejection wins over the
    // backend's. While set, only resetAll() is accepted; applying that reset
    // replaces the file after a backup copy is kept.
    readonly property string preferencesError: {
        root.revision;
        const problem = Model.problem(root.model);
        return problem.lua ? I18n.tr("Your keybindings.json could not be used, so your changes are paused. Reset all to start again; the broken file is kept.")
            : problem.file ? I18n.tr(problem.file) : "";
    }
    readonly property string preferencesDetail: {
        root.revision;
        const problem = Model.problem(root.model);
        return problem.lua ? root.luaReason(problem.lua) : "";
    }
    readonly property bool readOnly: { root.revision; return Model.broken(root.model); }
    // { "<xkb keycode>": "<level-1 keysym>" } for the active layout, {} when
    // unknown. Pass it to KeybindEditor.fromKeyEvent so Shift combinations are
    // recorded as Hyprland binds them (SUPER + SHIFT + 1, not code:10).
    readonly property var keymap: { root.revision; return root.model.keymap || ({}); }
    readonly property var actions: root.rows.actions
    readonly property var userBinds: root.rows.userBinds
    readonly property var diagnostics: root.rows.diagnostics
    readonly property bool dirty: { root.revision; return Model.dirty(root.model); }
    readonly property var rows: { root.revision; return Model.view(root.model); }
    // [{ id, group, label, custom, before, after, removed }] that apply() would change.
    readonly property var changes: { root.revision; return Model.changes(root.model); }
    readonly property var backend: SystemSettings.keybindings
    property var model: Model.create()
    property int revision: 0
    property int watchers: 0
    property bool held: false
    property string localError: ""
    signal applied()
    signal failed(string message)

    // Lua's error() prefixes "path/file.lua:72: "; the reason alone is for people.
    function luaReason(text) { return String(text).replace(/^\S*\.lua:\d+:\s*/, ""); }
    function acquire() {
        watchers++;
        if (!held) {
            held = true;
            backend.acquire();
        }
    }
    function release() {
        watchers = Math.max(0, watchers - 1);
        releaseIdle();
    }
    function releaseIdle() {
        if (!watchers && held && !busy) {
            held = false;
            backend.release();
        }
    }
    function refresh() {
        localError = "";
        if (!held) {
            held = true;
            backend.acquire();
        } else {
            backend.refresh();
        }
    }
    function reject(message) {
        localError = I18n.tr(message);
        failed(localError);
        return false;
    }
    function edit(operation) {
        if (!loaded)
            return reject("Load keyboard shortcuts before editing");
        if (backend.busy)
            return reject("Wait for the shortcut change to finish");
        try {
            const value = operation();
            revision++;
            localError = "";
            return value === undefined ? true : value;
        } catch (problem) {
            return reject(String(problem.message || problem));
        }
    }
    function keysFor(id) { root.revision; return Model.keysFor(model, id); }
    function action(id) { root.revision; return Model.action(model, id); }
    function conflicts(keyString, exceptId) { root.revision; return Model.conflicts(model, keyString, exceptId); }
    function setKeys(id, keys) { return edit(() => Model.setKeys(root.model, id, keys)); }
    // [{ id, keys }] applied all or not at all.
    function setManyKeys(changes) { return edit(() => Model.setManyKeys(root.model, changes)); }
    function disable(id) { return setKeys(id, []); }
    function reset(id) { return edit(() => Model.reset(root.model, id)); }
    function resetAll() { return edit(() => Model.resetAll(root.model)); }
    function addCustom(entry) { return edit(() => Model.addCustom(root.model, entry)); }
    function updateCustom(id, patch) { return edit(() => Model.updateCustom(root.model, id, patch)); }
    function removeCustom(id) { return edit(() => Model.removeCustom(root.model, id)); }
    function discard() {
        if (backend.busy)
            return reject("Wait for the shortcut change to finish");
        Model.discard(model);
        revision++;
        backend.error = "";
        refresh();
        return true;
    }
    function apply() {
        if (!loaded)
            return reject("Load keyboard shortcuts before editing");
        if (backend.busy)
            return false;
        if (!dirty)
            return true;
        localError = "";
        if (!held) {
            held = true;
            backend.acquire();
        }
        return backend.run(Model.request(model));
    }
    property Connections backendSignals: Connections {
        target: root.backend
        function onSnapshotChanged() {
            if (!root.backend.snapshot.state)
                return;
            Model.ingest(root.model, root.backend.snapshot);
            root.revision++;
        }
        function onErrorChanged() {
            if (root.backend.error)
                root.failed(I18n.tr(root.backend.error));
        }
        function onCompleted(result) {
            if (result.success) {
                root.localError = "";
                Model.applied(root.model, result);
                root.revision++;
                root.applied();
            }
        }
        function onLoadingChanged() { Qt.callLater(root.releaseIdle); }
        function onBusyChanged() {
            // Let SystemSettingsBackend schedule its post-apply snapshot first.
            if (!root.backend.busy)
                Qt.callLater(() => { root.backend.refresh(); Qt.callLater(root.releaseIdle); });
        }
    }
}
