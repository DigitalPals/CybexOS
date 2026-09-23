pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "ProcHelpers.js" as ProcHelpers

// Session actions used by the Control Panel and the keyboard cheatsheet
// reachable from its footer or Super+K.
Singleton {
    id: root

    property bool keysOpen: false
    property var screen: null
    property string actionInFlight: ""
    property string actionError: ""
    property string actionOutput: ""
    readonly property bool actionBusy: sessionAction.running

    function openKeys(targetScreen) {
        const popoutScreen = Screens.byName(Popouts.hostScreenName);
        screen = targetScreen ?? popoutScreen ?? Screens.focused;
        Popouts.close();
        Launcher.close();
        keysOpen = true;
    }

    function closeKeys() {
        keysOpen = false;
    }

    function toggleKeys(targetScreen) {
        if (keysOpen)
            closeKeys();
        else
            openKeys(targetScreen);
    }

    function closeAll() {
        keysOpen = false;
    }

    function run(action) {
        if (sessionAction.running)
            return false;
        closeAll();
        actionError = "";
        actionOutput = "";
        actionInFlight = action;
        sessionAction.command = ["/usr/local/libexec/cybexos-session-action", action];
        sessionAction.running = true;
        return true;
    }

    function lock() {
        return run("lock");
    }

    function suspend() {
        return run("suspend");
    }

    function reboot() {
        return run("reboot");
    }

    function shutdown() {
        return run("shutdown");
    }

    function logout() {
        return run("logout");
    }

    Process {
        id: sessionAction

        property bool exitSeen: false
        property int lastExit: ProcHelpers.NOT_STARTED

        stdout: StdioCollector {
            onStreamFinished: root.actionOutput = text.trim()
        }
        stderr: StdioCollector {
            onStreamFinished: root.actionError = text.trim()
        }
        onExited: exitCode => {
            exitSeen = true;
            lastExit = exitCode;
        }
        onRunningChanged: {
            if (running) {
                exitSeen = false;
                lastExit = ProcHelpers.NOT_STARTED;
                return;
            }
            if (root.actionInFlight === "")
                return;
            const finishedAction = root.actionInFlight;
            root.actionInFlight = "";
            const code = exitSeen ? lastExit : ProcHelpers.NOT_STARTED;
            if (code !== 0) {
                const detail = root.actionError !== "" ? root.actionError
                    : "The " + finishedAction + " action could not be completed.";
                root.actionError = detail;
                Notifs.send({
                    appName: "Session",
                    appIcon: "system-lock-screen",
                    summary: "Session action failed",
                    body: detail
                });
            }
        }
    }

    // The rows the cheatsheet draws. Kept here rather than in the overlay so
    // the list is data the Control Panel could also summarise, and so it
    // stays next to the actions it documents.
    readonly property var shortcutGroups: [
        {
            title: "SHELL",
            rows: [
                { label: "Launcher", keys: ["Super", "Space"] },
                { label: "Notifications", keys: ["Super", "N"] },
                { label: "Control Panel", keys: ["Super", "A"] },
                { label: "Shell settings", keys: ["Super", ","] },
                { label: "AI agent", keys: ["Super", "Ctrl", "Shift", "A"] },
                { label: "T3 Code", keys: ["Super", "T"] },
                { label: "Lock", keys: ["Super", "L"] },
                { label: "This overlay", keys: ["Super", "K"] }
            ]
        },
        {
            title: "WINDOWS",
            rows: [
                { label: "Close window", keys: ["Super", "Q"] },
                { label: "Toggle float", keys: ["Super", "F"] },
                { label: "Toggle split", keys: ["Super", "J"] },
                { label: "Focus", keys: ["Super", "←", "→"] },
                { label: "Fade window", keys: ["Super", "Backspace"] }
            ]
        },
        {
            title: "WORKSPACES",
            rows: [
                { label: "Switch", keys: ["Super", "1…9"] },
                { label: "Send window", keys: ["Super", "Shift", "1…9"] },
                { label: "Cycle", keys: ["Super", "Scroll"] }
            ]
        },
        {
            title: "CAPTURE & MEDIA",
            rows: [
                { label: "Region screenshot", keys: ["Print"] },
                { label: "Whole screen", keys: ["Shift", "Print"] },
                { label: "Record screen", keys: ["Super", "Shift", "`"] },
                { label: "OCR a region", keys: ["Super", "Shift", "O"] },
                { label: "Volume · brightness", keys: ["Fn"] }
            ]
        }
    ]
}
