pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Screen-recording state, read from the state files ~/.local/bin/screen-record
// keeps in $XDG_RUNTIME_DIR.
//
// The shell deliberately does not drive wf-recorder itself: the script already
// owns region selection, the freeze overlay, the output path and the saved
// notification, and it is bound to a compositor key, so a recording can start
// without the shell involved at all. Watching its state is what keeps the bar
// chip honest either way.
Singleton {
    id: root

    readonly property string stateDir:
        (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/screen-record"
    readonly property string script:
        Quickshell.env("HOME") + "/.local/bin/screen-record"

    property bool active: false
    property int recorderPid: 0
    property string recorderName: ""
    property string expectedStartTicks: ""
    property string actualStartTicks: ""
    property string outputFile: ""
    // Epoch seconds. 0 while not recording, or while a recording started by an
    // older copy of the script left no stamp behind.
    property double startedAt: 0
    // Seconds since the recording began, ticking once a second while active.
    property int elapsed: 0

    readonly property string elapsedLabel: {
        const total = Math.max(0, elapsed);
        const minutes = Math.floor(total / 60);
        const seconds = Math.floor(total % 60);
        return minutes + ":" + String(seconds).padStart(2, "0");
    }

    function toggle(mode) {
        const selected = ["region", "window", "screen"].indexOf(mode) !== -1
            ? mode : Settings.modOpts.indicators.recordingMode;
        Quickshell.execDetached([root.script, selected]);
        // The script selects a region before it writes any state, so give the
        // user time to drag one out before looking again.
        settle.restart();
    }

    function refresh() {
        pidView.reload();
        ticksView.reload();
        stampView.reload();
        outputView.reload();
    }

    function recomputeActive() {
        active = recorderPid > 0 && recorderName === "wf-recorder"
            && expectedStartTicks !== ""
            && expectedStartTicks === actualStartTicks;
    }

    function recomputeElapsed() {
        if (!active) {
            elapsed = 0;
            return;
        }
        elapsed = startedAt > 0
            ? Math.max(0, Math.floor(Date.now() / 1000 - startedAt))
            : elapsed + 1;
    }

    // The chip has to notice a recording the compositor keybind started, and
    // the only signal for that is the state files appearing. Each FileView
    // below watches its file's directory as well, which catches a creation
    // or an atomic replace with no polling; a reload rebuilds those inotify
    // watches, so nothing reloads them on a timer. The directory watch needs
    // the directory to exist before the first recording, so it is created
    // here as the script creates it, and the views re-arm once it does.
    Process {
        id: stateDirProc
        command: ["mkdir", "-p", "-m", "0700", root.stateDir]
        running: true
        onRunningChanged: {
            if (!running)
                root.refresh();
        }
    }

    // A PID file is only a ready marker, not proof the child is still alive:
    // wf-recorder can fail after the launching script exits and leave the
    // file behind. While the published PID names a live process, procfs is
    // read again every four seconds (no process, no watch), so a stale file
    // cannot pin the red chip on screen forever.
    Timer {
        id: liveness
        interval: 4000
        running: root.recorderPid > 0 && root.recorderName !== ""
        repeat: true
        onTriggered: procView.reload()
    }

    Timer {
        id: settle
        interval: 1200
        repeat: true
        triggeredOnStart: false
        property int ticks: 0
        onTriggered: {
            root.refresh();
            if (++ticks > 25) {
                ticks = 0;
                stop();
            }
        }
        onRunningChanged: {
            if (running)
                ticks = 0;
        }
    }

    Timer {
        interval: 1000
        running: root.active
        repeat: true
        onTriggered: root.recomputeElapsed()
    }

    onActiveChanged: recomputeElapsed()

    FileView {
        id: pidView
        path: root.stateDir + "/wf-recorder.pid"
        printErrors: false
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            const value = Number(text().trim());
            root.recorderPid = Number.isInteger(value) && value > 0 ? value : 0;
            if (root.recorderPid > 0)
                procView.reload();
            else
                root.active = false;
        }
        onLoadFailed: {
            root.recorderPid = 0;
            root.active = false;
            root.startedAt = 0;
        }
    }

    // Read on each liveness tick; see `liveness` above.
    FileView {
        id: procView
        path: root.recorderPid > 0 ? "/proc/" + root.recorderPid + "/comm" : ""
        printErrors: false
        onLoaded: {
            root.recorderName = text().trim();
            procStatView.reload();
            root.recomputeActive();
        }
        onLoadFailed: {
            root.recorderName = "";
            root.actualStartTicks = "";
            root.recomputeActive();
        }
    }

    FileView {
        id: procStatView
        path: root.recorderPid > 0 ? "/proc/" + root.recorderPid + "/stat" : ""
        printErrors: false
        onLoaded: {
            // Fields following the final `) ` begin at proc stat field 3;
            // process names may contain spaces, so splitting the whole line is
            // not safe. Start time is field 22, hence index 19 here.
            const raw = text();
            const close = raw.lastIndexOf(") ");
            const fields = close >= 0
                ? raw.slice(close + 2).trim().split(/\s+/) : [];
            root.actualStartTicks = fields.length > 19 ? fields[19] : "";
            root.recomputeActive();
        }
        onLoadFailed: {
            root.actualStartTicks = "";
            root.recomputeActive();
        }
    }

    FileView {
        id: ticksView
        path: root.stateDir + "/wf-recorder.start-ticks"
        printErrors: false
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            root.expectedStartTicks = text().trim();
            root.recomputeActive();
        }
        onLoadFailed: {
            root.expectedStartTicks = "";
            root.recomputeActive();
        }
    }

    FileView {
        id: stampView
        path: root.stateDir + "/started-at"
        printErrors: false
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            const value = Number(text().trim());
            root.startedAt = isFinite(value) && value > 0 ? value : 0;
            root.recomputeElapsed();
        }
        onLoadFailed: root.startedAt = 0
    }

    FileView {
        id: outputView
        path: root.stateDir + "/output-file"
        printErrors: false
        watchChanges: true
        onFileChanged: reload()
        onLoaded: root.outputFile = text().trim()
        onLoadFailed: root.outputFile = ""
    }
}
