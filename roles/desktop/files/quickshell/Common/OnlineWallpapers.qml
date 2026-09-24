pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import "WallhavenHelpers.js" as WallhavenHelpers

// Wallhaven search and download behind the Wallpaper page's Online view.
//
// Nothing here reaches the network until that view asks. Opening it runs the
// first search; after that only an explicit search, a filter change, "Show
// more" or a picked image makes a request, which keeps a person well inside
// Wallhaven's 45 requests a minute. Results live here rather than in the page,
// which Settings releases shortly after it closes, so reopening the view does
// not search again.
//
// A picked image is saved into the wallpaper folder by
// scripts/wallpaper-download.py and then selected like any other file there,
// so Matugen colours, rotation and the Library grid need nothing extra.
Singleton {
    id: root

    // Which half of the Wallpaper page is showing: "library" or "online".
    property string view: "library"

    // The filters start from these and the page's rows reset to them.
    readonly property var defaults: ({ sort: "popular", category: "general", size: "fit" })
    property string query: ""
    property string sort: defaults.sort
    property string category: defaults.category
    property string size: defaults.size

    property var results: []
    property int page: 0
    property int lastPage: 0
    property string seed: ""
    property bool busy: false
    property bool appending: false
    property bool searched: false
    property string error: ""
    property var request: null
    property int generation: 0

    readonly property bool hasMore: searched && !busy && page > 0 && page < lastPage
    // Each output's mode in pixels, from Hyprland. Qt's screen scale is the
    // integer wl_output scale (2 for a 1.5 fractional scale), which would ask
    // a 4K output for 5K images. A rotated output (odd transform) swaps sides.
    readonly property var screenSizes: Hyprland.monitors.values.map(monitor => {
        const transform = monitor.lastIpcObject ? Number(monitor.lastIpcObject.transform) : 0;
        const rotated = transform % 2 === 1;
        return {
            width: rotated ? monitor.height : monitor.width,
            height: rotated ? monitor.width : monitor.height,
            devicePixelRatio: 1
        };
    })
    readonly property string minimum: WallhavenHelpers.minimumFor(screenSizes)
    readonly property bool landscape: WallhavenHelpers.allLandscape(screenSizes)

    // File names already in the wallpaper folder, so a tile can say its image
    // is saved and picking it again needs no download.
    readonly property var saved: {
        const names = {};
        for (const file of Wallpaper.files)
            names[Wallpaper.basename(file)] = true;
        return names;
    }

    function ensureLoaded() {
        if (!searched && !busy)
            search();
    }

    function search() {
        fetchPage(1);
    }

    function more() {
        if (hasMore)
            fetchPage(page + 1);
    }

    function cancelSearch() {
        generation++;
        deadline.stop();
        const old = request;
        request = null;
        busy = false;
        appending = false;
        if (old) {
            old.onreadystatechange = null;
            old.abort();
        }
    }

    function failSearch(message) {
        cancelSearch();
        searched = true;
        error = message;
    }

    function fetchPage(target) {
        cancelSearch();
        const nextPage = target > 1;
        if (!nextPage) {
            results = [];
            page = 0;
            lastPage = 0;
            seed = "";
            searched = false;
        }
        busy = true;
        appending = nextPage;
        error = "";
        const token = generation;
        const url = WallhavenHelpers.searchUrl({
            query: query,
            sort: sort,
            category: category,
            minimum: size === "fit" ? minimum : "",
            landscape: size === "fit" && landscape,
            page: target,
            seed: seed
        });
        try {
            const xhr = new XMLHttpRequest();
            request = xhr;
            xhr.onreadystatechange = () => {
                if (token !== root.generation || xhr.readyState !== XMLHttpRequest.DONE)
                    return;
                deadline.stop();
                root.request = null;
                let parsed = null;
                if (xhr.status !== 200) {
                    root.error = WallhavenHelpers.statusError(xhr.status);
                } else {
                    try {
                        parsed = WallhavenHelpers.parseResults(xhr.responseText);
                    } catch (e) {
                        root.error = "Wallhaven returned an unreadable response. Try again.";
                    }
                }
                if (parsed !== null) {
                    root.results = nextPage ? WallhavenHelpers.merge(root.results, parsed.items)
                        : parsed.items;
                    root.page = parsed.page;
                    root.lastPage = parsed.lastPage;
                    if (parsed.seed !== "")
                        root.seed = parsed.seed;
                }
                // Settled last: the grid's footer shrinks and its end-of-list
                // check runs when these change, and both must see the page
                // that just arrived. Clearing them first let the shrinking
                // footer ask for that same page again.
                root.searched = true;
                root.appending = false;
                root.busy = false;
            };
            xhr.open("GET", url);
            deadline.restart();
            xhr.send();
        } catch (e) {
            failSearch("The search could not start. Try again.");
        }
    }

    Timer {
        id: deadline
        interval: 15000
        onTriggered: root.failSearch("Wallhaven did not answer in time. Check your connection and try again.")
    }

    // ---- download ---------------------------------------------------------
    // One download at a time, and the latest pick wins: picking another image
    // stops the running helper (SIGTERM; it removes its partial file) and
    // starts the new one once the old process has exited.
    property var downloadItem: null
    property string downloadDir: ""
    property var pendingItem: null
    property int downloadProgress: 0
    property string downloadResult: ""
    property string downloadError: ""
    property string failedId: ""
    readonly property string downloadingId: downloadItem ? downloadItem.id : ""

    function apply(item) {
        if (!item || item.id === downloadingId)
            return;
        downloadError = "";
        failedId = "";
        if (saved[item.fileName] && !downloadProc.running) {
            Wallpaper.set(item.fileName);
            return;
        }
        pendingItem = item;
        if (downloadProc.running)
            downloadProc.running = false;
        else
            startPending();
    }

    function startPending() {
        const item = pendingItem;
        pendingItem = null;
        if (!item || downloadProc.running)
            return;
        if (saved[item.fileName]) {
            Wallpaper.set(item.fileName);
            return;
        }
        downloadItem = item;
        downloadDir = Wallpaper.dir;
        downloadProgress = 0;
        downloadResult = "";
        downloadProc.command = ["python3",
            Quickshell.shellDir + "/scripts/wallpaper-download.py",
            item.image, downloadDir, String(item.size)];
        downloadProc.running = true;
    }

    // Settles on the falling edge of `running`, which also arrives when
    // python3 never started; a helper that printed no verdict counts as failed.
    function finishDownload() {
        const item = downloadItem;
        const result = downloadResult;
        const directory = downloadDir;
        downloadItem = null;
        downloadResult = "";
        downloadDir = "";
        if (pendingItem !== null) {
            // Superseded by a newer pick: the cancellation is not news.
            Qt.callLater(startPending);
            return;
        }
        if (result.indexOf("done ") === 0) {
            // A folder change while the image arrived: the file is saved
            // where it started, but it is not in the folder now on display.
            if (directory === Wallpaper.dir)
                Wallpaper.set(result.slice(5));
            return;
        }
        failedId = item ? item.id : "";
        downloadError = WallhavenHelpers.downloadError(
            result.indexOf("failed ") === 0 ? result.slice(7) : "");
    }

    Process {
        id: downloadProc

        stdout: SplitParser {
            onRead: line => {
                const text = line.trim();
                if (text.indexOf("progress ") === 0) {
                    const value = parseInt(text.slice(9), 10);
                    if (value >= 0 && value <= 100)
                        root.downloadProgress = value;
                } else if (text.indexOf("done ") === 0 || text.indexOf("failed ") === 0) {
                    root.downloadResult = text;
                }
            }
        }

        onRunningChanged: {
            if (!running && root.downloadItem !== null)
                root.finishDownload();
        }
    }
}
