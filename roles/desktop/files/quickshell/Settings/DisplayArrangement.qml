pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import "../Common"
import "../Common/DisplayHelpers.js" as Displays

// The arrangement preview, which is also how the page picks the display it
// edits (2026-09 redesign; the separate Display picker row is gone). Every
// display that shows its own picture is drawn to scale in Hyprland's layout
// coordinates; one that is off or mirroring another takes no room there and
// waits as a chip along the bottom, so it can still be chosen and turned on.
//
// Pressing a tile selects it. Dragging moves it; on release DisplayHelpers
// snaps it to the nearest shared edge. Each tile is a Tab stop: Enter or
// Space selects it and the arrow keys place it beside the others, which keeps
// the arrangement usable without a pointer.
//
// Both lists are keyed by display, not by the computed rectangles, so a tile
// survives the layout recomputing around it — keyboard focus stays on the
// display being moved.
Item {
    id: root

    property var drafts: []
    property string selectedKey: ""
    signal selected(string key)
    signal moved(string key, real x, real y)
    signal nudged(string key, string direction)

    readonly property var layout: Displays.rects(drafts)
    readonly property var aside: drafts.filter(draft => !(draft.enabled && draft.mirror === ""))
    readonly property real asideHeight: aside.length > 0
        ? Theme.chipHeight + Theme.settingsContentSpacing : 0
    // The part of the canvas the layout is drawn in, above the chips.
    readonly property real stageHeight: Math.max(1, height - asideHeight)
    readonly property real minX: layout.length ? Math.min(...layout.map(rect => rect.x)) : 0
    readonly property real minY: layout.length ? Math.min(...layout.map(rect => rect.y)) : 0
    readonly property real spanX: layout.length
        ? Math.max(1, Math.max(...layout.map(rect => rect.x + rect.width)) - minX) : 1
    readonly property real spanY: layout.length
        ? Math.max(1, Math.max(...layout.map(rect => rect.y + rect.height)) - minY) : 1
    readonly property real pad: Theme.scaled(18)
    readonly property real factor: Math.max(0.0001, Math.min((width - pad * 2) / spanX,
        (stageHeight - pad * 2) / spanY))
    readonly property real originX: (width - spanX * factor) / 2
    readonly property real originY: (stageHeight - spanY * factor) / 2

    function draftFor(key) {
        return root.drafts.find(item => item.key === key) || ({});
    }

    // Enter/Space select; arrows select and move. Shared by both kinds of
    // entry; `movable` is false for a chip, which has no place to move from.
    function handleKey(event, key, movable) {
        const directions = {};
        directions[Qt.Key_Left] = "left";
        directions[Qt.Key_Right] = "right";
        directions[Qt.Key_Up] = "up";
        directions[Qt.Key_Down] = "down";
        const direction = directions[event.key];
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                || event.key === Qt.Key_Space) {
            root.selected(key);
            event.accepted = true;
        } else if (direction && movable && root.enabled) {
            root.selected(key);
            root.nudged(key, direction);
            event.accepted = true;
        }
    }

    implicitHeight: Theme.scaled(190) + asideHeight
    Accessible.role: Accessible.Grouping
    Accessible.name: "Display arrangement"
    Accessible.description: "Select a display to change it below. Arrow keys place the focused display beside the others."

    Rectangle {
        anchors.fill: parent
        radius: Theme.chipRadius
        color: Theme.cardFill
    }

    Text {
        visible: root.layout.length === 0
        anchors.horizontalCenter: parent.horizontalCenter
        y: (root.stageHeight - height) / 2
        text: "No display is showing its own picture"
        font.family: Theme.fontMenu
        font.pixelSize: Theme.typography.secondary
        color: Theme.textFaint
    }

    Repeater {
        model: ScriptModel {
            values: root.layout.map(rect => rect.key)
        }

        delegate: Rectangle {
            id: tile

            required property string modelData
            readonly property var rect: root.layout.find(item => item.key === modelData)
                || ({ key: modelData, x: root.minX, y: root.minY, width: 1, height: 1 })
            readonly property var draft: root.draftFor(modelData)
            readonly property bool current: modelData === root.selectedKey
            readonly property var mirrors: root.drafts.filter(item => item.enabled && item.mirror === tile.modelData)
            property real dragX: 0
            property real dragY: 0
            property real pressX: 0
            property real pressY: 0
            property bool dragging: false

            x: root.originX + (rect.x - root.minX) * root.factor + dragX
            y: root.originY + (rect.y - root.minY) * root.factor + dragY
            z: dragging ? 2 : current ? 1 : 0
            width: Math.max(8, rect.width * root.factor - 2)
            height: Math.max(8, rect.height * root.factor - 2)
            radius: Math.min(6, width / 6)
            color: current ? Theme.accentAlpha(0.22) : dragMouse.containsMouse ? Theme.chipHover : Theme.chip
            border.width: current ? 2 : 1
            border.color: current ? Theme.accentText : Theme.stroke
            opacity: root.enabled ? 1 : 0.6
            activeFocusOnTab: root.enabled
            Accessible.role: Accessible.RadioButton
            Accessible.name: (draft.name || modelData) + ", " + (draft.label || "") + ", "
                + rect.width + " by " + rect.height + " at " + rect.x + ", " + rect.y
            Accessible.checkable: true
            Accessible.checked: tile.current
            Accessible.onPressAction: root.selected(tile.modelData)
            Keys.onPressed: event => root.handleKey(event, tile.modelData, true)

            // Focus ring outside the tile, so it never reads as the selection.
            Rectangle {
                anchors.fill: parent
                anchors.margins: -3
                radius: tile.radius + 3
                color: "transparent"
                border.width: tile.activeFocus ? 1 : 0
                border.color: Theme.accentText
            }

            Sym {
                visible: tile.current && tile.width > Theme.scaled(64) && tile.height > Theme.scaled(40)
                x: tile.width - width - Theme.scaled(5)
                y: Theme.scaled(5)
                name: "check"
                size: Theme.iconSmall
                color: Theme.accentText
            }

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
                    text: Displays.sizeLabel(tile.rect.width, tile.rect.height)
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
                cursorShape: tile.dragging ? Qt.ClosedHandCursor
                    : tile.current ? Qt.OpenHandCursor : Qt.PointingHandCursor
                onPressed: mouse => {
                    tile.forceActiveFocus(Qt.MouseFocusReason);
                    root.selected(tile.modelData);
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
                        root.moved(tile.modelData, tile.rect.x + tile.dragX / root.factor,
                            tile.rect.y + tile.dragY / root.factor);
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

    // Displays outside the layout: off, or showing another display's picture.
    Row {
        visible: root.aside.length > 0
        anchors.horizontalCenter: parent.horizontalCenter
        y: root.stageHeight
        spacing: Theme.controlSpacing

        Repeater {
            model: ScriptModel {
                values: root.aside.map(draft => draft.key)
            }

            delegate: Rectangle {
                id: chip

                required property string modelData
                readonly property var draft: root.draftFor(modelData)
                readonly property bool current: modelData === root.selectedKey
                readonly property string status: chip.draft.enabled
                    ? "mirrors " + (root.draftFor(chip.draft.mirror).name || "another display") : "off"

                width: Math.min(chipText.implicitWidth + Theme.scaled(20),
                    Math.max(Theme.chipHeight, (root.width - root.pad) / Math.max(1, root.aside.length)
                        - Theme.controlSpacing))
                height: Theme.chipHeight
                radius: Theme.chipRadius
                color: current ? Theme.accentAlpha(0.22) : chipMouse.containsMouse ? Theme.chipHover : "transparent"
                border.width: current ? 2 : 1
                border.color: current ? Theme.accentText : Theme.stroke
                opacity: root.enabled ? 1 : 0.6
                activeFocusOnTab: root.enabled
                Accessible.role: Accessible.RadioButton
                Accessible.name: (draft.name || modelData) + ", " + (draft.label || "") + ", " + chip.status
                Accessible.checkable: true
                Accessible.checked: chip.current
                Accessible.onPressAction: root.selected(chip.modelData)
                Keys.onPressed: event => root.handleKey(event, chip.modelData, false)

                Rectangle {
                    anchors.fill: parent
                    anchors.margins: -3
                    radius: chip.radius + 3
                    color: "transparent"
                    border.width: chip.activeFocus ? 1 : 0
                    border.color: Theme.accentText
                }

                Text {
                    id: chipText
                    anchors.centerIn: parent
                    width: Math.min(implicitWidth, parent.width - Theme.scaled(12))
                    text: (chip.draft.name || chip.modelData) + " · " + chip.status
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.secondary
                    color: chip.current ? Theme.textHi : Theme.textLow
                    elide: Text.ElideRight
                }

                MouseArea {
                    id: chipMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    enabled: root.enabled
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        chip.forceActiveFocus(Qt.MouseFocusReason);
                        root.selected(chip.modelData);
                    }
                }
            }
        }
    }
}
