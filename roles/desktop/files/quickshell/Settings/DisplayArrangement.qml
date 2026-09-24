pragma ComponentBehavior: Bound
import QtQuick
import "../Common"
import "../Common/DisplayHelpers.js" as Displays

// The arrangement preview: every display that shows its own picture, drawn
// to scale in Hyprland's layout coordinates. Dragging a tile moves that
// display; on release DisplayHelpers snaps it to the nearest shared edge.
// With the canvas focused, arrow keys place the selected display beside the
// others, which keeps the arrangement usable without a pointer.
Item {
    id: root

    property var drafts: []
    property string selectedKey: ""
    signal selected(string key)
    signal moved(string key, real x, real y)
    signal nudged(string key, string direction)

    readonly property var layout: Displays.rects(drafts)
    readonly property real minX: layout.length ? Math.min(...layout.map(rect => rect.x)) : 0
    readonly property real minY: layout.length ? Math.min(...layout.map(rect => rect.y)) : 0
    readonly property real spanX: layout.length
        ? Math.max(1, Math.max(...layout.map(rect => rect.x + rect.width)) - minX) : 1
    readonly property real spanY: layout.length
        ? Math.max(1, Math.max(...layout.map(rect => rect.y + rect.height)) - minY) : 1
    readonly property real pad: Theme.scaled(18)
    readonly property real factor: Math.max(0.0001, Math.min((width - pad * 2) / spanX,
        (height - pad * 2) / spanY))
    readonly property real originX: (width - spanX * factor) / 2
    readonly property real originY: (height - spanY * factor) / 2

    implicitHeight: Theme.scaled(190)
    activeFocusOnTab: true
    Accessible.role: Accessible.Pane
    Accessible.name: "Display arrangement. Arrow keys place the selected display beside the others."

    Keys.onPressed: event => {
        const directions = {};
        directions[Qt.Key_Left] = "left";
        directions[Qt.Key_Right] = "right";
        directions[Qt.Key_Up] = "up";
        directions[Qt.Key_Down] = "down";
        const direction = directions[event.key];
        if (direction && root.enabled && root.selectedKey !== "") {
            root.nudged(root.selectedKey, direction);
            event.accepted = true;
        }
    }

    Rectangle {
        anchors.fill: parent
        radius: Theme.chipRadius
        color: Theme.cardFill
        border.width: root.activeFocus ? 1 : 0
        border.color: Theme.accentText
    }

    Text {
        visible: root.layout.length === 0
        anchors.centerIn: parent
        text: "No display is showing its own picture"
        font.family: Theme.fontMenu
        font.pixelSize: Theme.typography.secondary
        color: Theme.textFaint
    }

    Repeater {
        model: root.layout

        delegate: Rectangle {
            id: tile

            required property var modelData
            readonly property var draft: root.drafts.find(item => item.key === modelData.key) || ({})
            readonly property bool current: modelData.key === root.selectedKey
            readonly property var mirrors: root.drafts.filter(item => item.enabled && item.mirror === modelData.key)
            property real dragX: 0
            property real dragY: 0
            property real pressX: 0
            property real pressY: 0
            property bool dragging: false

            x: root.originX + (modelData.x - root.minX) * root.factor + dragX
            y: root.originY + (modelData.y - root.minY) * root.factor + dragY
            z: dragging ? 2 : current ? 1 : 0
            width: Math.max(8, modelData.width * root.factor - 2)
            height: Math.max(8, modelData.height * root.factor - 2)
            radius: Math.min(6, width / 6)
            color: current ? Theme.accentAlpha(0.22) : dragMouse.containsMouse ? Theme.chipHover : Theme.chip
            border.width: current ? 2 : 1
            border.color: current ? Theme.accentText : Theme.stroke
            opacity: root.enabled ? 1 : 0.6
            Accessible.role: Accessible.Button
            Accessible.name: (draft.label || modelData.key) + ", " + modelData.width + " by "
                + modelData.height + " at " + modelData.x + ", " + modelData.y

            Column {
                anchors.centerIn: parent
                width: parent.width - 8
                spacing: 1

                Text {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    text: tile.draft.name || ""
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.control
                    font.weight: Theme.weightSemibold
                    color: tile.current ? Theme.textHi : Theme.textMid
                    elide: Text.ElideRight
                }
                Text {
                    width: parent.width
                    visible: tile.height > Theme.scaled(44)
                    horizontalAlignment: Text.AlignHCenter
                    text: Displays.sizeLabel(tile.modelData.width, tile.modelData.height)
                    font.family: Theme.fontMono
                    font.pixelSize: Theme.typography.metadata
                    color: Theme.textFaint
                    elide: Text.ElideRight
                }
                Text {
                    width: parent.width
                    visible: tile.mirrors.length > 0 && tile.height > Theme.scaled(60)
                    horizontalAlignment: Text.AlignHCenter
                    text: "Mirrored on " + tile.mirrors.map(item => item.name).join(", ")
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.metadata
                    color: Theme.textFaint
                    elide: Text.ElideRight
                }
            }

            MouseArea {
                id: dragMouse
                anchors.fill: parent
                hoverEnabled: true
                enabled: root.enabled
                cursorShape: tile.dragging ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                onPressed: mouse => {
                    root.forceActiveFocus();
                    root.selected(tile.modelData.key);
                    tile.pressX = mouse.x;
                    tile.pressY = mouse.y;
                }
                onPositionChanged: mouse => {
                    if (!pressed)
                        return;
                    const dx = mouse.x - tile.pressX;
                    const dy = mouse.y - tile.pressY;
                    if (!tile.dragging && Math.abs(dx) + Math.abs(dy) < 4)
                        return;
                    tile.dragging = true;
                    tile.dragX += dx;
                    tile.dragY += dy;
                }
                onReleased: {
                    if (tile.dragging)
                        root.moved(tile.modelData.key, tile.modelData.x + tile.dragX / root.factor,
                            tile.modelData.y + tile.dragY / root.factor);
                    tile.dragging = false;
                    tile.dragX = 0;
                    tile.dragY = 0;
                }
                onCanceled: {
                    tile.dragging = false;
                    tile.dragX = 0;
                    tile.dragY = 0;
                }
            }
        }
    }
}
