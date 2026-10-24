pragma Singleton
import QtQuick
import Quickshell

Singleton {
    id: root
    property bool watched: false
    property var snapshot: ({policy:{automatic:true, keepConfirmed:5, keepDays:30}, space:{}, deployments:[]})
    property string requestId: ""
    property bool pending: false
    property string requestError: ""
    readonly property bool busy: requester.busy || pending || ["checking", "cleaning"].includes(snapshot.state)
    readonly property bool ready: !busy && snapshot.state === "ready" && !!snapshot.reviewToken
    readonly property string error: requestError || requester.error || poll.error || snapshot.error || ""
    function refresh() { poll.run(["cybex", "maintenance", "status"]); }
    function request(args) { requestError = ""; requester.run(["cybex", "maintenance"].concat(args)); }
    function preview() { request(["preview"]); }
    function clean() { if (ready) request(["clean", snapshot.reviewId, snapshot.reviewToken]); }
    function pin(id, enabled) { request(["pin", id, enabled ? "true" : "false"]); }
    function changePolicy(value, previous) { requestError = ""; requester.run(["cybex", "maintenance", "policy", JSON.stringify({previous:previous, policy:value})]); }
    function bytes(value) {
        const gib = Number(value || 0) / 1073741824;
        return gib >= 1 ? gib.toFixed(1) + " GiB" : (Number(value || 0) / 1048576).toFixed(1) + " MiB";
    }
    onWatchedChanged: { if (watched) refresh(); }
    JsonCommand { id: poll; onCompleted: value => root.snapshot = value }
    JsonCommand {
        id: requester
        onCompleted: value => {
            root.requestId = value.requestId || "";
            root.pending = root.requestId !== "";
            root.refresh();
        }
    }
    JsonCommand {
        id: requestStatus
        onFailed: message => { root.pending = false; root.requestError = message; }
        onCompleted: value => {
            root.requestError = value.error || "";
            if (["done", "failed"].includes(value.state)) { root.pending = false; root.refresh(); }
        }
    }
    Timer { interval: 1500; repeat: true; running: root.pending; onTriggered: requestStatus.run(["cybex", "maintenance", "request", root.requestId]) }
    Timer { interval: 1500; repeat: true; running: root.watched || root.pending; onTriggered: root.refresh() }
}
