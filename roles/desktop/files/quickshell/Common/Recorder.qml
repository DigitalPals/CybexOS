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
// chip honest either way. A scrolling screenshot (~/.local/bin/screenshot
// scroll) publishes its capture in the same directory and lights the same
// chip, and a --webcam recording its area for WebcamOverlay.
Singleton {
    id: root

    readonly property string stateDir:
        (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/screen-record"
    readonly property string script:
        Quickshell.env("HOME") + "/.local/bin/screen-record"
    readonly property string screenshotScript:
        Quickshell.env("HOME") + "/.local/bin/screenshot"

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

    // `screenshot scroll` publishes "PID START_TICKS" here while it captures
    // frames. It shares the recording indicator: both mean "the screen is
    // being captured; click to finish".
    property bool scrolling: false
    property int scrollPid: 0
    property string scrollStartTicks: ""

    // The area a `screen-record --webcam` recording covers ("X,Y WxH"); empty
    // for any other recording. The camera bubble (WebcamOverlay) is shown
    // inside it while the recording runs.
    property string webcamGeometry: ""
    readonly property bool webcamRequested: webcamGeometry !== ""
    // The script publishes the request before the recorder has started, so
    // the camera can warm up meanwhile. Only that start-up window is allowed
    // without an active recording: a request left behind by a killed script
    // must not keep a camera open.
    readonly property bool webcamWanted: webcamRequested
        && (active || webcamStartup.running)
    // Where the user last dragged the bubble, for the rest of the session.
    property string webcamCorner: "bottom-right"

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

    // Finishes a running scrolling screenshot; never starts one.
    function finishScroll() {
        Quickshell.execDetached([root.screenshotScript, "scroll-stop"]);
    }

    function refresh() {
        pidView.reload();
        ticksView.reload();
        stampView.reload();
        outputView.reload();
        webcamView.reload();
        scrollView.reload();
    }

    // /proc comm is cut to 15 characters, so gpu-screen-recorder, which the
    // script prefers on NVIDIA when it is installed, reads "gpu-screen-reco".
    function recomputeActive() {
        active = recorderPid > 0
            && (recorderName === "wf-recorder" || recorderName === "gpu-screen-reco")
            && expectedStartTicks !== ""
            && expectedStartTicks === actualStartTicks;
    }

    // Field 22 of /proc/PID/stat, the process start time. Fields following
    // the final `) ` begin at field 3; process names may contain spaces, so
    // splitting the whole line is not safe.
    function startTicks(stat) {
        const close = stat.lastIndexOf(") ");
        const fields = close >= 0 ? stat.slice(close + 2).trim().split(/\s+/) : [];
        return fields.length > 19 ? fields[19] : "";
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
            root.actualStartTicks = root.startTicks(text());
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

    Timer {
        id: webcamStartup
        interval: 6000
    }

    FileView {
        id: webcamView
        path: root.stateDir + "/webcam"
        printErrors: false
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            const geometry = text().trim();
            if (geometry !== "" && geometry !== root.webcamGeometry)
                webcamStartup.restart();
            root.webcamGeometry = geometry;
        }
        onLoadFailed: root.webcamGeometry = ""
    }

    // A scrolling capture is published as one "PID START_TICKS" line and
    // validated against procfs like the recorder, so a capture that was
    // killed cannot leave the indicator lit. While a published capture is
    // alive, procfs is read again every four seconds; otherwise nothing polls.
    Timer {
        interval: 4000
        running: root.scrollPid > 0 && root.scrolling
        repeat: true
        onTriggered: scrollStatView.reload()
    }

    FileView {
        id: scrollView
        path: root.stateDir + "/scroll-capture"
        printErrors: false
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            const fields = text().trim().split(/\s+/);
            const pid = Number(fields[0]);
            root.scrollPid = Number.isInteger(pid) && pid > 0 ? pid : 0;
            root.scrollStartTicks = fields.length > 1 ? fields[1] : "";
            if (root.scrollPid > 0)
                scrollStatView.reload();
            else
                root.scrolling = false;
        }
        onLoadFailed: {
            root.scrollPid = 0;
            root.scrollStartTicks = "";
            root.scrolling = false;
        }
    }

    FileView {
        id: scrollStatView
        path: root.scrollPid > 0 ? "/proc/" + root.scrollPid + "/stat" : ""
        printErrors: false
        onLoaded: root.scrolling = root.scrollStartTicks !== ""
            && root.startTicks(text()) === root.scrollStartTicks
        onLoadFailed: root.scrolling = false
    }
}
