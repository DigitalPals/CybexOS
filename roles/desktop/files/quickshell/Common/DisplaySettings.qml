pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Settings -> Displays: one bounded request channel to
// scripts/display-settings.py, with SystemSettingsBackend's contract —
// consumers acquire/release it, `run()` sends one action, and `preview`
// holds an applied change that still needs Keep or Revert. Releasing the
// last claim during a trial restores the previous arrangement; a transient
// systemd timer does the same if the shell itself is gone.
Singleton {
    id: root

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
    readonly property string helper: Quickshell.shellDir + "/scripts/display-settings.py"
    signal completed(var result)
    signal refreshed()

    // Outputs appearing, disappearing or moving change the screen list; a
    // disabled output being unplugged does not, which the slow poll covers.
    readonly property string screenSignature: Quickshell.screens.map(screen =>
        screen.name + ":" + screen.x + ":" + screen.y + ":" + screen.width + "x" + screen.height).join(",")
    onScreenSignatureChanged: {
        if (watchers)
            debounce.restart();
    }

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
    function run(value) {
        if (busy)
            return false;
        if (preview && value.action !== "confirm" && value.action !== "rollback") {
            error = "Keep or revert the current display change first.";
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
        return {success: false, error: "The display settings helper could not finish. Retry after checking the session."};
    }

    Timer {
        id: debounce
        interval: 400
        onTriggered: root.refresh()
    }
    Timer {
        interval: 10000
        running: root.watchers > 0 && root.preview === null
        repeat: true
        onTriggered: root.refresh()
    }
    Process {
        id: snapshotProc
        property string body: ""
        property int code: -1
        property int issuedRevision: 0
        command: ["python3", "-B", root.helper]
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
                        // A trial started before a shell restart, or ended by
                        // its timer, is picked up here.
                        if (result.trial && !root.preview)
                            root.preview = result.trial;
                        else if (!result.trial && root.preview && !root.busy) {
                            root.preview = null;
                            root.message = "The display change ended; the previous settings were restored.";
                        }
                        if (JSON.stringify(root.snapshot) !== JSON.stringify(result))
                            root.snapshot = result;
                        root.loaded = true;
                        root.refreshed();
                    } else {
                        root.error = result.error || "Could not read the displays";
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
        command: ["python3", "-B", root.helper]
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
                root.error = result.success ? "" : result.error || "Could not change the displays";
                root.message = result.success ? result.message || "Updated" : "";
                if (result.checkpoint)
                    root.preview = {checkpoint: result.checkpoint, expires: result.expires};
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
