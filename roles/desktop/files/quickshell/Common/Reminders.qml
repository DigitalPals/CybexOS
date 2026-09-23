pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "Format.js" as Format
import "ProcHelpers.js" as ProcHelpers

// Canonical reminder state lives in the helper's atomic JSON records. This
// singleton is a live read model for the bar and manager; systemd owns timing.
Singleton {
    id: root

    readonly property string helper:
        Quickshell.env("HOME") + "/.local/bin/quickshell-reminder"
    property var records: []
    property bool loading: false
    property bool refreshPending: false
    property string error: ""
    readonly property int count: records.length
    readonly property double nextDue: count > 0 ? Number(records[0].due) : 0
    readonly property string nextDueLabel: nextDue > 0
        ? Qt.formatDateTime(new Date(nextDue * 1000), Settings.clock24 ? "HH:mm" : "h:mm AP")
        : ""
    readonly property string tooltip: count === 0 ? "Reminders"
        : count + (count === 1 ? " reminder" : " reminders")
            + " · next " + nextDueLabel

    function refresh() {
        if (listProc.running) {
            refreshPending = true;
            return;
        }
        loading = true;
        listProc.running = true;
    }

    function restore() {
        if (!restoreProc.running)
            restoreProc.running = true;
    }

    function run(args) {
        Quickshell.execDetached([helper].concat(args));
        settle.restart();
    }

    function add(minutes, message) {
        run(["add", String(minutes), message || ""]);
    }

    function cancel(id) {
        run(["cancel", id]);
    }

    function clear() {
        run(["clear"]);
    }

    Process {
        id: listProc
        property bool exitSeen: false
        property int lastExit: 0
        command: [root.helper, "list", "--json"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const parsed = JSON.parse(text);
                    root.records = Array.isArray(parsed) ? parsed : [];
                    root.error = "";
                } catch (e) {
                    root.error = "Could not read reminders";
                }
            }
        }
        onExited: (exitCode, exitStatus) => {
            listProc.exitSeen = true;
            listProc.lastExit = exitCode;
        }
        // Settles on the falling edge of `running`: a helper that cannot be
        // launched sends no exited(), and must not leave `loading` stuck or
        // a queued refresh stranded.
        onRunningChanged: {
            if (running) {
                exitSeen = false;
                lastExit = 0;
                return;
            }
            root.loading = false;
            if ((exitSeen ? lastExit : ProcHelpers.NOT_STARTED) !== 0)
                root.error = "Could not read reminders";
            if (root.refreshPending) {
                root.refreshPending = false;
                Qt.callLater(root.refresh);
            }
        }
    }

    // The helper calls `reminders refresh` over IPC itself whenever restore
    // delivered or rescheduled something, so its exit needs no second list —
    // unless this list still shows an overdue record, which is either still
    // failing delivery or was delivered behind a missed IPC call.
    Process {
        id: restoreProc
        command: [root.helper, "restore"]
        onRunningChanged: {
            if (running)
                return;
            if (root.count > 0 && root.nextDue * 1000 <= Date.now())
                root.refresh();
            root.armRestore();
        }
    }

    // add/cancel/clear refresh the shell over IPC once their work is done;
    // this single delayed read is only the fallback for a missed call.
    Timer {
        id: settle
        interval: 1500
        onTriggered: root.refresh()
    }

    // Restore delivers overdue records whose notification previously failed
    // and recreates missing timers. With nothing held there is nothing to
    // restore; otherwise it runs shortly after the earliest due time (the
    // systemd timer normally delivers first), every minute while a record is
    // overdue, and at least hourly as a lost-timer check.
    function restoreDelayMs() {
        const untilDue = nextDue * 1000 - Date.now() + 30000;
        return Math.max(Format.MS_MINUTE, Math.min(Format.MS_HOUR, untilDue));
    }

    function armRestore() {
        if (count === 0 || !startupRestore.done) {
            restoreTimer.stop();
            return;
        }
        restoreTimer.interval = restoreDelayMs();
        restoreTimer.restart();
    }

    onRecordsChanged: armRestore()

    Timer {
        id: restoreTimer
        onTriggered: root.restore()
    }

    // Session start: the list is a cheap local read and goes at once; the
    // restore pass (jq and systemctl per record) waits out the startup burst.
    Timer {
        id: startupRestore
        property bool done: false
        interval: 8000
        onTriggered: {
            done = true;
            root.restore();
        }
    }

    Component.onCompleted: {
        refresh();
        startupRestore.start();
    }
}
