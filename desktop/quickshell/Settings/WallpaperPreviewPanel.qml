pragma ComponentBehavior: Bound
import QtQuick
import "../Common"
import "../Common/WallhavenHelpers.js" as WallhavenHelpers

// Presentation only. The picker supplies a validated item/details and owns
// the apply action, so this panel also fits a narrow welcome step.
Item {
    id: root
    property var item: null
    property var details: null
    property bool online: false
    property bool busy: false
    property int progress: 0
    property string error: ""
    signal useRequested()
    signal moreLikeRequested()
    readonly property var info: details || item
    readonly property bool fits: item && item.width > 0 && OnlineWallpapers.screenSizes.every(screen =>
        item.width >= screen.width && item.height >= screen.height)
    function reveal(action) {
        if (!action.activeFocus)
            return;
        const y = action.mapToItem(content, 0, 0).y;
        scroll.contentY = Math.max(0, Math.min(y, Math.max(0, scroll.contentHeight - scroll.height)));
    }
    Flickable {
        id: scroll
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: useButton.top
        anchors.bottomMargin: Theme.controlSpacing
        contentHeight: content.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
            id: content
            width: root.width
            spacing: Theme.controlSpacing
            Rectangle {
                width: parent.width
                height: width * 10 / 16
                radius: Theme.chipRadius
                color: Theme.cardFill
                clip: true
                Image {
                    anchors.fill: parent
                    source: !root.item ? "" : root.online
                        ? OnlineWallpapers.saved[root.item.fileName]
                            ? Wallpaper.url(Wallpaper.dir + "/" + root.item.fileName) : root.item.thumb
                        : root.item.path
                    asynchronous: true
                    fillMode: Image.PreserveAspectCrop
                    sourceSize.width: 600
                }
            }
            Text {
                width: parent.width
                text: root.item ? root.item.label || root.item.fileName : I18n.tr("Select a wallpaper to preview")
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.control
                font.weight: Theme.weightSemibold
                color: Theme.textHi
            }
            Text {
                width: parent.width
                visible: root.item !== null
                text: root.item && root.item.width > 0 ? WallhavenHelpers.describe(root.item) : ""
                wrapMode: Text.Wrap
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.secondary
                color: Theme.textMid
            }
            Text {
                width: parent.width
                visible: root.item !== null && root.item.width > 0 && OnlineWallpapers.screenSizes.length > 0
                text: root.fits ? I18n.tr("Fits your displays") : I18n.tr("Smaller than your displays")
                wrapMode: Text.Wrap
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.secondary
                color: root.fits ? Theme.textMid : Theme.amber
            }
            Text {
                visible: root.item !== null && (root.info.colors || []).length > 0
                width: parent.width
                text: I18n.tr("Colours in this image")
                wrapMode: Text.Wrap
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.secondary
                color: Theme.textMid
            }
            Flow {
                width: parent.width
                spacing: 5
                Repeater {
                    model: root.info ? root.info.colors || [] : []
                    Rectangle {
                        required property string modelData
                        width: 21; height: 21; radius: 6
                        color: modelData
                        border.width: 1
                        border.color: Theme.stroke
                        Accessible.role: Accessible.StaticText
                        Accessible.name: I18n.format("Image colour %1", [modelData])
                    }
                }
            }
            Text {
                width: parent.width
                visible: root.online && root.details && root.details.uploader !== ""
                text: root.details ? I18n.format("Uploaded by %1", [root.details.uploader]) : ""
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.secondary
                color: Theme.textMid
            }
            Text {
                width: parent.width
                visible: root.online && root.details && root.details.tags.length > 0
                text: root.details ? root.details.tags.join(" · ") : ""
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                maximumLineCount: 3
                elide: Text.ElideRight
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.secondary
                color: Theme.textFaint
            }
            SettingsAction {
                visible: root.online && root.details && root.details.source !== ""
                text: I18n.tr("Source")
                glyph: "open_in_new"
                Accessible.name: I18n.tr("Open wallpaper source")
                tooltip: root.details ? root.details.source : ""
                onActiveFocusChanged: root.reveal(this)
                onTriggered: Qt.openUrlExternally(root.details.source)
            }
            SettingsAction {
                visible: root.online && root.item !== null
                width: parent.width
                text: I18n.tr("View on Wallhaven")
                onActiveFocusChanged: root.reveal(this)
                onTriggered: Qt.openUrlExternally(root.item.page)
            }
            SettingsAction {
                visible: root.online && root.item !== null
                text: I18n.tr("More like this")
                onActiveFocusChanged: root.reveal(this)
                onTriggered: root.moreLikeRequested()
            }
            Rectangle {
                visible: root.busy
                width: parent.width
                height: 4
                radius: 2
                color: Theme.cardFill
                Rectangle { width: parent.width * root.progress / 100; height: parent.height; color: Theme.accent }
            }
            SettingsHint { width: parent.width; text: root.error; tone: "error" }
            Text {
                width: parent.width
                visible: root.online
                text: I18n.tr("Safe-for-work only. Images belong to their creators; check the source before reusing.")
                wrapMode: Text.Wrap
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.secondary
                color: Theme.textFaint
            }
        }
    }
    // The full label, or "Apply" where a narrow panel, a long translation or
    // large text would push it past the button's edges.
    SettingsAction {
        id: useButton
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        primary: true
        enabled: root.item !== null && !root.busy
        text: root.busy ? I18n.format("Downloading %1%", [root.progress])
            : useLabel.advanceWidth + 24 <= width ? useLabel.text : I18n.tr("Apply")
        Accessible.name: root.busy ? text : useLabel.text
        onTriggered: root.useRequested()
    }
    TextMetrics {
        id: useLabel
        text: I18n.tr("Use this wallpaper")
        font.family: Theme.fontMenu
        font.pixelSize: Theme.typography.control
        font.weight: Theme.weightSemibold
    }
}
