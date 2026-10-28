pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "SettingsSearchData.js" as SearchData
import "SettingsRecentHelpers.js" as Helpers

// The settings a person changed in the Settings window, kept for Home's
// "Recently changed" list with the value each replaced, so Undo restores it
// days later as well as seconds later. A small private state file, written
// once a burst of changes settles; shell.json itself is never touched here.
Singleton {
    id: root

    readonly property string filePath: Quickshell.env("HOME")
        + "/.local/state/cybexos/shell/settings-recent.json"
    property var entries: []
    // An Undo writes through Settings.set too; that write is not a change.
    property bool restoring: false
    // A minute tick keeps "5 minutes ago" true while Home is on screen.
    property double now: Date.now()

    readonly property var rows: {
        void Settings.revision;
        return Helpers.visible(root.entries, SearchData.ROWS, key => Settings[key], root.now);
    }

    function undo(row) {
        if (!row)
            return;
        restoring = true;
        Settings.set(row.key, row.entry.before);
        restoring = false;
        entries = Helpers.remove(entries, row.key);
        saveTimer.restart();
        Settings.announcement = row.label + " restored.";
    }

    Connections {
        target: Settings
        function onValueSet(key, before, after) {
            // Only what the person did in the Settings window: the Control
            // Center's toggles and the shell's own bookkeeping are not changes
            // anyone would look for here.
            if (root.restoring || !Settings.panelOpen)
                return;
            const next = Helpers.record(root.entries, SearchData.ROWS, key, before, after, Date.now());
            if (next !== root.entries) {
                root.entries = next;
                saveTimer.restart();
            }
        }
    }

    Timer {
        interval: 60000
        running: Settings.panelOpen
        repeat: true
        triggeredOnStart: true
        onTriggered: root.now = Date.now()
    }

    Timer {
        id: saveTimer
        interval: 1000
        onTriggered: store.setText(Helpers.serialize(root.entries))
    }

    FileView {
        id: store
        path: root.filePath
        printErrors: false
        atomicWrites: true
        onLoaded: root.entries = Helpers.parse(text())
    }
}
