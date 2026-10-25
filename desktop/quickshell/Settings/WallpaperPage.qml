pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import "../Common"

// Shared picker above the existing current, rotation and folder rows.
Item {
    id: page

    readonly property string dirLabel: Settings.wallDir
    readonly property string currentPage: {
        const match = /^wallhaven-([a-z0-9]{1,16})\.(jpg|png)$/.exec(Settings.wall);
        return match ? "https://wallhaven.cc/w/" + match[1] : "";
    }

    Item {
        id: column
        width: Math.min(Theme.scaled(900, Theme.typeScale), Math.max(0, page.width - 8))
        x: Math.max(0, Math.floor((page.width - 8 - width) / 2))
        height: page.height

        WallpaperPicker {
            id: picker
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: currentRow.top
            anchors.bottomMargin: Theme.settingsGroupSpacing
            tab: OnlineWallpapers.view
            compact: width < 780
            onTabChanged: OnlineWallpapers.view = tab
            onEscapeRequested: Settings.closePanel()
        }
        Connections {
            target: OnlineWallpapers
            function onViewChanged() { picker.tab = OnlineWallpapers.view; }
        }
        SettingsRow {
            id: currentRow
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: options.top
            anchors.bottomMargin: Theme.settingsGroupSpacing
            label: I18n.tr("Current")
            hint: Settings.wall !== "" ? Settings.wall : I18n.tr("Cybex OS default")
            dirty: false
            resetKeys: []
            Row {
                x: currentRow.contentRight - width
                y: (currentRow.lineHeight - height) / 2
                spacing: Theme.iconTextSpacing
                SettingsAction {
                    visible: page.currentPage !== ""
                    compact: true
                    glyph: "open_in_new"
                    text: I18n.tr("Current on Wallhaven")
                    Accessible.name: I18n.tr("Open the current wallpaper's Wallhaven page")
                    onTriggered: Qt.openUrlExternally(page.currentPage)
                }
                SettingsAction {
                    text: I18n.tr("Shuffle now")
                    glyph: "shuffle"
                    enabled: Wallpaper.files.length > 1
                    Accessible.name: I18n.tr("Shuffle wallpaper now")
                    onTriggered: Wallpaper.shuffle()
                }
            }
        }

        SettingsDisclosure {
            id: options
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            text: I18n.tr("Rotation and folder")
            keys: ["shuffle", "wallDir"]

            SettingsGroup {
                id: rotationGroup
                width: parent.width
                title: I18n.tr("Rotation")

                PickerRow {
                    width: parent.width
                    label: I18n.tr("Rotate")
                    settingKey: "shuffle"
                    model: [
                        { value: "Off", label: I18n.tr("Off") },
                        { value: "15m", label: I18n.tr("15 min") },
                        { value: "1h", label: I18n.tr("1 hour") },
                        { value: "1d", label: I18n.tr("Daily") }
                    ]
                }
            }

            SettingsGroup {
                id: folderGroup
                width: parent.width
                title: I18n.tr("Folder")

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
                        : Wallpaper.loading ? I18n.tr("Loading…")
                        : Wallpaper.files.length === 1 ? I18n.tr("1 image")
                        : I18n.format("%1 images", [Wallpaper.files.length])
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
                        Accessible.name: I18n.format("Wallpaper folder %1", [page.dirLabel])
                    }
                    Row {
                        id: folderActions
                        x: folderRow.narrow ? folderRow.markInset : folderRow.contentRight - width
                        y: folderRow.narrow
                            ? Theme.settingsStackOffset + (Theme.settingsControlHeight - height) / 2
                            : (folderRow.lineHeight - height) / 2
                        spacing: Theme.iconTextSpacing

                        SettingsAction {
                            text: I18n.tr("Choose…")
                            glyph: "folder"
                            Accessible.name: I18n.tr("Choose wallpaper folder")
                            onTriggered: folderDialog.openAt(Settings.wallDir)
                        }
                        SettingsAction {
                            text: I18n.tr("Open")
                            glyph: "folder_open"
                            Accessible.name: I18n.tr("Open wallpaper folder")
                            onTriggered: Quickshell.execDetached(["xdg-open", Wallpaper.dir])
                        }
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
