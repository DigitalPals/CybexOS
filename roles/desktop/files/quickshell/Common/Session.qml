pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "ProcHelpers.js" as ProcHelpers
import "KeybindHelpers.js" as KeybindHelpers

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

    // The cheatsheet's groups, read from Hyprland's live bindings each time
    // it opens (KeybindHelpers.js documents the description convention). A
    // binding added in user.lua therefore appears without a shell restart,
    // and a failed read shows as an error rather than as a stale list.
    property var shortcutGroups: []
    property string shortcutsError: ""
    readonly property bool shortcutsLoading: bindsQuery.running

    function refreshShortcuts() {
        if (!bindsQuery.running)
            bindsQuery.running = true;
    }

    function openKeys(targetScreen) {
        const popoutScreen = Screens.byName(Popouts.hostScreenName);
        screen = targetScreen ?? popoutScreen ?? Screens.focused;
        Popouts.close();
        Launcher.close();
        refreshShortcuts();
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

    Process {
        id: bindsQuery

        property bool exitSeen: false
        property int lastExit: ProcHelpers.NOT_STARTED
        property string output: ""
        property string errorText: ""

        command: ["hyprctl", "binds", "-j"]
        stdout: StdioCollector {
            onStreamFinished: bindsQuery.output = text
        }
        stderr: StdioCollector {
            onStreamFinished: bindsQuery.errorText = text
        }
        onExited: exitCode => {
            exitSeen = true;
            lastExit = exitCode;
        }
        onRunningChanged: {
            if (running) {
                exitSeen = false;
                lastExit = ProcHelpers.NOT_STARTED;
                output = "";
                errorText = "";
                return;
            }
            const code = exitSeen ? lastExit : ProcHelpers.NOT_STARTED;
            if (code !== 0) {
                root.shortcutGroups = [];
                root.shortcutsError = ProcHelpers.commandError("hyprctl", code, errorText);
                return;
            }
            const result = KeybindHelpers.fromJson(output);
            root.shortcutGroups = result.groups;
            root.shortcutsError = result.error;
        }
    }
}
