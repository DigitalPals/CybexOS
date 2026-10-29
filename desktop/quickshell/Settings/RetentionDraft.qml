pragma Singleton
import QtQuick
import "../Common"

// How long recovery points are kept, as edited but not yet prepared. It used
// to live in the Storage page and vanish with it; now the Recovery points tab
// and the header's Changes review read the same draft (2026-10 redesign).
// Preparing it builds a system change that applies after a restart.
QtObject {
    id: root

    readonly property var fallback: ({ automatic: true, keepConfirmed: 5, keepDays: 30 })
    property var draft: fallback
    property var policyBaseline: fallback
    readonly property var status: Maintenance.snapshot
    readonly property var configuredPolicy: status.desiredPolicy || status.policy || fallback
    readonly property bool dirty: !same(draft, policyBaseline)
    // The declaration changed under the draft: someone else edited it.
    readonly property bool conflict: dirty && !same(policyBaseline, configuredPolicy)
    readonly property bool canPrepare: (dirty || status.configurationChanged === true)
        && !status.configurationError && !conflict && !Maintenance.busy
        && !Updates.runActive && !Updates.rebootRecommended

    function same(a, b) {
        return a.automatic === b.automatic && a.keepConfirmed === b.keepConfirmed
            && a.keepDays === b.keepDays;
    }

    function discard() {
        policyBaseline = Object.assign({}, configuredPolicy);
        draft = Object.assign({}, policyBaseline);
    }

    function edit(values) {
        draft = Object.assign({}, draft, values);
    }

    function prepare() {
        if (!canPrepare)
            return false;
        Maintenance.changePolicy(draft, policyBaseline);
        return true;
    }

    property Connections updates: Connections {
        target: Maintenance
        function onSnapshotChanged() {
            if (!root.dirty || root.same(root.draft, root.configuredPolicy))
                root.discard();
        }
    }

    Component.onCompleted: discard()
}
