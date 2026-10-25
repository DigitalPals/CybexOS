pragma ComponentBehavior: Bound
import QtQuick
import "../Common"
import "../Common/WallhavenHelpers.js" as WallhavenHelpers

// Filters and listing only; WallpaperPicker places the shared preview beside
// this view. No timer, scrolling edge or text edit can start a search.
Item {
    id: root
    property bool automatic: false
    signal selected(var item)
    Component.onCompleted: {
        OnlineWallpapers.refreshMetered();
        OnlineWallpapers.ensureLoaded(automatic);
    }
    function runSearch() {
        OnlineWallpapers.query = queryField.text.trim();
        OnlineWallpapers.search();
    }
    Column {
        id: filters
        width: parent.width
        spacing: 7
        Row {
            width: parent.width
            spacing: 6
            SettingsField {
                id: queryField
                objectName: "wallhavenSearch"
                width: Math.max(0, parent.width - searchButton.width - parent.spacing)
                placeholderText: I18n.tr("Mountains, city at night…")
                Accessible.name: I18n.tr("Search Wallhaven wallpapers")
                maximumLength: 100
                text: OnlineWallpapers.query
                onAccepted: root.runSearch()
                Keys.onDownPressed: { if (resultGrid.count > 0) resultGrid.focusItem(0); }
            }
            SettingsAction {
                id: searchButton
                compact: true
                glyph: "search"
                text: I18n.tr("Search")
                enabled: !OnlineWallpapers.paused
                onTriggered: root.runSearch()
            }
        }
        PillRow {
            width: parent.width
            model: [
                { value: "minimalism", label: I18n.tr("Minimal") },
                { value: "nature", label: I18n.tr("Nature") },
                { value: "space", label: I18n.tr("Space") },
                { value: "city", label: I18n.tr("City") },
                { value: "abstract", label: I18n.tr("Abstract") },
                { value: "dark", label: I18n.tr("Dark") },
                { value: "pixel art", label: I18n.tr("Pixel art") }
            ]
            current: OnlineWallpapers.query
            segmented: false
            padH: 8
            onPicked: value => { OnlineWallpapers.query = value; OnlineWallpapers.search(); }
        }
        Row {
            width: parent.width
            spacing: 6
            SettingsSelect {
                width: Math.floor((parent.width - 12) / 3)
                Accessible.name: I18n.tr("Sort wallpapers")
                model: [
                    { value: "popular", label: I18n.tr("Popular") },
                    { value: "trending", label: I18n.tr("Trending") },
                    { value: "latest", label: I18n.tr("Latest") },
                    { value: "random", label: I18n.tr("Random") }
                ]
                current: OnlineWallpapers.sort
                onPicked: value => { OnlineWallpapers.sort = value; root.runSearch(); }
            }
            SettingsSelect {
                width: Math.floor((parent.width - 12) / 3)
                Accessible.name: I18n.tr("Wallpaper category")
                model: [
                    { value: "general", label: I18n.tr("General") },
                    { value: "anime", label: I18n.tr("Anime") },
                    { value: "both", label: I18n.tr("Both") }
                ]
                current: OnlineWallpapers.category
                onPicked: value => { OnlineWallpapers.category = value; root.runSearch(); }
            }
            SettingsSelect {
                width: Math.floor((parent.width - 12) / 3)
                Accessible.name: I18n.tr("Wallpaper size")
                model: [
                    { value: "fit", label: I18n.tr("Fits my displays") },
                    { value: "any", label: I18n.tr("Any size") }
                ]
                current: OnlineWallpapers.size
                onPicked: value => { OnlineWallpapers.size = value; root.runSearch(); }
            }
        }
        Flow {
            width: parent.width
            spacing: 4
            SettingsAction {
                compact: true
                glyph: "close"
                text: I18n.tr("Any colour")
                onTriggered: { OnlineWallpapers.color = ""; root.runSearch(); }
            }
            Repeater {
                model: WallhavenHelpers.COLORS
                Rectangle {
                    id: swatch
                    required property string modelData
                    width: 19; height: 19; radius: 5
                    color: "#" + modelData
                    border.width: activeFocus || OnlineWallpapers.color === modelData ? 2 : 1
                    border.color: activeFocus ? Theme.accent : Theme.textMid
                    activeFocusOnTab: true
                    Accessible.role: Accessible.RadioButton
                    Accessible.name: I18n.format("Filter by colour %1", [modelData])
                    Accessible.checked: OnlineWallpapers.color === modelData
                    function activate() { OnlineWallpapers.color = modelData; root.runSearch(); }
                    Accessible.onPressAction: activate()
                    Keys.onPressed: event => {
                        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                            activate(); event.accepted = true;
                        } else if (event.key === Qt.Key_Right || event.key === Qt.Key_Down) {
                            nextItemInFocusChain(true).forceActiveFocus(); event.accepted = true;
                        } else if (event.key === Qt.Key_Left || event.key === Qt.Key_Up) {
                            nextItemInFocusChain(false).forceActiveFocus(); event.accepted = true;
                        }
                    }
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: { swatch.forceActiveFocus(); swatch.activate(); }
                    }
                }
            }
        }
    }
    WallpaperGrid {
        id: resultGrid
        anchors.top: filters.bottom
        anchors.topMargin: 10
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: footer.top
        online: true
        items: OnlineWallpapers.results
        selectedKey: OnlineWallpapers.selected ? OnlineWallpapers.selected.id : ""
        onSelected: item => { OnlineWallpapers.select(item.id); root.selected(item); }
        StatusPlaceholder {
            anchors.centerIn: parent
            width: Math.max(0, parent.width - 24)
            shown: OnlineWallpapers.results.length === 0
            kind: OnlineWallpapers.busy ? "loading" : OnlineWallpapers.error !== "" ? "error" : "empty"
            glyph: "image"
            title: OnlineWallpapers.busy ? I18n.tr("Searching Wallhaven…")
                : OnlineWallpapers.error !== "" ? I18n.tr("Search failed")
                : !OnlineWallpapers.searched ? I18n.tr("Load wallpapers from Wallhaven?") : I18n.tr("No wallpapers found")
            detail: OnlineWallpapers.error !== "" ? OnlineWallpapers.error
                : I18n.tr("Choose a topic or search. Downloads happen only when you use a wallpaper.")
        }
    }
    Column {
        id: footer
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        spacing: 4
        SettingsHint { width: parent.width; text: OnlineWallpapers.rateMessage || OnlineWallpapers.error; tone: "error" }
        SettingsAction {
            visible: !OnlineWallpapers.searched || OnlineWallpapers.hasMore || OnlineWallpapers.error !== ""
            width: parent.width
            text: !OnlineWallpapers.searched ? I18n.tr("Load wallpapers from Wallhaven?")
                : OnlineWallpapers.error !== "" ? I18n.tr("Try again")
                : OnlineWallpapers.size === "fit" ? I18n.tr("Show more · sized for your displays") : I18n.tr("Show more")
            enabled: !OnlineWallpapers.busy && !OnlineWallpapers.paused
            onTriggered: {
                if (!OnlineWallpapers.searched || OnlineWallpapers.error !== "") root.runSearch();
                else OnlineWallpapers.more();
            }
        }
    }
}
