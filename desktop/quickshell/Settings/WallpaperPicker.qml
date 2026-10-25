pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import "../Common"
import "../Common/WallpaperNames.js" as WallpaperNames

// Public embedding API is documented in docs/wallpapers.md. No SettingsPage
// ancestor is needed; the parent supplies width and height and handles Escape.
Item {
    id: root
    property bool embedded: false
    property bool compact: embedded
    property string tab: "collection" // collection | online | library
    property bool automaticOnlineLoad: false
    property real previewWidth: compact ? 180 : 200
    readonly property var selected: tab === "online" ? OnlineWallpapers.selected : localSelection
    property var localSelection: null
    signal applied(string fileName)
    signal escapeRequested()
    implicitWidth: 740
    implicitHeight: 430
    Keys.onEscapePressed: event => { root.escapeRequested(); event.accepted = true; }

    function localItems(paths, bundled) {
        return paths.map(path => ({ path: path, fileName: Wallpaper.basename(path),
            label: WallpaperNames.label(Wallpaper.basename(path), bundled),
            width: bundled ? 2560 : 0, height: bundled ? 1440 : 0, size: 0, colors: [] }));
    }
    function chooseLocal(item) {
        localSelection = item;
        infoProc.requestedPath = item.path;
        if (infoProc.running) {
            infoProc.running = false;
        } else {
            infoProc.startPending();
        }
    }
    function useSelected() {
        if (!selected)
            return;
        if (tab === "online")
            OnlineWallpapers.apply(selected);
        else if (tab === "collection")
            Wallpaper.applyBundled(selected.path);
        else {
            Wallpaper.set(selected.path);
            applied(selected.fileName);
        }
    }
    function selectInitial() {
        if (tab === "online")
            return;
        const items = localItems(tab === "collection" ? Wallpaper.bundledFiles : Wallpaper.files,
            tab === "collection");
        const item = items.find(entry => entry.fileName === Settings.wall) || items[0];
        if (item)
            chooseLocal(item);
    }
    onTabChanged: { localSelection = null; Qt.callLater(selectInitial); }
    Component.onCompleted: selectInitial()

    PillRow {
        id: tabs
        width: parent.width
        model: [
            { value: "collection", label: I18n.tr("Cybex OS collection") },
            { value: "online", label: I18n.tr("Wallhaven") },
            { value: "library", label: I18n.tr("My pictures") }
        ]
        current: root.tab
        onPicked: value => root.tab = value
    }
    Item {
        id: listing
        anchors.top: tabs.bottom
        anchors.topMargin: 12
        anchors.left: parent.left
        anchors.right: preview.left
        anchors.rightMargin: 16
        anchors.bottom: parent.bottom
        WallpaperGrid {
            anchors.fill: parent
            visible: root.tab !== "online"
            items: root.localItems(root.tab === "collection" ? Wallpaper.bundledFiles : Wallpaper.files,
                root.tab === "collection")
            selectedKey: root.localSelection ? root.localSelection.path : ""
            onSelected: item => root.chooseLocal(item)
            StatusPlaceholder {
                anchors.centerIn: parent
                width: Math.max(0, parent.width - 24)
                shown: root.tab === "library" && Wallpaper.files.length === 0
                kind: Wallpaper.loading ? "loading" : "empty"
                glyph: "image"
                title: Wallpaper.loading ? I18n.tr("Loading wallpapers…") : I18n.tr("No images found")
                detail: Settings.wallDir
            }
        }
        Loader {
            anchors.fill: parent
            active: root.tab === "online"
            visible: active
            sourceComponent: WallpaperOnlineView { automatic: root.automaticOnlineLoad }
        }
    }
    WallpaperPreviewPanel {
        id: preview
        anchors.top: listing.top
        anchors.bottom: parent.bottom
        anchors.right: parent.right
        width: Math.min(root.previewWidth, root.width * 0.36)
        item: root.selected
        details: root.tab === "online" ? OnlineWallpapers.details : null
        online: root.tab === "online"
        busy: online ? item !== null && OnlineWallpapers.downloadingId === item.id : Wallpaper.importing
        progress: online ? OnlineWallpapers.downloadProgress : 0
        error: online ? OnlineWallpapers.downloadError || OnlineWallpapers.detailsError : Wallpaper.importError
        onUseRequested: root.useSelected()
        onMoreLikeRequested: { if (root.selected) OnlineWallpapers.moreLike(root.selected.id); }
    }
    Connections {
        target: OnlineWallpapers
        function onApplied(fileName) { if (root.tab === "online") root.applied(fileName); }
        // An automatic welcome listing waits for the metering probe, without
        // opening any network requests while that answer is still unknown.
        function onMeteredKnownChanged() {
            if (root.tab === "online" && root.automaticOnlineLoad && OnlineWallpapers.autoLoadAllowed())
                OnlineWallpapers.ensureLoaded(true);
        }
    }
    Connections {
        target: Wallpaper
        function onApplied(fileName) { if (root.tab === "collection") root.applied(fileName); }
    }
    Process {
        id: infoProc
        property string requestedPath: ""
        property string activePath: ""
        property string body: ""
        function startPending() {
            if (requestedPath === "" || running)
                return;
            activePath = requestedPath;
            requestedPath = "";
            body = "";
            command = ["python3", Quickshell.shellDir + "/scripts/wallpaper-info.py", activePath];
            running = true;
        }
        stdout: StdioCollector { onStreamFinished: infoProc.body = text }
        onRunningChanged: {
            if (running)
                return;
            if (root.localSelection && root.localSelection.path === activePath && requestedPath === "") {
                try {
                    root.localSelection = Object.assign({}, root.localSelection, JSON.parse(body));
                } catch (e) { /* The image itself remains usable if metadata cannot be read. */ }
            }
            Qt.callLater(startPending);
        }
    }
}
