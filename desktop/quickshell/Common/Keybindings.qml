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
            : root.model.state.error ? I18n.format("Could not load keyboard shortcuts: %1", root.model.state.error) : "");
    }
    readonly property var actions: root.rows.actions
    readonly property var userBinds: root.rows.userBinds
    readonly property var diagnostics: root.rows.diagnostics
    readonly property bool dirty: { root.revision; return Model.dirty(root.model); }
    readonly property var rows: { root.revision; return Model.view(root.model); }
    readonly property var backend: SystemSettings.keybindings
    property var model: Model.create()
    property int revision: 0
    property int watchers: 0
    property bool held: false
    property string localError: ""
    signal applied()
    signal failed(string message)

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
            } else {
                // A successful follow-up snapshot may clear the transport
                // error; keep the failed apply visible until the next edit.
                root.localError = I18n.tr(root.backend.error);
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
