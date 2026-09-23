pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "NetworkStatusHelpers.js" as NetworkStatusHelpers
import "ProcHelpers.js" as ProcHelpers

// One event-driven answer to "can Internet work start now?" for every shell
// service. A device being present is not enough: loopback, Docker, or a Wi-Fi
// association can all exist before DNS and a default route do. NetworkManager's
// overall state reaches connected only once it has global connectivity.
//
// `nmcli monitor` supplies the edge; the small status command supplies both
// the initial value and a stable, machine-readable snapshot after each edge.
// The poll is only a safety net while the monitor is down.
//
// This is also the shell's only NetworkManager event stream: `nmcli monitor`
// reports device state changes too, so EthernetState listens to
// `monitorEvent` rather than running a second `nmcli device monitor`.
Singleton {
    id: root

    property bool known: false
    property bool online: false
    property string error: ""
    property bool refreshAgain: false
    property string lastLoggedError: ""
    // Consecutive failed status reads; see NetworkStatusHelpers.holdsKnownState.
    property int failures: 0

    readonly property bool monitorRunning: monitorProc.running
    // One line of `nmcli monitor` output, for consumers that keep their own
    // NetworkManager snapshot.
    signal monitorEvent(string line)

    function refresh() {
        if (statusProc.running) {
            refreshAgain = true;
            return;
        }
        statusProc.running = true;
    }

    function apply(exitCode, body, errText) {
        const next = exitCode === 0 ? NetworkStatusHelpers.onlineState(body) : null;
        if (next !== null) {
            failures = 0;
            confirmRetry.stop();
            known = true;
            online = next;
            error = "";
            return;
        }

        const reason = exitCode === 0
            ? "NetworkManager returned an unknown connectivity state"
            : ProcHelpers.commandError("NetworkManager status", exitCode, errText,
                ({ 124: "NetworkManager status timed out" }));
        failures++;
        // A single slow read keeps the last answer and asks again shortly:
        // with the monitor attached, nothing else would re-read until the
        // next NetworkManager event.
        if (NetworkStatusHelpers.holdsKnownState(known, failures)) {
            confirmRetry.restart();
            return;
        }

        // Repeated failures cannot vouch for the old state.
        known = false;
        online = false;
        error = reason;
        if (error !== lastLoggedError) {
            console.warn("network status unavailable:", error);
            lastLoggedError = error;
        }
    }

    onErrorChanged: {
        if (error === "")
            lastLoggedError = "";
    }

    Timer {
        id: snapshotDebounce
        interval: 250
        onTriggered: root.refresh()
    }

    Timer {
        id: confirmRetry
        interval: 2000
        onTriggered: root.refresh()
    }

    // Safety net only while there is no event stream to rely on.
    Timer {
        interval: 30000
        running: !root.monitorRunning
        repeat: true
        onTriggered: root.refresh()
    }

    Timer {
        id: monitorRestart
        interval: NetworkStatusHelpers.MONITOR_RESTART_MIN_MS
        onTriggered: {
            if (!monitorProc.running)
                monitorProc.running = true;
        }
    }

    Process {
        id: statusProc

        property string body: ""
        property string errText: ""
        property bool exitSeen: false
        property int lastExit: 0

        command: ["timeout", "5s", "env", "LC_ALL=C", "nmcli", "--terse",
            "--fields", "STATE", "general", "status"]

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

    Process {
        id: monitorProc

        // When the current run began; 0 once it has ended, so a restart
        // that never starts reads as an immediate failure.
        property real startedAt: Date.now()
        property int shortRuns: 0
        property string errText: ""
        property bool exitSeen: false
        property int lastExit: 0
        property string lastLoggedFailure: ""

        command: ["env", "LC_ALL=C", "nmcli", "monitor"]
        running: true

        stdout: SplitParser {
            onRead: line => {
                snapshotDebounce.restart();
                root.monitorEvent(line);
            }
        }
        stderr: StdioCollector {
            onStreamFinished: monitorProc.errText = text
        }
        onExited: (exitCode, exitStatus) => {
            monitorProc.exitSeen = true;
            monitorProc.lastExit = exitCode;
        }
        onRunningChanged: {
            if (running) {
                monitorRestart.stop();
                startedAt = Date.now();
                errText = "";
                exitSeen = false;
                lastExit = 0;
                return;
            }
            // NetworkManager itself can restart. Keep the fallback snapshot
            // current while waiting to reattach to its event stream, and back
            // off while the monitor keeps failing straight away.
            const ranMs = startedAt > 0 ? Date.now() - startedAt : 0;
            startedAt = 0;
            shortRuns = NetworkStatusHelpers.monitorShortRuns(shortRuns, ranMs);
            if (shortRuns === 1) {
                lastLoggedFailure = "";
            } else {
                const failure = ProcHelpers.commandError("nmcli monitor",
                    exitSeen ? lastExit : ProcHelpers.NOT_STARTED, errText);
                if (failure !== lastLoggedFailure) {
                    console.warn("network monitor stopped:", failure);
                    lastLoggedFailure = failure;
                }
            }
            root.refresh();
            monitorRestart.interval = NetworkStatusHelpers.monitorRestartDelay(shortRuns);
            monitorRestart.restart();
        }
    }

    Component.onCompleted: refresh()
}
