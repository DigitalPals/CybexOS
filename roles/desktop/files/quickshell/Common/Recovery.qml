pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "ProcHelpers.js" as ProcHelpers
import "RecoveryHelpers.js" as RecoveryHelpers

// Recovery points and the recovery boot. The root helper republishes its
// index after every change and at boot; this is a read model plus one
// action. Restoring runs the helper as a transient system unit, so systemd
// asks the session's Polkit agent to authorize it, exactly as updates do.
Singleton {
    id: root

    property var index: RecoveryHelpers.parseIndex("")
    readonly property var points: index.points
    readonly property var replaced: index.replaced
    readonly property bool supported: index.supported
    readonly property bool loaded: index.valid
    readonly property string unsupportedReason: index.message
    // The recovery point this boot runs from (kernel command line), or "".
    property string recoveryBootId: ""
    readonly property bool recoveryBoot: recoveryBootId !== ""
    property bool recoveryHelperAvailable: false
    property string restoringId: ""
    property string restoredId: ""
    readonly property bool busy: restoreProc.running
    readonly property bool restartPending: index.pendingReboot || restoredId !== ""
    property string error: ""
    property string result: ""
    property bool announced: false

    function refresh() {
        indexView.reload();
    }

    function pointFor(id) {
        return points.find(point => point.id === id) || null;
    }

    function restore(id) {
        if (busy)
            return;
        const helper = RecoveryHelpers.helperPath(recoveryBootId, recoveryHelperAvailable);
        const command = RecoveryHelpers.restoreCommand(helper, id, Date.now());
        if (command.length === 0) {
            error = "That recovery point is not valid.";
            return;
        }
        error = "";
        result = "";
        restoringId = id;
        restoreProc.command = command;
        restoreProc.running = true;
    }

    function finishRestore() {
        if (restoreProc.lastExit === 0) {
            restoredId = restoringId;
            result = "Restored. Restart to start " + RecoveryHelpers.pointTime(restoringId)
                + "; the replaced system is kept until you discard it.";
        } else {
            error = RecoveryHelpers.restoreError(restoreProc.lastExit, restoreErr.text);
        }
        restoringId = "";
        indexView.reload();
    }

    FileView {
        path: "/proc/cmdline"
        blockLoading: true
        printErrors: false
        onLoaded: root.recoveryBootId = RecoveryHelpers.recoveryBootId(text())
    }

    // Present only in a recovery boot; see RecoveryHelpers.RECOVERY_HELPER.
    FileView {
        path: root.recoveryBoot ? RecoveryHelpers.RECOVERY_HELPER : ""
        printErrors: false
        onLoaded: root.recoveryHelperAvailable = true
        onLoadFailed: root.recoveryHelperAvailable = false
    }

    FileView {
        id: indexView
        path: RecoveryHelpers.INDEX_PATH
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: root.index = RecoveryHelpers.parseIndex(text())
        onLoadFailed: root.index = RecoveryHelpers.parseIndex("")
    }

    Process {
        id: restoreProc
        property int lastExit: ProcHelpers.NOT_STARTED
        stdout: StdioCollector {}
        stderr: StdioCollector {
            id: restoreErr
        }
        onExited: (exitCode, exitStatus) => restoreProc.lastExit = exitCode
        // Settles on the falling edge of `running`, after both streams, so a
        // unit that could not start still reports instead of hanging.
        onRunningChanged: {
            if (running) {
                lastExit = ProcHelpers.NOT_STARTED;
                return;
            }
            Qt.callLater(root.finishRestore);
        }
    }

    // A recovery boot says so once per session. The notification is critical,
    // so it stays until dismissed; its action opens the section that restores.
    Process {
        id: announcement
        command: ["notify-send", "--app-name=Recovery", "--urgency=critical", "--wait",
            "--action=open=Restore or return…", "Running a recovery point",
            "Changes you make now are temporary and disappear when you restart. "
                + "Restore this recovery point to keep it."]
        stdout: StdioCollector {
            onStreamFinished: {
                if (text.trim() === "open")
                    Settings.showSetting("system", "recoveryPoints", "");
            }
        }
    }

    // Waits for this shell's own notification server to be listening.
    Timer {
        interval: 4000
        running: root.recoveryBoot && !root.announced
        onTriggered: {
            root.announced = true;
            announcement.running = true;
        }
    }
}
