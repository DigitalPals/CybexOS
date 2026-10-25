pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import "../Common"

// One virtualized, preview-only grid for local files and Wallhaven results.
// Enter selects; applying always belongs to the preview's explicit action.
GridView {
    id: root
    property var items: []
    property string selectedKey: ""
    property bool online: false
    signal selected(var item)
    readonly property int columnCount: width >= 300 ? 3 : width >= 190 ? 2 : 1
    cellWidth: Math.floor(width / columnCount)
    cellHeight: Math.floor((cellWidth - 8) * 10 / 16) + 8
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    model: ScriptModel { values: root.items }
    currentIndex: 0

    function focusItem(index) {
        const next = Math.max(0, Math.min(count - 1, index));
        positionViewAtIndex(next, GridView.Contain);
        const item = itemAtIndex(next);
        if (item)
            item.forceActiveFocus();
        currentIndex = next;
        if (!item)
            Qt.callLater(() => { if (root.currentItem) root.currentItem.forceActiveFocus(); });
    }

    delegate: Item {
        id: cell
        required property var modelData
        required property int index
        readonly property string key: modelData.id || modelData.path
        readonly property string resolution: modelData.width > 0
            ? modelData.width + " × " + modelData.height : modelData.label
        readonly property bool chosen: root.selectedKey === key
        readonly property bool downloading: root.online && OnlineWallpapers.downloadingId === modelData.id
        width: root.cellWidth
        height: root.cellHeight
        activeFocusOnTab: index === root.currentIndex
        Accessible.role: Accessible.Button
        Accessible.name: I18n.format("Preview wallpaper %1", [modelData.label || modelData.fileName])
        Accessible.selected: chosen
        Accessible.onPressAction: activate()
        function activate() {
            root.currentIndex = index;
            root.selected(modelData);
        }
        Component.onCompleted: { if (!root.online) Wallpaper.requestThumbnail(modelData.path); }
        Keys.onPressed: event => {
            let next = -1;
            if (event.key === Qt.Key_Left) next = index - 1;
            else if (event.key === Qt.Key_Right) next = index + 1;
            else if (event.key === Qt.Key_Up) next = index - root.columnCount;
            else if (event.key === Qt.Key_Down) next = index + root.columnCount;
            else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                activate(); event.accepted = true; return;
            }
            if (next >= 0 && next < root.count) {
                root.focusItem(next);
                event.accepted = true;
            }
        }
        // Qt's rectangle clipping also draws in the software renderer used
        // by isolated real-engine checks; native rounded clipping does not.
        Rectangle {
            anchors.fill: parent
            anchors.rightMargin: 8
            anchors.bottomMargin: 8
            radius: Theme.chipRadius
            color: Theme.cardFill
            clip: true
            border.width: cell.chosen || cell.activeFocus ? 2 : 0
            border.color: cell.activeFocus ? Theme.textHi : Theme.accent
            Image {
                anchors.fill: parent
                anchors.margins: 2
                source: root.online ? cell.modelData.thumb : Wallpaper.thumbnailFor(cell.modelData.path)
                asynchronous: true
                fillMode: Image.PreserveAspectCrop
                sourceSize.width: 360
            }
            // The size or name badge shows whole or not at all: an elided
            // "256…440" reads as a different size. The preview names it too.
            Rectangle {
                anchors.left: parent.left
                anchors.leftMargin: 6
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 6
                visible: width <= parent.width - 12 && height <= parent.height - 12
                width: badge.implicitWidth + 10
                height: badge.implicitHeight + 6
                radius: 4
                color: Qt.rgba(0, 0, 0, 0.65)
                Text {
                    id: badge
                    anchors.centerIn: parent
                    textFormat: Text.PlainText
                    text: cell.resolution
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.secondary
                    color: "#ffffff"
                }
            }
            Rectangle {
                visible: cell.chosen
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: 6
                width: 18; height: 18; radius: 9
                color: Theme.accent
                Sym { anchors.centerIn: parent; name: "check"; size: Theme.iconSmall; color: Theme.accentFg }
            }
            Rectangle {
                visible: cell.downloading
                anchors.left: parent.left
                anchors.bottom: parent.bottom
                height: 4
                width: parent.width * OnlineWallpapers.downloadProgress / 100
                color: Theme.accent
            }
            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: { cell.forceActiveFocus(); cell.activate(); }
            }
        }
    }
}
