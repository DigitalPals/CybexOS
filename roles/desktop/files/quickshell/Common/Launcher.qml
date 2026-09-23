pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "Format.js" as Format

// Launcher lifecycle and persistent application-use ranking. The selected
// screen is captured when opening so the overlay does not jump mid-search.
Singleton {
    id: root

    property bool open: false
    property var screen: null
    property var usage: ({})

    readonly property string usageFile: Quickshell.statePath("launcher-usage.json")

    function toggle(targetScreen) {
        if (open) {
            close();
            return;
        }
        Popouts.close();
        screen = targetScreen ?? Screens.focused;
        open = true;
    }

    function close() {
        open = false;
    }

    function recordLaunch(app) {
        const key = app.id || app.name;
        const previous = usage[key] || { count: 0, last: 0 };
        const next = Object.assign({}, usage);
        next[key] = { count: previous.count + 1, last: Date.now() };
        usage = next;
        usageView.setText(JSON.stringify(usage));
    }

    function usageBoost(app) {
        const item = usage[app.id || app.name];
        if (!item)
            return 0;
        const ageDays = Math.max(0, Date.now() - item.last) / Format.MS_DAY;
        return Math.log(1 + item.count) * 180 + 700 / (1 + ageDays);
    }

    // A `>` command is started detached, like every other launcher row: a
    // tracked Process would be SIGTERMed by the next command and by a shell
    // reload, and a stderr collector would buffer a long-lived app's output
    // for its whole lifetime. The typed text is handed to the wrapper as a
    // positional argument, never spliced into it, so the only shell that
    // parses it is the inner `sh -c "$1"` the user asked for. Its stderr goes
    // to the journal with the shell's own; a failure still raises a
    // notification carrying the exit status.
    function executeCommand(command) {
        Quickshell.execDetached(["sh", "-c",
            'sh -c "$1"; rc=$?; [ "$rc" -eq 0 ] || '
            + 'notify-send "Launcher command failed" "$1 exited with status $rc"',
            "sh", command]);
        close();
    }

    FileView {
        id: usageView
        path: root.usageFile
        printErrors: false
        atomicWrites: true
        blockWrites: true
        onLoaded: {
            try {
                const parsed = JSON.parse(text());
                if (parsed && typeof parsed === "object")
                    root.usage = parsed;
            } catch (e) {
                console.warn("launcher usage state is invalid:", e);
            }
        }
    }
}
