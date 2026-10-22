import QtQuick
import "InputDraft.js" as Draft

// Session-owned input edits. Pages and their polling claims may disappear
// during search, navigation or a long close; only Apply or Discard settles
// a draft. Its original version stays attached until then for stale writes.
QtObject {
    id: root
    required property var service
    required property string section
    required property var fields
    property var draft: ({})
    property var original: ({})
    property string version: ""
    property var submitted: null
    property var supersededSnapshot: null
    readonly property var changes: Draft.patch(draft, original, fields)
    readonly property bool dirty: Object.keys(changes).length > 0

    function load() {
        if (!service.loaded || !service.snapshot[section]) return;
        // The page may reopen before a post-Apply refresh. Discard still
        // restores the committed baseline, never the cached pre-write values.
        if (service.snapshot === supersededSnapshot) {
            draft = Draft.clone(original);
            return;
        }
        original = Draft.clone(service.snapshot[section]);
        draft = Draft.clone(original);
        version = service.snapshot.version;
    }
    function refresh() { if (!dirty && submitted === null) load(); }
    function apply() {
        if (!dirty || service.busy || submitted !== null) return;
        const values = Draft.clone(draft);
        if (service.run({action: "apply", section: section, version: version, values: changes}))
            submitted = {values: values, snapshot: service.snapshot};
    }
    property Connections updates: Connections {
        target: root.service
        function onSnapshotChanged() { root.refresh(); }
        function onLoadedChanged() { root.refresh(); }
        function onCompleted(result) {
            if (root.submitted === null) return;
            if (result.success && typeof result.version === "string" && result.version) {
                root.supersededSnapshot = root.submitted.snapshot;
                root.version = result.version;
                root.original = root.submitted.values;
            }
            root.submitted = null;
        }
    }
}
