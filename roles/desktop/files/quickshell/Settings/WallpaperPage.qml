pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Widgets
import "../Common"

// The one page that does not scroll as a whole: the gallery stays
// virtualized and takes whatever height the rows around it leave. It keeps
// the other pages' bounded column and row grammar all the same (2026-09
// redesign): a Browse row picks Library or Online, the grid sits in the row
// grid, and the current image, rotation and folder are rows with their
// controls on the right-hand edge. The Online view (Wallhaven) is loaded only
// once it is chosen, so opening the page never reaches the network by itself.
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

    // SettingsPage's column: bounded, centered, and clear of the gutter a
    // scrolling page keeps for its scroll bar, so moving between pages does
    // not shift the rows sideways.
    Item {
        id: column
        width: Math.min(Theme.scaled(640, Theme.typeScale), Math.max(0, page.width - 8))
        x: Math.max(0, Math.floor((page.width - 8 - width) / 2))
        height: page.height

        // Where to look is view state, not a setting: nothing to mark as
        // changed and nothing to reset.
        PickerRow {
            id: viewTabs
            width: parent.width
            label: "Browse"
            model: [
                { value: "library", label: "Library" },
                { value: "online", label: "Online" }
            ]
            current: OnlineWallpapers.view
            dirty: false
            resetKeys: []
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
            title: "Library"

            GridView {
                id: wallGrid
                readonly property int columnCount: width < Theme.settingsNarrowWidth ? 1 : 2
                // The label lane on the left; on the right, each tile's own
                // 7px gutter falls into the reset column, so the tiles end
                // where the rows' controls do.
                x: Theme.settingsMarkInset
                width: Math.max(0, parent.width - x - Theme.chipHeight + 7)
                height: Math.max(0, galleryGroup.availableContentHeight
                    - currentRow.height - galleryGroup.rowSpacing)
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                cellWidth: Math.floor(width / columnCount)
                cellHeight: columnCount === 1
                    ? Math.max(126, Math.min(190, cellWidth * 0.42))
                    : Math.max(106, Math.min(150, cellWidth * 0.58 + 7))
                model: Wallpaper.files.length
                currentIndex: 0

                delegate: Item {
                    id: cell
                    required property int index
                    readonly property string imagePath: Wallpaper.files[index] || ""
                    readonly property string thumbnailSource: Wallpaper.thumbnailFor(imagePath)
                    readonly property bool current:
                        page.basename(Wallpaper.current) === page.basename(imagePath)

                    width: wallGrid.cellWidth
                    height: wallGrid.cellHeight
                    activeFocusOnTab: index === wallGrid.currentIndex
                    Accessible.role: Accessible.Button
                    Accessible.name: "Use wallpaper " + page.basename(imagePath)
                    Accessible.selected: current
                    Accessible.onPressAction: cell.activate()

                    Component.onCompleted: Wallpaper.requestThumbnail(imagePath)
                    onImagePathChanged: Wallpaper.requestThumbnail(imagePath)

                    function activate() {
                        wallGrid.currentIndex = index;
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
                        border.width: cell.current || cell.activeFocus ? 2 : 0
                        border.color: cell.activeFocus ? Theme.textHi : Theme.accent

                        Rectangle {
                            anchors.fill: parent
                            color: Theme.cardFill
                            visible: wallImage.status !== Image.Ready
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
                            source: cell.thumbnailSource
                            fillMode: Image.PreserveAspectCrop
                            asynchronous: true
                            cache: true
                            sourceSize.width: 330
                        }

                        Rectangle {
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.bottom: parent.bottom
                            height: fileName.implicitHeight + 10
                            visible: cellMouse.containsMouse || cell.activeFocus
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

            // What is on the desktop now, named, with the shuffle that used
            // to be the grid's last tile. The search index's "Wallpaper"
            // lands here. Choosing a wallpaper is not a departure from a
            // default, so the row carries no changed mark and no reset.
            SettingsRow {
                id: currentRow
                width: parent.width
                label: "Current"
                settingKey: "wall"
                dirty: false
                resetKeys: []
                narrowLabelInset: currentRow.undoWidth
                controlLeft: currentRow.narrow ? currentRow.labelWidth : currentName.x

                Text {
                    id: currentName
                    readonly property real laneLeft: currentRow.narrow
                        ? currentRow.markInset : currentRow.labelWidth
                    width: Math.max(0, Math.min(implicitWidth,
                        shuffleAction.x - Theme.controlSpacing - laneLeft))
                    x: currentRow.narrow ? laneLeft : shuffleAction.x - Theme.controlSpacing - width
                    y: shuffleAction.y + (shuffleAction.height - height) / 2
                    text: currentRow.stored !== "" ? currentRow.stored : "None"
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.control
                    color: currentRow.stored !== "" ? Theme.textHi : Theme.textFaint
                    elide: Text.ElideMiddle
                }
                SettingsAction {
                    id: shuffleAction
                    x: currentRow.contentRight - width
                    y: currentRow.narrow
                        ? Theme.settingsStackOffset + (Theme.settingsControlHeight - height) / 2
                        : (currentRow.lineHeight - height) / 2
                    text: "Shuffle now"
                    glyph: "shuffle"
                    enabled: Wallpaper.files.length > 1
                    Accessible.name: "Shuffle wallpaper now"
                    onTriggered: Wallpaper.shuffle()
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

            // The folder names itself: its path is the row's label, in the
            // mono face and eliding in the middle so both ends of a long
            // path stay readable, with the actions on the controls' edge. A
            // folder that cannot be used says why on the hint line. Like the
            // current wallpaper, it has no default to reset to.
            SettingsRow {
                id: folderRow
                width: parent.width
                settingKey: "wallDir"
                dirty: false
                resetKeys: []
                hint: Wallpaper.directoryError !== "" ? Wallpaper.directoryError
                    : Wallpaper.loading ? "Loading…"
                    : Wallpaper.files.length === 1 ? "1 image"
                    : Wallpaper.files.length + " images"
                hintTone: Wallpaper.directoryError !== "" ? "error" : "info"
                narrowLabelInset: folderRow.undoWidth
                controlLeft: folderActions.x

                Text {
                    id: folderPath
                    x: folderRow.markInset
                    y: folderRow.narrow ? 0 : (folderRow.lineHeight - height) / 2
                    width: folderRow.narrow
                        ? Math.max(0, folderRow.contentRight - x)
                        : Math.max(0, folderActions.x - Theme.controlSpacing - x)
                    text: page.dirLabel
                    font.family: Theme.fontMono
                    font.pixelSize: Theme.typography.control
                    color: Theme.textMid
                    elide: Text.ElideMiddle
                    Accessible.role: Accessible.StaticText
                    Accessible.name: "Wallpaper folder " + page.dirLabel
                }
                Row {
                    id: folderActions
                    x: folderRow.narrow ? folderRow.markInset : folderRow.contentRight - width
                    y: folderRow.narrow
                        ? Theme.settingsStackOffset + (Theme.settingsControlHeight - height) / 2
                        : (folderRow.lineHeight - height) / 2
                    spacing: Theme.iconTextSpacing

                    SettingsAction {
                        text: "Choose…"
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
        }
    }

    FolderDialog {
        id: folderDialog
        onFolderChosen: path => Wallpaper.requestDirectory(path)
    }
}
