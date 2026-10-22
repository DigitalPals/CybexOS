pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Qt.labs.folderlistmodel
import "SettingsHelpers.js" as SettingsHelpers
import "Format.js" as Format

// Wallpaper management: quickshell draws the image on the background layer;
// this singleton tracks the directory and delegates the current selection to
// the Settings store (design v2 Wallpaper page). Material color generation
// lives in Palette, keeping image selection and palette validation separate.
Singleton {
    id: root

    readonly property string dir: Settings.wallDir === "~"
        ? Quickshell.env("HOME")
        : Settings.wallDir.indexOf("~/") === 0
        ? Quickshell.env("HOME") + Settings.wallDir.slice(1) : Settings.wallDir
    property var files: []
    readonly property bool loading: folderModel.status === FolderListModel.Loading
    property string pendingDir: ""
    property bool candidateLoadingSeen: false
    property string directoryError: ""
    property var thumbnailPaths: ({})
    property var thumbnailPending: ({})
    property var thumbnailQueue: []
    // Sources handed to the running helper, in argument order, and how many
    // of its one-line-per-source answers have arrived.
    property var activeThumbnailBatch: []
    property int thumbnailAnswered: 0
    readonly property int thumbnailBatchLimit: 24
    readonly property string currentIdentity: dir + "/" + Settings.wall

    readonly property string current:
        Settings.wall !== "" ? url(dir + "/" + Settings.wall) : ""

    function url(path) {
        return path.startsWith("file:") ? path : "file://" + path;
    }

    function basename(path) {
        const raw = path.split("/").pop();
        try {
            return decodeURIComponent(raw);
        } catch (error) {
            return raw;
        }
    }

    function set(path) {
        Settings.set("wall", basename(path));
    }

    // Selects a file already in the wallpaper folder by its bare name, for
    // `ipc wallpaper set`. Anything else (a path, an unknown name) is refused,
    // so the call can only choose among the images the folder offers.
    function setByName(name) {
        if (typeof name !== "string" || name === "" || name.indexOf("/") >= 0)
            return false;
        if (!files.some(file => basename(file) === name))
            return false;
        set(name);
        return true;
    }

    function shuffle() {
        if (files.length < 2)
            return;
        const others = files.filter(f => basename(f) !== Settings.wall);
        set(others[Math.floor(Math.random() * others.length)]);
    }

    function refreshFiles() {
        const next = [];
        for (let i = 0; i < folderModel.count; i++) {
            const url = folderModel.get(i, "fileUrl");
            if (url)
                next.push(url.toString());
        }
        files = next;
    }

    // The settings grid asks only for its visible delegates. The helper keeps
    // 640x384 JPEG previews on disk and returns a source-revision query so a
    // changed wallpaper bypasses Qt's in-memory pixmap cache. Cached paths stay
    // in this singleton when the Settings page is closed and reopened.
    function thumbnailFor(path) {
        return thumbnailPaths[path] || "";
    }

    function requestThumbnail(path) {
        if (path === "" || thumbnailPending[path])
            return;
        const pending = Object.assign({}, thumbnailPending);
        pending[path] = true;
        thumbnailPending = pending;
        thumbnailQueue = thumbnailQueue.concat([path]);
        // Every visible cell asks in the same frame; collect them into one
        // helper run rather than starting Python once per cell.
        Qt.callLater(startNextThumbnail);
    }

    function startNextThumbnail() {
        if (thumbnailProc.running || activeThumbnailBatch.length > 0
                || thumbnailQueue.length === 0)
            return;
        activeThumbnailBatch = thumbnailQueue.slice(0, thumbnailBatchLimit);
        thumbnailQueue = thumbnailQueue.slice(thumbnailBatchLimit);
        thumbnailAnswered = 0;
        thumbnailProc.command = ["python3",
            Quickshell.shellDir + "/scripts/wallpaper-thumbnail.py"]
            .concat(activeThumbnailBatch);
        thumbnailProc.running = true;
    }

    // Records one helper answer. Anything that is not a cached file URL keeps
    // the old behavior of showing the full image.
    function settleThumbnail(source, cached) {
        const pending = Object.assign({}, thumbnailPending);
        delete pending[source];
        thumbnailPending = pending;
        const paths = Object.assign({}, thumbnailPaths);
        if (cached.indexOf("file:") === 0) {
            paths[source] = cached;
        } else {
            paths[source] = source;
            console.warn("wallpaper thumbnail generation failed for", source);
        }
        thumbnailPaths = paths;
    }

    // Settles on the falling edge of `running`, which is the only signal
    // Quickshell sends when python3 cannot start at all; sources the helper
    // never answered fall back rather than stalling the queue.
    function finishThumbnailBatch() {
        const batch = activeThumbnailBatch;
        const answered = thumbnailAnswered;
        activeThumbnailBatch = [];
        thumbnailAnswered = 0;
        for (let i = answered; i < batch.length; i++)
            settleThumbnail(batch[i], "");
        Qt.callLater(startNextThumbnail);
    }

    function requestDirectory(path) {
        const normalized = SettingsHelpers.pathIn(path, "");
        if (normalized === "") {
            directoryError = "Choose an absolute folder or a path under ~/";
            return;
        }
        if (normalized === Settings.wallDir) {
            directoryError = "";
            return;
        }
        pendingDir = normalized;
        candidateLoadingSeen = false;
        directoryError = "";
        const expanded = normalized === "~" ? Quickshell.env("HOME")
            : normalized.indexOf("~/") === 0
            ? Quickshell.env("HOME") + normalized.slice(1) : normalized;
        candidateModel.folder = url(expanded);
        candidateTimeout.restart();
        Qt.callLater(validateCandidate);
    }

    function validateCandidate() {
        if (pendingDir === "" || !candidateLoadingSeen
                || candidateModel.status === FolderListModel.Loading)
            return;
        candidateTimeout.stop();
        if (candidateModel.count < 1) {
            directoryError = "Folder is unreadable or has no supported images";
            pendingDir = "";
            return;
        }
        let selected = "";
        for (let i = 0; i < candidateModel.count; i++) {
            const candidate = candidateModel.get(i, "fileName");
            if (candidate === Settings.wall) {
                selected = candidate;
                break;
            }
        }
        if (selected === "")
            selected = candidateModel.get(0, "fileName");
        const committed = pendingDir;
        pendingDir = "";
        Settings.set("wallDir", committed);
        Settings.set("wall", selected);
    }

    FolderListModel {
        id: folderModel
        folder: "file://" + root.dir
        nameFilters: ["*.jpg", "*.jpeg", "*.png", "*.webp", "*.JPG", "*.JPEG", "*.PNG", "*.WEBP"]
        showDirs: false
        showFiles: true
        sortField: FolderListModel.Name
        onCountChanged: root.refreshFiles()
        onStatusChanged: root.refreshFiles()
    }

    FolderListModel {
        id: candidateModel
        nameFilters: folderModel.nameFilters
        showDirs: false
        showFiles: true
        sortField: FolderListModel.Name
        onCountChanged: Qt.callLater(root.validateCandidate)
        onStatusChanged: {
            if (status === FolderListModel.Loading)
                root.candidateLoadingSeen = true;
            Qt.callLater(root.validateCandidate);
        }
    }

    Timer {
        id: candidateTimeout
        interval: 2500
        onTriggered: {
            root.directoryError = "Folder could not be read";
            root.pendingDir = "";
        }
    }

    // Pre-settings state file, now read-only: migrated into Settings.wall on
    // the store's first run and never written again.
    FileView {
        id: legacyState
        path: Quickshell.statePath("wallpaper")
        printErrors: false
        onLoaded: {
            const saved = text().trim();
            if (Settings.firstRun && saved !== "")
                Settings.set("wall", saved.split("/").pop());
        }
    }

    // ---- rotate wallpaper -------------------------------------------------
    readonly property int shuffleMs: Settings.shuffle === "15m" ? 900000
        : Settings.shuffle === "1h" ? Format.MS_HOUR : Format.MS_DAY
    // A rotation that fell due while nobody was looking.
    property bool shuffleOwed: false

    // A change is a 4K decode plus a Matugen run, so an idle or locked
    // session does not rotate; the first input afterwards takes the one
    // rotation it missed. The timer keeps running through idle, because
    // restarting a daily interval at every idle spell would never fire.
    Timer {
        running: Settings.shuffle !== "Off"
        repeat: true
        interval: root.shuffleMs
        onTriggered: {
            if (Activity.idle)
                root.shuffleOwed = true;
            else
                root.shuffle();
        }
        onRunningChanged: {
            if (!running)
                root.shuffleOwed = false;
        }
    }

    Connections {
        target: Activity

        function onResumed() {
            if (!root.shuffleOwed)
                return;
            root.shuffleOwed = false;
            root.shuffle();
        }
    }

    Process {
        id: thumbnailProc

        // One line per source, flushed as each finishes, so a cell shows
        // its preview without waiting for the rest of the batch.
        stdout: SplitParser {
            onRead: line => {
                // The helper never prints a blank answer ("-" is failure).
                const index = root.thumbnailAnswered;
                if (line.trim() === "" || index >= root.activeThumbnailBatch.length)
                    return;
                root.thumbnailAnswered = index + 1;
                root.settleThumbnail(root.activeThumbnailBatch[index], line.trim());
            }
        }

        onRunningChanged: {
            if (!running && root.activeThumbnailBatch.length > 0)
                root.finishThumbnailBatch();
        }
    }
}
