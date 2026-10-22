pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "BatteryViewHelpers.js" as BatteryView
import "ProcHelpers.js" as ProcHelpers

// UPower owns the setting and firmware owns the limits. This singleton only
// adapts physical battery objects into one laptop-wide switch; it deliberately
// keeps no shell preference that could disagree with the actual charge policy.
Singleton {
    id: root

    property bool known: false
    property bool supported: false
    property bool enabled: false
    property bool mixed: false
    property int batteryCount: 0
    property string limitText: BatteryView.MISSING
    property string statusError: ""
    property string actionError: ""
    property bool refreshAgain: false
    property int watchers: 0
    // `upower --monitor-detail` block state: the device the current block
    // describes and the last charge-threshold values seen per device. Plain
    // JS bookkeeping; nothing binds to it.
    property string monitorDevice: ""
    property var monitorSeen: ({})

    readonly property bool busy: setProc.running
    readonly property string error: actionError !== ""
        ? actionError : statusError
    readonly property string helperPath:
        Quickshell.shellDir + "/scripts/battery-health"

    function acquire() {
        watchers++;
        if (watchers !== 1)
            return;
        refresh();
        monitorDevice = "";
        monitorSeen = ({});
        monitorProc.running = true;
    }

    function release() {
        watchers = Math.max(0, watchers - 1);
        if (watchers !== 0)
            return;
        monitorRestart.stop();
        monitorProc.running = false;
    }

    function refresh() {
        if (statusProc.running) {
            refreshAgain = true;
            return;
        }
        statusProc.running = true;
    }

    function setEnabled(value) {
        if (!known || !supported || setProc.running)
            return;
        actionError = "";
        errorClear.stop();
        setProc.desired = value;
        setProc.running = true;
    }

    function applyStatus(exitCode, body, errText) {
        const state = exitCode === 0
            ? BatteryView.parseChargeThresholdStatus(body) : null;
        if (state !== null) {
            known = true;
            supported = state.supported;
            enabled = state.enabled;
            mixed = state.mixed;
            batteryCount = state.batteryCount;
            limitText = BatteryView.formatChargeLimit(state);
            statusError = "";
            return;
        }

        known = false;
        supported = false;
        enabled = false;
        mixed = false;
        batteryCount = 0;
        limitText = BatteryView.MISSING;
        statusError = exitCode === 0
            ? "UPower returned unreadable battery-health data"
            : ProcHelpers.commandError("Battery health status", exitCode, errText);
        console.warn("battery health unavailable:", statusError);
    }

    // Safety net only while the UPower monitor is down; see monitorProc.
    Timer {
        interval: 30000
        running: root.watchers > 0 && !monitorProc.running
        repeat: true
        onTriggered: root.refresh()
    }

    Timer {
        id: refreshDebounce
        interval: 250
        onTriggered: root.refresh()
    }

    Timer {
        id: monitorRestart
        interval: 5000
        onTriggered: {
            if (root.watchers > 0 && !monitorProc.running) {
                monitorProc.running = true;
                // A change made while it was down was never reported.
                root.refresh();
            }
        }
    }

    Timer {
        id: errorClear
        interval: 5000
        onTriggered: root.actionError = ""
    }

    Process {
        id: statusProc

        property string body: ""
        property string errText: ""
        property bool exitSeen: false
        property int lastExit: 0

        command: ["bash", root.helperPath, "status"]

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
            root.applyStatus(exitSeen ? lastExit : ProcHelpers.NOT_STARTED,
                body, errText);
            if (root.refreshAgain) {
                root.refreshAgain = false;
                Qt.callLater(root.refresh);
            }
        }
    }

    Process {
        id: setProc

        property bool desired: false
        property string errText: ""
        property bool exitSeen: false
        property int lastExit: 0

        command: ["bash", root.helperPath, "set", desired ? "true" : "false"]

        stderr: StdioCollector {
            onStreamFinished: setProc.errText = text
        }
        onExited: (exitCode, exitStatus) => {
            setProc.exitSeen = true;
            setProc.lastExit = exitCode;
        }
        onRunningChanged: {
            if (running) {
                errText = "";
                exitSeen = false;
                lastExit = 0;
                return;
            }

            const status = exitSeen ? lastExit : ProcHelpers.NOT_STARTED;
            if (status === 0) {
                root.actionError = "";
            } else {
                root.actionError = ProcHelpers.commandError(
                    "Charge-limit update", status, errText);
                console.warn("battery health update failed:", root.actionError);
                errorClear.restart();
            }
            // A multi-pack update can fail after changing an earlier pack.
            // Always read the backend again so even that partial result is
            // represented truthfully once the error message clears.
            refreshDebounce.restart();
        }
    }

    // One line of `upower --monitor-detail`. A battery reprints its whole
    // detail block on every energy or rate change — several times a minute
    // while charging — and none of that moves the charge policy. Only a
    // device appearing or leaving, the daemon changing, or a charge-threshold
    // line whose value differs from the last one seen asks for a status read.
    function monitorLine(line) {
        const text = String(line);
        const header = /^\S/.test(text) ? text.match(
            /(device added|device removed|device changed|daemon changed):\s*(\S*)/)
            : null;
        if (header !== null) {
            monitorDevice = header[2];
            if (header[1] !== "device changed")
                refreshDebounce.restart();
            return;
        }
        const field = text.match(/^\s*(charge-[a-z-]*threshold[a-z-]*):\s*(.*)$/);
        if (field === null)
            return;
        const key = monitorDevice + " " + field[1];
        const value = field[2].trim();
        if (monitorSeen[key] === value)
            return;
        monitorSeen[key] = value;
        refreshDebounce.restart();
    }

    // UPower's own monitor supplies change notifications without keeping a
    // privileged process around. The 30-second timer above covers only the
    // gap while it is down, as NetworkStatus's does for nmcli monitor, and
    // each restart reads the status afresh.
    Process {
        id: monitorProc

        command: ["upower", "--monitor-detail"]

        stdout: SplitParser {
            onRead: line => root.monitorLine(line)
        }
        onRunningChanged: {
            if (!running && root.watchers > 0)
                monitorRestart.restart();
        }
    }
}
