pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "EthernetHelpers.js" as EthernetHelpers
import "ProcHelpers.js" as ProcHelpers

// Wired NetworkManager devices. Quickshell's Networking API exposes the
// Wi-Fi radio and networks but not enough wired-device detail for the bar, so
// one ref-counted nmcli snapshot serves every visible consumer. It is
// refreshed from NetworkStatus's shared `nmcli monitor` stream.
Singleton {
    id: root

    property var devices: []
    readonly property var connectedDevices: devices.filter(device => device.connected)
    readonly property bool connected: connectedDevices.length > 0
    property bool known: false
    property string error: ""

    property int watchers: 0
    property bool refreshAgain: false

    function acquire() {
        watchers++;
        if (watchers !== 1)
            return;
        refresh();
    }

    function release() {
        watchers = Math.max(0, watchers - 1);
        if (watchers !== 0)
            return;
        monitorDebounce.stop();
    }

    function refresh() {
        if (statusProc.running) {
            refreshAgain = true;
            return;
        }
        statusProc.running = true;
    }

    function apply(exitCode, body, errText) {
        known = true;
        var next = exitCode === 0 ? EthernetHelpers.parseDevices(body) : null;
        if (next !== null) {
            devices = next;
            error = "";
            return;
        }

        // A failed read cannot vouch for an old connected state. Clear the
        // snapshot and say why instead of leaving a false wired highlight.
        devices = [];
        error = exitCode === 0
            ? "NetworkManager returned Ethernet status this shell could not read"
            : ProcHelpers.commandError("nmcli device show", exitCode, errText,
                ({ 124: "NetworkManager status timed out" }));
        if (error !== lastLoggedError) {
            console.warn("ethernet status unavailable:", error);
            lastLoggedError = error;
        }
    }

    property string lastLoggedError: ""
    onErrorChanged: {
        if (error === "")
            lastLoggedError = "";
    }

    // NetworkStatus owns the shell's one `nmcli monitor`, which reports
    // device state changes as well as connectivity. The poll is only a safety
    // net while that stream is down.
    Timer {
        id: poll
        interval: 30000
        running: root.watchers > 0 && !NetworkStatus.monitorRunning
        repeat: true
        onTriggered: root.refresh()
    }

    Timer {
        id: monitorDebounce
        interval: 350
        onTriggered: root.refresh()
    }

    Connections {
        target: NetworkStatus

        function onMonitorEvent(line) {
            if (root.watchers > 0)
                monitorDebounce.restart();
        }

        // Events are lost while the stream is down or reattaching, so each
        // edge takes a fresh snapshot.
        function onMonitorRunningChanged() {
            if (root.watchers > 0)
                monitorDebounce.restart();
        }
    }

    Process {
        id: statusProc

        property string body: ""
        property string errText: ""
        property bool exitSeen: false
        property int lastExit: 0

        command: ["timeout", "10s", "env", "LC_ALL=C", "nmcli", "--terse",
            "--mode", "multiline", "--fields",
            "GENERAL.DEVICE,GENERAL.TYPE,GENERAL.CONNECTION,GENERAL.STATE,IP4.ADDRESS",
            "device", "show"]

        stdout: StdioCollector {
            onStreamFinished: statusProc.body = text
        }
        stderr: StdioCollector {
            onStreamFinished: statusProc.errText = text
        }
        onExited: (exitCode, exitStatus) => {
            statusProc.exitSeen = true;
            statusProc.lastExit = exitCode;
        }
        onRunningChanged: {
            if (running) {
                body = "";
                errText = "";
                exitSeen = false;
                lastExit = 0;
                return;
            }
            root.apply(exitSeen ? lastExit : ProcHelpers.NOT_STARTED, body, errText);
            if (root.refreshAgain) {
                root.refreshAgain = false;
                Qt.callLater(root.refresh);
            }
        }
    }
}
