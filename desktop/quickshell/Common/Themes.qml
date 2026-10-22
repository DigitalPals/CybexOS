pragma Singleton
import QtQuick
import Quickshell
import Qt.labs.folderlistmodel
import "SettingsHelpers.js" as SettingsHelpers
import "ThemeHelpers.js" as ThemeHelpers

// Named appearance themes (docs/shell-appearance.md#themes). The theme files,
// their validation, wallpaper copying and the mapping of a theme to settings
// live in scripts/theme-packs.py, which `cybex theme` runs too; this lists
// themes for Settings → Appearance and applies one as a single undoable
// settings change. Nothing is read until Appearance opens or IPC asks; from
// then on a theme folder added or removed by hand appears without a restart.
Singleton {
    id: root

    readonly property string script: Quickshell.shellDir + "/scripts/theme-packs.py"
    // cybexos-runtime exports the user theme root to the shell.
    readonly property string userRoot: Quickshell.env("CYBEXOS_THEME_ROOT")
        || Quickshell.env("HOME") + "/.local/share/cybexos/themes"
    property var entries: []
    property bool loaded: false
    // The last failure, for the Theme row's hint.
    property string error: ""
    // A completed save, for the same hint.
    property string message: ""
    readonly property bool busy: listRequest.running || resolveRequest.running
        || saveRequest.running

    // What the current settings show: { value, label, modified }.
    readonly property var current: {
        void Settings.revision;
        return ThemeHelpers.current(root.entries, Settings);
    }

    function refresh() {
        if (listRequest.running) {
            listRequest.again = true;
            return;
        }
        listRequest.running = true;
    }

    function parseReply(body) {
        try {
            return JSON.parse(body);
        } catch (e) {
            return null;
        }
    }

    function failure(code, body, stderr, fallback) {
        const reply = parseReply(body);
        if (reply && typeof reply.error === "string" && reply.error !== "")
            return reply.error;
        const lines = String(stderr || "").trim().split("\n");
        return lines[lines.length - 1] || fallback + " (exit " + code + ")";
    }

    // Copies the theme's wallpaper into the wallpaper folder if it has one,
    // then applies it.
    function apply(id) {
        if (resolveRequest.running || typeof id !== "string" || id === "")
            return;
        error = "";
        message = "";
        resolveRequest.command = ["python3", "-B", root.script, "resolve", id,
            "--wall-dir", Wallpaper.dir];
        resolveRequest.running = true;
    }

    // `theme use` IPC: a payload `cybex theme apply` resolved. The shell checks
    // it against its own schema before anything changes. Returns "ok" or
    // "error: <reason>".
    function use(text) {
        const payload = ThemeHelpers.payloadIn(parseReply(text), SettingsHelpers.normalizeKey);
        if (payload === null)
            return "error: the theme does not fit this shell's settings";
        if (!Settings.loaded || Settings.loadError)
            return "error: settings are not available";
        Settings.applyValues(payload.patch, "Theme",
            "Applied " + payload.name + ". Undo available for eight seconds.");
        error = "";
        return "ok";
    }

    function saveCurrent(name) {
        const trimmed = ThemeHelpers.nameIn(name);
        if (saveRequest.running || trimmed === "")
            return false;
        error = "";
        message = "";
        saveRequest.command = ["python3", "-B", root.script, "save", "--name", trimmed];
        saveRequest.inputText = JSON.stringify(Settings.snapshot()) + "\n";
        saveRequest.running = true;
        return true;
    }

    Component.onCompleted: refresh()

    FolderListModel {
        folder: "file://" + root.userRoot
        showDirs: true
        showFiles: false
        showHidden: false
        onCountChanged: refreshTimer.restart()
    }

    // An install renames one finished folder into place; a burst of changes
    // is listed once.
    Timer {
        id: refreshTimer
        interval: 300
        onTriggered: root.refresh()
    }

    CommandRequest {
        id: listRequest
        property bool again: false
        command: ["python3", "-B", root.script, "list", "--json"]
        timeoutMs: 15000
        onCompleted: (code, body, stderr) => {
            const reply = code === 0 ? root.parseReply(body) : null;
            if (reply) {
                root.entries = ThemeHelpers.catalogueIn(reply, SettingsHelpers.normalizeKey);
                root.loaded = true;
            } else {
                root.error = root.failure(code, body, stderr, "Could not list themes");
            }
            if (again) {
                again = false;
                Qt.callLater(root.refresh);
            }
        }
    }

    CommandRequest {
        id: resolveRequest
        timeoutMs: 30000
        onCompleted: (code, body, stderr) => {
            const result = code === 0 ? root.use(body.trim()) : "";
            if (code !== 0)
                root.error = root.failure(code, body, stderr, "Could not apply the theme");
            else if (result !== "ok")
                root.error = result.replace(/^error: /, "");
        }
    }

    CommandRequest {
        id: saveRequest
        stdinEnabled: true
        timeoutMs: 15000
        onCompleted: (code, body, stderr) => {
            const reply = code === 0 ? root.parseReply(body) : null;
            if (!reply || typeof reply.id !== "string") {
                root.error = root.failure(code, body, stderr, "Could not save the theme");
                return;
            }
            // The new theme is made from these settings, so it is current.
            Settings.set("theme", reply.id);
            root.message = "Saved as " + reply.name;
            root.refresh();
        }
    }
}
