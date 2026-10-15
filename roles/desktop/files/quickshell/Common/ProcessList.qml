pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "ProcessListHelpers.js" as ProcessListHelpers

// The Control Center's Top processes list (Popovers/Drawer/DrawerProcesses.qml).
//
// It samples only while a view holds a claim — the list is on screen — every
// two seconds, as the CPU and memory meters above it do. One sample is one
// short-lived `scripts/processes list` (bash builtins only); the CPU share
// of each process is the change in its CPU time between two samples, so the
// first reading after opening is primed half a second later.
//
// Ending a process is two steps the view confirms: SIGTERM, which lets the
// application save and quit; and, when it is still running a few seconds
// later, the offer of SIGKILL. Both go through the helper's start-time
// check, so a pid reused since the list was read is never signalled.
Singleton {
    id: root

    readonly property string helper: Quickshell.shellDir + "/scripts/processes"
    // "cpu" or "memory"; a view choice for the session, not a setting.
    property string mode: "cpu"
    readonly property int limit: ProcessListHelpers.DEFAULT_LIMIT
    property int watchers: 0
    property var previous: null
    property var all: []
    readonly property var rows: ProcessListHelpers.rank(all, mode, limit)
    property bool loaded: false
    property string error: ""
    property int pageSize: 4096

    // The row awaiting "End process" confirmation, as { pid, start, name }.
    property var confirming: null
    // The process sent SIGTERM: { pid, start, name, stage } where stage is
    // "ending" until it is gone or "stuck" once Force quit is on offer.
    property var ending: null
    // The last outcome, read out and shown under the list for a few seconds.
    property string notice: ""

    function acquire() {
        watchers++;
        if (watchers !== 1)
            return;
        previous = null;
        if (!pageSizeProbe.done && !pageSizeProbe.running)
            pageSizeProbe.running = true;
        refresh();
        primeTimer.restart();
    }

    // The last view gone also drops a pending confirmation: nothing is left
    // to show it, and coming back must not find a stale question armed.
    function release() {
        watchers = Math.max(0, watchers - 1);
        if (watchers > 0)
            return;
        primeTimer.stop();
        graceTimer.stop();
        confirming = null;
        ending = null;
        notice = "";
    }

    function refresh() {
        if (!listRequest.running)
            listRequest.running = true;
    }

    function setMode(next) {
        if (ProcessListHelpers.MODES.indexOf(next) !== -1)
            mode = next;
    }

    function canEnd(row) {
        return ProcessListHelpers.canEnd(row, Quickshell.processId);
    }

    function requestEnd(row) {
        if (!canEnd(row) || ending !== null)
            return;
        notice = "";
        confirming = { pid: row.pid, start: row.start, name: row.name };
    }

    function cancel() {
        confirming = null;
        if (ending !== null && ending.stage === "stuck")
            ending = null;
        graceTimer.stop();
    }

    function confirmEnd() {
        const target = confirming;
        confirming = null;
        if (target === null || signalRequest.running)
            return;
        ending = { pid: target.pid, start: target.start, name: target.name, stage: "ending" };
        send(target, "TERM");
    }

    function forceQuit() {
        if (ending === null || ending.stage !== "stuck" || signalRequest.running)
            return;
        ending = Object.assign({}, ending, { stage: "killing" });
        send(ending, "KILL");
    }

    function send(target, signalName) {
        signalRequest.signalName = signalName;
        signalRequest.command = ["bash", helper, "signal", String(target.pid),
            String(target.start), signalName];
        signalRequest.running = true;
    }

    function finishSignal(code, stderrText) {
        const target = ending;
        if (target === null)
            return;
        if (code === 3) {
            // Already gone: what the person wanted has happened.
            ending = null;
            graceTimer.stop();
            notice = target.name + " ended";
        } else if (code !== 0) {
            ending = null;
            graceTimer.stop();
            const detail = stderrText.trim().split("\n").pop().replace(/^.*kill:\s*/, "");
            notice = "Couldn’t end " + target.name + (detail !== "" ? ": " + detail : "");
        } else if (signalRequest.signalName === "TERM") {
            graceTimer.restart();
        }
        refresh();
    }

    function finishList(code, body) {
        if (code !== 0) {
            error = "Process list unavailable";
            return;
        }
        const current = ProcessListHelpers.parseSnapshot(body);
        all = ProcessListHelpers.rows(previous, current, pageSize);
        previous = current;
        error = "";
        loaded = true;
        if (ending !== null && !ProcessListHelpers.stillRunning(all, ending)) {
            notice = ending.name + (ending.stage === "killing" ? " was force quit" : " ended");
            ending = null;
            graceTimer.stop();
        }
    }

    CommandRequest {
        id: listRequest
        command: ["bash", root.helper, "list"]
        timeoutMs: 5000
        onCompleted: (code, body, stderrText) => root.finishList(code, body)
    }

    CommandRequest {
        id: signalRequest
        property string signalName: "TERM"
        timeoutMs: 5000
        onCompleted: (code, body, stderrText) => root.finishSignal(code, stderrText)
    }

    // Resident memory is counted in pages.
    Process {
        id: pageSizeProbe
        property bool done: false
        command: ["getconf", "PAGESIZE"]
        stdout: StdioCollector {
            onStreamFinished: {
                const value = parseInt(text.trim());
                if (value > 0)
                    root.pageSize = value;
            }
        }
        onRunningChanged: {
            if (!running)
                done = true;
        }
    }

    Timer {
        interval: 2000
        running: root.watchers > 0
        repeat: true
        onTriggered: root.refresh()
    }

    // The second snapshot that gives the first CPU shares.
    Timer {
        id: primeTimer
        interval: 500
        onTriggered: {
            if (root.watchers > 0)
                root.refresh();
        }
    }

    // How long a process gets to quit on SIGTERM before Force quit is offered.
    Timer {
        id: graceTimer
        interval: 3000
        onTriggered: {
            if (root.ending !== null && root.ending.stage === "ending")
                root.ending = Object.assign({}, root.ending, { stage: "stuck" });
        }
    }

    onNoticeChanged: {
        if (notice !== "")
            noticeTimer.restart();
    }

    Timer {
        id: noticeTimer
        interval: 6000
        onTriggered: root.notice = ""
    }
}
