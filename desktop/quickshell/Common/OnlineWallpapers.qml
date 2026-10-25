pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import "WallhavenHelpers.js" as WallhavenHelpers

// Wallhaven listings, selected-image details and explicit downloads.
//
// Creating the singleton never contacts Wallhaven. The chosen view asks for
// its first listing; welcome first checks metering. Searches and details share
// one request budget, and cached details survive the Settings view's lifetime.
// A download starts only from Apply, saves into the user's wallpaper folder,
// and joins the same Matugen/rotation flow as a local file.
Singleton {
    id: root

    // Settings tab state; an embedded picker can keep its own tab.
    property string view: "collection"

    // The filters start from these and the page's rows reset to them.
    readonly property var defaults: ({ sort: "popular", category: "general", size: "fit" })
    property string query: ""
    property string color: ""
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
    readonly property var screenSizes: Hyprland.monitors.values.length === 0
        ? Quickshell.screens.map(screen => ({ width: screen.width, height: screen.height,
            devicePixelRatio: screen.devicePixelRatio }))
        : Hyprland.monitors.values.map(monitor => {
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

    function ensureLoaded(automatic) {
        if (automatic && !autoLoadAllowed())
            return;
        if (!searched && !busy)
            search();
    }

    signal applied(string fileName)
    property var selected: null
    readonly property var details: selected ? detailsCache[selected.id] || null : null
    property var detailsCache: ({})
    property bool detailsBusy: false
    property string detailsError: ""
    property var detailsRequest: null
    property int detailsGeneration: 0
    property var requestTimes: []
    property double pausedUntil: 0
    property double clockNow: Date.now()
    property int rateRemaining: -1
    property int rateLimit: -1
    readonly property bool paused: pausedUntil > clockNow
    readonly property string rateMessage: paused
        ? I18n.tr("Wallhaven requests are paused. Try again in a minute.") : ""

    // GENERAL.METERED reports both explicit and guessed metering. Unknown is
    // conservative: welcome asks before loading, rather than guessing free.
    property bool meteredKnown: false
    property bool metered: true
    function autoLoadAllowed() { return meteredKnown && !metered; }
    // Metering only matters while an online view is on screen. Views hold a
    // watch (WallpaperOnlineView, through a Claim); without one, NetworkManager
    // events cost nothing here.
    property int meteringWatchers: 0
    function watchMetering() {
        meteringWatchers++;
        if (meteringWatchers === 1)
            refreshMetered();
    }
    function unwatchMetering() {
        meteringWatchers = Math.max(0, meteringWatchers - 1);
        if (meteringWatchers === 0)
            meteredThrottle.stop();
    }
    // The last answer stays in force while a new probe runs; only the probe's
    // own result (or its failure) changes it.
    function refreshMetered() {
        if (!meteredProc.running)
            meteredProc.running = true;
    }
    // At most one probe per throttle interval, however many events arrive.
    function meteringEvent() {
        if (meteringWatchers > 0 && !meteredThrottle.running)
            meteredThrottle.start();
    }
    function meteredTick() {
        if (meteringWatchers === 0)
            return;
        if (meteredProc.running)
            meteredThrottle.restart();
        else
            refreshMetered();
    }

    function reserveRequest() {
        clockNow = Date.now();
        requestTimes = WallhavenHelpers.requestWindow(requestTimes, clockNow);
        if (paused || requestTimes.length >= 45) {
            if (!paused)
                pausedUntil = requestTimes[0] + 60000;
            return false;
        }
        requestTimes = requestTimes.concat([clockNow]);
        return true;
    }

    function readRate(xhr) {
        const remaining = xhr.getResponseHeader("x-ratelimit-remaining") || "";
        const limit = xhr.getResponseHeader("x-ratelimit-limit") || "";
        rateRemaining = /^\d+$/.test(remaining) ? Number(remaining) : -1;
        rateLimit = /^\d+$/.test(limit) ? Number(limit) : -1;
        pausedUntil = Math.max(pausedUntil, WallhavenHelpers.ratePause(xhr.status,
            remaining, limit, xhr.getResponseHeader("retry-after") || "", Date.now()));
        clockNow = Date.now();
    }

    function select(id) {
        const item = results.find(entry => entry.id === id);
        if (!item || !WallhavenHelpers.validId(id))
            return false;
        selected = item;
        detailsGeneration++;
        detailsDeadline.stop();
        if (detailsRequest) {
            detailsRequest.onreadystatechange = null;
            detailsRequest.abort();
            detailsRequest = null;
        }
        detailsBusy = false;
        detailsError = "";
        if (detailsCache[id])
            return true;
        if (!reserveRequest()) {
            detailsError = rateMessage;
            return true;
        }
        const token = detailsGeneration;
        try {
            const xhr = new XMLHttpRequest();
            detailsRequest = xhr;
            detailsBusy = true;
            xhr.onreadystatechange = () => {
                if (token !== root.detailsGeneration || xhr.readyState !== XMLHttpRequest.DONE)
                    return;
                detailsDeadline.stop();
                root.detailsRequest = null;
                root.detailsBusy = false;
                root.readRate(xhr);
                if (xhr.status !== 200) {
                    root.detailsError = I18n.format(WallhavenHelpers.statusError(xhr.status), [xhr.status]);
                    return;
                }
                try {
                    const cache = Object.assign({}, root.detailsCache);
                    cache[id] = WallhavenHelpers.parseDetails(xhr.responseText, id);
                    root.detailsCache = cache;
                } catch (e) {
                    root.detailsError = I18n.tr("Wallhaven returned unreadable details. Try selecting again.");
                }
            };
            xhr.open("GET", WallhavenHelpers.detailsUrl(id));
            detailsDeadline.restart();
            xhr.send();
        } catch (e) {
            detailsDeadline.stop();
            detailsRequest = null;
            detailsBusy = false;
            detailsError = I18n.tr("The details could not load. Try selecting again.");
        }
        return true;
    }

    function moreLike(id) {
        const queryString = WallhavenHelpers.likeQuery(id);
        if (queryString === "")
            return;
        query = queryString;
        search();
    }

    Timer {
        interval: 1000
        running: root.pausedUntil > 0
        repeat: true
        onTriggered: {
            root.clockNow = Date.now();
            if (!root.paused)
                root.pausedUntil = 0;
        }
    }
    Timer {
        id: detailsDeadline
        interval: 15000
        onTriggered: {
            root.detailsGeneration++;
            if (root.detailsRequest) {
                root.detailsRequest.onreadystatechange = null;
                root.detailsRequest.abort();
                root.detailsRequest = null;
            }
            root.detailsBusy = false;
            root.detailsError = I18n.tr("The details could not load. Try selecting again.");
        }
    }
    Process {
        id: meteredProc
        command: ["python3", Quickshell.shellDir + "/scripts/network-tool.py", "metered"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const state = JSON.parse(text);
                    root.metered = state.metered !== false;
                    root.meteredKnown = state.known === true;
                } catch (e) {
                    root.meteredKnown = false;
                    root.metered = true;
                }
            }
        }
    }
    Timer {
        id: meteredThrottle
        interval: 4000
        onTriggered: root.meteredTick()
    }
    Connections {
        target: NetworkStatus
        enabled: root.meteringWatchers > 0
        function onMonitorEvent(line) { root.meteringEvent(); }
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
        if (!reserveRequest())
            return;
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
            color: color,
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
                root.readRate(xhr);
                let parsed = null;
                if (xhr.status !== 200) {
                    root.error = I18n.format(WallhavenHelpers.statusError(xhr.status), [xhr.status]);
                } else {
                    try {
                        parsed = WallhavenHelpers.parseResults(xhr.responseText);
                    } catch (e) {
                        root.error = I18n.tr("Wallhaven returned an unreadable response. Try again.");
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
            failSearch(I18n.tr("The search could not start. Try again."));
        }
    }

    Timer {
        id: deadline
        interval: 15000
        onTriggered: root.failSearch(I18n.tr("Wallhaven did not answer in time. Check your connection and try again."))
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
            applied(item.fileName);
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
            applied(item.fileName);
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
            if (directory === Wallpaper.dir) {
                Wallpaper.reloadDirectory();
                Wallpaper.set(result.slice(5));
                applied(result.slice(5));
            }
            return;
        }
        failedId = item ? item.id : "";
        downloadError = I18n.tr(WallhavenHelpers.downloadError(
            result.indexOf("failed ") === 0 ? result.slice(7) : ""));
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
