pragma Singleton
import QtQuick
import Quickshell

Singleton {
    id: root
    property bool open: false
    property string query: ""
    property bool installedTab: false
    property var inventory: ({desired: [], packages: []})
    property var draft: []
    property var results: []
    property int total: 0
    property string requestId: ""
    property string requestError: ""
    property bool requestPending: false
    property bool conflict: false
    readonly property bool canStage: (dirty || inventory.configurationChanged === true) && !conflict && !busy && !Updates.runActive && !Updates.rebootRecommended
    readonly property bool busy: catalogue.busy || loader.busy || requester.busy || requestPending
    readonly property bool dirty: JSON.stringify(draft.slice().sort()) !== JSON.stringify((inventory.desired || []).slice().sort())
    readonly property string error: requestError || (conflict ? "Package choices changed elsewhere. Discard selections and refresh before building." : "") || requester.error || loader.error || catalogue.error
    readonly property bool ownDeployment: Updates.deployment.changeKind === "software"
        && (requestId === "" || Updates.deployment.requestId === requestId)

    signal present()
    function show() { if (open) present(); else open = true; refresh(); }
    function close() { open = false; }
    function refresh() {
        loader.run(["cybex", "software", "list"]);
        searchDelay.restart();
    }
    function discard() { conflict = false; draft = (inventory.desired || []).slice(); refresh(); }
    function toggle(attribute) {
        draft = draft.includes(attribute) ? draft.filter(p => p !== attribute) : draft.concat([attribute]);
    }
    function stage() {
        if (!canStage) return;
        requestError = "";
        requester.run(["cybex", "software", "stage", JSON.stringify({packages: draft, previous: inventory.desired || []})]);
    }
    onQueryChanged: searchDelay.restart()
    Timer { id: searchDelay; interval: 250; onTriggered: { if (!catalogue.run(["cybex", "software", "search", root.query])) restart(); } }
    JsonCommand {
        id: loader
        onCompleted: value => {
            const edited = root.dirty;
            if (edited && JSON.stringify((root.inventory.desired || []).slice().sort()) !== JSON.stringify((value.desired || []).slice().sort())) root.conflict = true;
            root.inventory = value;
            if (!edited) root.draft = (value.desired || []).slice();
        }
    }
    JsonCommand {
        id: catalogue
        onCompleted: value => {
            root.results = value.results || []; root.total = value.total || 0;
        }
    }
    JsonCommand { id: requester; onCompleted: value => { root.requestId = value.requestId || ""; root.requestPending = root.requestId !== ""; } }
    JsonCommand {
        id: requestStatus
        onFailed: message => { root.requestPending = false; root.requestError = message; }
        onCompleted: value => {
            root.requestError = value.error || "";
            if (["done", "failed"].includes(value.state)) { root.requestPending = false; root.refresh(); }
        }
    }
    Timer { interval: 1500; repeat: true; running: root.requestPending; onTriggered: requestStatus.run(["cybex", "software", "request", root.requestId]) }
}
