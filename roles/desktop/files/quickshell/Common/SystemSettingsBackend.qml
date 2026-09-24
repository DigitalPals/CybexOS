import QtQuick
import Quickshell
import Quickshell.Io

// One bounded request channel per service, shared by all settings consumers.
Item {
    id: root
    property string domain: ""
    property int watchers: 0
    property var snapshot: ({})
    property string error: ""
    property string message: ""
    property bool loaded: false
    property var request: ({})
    property var preview: null
    property int revision: 0
    property bool refreshQueued: false
    readonly property bool busy: actionProc.running
    readonly property bool loading: snapshotProc.running
    readonly property bool watching: monitor.running
    signal completed(var result)

    function acquire() {
        watchers++;
        if (watchers === 1)
            refresh();
    }
    function release() {
        watchers = Math.max(0, watchers - 1);
        if (!watchers && snapshotProc.running)
            snapshotProc.signal(15);
        if (!watchers && preview && !busy)
            run({action: "rollback", checkpoint: preview.checkpoint});
    }
    function refresh() {
        if (loading) {
            refreshQueued = true;
            return;
        }
        if (watchers && !busy)
            snapshotProc.running = true;
    }
    onWatchersChanged: monitor.running = watchers > 0
    function run(value) {
        if (busy)
            return false;
        if (preview && value.action !== "confirm" && value.action !== "rollback") {
            error = "Keep or revert the current network trial first.";
            return false;
        }
        revision++;
        request = value;
        error = "";
        message = "";
        actionProc.running = true;
        return true;
    }
    function decode(body, code) {
        if (code === 0) {
            try {
                const result = JSON.parse(body);
                if (result && !Array.isArray(result) && typeof result.success === "boolean")
                    return result;
            } catch (_) {}
        }
        return {success: false, error: "The settings helper could not finish. Retry after checking the service."};
    }
    Timer {
        id: debounce
        interval: 400
        onTriggered: root.refresh()
    }
    Timer {
        interval: 15000
        running: root.watchers > 0
        repeat: true
        onTriggered: {
            root.refresh();
            if (!monitor.running)
                monitor.running = true;
        }
    }
    Process {
        id: monitor
        command: root.domain === "sound" ? ["pactl", "subscribe"]
            : root.domain === "network" ? ["nmcli", "monitor"]
            : ["gdbus", "monitor", "--session", "--dest", "org.gnome.OnlineAccounts"]
        stdout: SplitParser { onRead: debounce.restart() }
        stderr: StdioCollector {}
    }
    Process {
        id: snapshotProc
        property string body: ""
        property int code: -1
        property int issuedRevision: 0
        command: ["python3", "-B", Quickshell.shellDir + "/scripts/system-settings.py", root.domain]
        stdinEnabled: true
        stdout: StdioCollector { onStreamFinished: snapshotProc.body = text }
        stderr: StdioCollector {}
        onStarted: write('{"action":"snapshot"}\n')
        onExited: exitCode => { code = exitCode; }
        onRunningChanged: {
            if (running) {
                body = "";
                code = -1;
                issuedRevision = root.revision;
            } else {
                if (root.watchers && issuedRevision === root.revision) {
                    const result = root.decode(body, code);
                    if (result.success) {
                        if (JSON.stringify(root.snapshot) !== JSON.stringify(result))
                            root.snapshot = result;
                        root.loaded = true;
                    } else {
                        root.error = result.error || "Could not read system settings";
                    }
                }
                if (root.refreshQueued) {
                    root.refreshQueued = false;
                    Qt.callLater(root.refresh);
                }
            }
        }
    }
    Process {
        id: actionProc
        property string body: ""
        property int code: -1
        command: ["python3", "-B", Quickshell.shellDir + "/scripts/system-settings.py", root.domain]
        stdinEnabled: true
        stdout: StdioCollector { onStreamFinished: actionProc.body = text }
        stderr: StdioCollector {}
        onStarted: write(JSON.stringify(root.request) + "\n")
        onExited: exitCode => { code = exitCode; }
        onRunningChanged: {
            if (running) {
                body = "";
                code = -1;
            } else {
                const result = root.decode(body, code);
                root.error = result.success ? "" : result.error || "Could not apply settings";
                root.message = result.success ? result.message || "Updated" : "";
                if (result.checkpoint)
                    root.preview = result;
                else if (root.request.action === "confirm" || root.request.action === "rollback")
                    root.preview = null;
                root.completed(result);
                if (!root.watchers && root.preview)
                    Qt.callLater(() => {
                        if (root.preview && !root.watchers)
                            root.run({action: "rollback", checkpoint: root.preview.checkpoint});
                    });
                else
                    Qt.callLater(root.refresh);
            }
        }
    }
    Timer {
        interval: 55000
        running: actionProc.running
        onTriggered: actionProc.signal(15)
    }
    Timer {
        interval: 25000
        running: snapshotProc.running
        onTriggered: snapshotProc.signal(15)
    }
}
