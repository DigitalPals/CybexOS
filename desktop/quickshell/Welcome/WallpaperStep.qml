pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import "../Common"
import "../Common/WallpaperNames.js" as WallpaperNames

// Wallpaper, laid out like the installer's disk screen: the choices on the
// left, a card on the right. It opens on Wallhaven. Choosing a tile applies
// it at once; the card shows it on a miniature desktop with the colours the
// Style step takes from it. Wallhaven lists automatically only on a known
// unmetered connection; otherwise it asks first.
Item {
    id: root
    objectName: "welcomeWallpaperStep"
    property string tab: "online"
    readonly property bool online: tab === "online"
    readonly property var items: online ? OnlineWallpapers.results
        : tab === "collection" ? localItems(Wallpaper.bundledFiles, true) : localItems(Wallpaper.files, false)
    function localItems(paths, bundled) {
        return paths.map(path => ({path: path, fileName: Wallpaper.basename(path),
            label: WallpaperNames.label(Wallpaper.basename(path), bundled), width: 0, height: 0}));
    }
    function chosen(item) {
        const wall = Settings.wall;
        if (root.online)
            return wall === item.fileName || OnlineWallpapers.downloadingId === item.id;
        if (root.tab === "collection")
            return (wall === "" && item.fileName === "moon-mountains.png") || wall === item.fileName || wall === "cybexos-" + item.fileName;
        return wall === item.fileName;
    }
    function use(item) {
        if (root.online) {
            OnlineWallpapers.select(item.id);
            OnlineWallpapers.apply(item);
        } else if (root.tab === "collection") {
            Wallpaper.applyBundled(item.path);
        } else {
            Wallpaper.set(item.path);
        }
    }
    function runSearch() {
        OnlineWallpapers.query = search.text.trim();
        OnlineWallpapers.search();
    }
    // The metering probe runs only while Wallhaven is on screen.
    Claim {
        active: root.visible && root.online
        onClaimed: { OnlineWallpapers.watchMetering(); OnlineWallpapers.ensureLoaded(true); }
        onReleased: OnlineWallpapers.unwatchMetering()
    }
    Connections {
        target: OnlineWallpapers
        function onMeteredKnownChanged() {
            if (root.visible && root.online && OnlineWallpapers.autoLoadAllowed())
                OnlineWallpapers.ensureLoaded(true);
        }
    }

    Column {
        id: heading
        x: Kiosk.px(64)
        y: Kiosk.px(34)
        width: parent.width - Kiosk.px(128)
        spacing: Kiosk.px(8)
        KioskText {
            width: parent.width
            text: I18n.tr("Find your view.")
            size: 40
            font.weight: Font.Bold
            font.letterSpacing: -Kiosk.px(1)
            elide: Text.ElideRight
            Accessible.role: Accessible.Heading
        }
        KioskText {
            width: parent.width
            text: I18n.tr("Pick one and it is on your desktop at once. Its colours tint the rest of Cybex OS.")
            size: 19
            tone: "fog"
            elide: Text.ElideRight
        }
    }

    Item {
        id: choices
        x: Kiosk.px(64)
        anchors.top: heading.bottom
        anchors.topMargin: Kiosk.px(22)
        anchors.bottom: footer.top
        anchors.bottomMargin: Kiosk.px(12)
        width: parent.width - Kiosk.px(128) - Kiosk.px(380) - Kiosk.px(36)
        Row {
            id: tools
            width: parent.width
            spacing: Kiosk.px(12)
            KioskSegmented {
                id: tabs
                label: I18n.tr("Wallpaper source")
                model: [{value: "online", label: I18n.tr("Wallhaven"), icon: "public"},
                    {value: "collection", label: I18n.tr("Cybex OS"), icon: "image"},
                    {value: "library", label: I18n.tr("My pictures"), icon: "folder"}]
                current: root.tab
                onPicked: value => root.tab = value
            }
            KioskField {
                id: search
                objectName: "wallhavenSearch"
                visible: root.online
                width: parent.width - tabs.width - parent.spacing
                height: tabs.height
                designHeight: 46
                fontSize: 16
                icon: "search"
                placeholder: I18n.tr("Search Wallhaven")
                label: I18n.tr("Search Wallhaven wallpapers")
                maximumLength: 100
                text: OnlineWallpapers.query
                enabled: !OnlineWallpapers.paused
                onAccepted: root.runSearch()
                Keys.onDownPressed: event => { if (grid.count > 0) grid.focusItem(0); event.accepted = true; }
            }
            KioskText {
                visible: !root.online
                width: parent.width - tabs.width - parent.spacing
                height: tabs.height
                verticalAlignment: Text.AlignVCenter
                text: root.tab === "collection" ? I18n.tr("Made for Cybex OS. No download needed.") : Settings.wallDir
                mono: root.tab === "library"
                size: root.tab === "library" ? 13 : 14
                tone: "faint"
                elide: Text.ElideMiddle
            }
        }
        GridView {
            id: grid
            objectName: "wallpaperGrid"
            readonly property bool online: root.online
            readonly property real gap: Kiosk.px(12)
            anchors.top: tools.bottom
            anchors.topMargin: Kiosk.px(14)
            anchors.bottom: parent.bottom
            width: parent.width + gap
            cellWidth: Math.floor(width / 3)
            cellHeight: Kiosk.px(130) + gap
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            model: ScriptModel { values: root.items }
            currentIndex: 0
            function focusItem(index) {
                const next = Math.max(0, Math.min(count - 1, index));
                positionViewAtIndex(next, GridView.Contain);
                currentIndex = next;
                const item = itemAtIndex(next);
                if (item) item.forceActiveFocus();
                else Qt.callLater(() => { if (grid.currentItem) grid.currentItem.forceActiveFocus(); });
            }
            footer: Item {
                width: grid.width - grid.gap
                height: more.visible ? more.height + Kiosk.px(4) : 0
                KioskButton {
                    id: more
                    anchors.horizontalCenter: parent.horizontalCenter
                    visible: root.online && OnlineWallpapers.hasMore
                    small: true
                    text: OnlineWallpapers.size === "fit" ? I18n.tr("Show more · sized for your displays") : I18n.tr("Show more")
                    enabled: !OnlineWallpapers.busy && !OnlineWallpapers.paused
                    onClicked: OnlineWallpapers.more()
                }
            }
            delegate: Item {
                id: cell
                required property var modelData
                required property int index
                readonly property bool chosen: root.chosen(modelData)
                readonly property bool downloading: root.online && OnlineWallpapers.downloadingId === modelData.id
                readonly property string caption: modelData.width > 0 ? modelData.width + "×" + modelData.height : modelData.label
                width: grid.cellWidth
                height: grid.cellHeight
                activeFocusOnTab: index === grid.currentIndex
                Accessible.role: Accessible.Button
                Accessible.name: I18n.format("Select wallpaper %1", [modelData.label || modelData.fileName])
                Accessible.selected: chosen
                Accessible.onPressAction: activate()
                function activate() {
                    grid.currentIndex = index;
                    root.use(modelData);
                }
                Component.onCompleted: { if (!root.online) Wallpaper.requestThumbnail(modelData.path); }
                // Space is the guide's peek; Enter chooses.
                Keys.onPressed: event => {
                    let next = -1;
                    if (event.key === Qt.Key_Left) next = index - 1;
                    else if (event.key === Qt.Key_Right) next = index + 1;
                    else if (event.key === Qt.Key_Up) next = index - 3;
                    else if (event.key === Qt.Key_Down) next = index + 3;
                    else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        if (!event.isAutoRepeat) activate();
                        event.accepted = true;
                        return;
                    }
                    if (next >= 0 && next < grid.count) {
                        grid.focusItem(next);
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Up && root.online) {
                        search.forceActiveFocus();
                        event.accepted = true;
                    }
                }
                Rectangle {
                    visible: cell.chosen
                    anchors.fill: tile
                    anchors.margins: -Kiosk.px(3)
                    radius: tile.radius + Kiosk.px(3)
                    color: "transparent"
                    border.width: Kiosk.px(3)
                    border.color: Kiosk.accentGlow
                }
                Rectangle {
                    id: tile
                    width: parent.width - grid.gap
                    height: parent.height - grid.gap
                    radius: Kiosk.px(14)
                    color: Kiosk.card
                    clip: true
                    Image {
                        anchors.fill: parent
                        source: root.online ? cell.modelData.thumb : Wallpaper.thumbnailFor(cell.modelData.path)
                        asynchronous: true
                        fillMode: Image.PreserveAspectCrop
                        sourceSize.width: 480
                    }
                    Rectangle {
                        anchors.fill: parent
                        radius: parent.radius
                        color: "transparent"
                        border.width: Math.max(1, Kiosk.px(1.5))
                        border.color: cell.chosen ? Kiosk.accent : cellMouse.containsMouse ? Kiosk.line2 : Kiosk.line
                    }
                    Rectangle {
                        anchors.left: parent.left
                        anchors.bottom: parent.bottom
                        anchors.margins: Kiosk.px(8)
                        visible: cell.caption !== "" && width <= parent.width - Kiosk.px(16)
                        width: captionText.implicitWidth + Kiosk.px(14)
                        height: captionText.implicitHeight + Kiosk.px(4)
                        radius: Kiosk.px(6)
                        color: "#d1141517"
                        KioskText {
                            id: captionText
                            anchors.centerIn: parent
                            text: cell.caption
                            mono: true
                            size: 11
                            font.weight: Font.Medium
                            tone: "fog"
                        }
                    }
                    Rectangle {
                        visible: cell.chosen && !cell.downloading
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.margins: Kiosk.px(8)
                        width: Kiosk.px(24)
                        height: width
                        radius: width / 2
                        color: Kiosk.accent
                        KioskIcon { anchors.centerIn: parent; name: "check"; designSize: 14; color: Kiosk.accentInk }
                    }
                    Rectangle {
                        visible: cell.downloading
                        anchors.left: parent.left
                        anchors.bottom: parent.bottom
                        height: Kiosk.px(4)
                        width: parent.width * OnlineWallpapers.downloadProgress / 100
                        color: Kiosk.accent
                    }
                }
                KioskFocusRing { anchors.fill: tile; visible: cell.activeFocus; baseRadius: tile.radius }
                MouseArea {
                    id: cellMouse
                    anchors.fill: tile
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: { cell.forceActiveFocus(); cell.activate(); }
                }
            }
            // Loading, asking before Wallhaven, failures and empty folders.
            Column {
                anchors.centerIn: parent
                anchors.horizontalCenterOffset: -grid.gap / 2
                width: Math.min(parent.width - Kiosk.px(48), Kiosk.px(460))
                spacing: Kiosk.px(10)
                visible: grid.count === 0
                KioskText {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    size: 19
                    font.weight: Font.Bold
                    text: !root.online ? (Wallpaper.loading ? I18n.tr("Loading wallpapers…") : I18n.tr("No images found"))
                        : OnlineWallpapers.busy ? I18n.tr("Searching Wallhaven…")
                        : OnlineWallpapers.error !== "" ? I18n.tr("Search failed")
                        : !OnlineWallpapers.searched ? I18n.tr("Load wallpapers from Wallhaven?") : I18n.tr("No wallpapers found")
                }
                KioskText {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    size: 14
                    tone: "fog"
                    visible: text !== ""
                    text: !root.online ? (Wallpaper.loading ? "" : Settings.wallDir)
                        : OnlineWallpapers.busy ? ""
                        : OnlineWallpapers.error !== "" ? OnlineWallpapers.error
                        : I18n.tr("Choose a topic or search. Downloads happen only when you use a wallpaper.")
                }
                KioskButton {
                    anchors.horizontalCenter: parent.horizontalCenter
                    visible: root.online && !OnlineWallpapers.busy && (!OnlineWallpapers.searched || OnlineWallpapers.error !== "")
                    small: true
                    kind: "primary"
                    text: OnlineWallpapers.error !== "" ? I18n.tr("Try again") : I18n.tr("Load wallpapers")
                    enabled: !OnlineWallpapers.paused
                    onClicked: root.runSearch()
                }
            }
        }
    }

    KioskCard {
        id: applied
        anchors.right: parent.right
        anchors.rightMargin: Kiosk.px(64)
        anchors.top: choices.top
        width: Kiosk.px(380)
        height: card.implicitHeight + Kiosk.px(36)
        Column {
            id: card
            x: Kiosk.px(20)
            y: Kiosk.px(18)
            width: parent.width - Kiosk.px(40)
            Item {
                width: parent.width
                height: Kiosk.px(26)
                KioskKicker { anchors.left: parent.left; text: I18n.tr("On your desktop") }
                KioskText {
                    anchors.right: parent.right
                    text: OnlineWallpapers.downloadingId !== "" ? I18n.format("Downloading %1%", [OnlineWallpapers.downloadProgress])
                        : Wallpaper.importing ? I18n.tr("Copying…") : I18n.tr("applied")
                    mono: true
                    size: 12
                    tone: "faint"
                }
            }
            DesktopPreview {
                width: parent.width
                height: Math.round(width * 9 / 16)
            }
            Item { width: 1; height: Kiosk.px(14) }
            KioskText {
                width: parent.width
                text: Welcome.wallpaperName
                size: 19
                font.weight: Font.Bold
                elide: Text.ElideRight
            }
            KioskText {
                width: parent.width
                text: Welcome.wallpaperSource === "wallhaven" ? I18n.tr("From Wallhaven")
                    : Welcome.wallpaperSource === "collection" ? I18n.tr("Cybex OS collection") : I18n.tr("From your pictures")
                size: 14
                tone: "fog"
                elide: Text.ElideRight
            }
            Item { width: 1; height: Kiosk.px(18) }
            Item {
                width: parent.width
                height: Kiosk.px(22)
                KioskKicker { anchors.left: parent.left; text: I18n.tr("Its colours") }
                KioskText { anchors.right: parent.right; text: I18n.tr("Style uses these"); mono: true; size: 12; tone: "faint" }
            }
            WallpaperSwatches { size: 28 }
            KioskText {
                width: parent.width
                topPadding: Kiosk.px(12)
                visible: text !== ""
                wrapMode: Text.WordWrap
                text: OnlineWallpapers.rateMessage || OnlineWallpapers.downloadError || Wallpaper.importError
                size: 13.5
                tone: "red"
            }
        }
    }

    KioskFooter {
        id: footer
        anchors.bottom: parent.bottom
        width: parent.width
        onNext: Welcome.move(1)
        Row {
            anchors.verticalCenter: parent.verticalCenter
            spacing: Kiosk.px(8)
            KioskKeycap { anchors.verticalCenter: parent.verticalCenter; small: true; text: I18n.tr("Spacebar") }
            KioskText {
                anchors.verticalCenter: parent.verticalCenter
                text: Welcome.error !== "" ? Welcome.error : I18n.tr("Hold to look at your desktop")
                size: 14
                tone: Welcome.error !== "" ? "red" : "faint"
            }
        }
    }
}
