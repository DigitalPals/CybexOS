pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "GameModeState.js" as GameModeState

// Game mode, read from the state file game-mode keeps in
// $XDG_RUNTIME_DIR/cybexos. The helper owns the compositor effects and the
// idle inhibitor and is bound to Super+Shift+G, so game mode can start without
// the shell; watching its state keeps the indicator honest either way.
Singleton {
    id: root

    readonly property string stateDir:
        (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/cybexos"
    readonly property string helper:
        "game-mode"
    readonly property string instance:
        Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") || ""

    property bool active: false

    function turnOff() {
        Quickshell.execDetached([root.helper, "off"]);
    }

    // The FileView also watches its file's directory, which catches the
    // helper's atomic replace with no polling. That directory must exist
    // before game mode is first turned on, so it is created here exactly as
    // the session starter and the helper create it, and the view re-arms.
    Process {
        command: ["mkdir", "-p", "-m", "0700", root.stateDir]
        running: true
        onRunningChanged: {
            if (!running)
                stateView.reload();
        }
    }

    FileView {
        id: stateView
        path: root.stateDir + "/game-mode.json"
        printErrors: false
        watchChanges: true
        onFileChanged: reload()
        onLoaded: root.active = GameModeState.isActive(text(), root.instance)
        onLoadFailed: root.active = false
    }
}
