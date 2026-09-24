pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Widgets
import "../Common"
import "../Common/WallhavenHelpers.js" as WallhavenHelpers

// The Wallpaper page's Online view: search Wallhaven, then pick a result to
// save it into the wallpaper folder and use it. The tiles read like the
// Library grid's (same sizes, focus, keys and current mark, in the same row
// grid); the search is a row like the filters under it. OnlineWallpapers
// owns the requests, so this view only draws and forwards picks.
Item {
    id: root

    readonly property var results: OnlineWallpapers.results
    readonly property string currentPage: {
        const match = /^wallhaven-([a-z0-9]{1,16})\.(jpg|png)$/.exec(Settings.wall);
        return match ? "https://wallhaven.cc/w/" + match[1] : "";
    }

    Component.onCompleted: OnlineWallpapers.ensureLoaded()

    function runSearch() {
        OnlineWallpapers.query = queryField.text.trim();
        OnlineWallpapers.search();
    }

    // key: "sort", "category" or "size" on OnlineWallpapers.
    function setFilter(key, value) {
        OnlineWallpapers[key] = value;
        runSearch();
    }

    function loadMoreAtEnd() {
        if (resultGrid.atYEnd && resultGrid.contentHeight > resultGrid.height)
            OnlineWallpapers.more();
    }

    function focusResult(index) {
        const clamped = Math.max(0, Math.min(resultGrid.count - 1, index));
        // Focus moves before currentIndex does, as in the Library grid.
        resultGrid.positionViewAtIndex(clamped, GridView.Contain);
        const target = resultGrid.itemAtIndex(clamped);
        if (target)
            target.forceActiveFocus();
        resultGrid.currentIndex = clamped;
        if (!target) {
            Qt.callLater(() => {
                if (resultGrid.currentItem)
                    resultGrid.currentItem.forceActiveFocus();
            });
        }
    }

    SettingsGroup {
        id: searchGroup
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        title: "Find wallpapers"

        // [Search][field][search button][undo]: the field ends at the
        // button, the button on the controls' edge; the label already says
        // Search, so the button is the icon alone. The query runs on Enter or
        // the button, never on focus loss, so this is not a SettingsTextRow.
        SettingsRow {
            id: searchRow
            width: parent.width
            label: "Search"
            narrowLabelInset: searchRow.undoWidth
            controlLeft: queryField.x

            SettingsField {
                id: queryField
                readonly property real laneLeft: searchRow.narrow
                    ? searchRow.markInset : searchRow.labelWidth
                objectName: "wallhavenSearch"
                width: searchRow.narrow
                    ? Math.max(0, searchButton.x - Theme.controlSpacing - laneLeft)
                    : Math.max(0, Math.min(Theme.scaled(300, Theme.typeScale),
                        searchButton.x - Theme.controlSpacing - laneLeft))
                x: searchButton.x - Theme.controlSpacing - width
                y: searchRow.narrow ? Theme.settingsStackOffset
                    : (searchRow.lineHeight - height) / 2
                placeholderText: "Mountains, city at night…"
                Accessible.name: "Search Wallhaven wallpapers"
                Accessible.description: "Press Enter to search, then Down to reach the results."
                maximumLength: 100
                Component.onCompleted: text = OnlineWallpapers.query
                onAccepted: root.runSearch()
                Keys.onPressed: event => {
                    if (event.key === Qt.Key_Down && resultGrid.count > 0) {
                        root.focusResult(resultGrid.currentIndex);
                        event.accepted = true;
                    }
                }
            }

            SettingsAction {
                id: searchButton
                x: searchRow.contentRight - width
                y: queryField.y + (queryField.height - height) / 2
                compact: true
                text: "Search"
                glyph: "search"
                enabled: !OnlineWallpapers.busy || OnlineWallpapers.appending
                onTriggered: root.runSearch()
            }
        }

        PickerRow {
            width: parent.width
            label: "Sort"
            model: WallhavenHelpers.SORTS
            current: OnlineWallpapers.sort
            dirty: OnlineWallpapers.sort !== OnlineWallpapers.defaults.sort
            onPicked: value => root.setFilter("sort", value)
            onResetRequested: root.setFilter("sort", OnlineWallpapers.defaults.sort)
        }

        PickerRow {
            width: parent.width
            label: "Category"
            model: WallhavenHelpers.CATEGORIES
            current: OnlineWallpapers.category
            dirty: OnlineWallpapers.category !== OnlineWallpapers.defaults.category
            onPicked: value => root.setFilter("category", value)
            onResetRequested: root.setFilter("category", OnlineWallpapers.defaults.category)
        }

        PickerRow {
            width: parent.width
            label: "Size"
            model: WallhavenHelpers.SIZES
            current: OnlineWallpapers.size
            caption: OnlineWallpapers.size === "fit" && OnlineWallpapers.minimum !== ""
                ? "≥ " + OnlineWallpapers.minimum.replace("x", " × ") : ""
            dirty: OnlineWallpapers.size !== OnlineWallpapers.defaults.size
            onPicked: value => root.setFilter("size", value)
            onResetRequested: root.setFilter("size", OnlineWallpapers.defaults.size)
        }
    }

    SettingsGroup {
        id: resultsGroup
        anchors.top: searchGroup.bottom
        anchors.topMargin: Theme.settingsGroupSpacing
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: statusHint.top
        anchors.bottomMargin: statusHint.visible ? Theme.settingsContentSpacing : 0
        title: OnlineWallpapers.query !== "" ? "Results for “" + OnlineWallpapers.query + "”" : "Results"

        GridView {
            id: resultGrid
            readonly property int columnCount: width < Theme.settingsNarrowWidth ? 1 : 2
            // In the row grid, as the Library grid is: the label lane on the
            // left, each tile's 7px gutter in the reset column on the right.
            x: Theme.settingsMarkInset
            width: Math.max(0, parent.width - x - Theme.chipHeight + 7)
            height: resultsGroup.availableContentHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            cellWidth: Math.floor(width / columnCount)
            cellHeight: columnCount === 1
                ? Math.max(126, Math.min(190, cellWidth * 0.42))
                : Math.max(106, Math.min(150, cellWidth * 0.58 + 7))
            currentIndex: 0
            // ScriptModel diffs by entry identity, so a later page appends
            // tiles instead of rebuilding the grid and losing the scroll.
            model: ScriptModel { values: root.results }

            delegate: Item {
                id: cell
                required property var modelData
                required property int index
                readonly property bool current: Settings.wall === modelData.fileName
                readonly property bool saved: OnlineWallpapers.saved[modelData.fileName] === true
                readonly property bool downloading: OnlineWallpapers.downloadingId === modelData.id
                readonly property bool failed: OnlineWallpapers.failedId === modelData.id

                width: resultGrid.cellWidth
                height: resultGrid.cellHeight
                activeFocusOnTab: index === resultGrid.currentIndex
                Accessible.role: Accessible.Button
                Accessible.name: "Use Wallhaven wallpaper, " + WallhavenHelpers.describe(modelData)
                    + (saved ? ", saved" : "")
                Accessible.selected: current
                Accessible.onPressAction: cell.activate()

                function activate() {
                    resultGrid.currentIndex = index;
                    OnlineWallpapers.apply(modelData);
                }

                Keys.onPressed: event => {
                    let next = -1;
                    if (event.key === Qt.Key_Left)
                        next = index - 1;
                    else if (event.key === Qt.Key_Right)
                        next = index + 1;
                    else if (event.key === Qt.Key_Up)
                        next = index - resultGrid.columnCount;
                    else if (event.key === Qt.Key_Down)
                        next = index + resultGrid.columnCount;
                    else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                            || event.key === Qt.Key_Space) {
                        activate(); event.accepted = true; return;
                    }
                    if (next >= 0 && next < resultGrid.count) {
                        root.focusResult(next);
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Down && OnlineWallpapers.hasMore) {
                        OnlineWallpapers.more();
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Up) {
                        queryField.forceActiveFocus();
                        event.accepted = true;
                    }
                }

                ClippingRectangle {
                    anchors.fill: parent
                    anchors.rightMargin: 7
                    anchors.bottomMargin: 7
                    radius: 10
                    color: Theme.cardFill
                    contentInsideBorder: true
                    border.width: cell.current || cell.activeFocus || cell.failed ? 2 : 0
                    border.color: cell.activeFocus ? Theme.textHi
                        : cell.failed ? Theme.redText : Theme.accent

                    Rectangle {
                        anchors.fill: parent
                        color: Theme.cardFill
                        visible: thumbImage.status !== Image.Ready
                        Text {
                            anchors.centerIn: parent
                            width: parent.width - 20
                            horizontalAlignment: Text.AlignHCenter
                            text: thumbImage.status === Image.Error ? "Could not load" : "Loading…"
                            font.family: Theme.fontMenu
                            font.pixelSize: Theme.typography.secondary
                            color: Theme.textFaint
                            elide: Text.ElideRight
                        }
                    }

                    Image {
                        id: thumbImage
                        anchors.fill: parent
                        source: cell.modelData.thumb
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        cache: true
                    }

                    Rectangle {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        height: detail.implicitHeight + 10
                        visible: !cell.downloading && (cellMouse.containsMouse || cell.activeFocus)
                        color: Qt.rgba(0, 0, 0, 0.62)
                        Text {
                            id: detail
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.leftMargin: 7
                            anchors.rightMargin: 7
                            anchors.verticalCenter: parent.verticalCenter
                            text: WallhavenHelpers.describe(cell.modelData)
                                + (cell.saved ? " · saved" : "")
                            elide: Text.ElideRight
                            font.family: Theme.fontMenu
                            font.pixelSize: Theme.typography.primary
                            color: "#ffffff"
                        }
                    }

                    // Download progress: a scrim with the percentage, and a bar
                    // along the bottom edge that fills as the bytes arrive.
                    Rectangle {
                        anchors.fill: parent
                        visible: cell.downloading
                        color: Qt.rgba(0, 0, 0, 0.55)
                        Text {
                            anchors.centerIn: parent
                            text: "Downloading " + OnlineWallpapers.downloadProgress + "%"
                            font.family: Theme.fontMenu
                            font.pixelSize: Theme.typography.control
                            font.weight: Theme.weightMedium
                            color: "#ffffff"
                        }
                        Rectangle {
                            anchors.left: parent.left
                            anchors.bottom: parent.bottom
                            height: 3
                            width: parent.width * OnlineWallpapers.downloadProgress / 100
                            color: Theme.accent
                        }
                    }

                    Rectangle {
                        visible: cell.current || cell.saved
                        anchors.top: parent.top
                        anchors.topMargin: 6
                        anchors.right: parent.right
                        anchors.rightMargin: 6
                        width: 16; height: 16; radius: 8
                        color: cell.current ? Theme.accent : Qt.rgba(0, 0, 0, 0.62)
                        Sym {
                            anchors.centerIn: parent
                            name: cell.current ? "check" : "download"
                            size: Theme.iconSmall
                            symWeight: 700
                            color: cell.current ? Theme.accentFg : "#ffffff"
                        }
                    }

                    MouseArea {
                        id: cellMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            cell.forceActiveFocus();
                            cell.activate();
                        }
                    }
                }
            }

            // The next page loads when the person scrolls to the end (or
            // arrows past the last row), one request per 24 results.
            // contentHeight > height keeps a short first page from chaining
            // requests on its own. The check runs after the current layout
            // pass: atYEnd also changes while the footer resizes, and asking
            // from inside that resize is a binding loop.
            onAtYEndChanged: {
                if (atYEnd)
                    Qt.callLater(root.loadMoreAtEnd);
            }

            footer: Item {
                width: resultGrid.width
                height: OnlineWallpapers.appending
                    ? moreText.implicitHeight + Theme.settingsContentSpacing * 2 : 0
                visible: height > 0

                Text {
                    id: moreText
                    anchors.centerIn: parent
                    text: "Loading more…"
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.secondary
                    color: Theme.textFaint
                }
            }

            StatusPlaceholder {
                anchors.centerIn: parent
                width: Math.max(0, parent.width - 40)
                height: implicitHeight
                shown: root.results.length === 0
                    && (OnlineWallpapers.busy || OnlineWallpapers.searched)
                kind: OnlineWallpapers.busy ? "loading"
                    : OnlineWallpapers.error !== "" ? "error" : "empty"
                glyph: OnlineWallpapers.busy ? "progress_activity"
                    : OnlineWallpapers.error !== "" ? "error" : "image"
                title: OnlineWallpapers.busy ? "Searching Wallhaven…"
                    : OnlineWallpapers.error !== "" ? "Search failed" : "No wallpapers found"
                detail: OnlineWallpapers.busy ? ""
                    : OnlineWallpapers.error !== "" ? OnlineWallpapers.error
                    : OnlineWallpapers.size === "fit"
                        ? "Try other words, or choose Any size to include smaller images."
                        : "Try other words or another category."
            }
        }
    }

    SettingsHint {
        id: statusHint
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.rightMargin: Theme.chipHeight
        anchors.bottom: footerRow.top
        anchors.bottomMargin: visible ? Theme.settingsContentSpacing : 0
        tone: "error"
        text: OnlineWallpapers.downloadError !== "" ? OnlineWallpapers.downloadError
            : root.results.length > 0 ? OnlineWallpapers.error : ""
    }

    // The links end on the controls' edge, one reset column in.
    ResponsiveActionRow {
        id: footerRow
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.rightMargin: Theme.chipHeight
        anchors.bottom: parent.bottom
        breakpoint: 540
        description: "Safe-for-work only · saves to " + Settings.wallDir

        SettingsAction {
            visible: root.currentPage !== ""
            text: "Current on Wallhaven"
            glyph: "open_in_new"
            Accessible.name: "Open the current wallpaper's Wallhaven page"
            onTriggered: Qt.openUrlExternally(root.currentPage)
        }
        SettingsAction {
            text: "wallhaven.cc"
            glyph: "open_in_new"
            Accessible.name: "Open wallhaven.cc"
            onTriggered: Qt.openUrlExternally("https://wallhaven.cc")
        }
    }
}
