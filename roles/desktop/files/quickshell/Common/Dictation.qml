pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Voxtype writes this state for every control path, including compositor
// keybindings. Watching it keeps the menubar honest even when it did not start
// the recording itself.
Singleton {
    id: root

    // Voxtype is installed only with the developer tooling feature. Without
    // it there is no daemon, so nothing watches or waits for its state file
    // and the menubar offers no dictation.
    readonly property bool available: Settings.developerToolsConfigured
    readonly property string statePath:
        (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/voxtype/state"
    property string state: "idle"
    readonly property bool recording: state === "recording"
    readonly property bool transcribing: state === "transcribing"
    readonly property bool busy: recording || transcribing

    function refresh() {
        stateView.reload();
    }

    function run(command) {
        Quickshell.execDetached(command);
        settle.restart();
    }

    function toggle(language) {
        if (recording)
            run(["voxtype", "record", "stop"]);
        else if (transcribing)
            run(["voxtype", "record", "cancel"]);
        else {
            const selected = language || Settings.modOpts.indicators.dictationPrimaryLanguage;
            if (selected === "off")
                return;
            run(["voxtype", "--model", Settings.modOpts.indicators.dictationModel,
                "--language", selected, "record", "start"]);
        }
    }

    // Whether the last read found no state file. The view also watches the
    // file's directory, so while the file exists a creation or an atomic
    // replace is seen without polling; only a missing file may have taken
    // its directory with it (the daemon not started yet), and a missing
    // directory cannot be watched.
    property bool stateMissing: false

    FileView {
        id: stateView
        path: root.available ? root.statePath : ""
        printErrors: false
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            root.stateMissing = false;
            const value = text().trim();
            root.state = ["idle", "recording", "transcribing"].indexOf(value) !== -1
                ? value : "idle";
        }
        onLoadFailed: {
            root.stateMissing = true;
            root.state = "idle";
        }
    }

    // inotify covers normal transitions; this bounded replay covers a daemon
    // replacing the state file between watches after a bar-originated action.
    Timer {
        id: settle
        interval: 250
        repeat: true
        property int ticks: 0
        onTriggered: {
            root.refresh();
            if (++ticks >= 20)
                stop();
        }
        onRunningChanged: {
            if (running)
                ticks = 0;
        }
    }

    // Each reload rebuilds the view's inotify watches, so the poll runs only
    // while there is no file to watch, and not while the session is idle.
    Timer {
        interval: 3000
        running: root.available && root.stateMissing && !Activity.idle
        repeat: true
        onTriggered: root.refresh()
    }

    Connections {
        target: Activity

        function onResumed() {
            if (root.available && root.stateMissing)
                root.refresh();
        }
    }
}
