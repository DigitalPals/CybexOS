pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Widgets
import "../Common"

// The gallery remains virtualized. Rotation and folder management are cards
// that reserve enough room for their controls at both wide and narrow sizes.
// The Online view (Wallhaven) is loaded only once it is chosen, so opening
// the page never reaches the network by itself.
Item {
    id: page

    readonly property string dirLabel: Settings.wallDir
    readonly property bool online: OnlineWallpapers.view === "online"

    function basename(path) {
        return Wallpaper.basename(path);
    }

    function focusThumbnail(index) {
        const clamped = Math.max(0, Math.min(wallGrid.count - 1, index));
        // Focus moves before currentIndex does: the tab stop follows it, and
        // Qt will not drop activeFocusOnTab from the cell that still holds
        // focus (see PillRow). Scrolling first creates the target's delegate.
        wallGrid.positionViewAtIndex(clamped, GridView.Contain);
        const target = wallGrid.itemAtIndex(clamped);
        if (target)
            target.forceActiveFocus();
        wallGrid.currentIndex = clamped;
        if (!target) {
            Qt.callLater(() => {
                if (wallGrid.currentItem)
                    wallGrid.currentItem.forceActiveFocus();
            });
        }
    }

    PillRow {
        id: viewTabs
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        model: [
            { value: "library", label: "Library" },
            { value: "online", label: "Online" }
        ]
        current: OnlineWallpapers.view
        onPicked: value => OnlineWallpapers.view = value
    }

    Loader {
        id: onlineView
        anchors.top: viewTabs.bottom
        anchors.topMargin: Theme.settingsGroupSpacing
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        active: page.online
        visible: active
        sourceComponent: WallpaperOnlineView {}
    }

    SettingsGroup {
        id: galleryGroup
        visible: !page.online
        anchors.top: viewTabs.bottom
        anchors.topMargin: Theme.settingsGroupSpacing
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: rotationGroup.top
        anchors.bottomMargin: Theme.settingsGroupSpacing
        title: "Wallpaper"

        GridView {
            id: wallGrid
            readonly property int columnCount: width < Theme.settingsNarrowWidth ? 1 : 2
            width: parent.width
            height: galleryGroup.availableContentHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            cellWidth: Math.floor(width / columnCount)
            cellHeight: columnCount === 1
                ? Math.max(126, Math.min(190, cellWidth * 0.42))
                : Math.max(106, Math.min(150, cellWidth * 0.58 + 7))
            model: Wallpaper.files.length + 1
            currentIndex: 0

            delegate: Item {
                id: cell
                required property int index
                readonly property bool shuffle: index === Wallpaper.files.length
                readonly property string imagePath: shuffle ? "" : Wallpaper.files[index]
                readonly property string thumbnailSource: shuffle ? ""
                    : Wallpaper.thumbnailFor(imagePath)
                readonly property bool current: !shuffle
                    && page.basename(Wallpaper.current) === page.basename(imagePath)

                width: wallGrid.cellWidth
                height: wallGrid.cellHeight
                activeFocusOnTab: index === wallGrid.currentIndex
                Accessible.role: Accessible.Button
                Accessible.name: shuffle ? "Shuffle wallpaper now"
                    : "Use wallpaper " + page.basename(imagePath)
                Accessible.selected: current
                Accessible.onPressAction: cell.activate()

                Component.onCompleted: {
                    if (!shuffle)
                        Wallpaper.requestThumbnail(imagePath);
                }
                onImagePathChanged: {
                    if (!shuffle)
                        Wallpaper.requestThumbnail(imagePath);
                }

                function activate() {
                    wallGrid.currentIndex = index;
                    if (shuffle)
                        Wallpaper.shuffle();
                    else
                        Wallpaper.set(imagePath);
                }

                Keys.onPressed: event => {
                    let next = -1;
                    if (event.key === Qt.Key_Left)
                        next = index - 1;
                    else if (event.key === Qt.Key_Right)
                        next = index + 1;
                    else if (event.key === Qt.Key_Up)
                        next = index - wallGrid.columnCount;
                    else if (event.key === Qt.Key_Down)
                        next = index + wallGrid.columnCount;
                    else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                            || event.key === Qt.Key_Space) {
                        activate(); event.accepted = true; return;
                    }
                    if (next >= 0 && next < wallGrid.count) {
                        page.focusThumbnail(next);
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
                    border.width: cell.current || cell.activeFocus ? 2 : cell.shuffle ? 1 : 0
                    border.color: cell.activeFocus ? Theme.textHi
                        : cell.current ? Theme.accent : Theme.stroke

                    Rectangle {
                        anchors.fill: parent
                        color: Theme.cardFill
                        visible: !cell.shuffle && wallImage.status !== Image.Ready
                        Text {
                            anchors.centerIn: parent
                            width: parent.width - 20
                            horizontalAlignment: Text.AlignHCenter
                            text: wallImage.status === Image.Error ? "Could not load" : "Loading…"
                            font.family: Theme.fontMenu
                            font.pixelSize: Theme.typography.secondary
                            color: Theme.textFaint
                            elide: Text.ElideRight
                        }
                    }

                    Image {
                        id: wallImage
                        anchors.fill: parent
                        visible: !cell.shuffle
                        source: cell.thumbnailSource
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        cache: true
                        sourceSize.width: 330
                    }

                    Column {
                        visible: cell.shuffle
                        anchors.centerIn: parent
                        width: parent.width - 20
                        spacing: 4
                        Sym {
                            anchors.horizontalCenter: parent.horizontalCenter
                            name: "shuffle"
                            size: Theme.iconLarge
                            color: Theme.textLow
                        }
                        Text {
                            width: parent.width
                            horizontalAlignment: Text.AlignHCenter
                            text: "Shuffle now"
                            font.family: Theme.fontMenu
                            font.pixelSize: Theme.typography.control
                            font.weight: Theme.weightMedium
                            color: Theme.textLow
                            elide: Text.ElideRight
                        }
                    }

                    Rectangle {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        height: fileName.implicitHeight + 10
                        visible: !cell.shuffle && (cellMouse.containsMouse || cell.activeFocus)
                        color: Qt.rgba(0, 0, 0, 0.62)
                        Text {
                            id: fileName
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.leftMargin: 7
                            anchors.rightMargin: 7
                            anchors.verticalCenter: parent.verticalCenter
                            text: page.basename(cell.imagePath)
                            elide: Text.ElideMiddle
                            font.family: Theme.fontMenu
                            font.pixelSize: Theme.typography.primary
                            color: "#ffffff"
                        }
                    }

                    Rectangle {
                        visible: cell.current
                        anchors.top: parent.top
                        anchors.topMargin: 6
                        anchors.right: parent.right
                        anchors.rightMargin: 6
                        width: 16; height: 16; radius: 8
                        color: Theme.accent
                        Sym {
                            anchors.centerIn: parent
                            name: "check"
                            size: Theme.iconSmall
                            symWeight: 700
                            color: Theme.accentFg
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

            StatusPlaceholder {
                anchors.centerIn: parent
                width: Math.max(0, parent.width - 40)
                height: implicitHeight
                shown: Wallpaper.loading || Wallpaper.files.length === 0
                kind: Wallpaper.loading ? "loading" : "empty"
                glyph: Wallpaper.loading ? "progress_activity" : "image"
                title: Wallpaper.loading ? "Loading wallpapers…" : "No images found"
                detail: Wallpaper.loading ? "" : page.dirLabel
            }
        }
    }

    SettingsGroup {
        id: rotationGroup
        visible: !page.online
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: folderGroup.top
        anchors.bottomMargin: Theme.settingsGroupSpacing
        title: "Rotation"

        PickerRow {
            width: parent.width
            label: "Rotate"
            settingKey: "shuffle"
            model: [
                { value: "Off", label: "Off" },
                { value: "15m", label: "15 min" },
                { value: "1h", label: "1 hour" },
                { value: "1d", label: "Daily" }
            ]
        }
    }

    SettingsGroup {
        id: folderGroup
        visible: !page.online
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        title: "Folder"

        Text {
            visible: Wallpaper.directoryError !== ""
            width: parent.width
            height: visible ? implicitHeight : 0
            text: Wallpaper.directoryError
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.secondary
            color: Theme.redText
            wrapMode: Text.Wrap
            maximumLineCount: 2
            elide: Text.ElideRight
            Accessible.role: Accessible.AlertMessage
            Accessible.name: text
        }

        ResponsiveActionRow {
            width: parent.width
            breakpoint: 540
            descriptionMono: true
            description: page.dirLabel + " · " + Wallpaper.files.length + " images"

            SettingsAction {
                text: "Choose folder"
                glyph: "folder"
                Accessible.name: "Choose wallpaper folder"
                onTriggered: folderDialog.openAt(Settings.wallDir)
            }
            SettingsAction {
                text: "Open"
                glyph: "folder_open"
                Accessible.name: "Open wallpaper folder"
                onTriggered: Quickshell.execDetached(["xdg-open", Wallpaper.dir])
            }
        }
    }

    FolderDialog {
        id: folderDialog
        onFolderChosen: path => Wallpaper.requestDirectory(path)
    }
}
