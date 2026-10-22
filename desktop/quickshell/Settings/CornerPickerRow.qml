pragma ComponentBehavior: Bound
import QtQuick
import "../Common"

// [label][miniature screen][corner name][undo]: a screen-corner choice drawn
// as the screen, so the answer is seen where it will happen rather than read
// out of four text pills. Each corner is a radio button; the arrow keys move
// across and down the way the corners sit.
SettingsRow {
    id: root

    // Values are "<top|bottom>-<left|right>".
    property var current: root.stored
    readonly property var corners: ["top-left", "top-right", "bottom-left", "bottom-right"]
    readonly property int screenWidth: Theme.scaled(72)
    readonly property int screenHeight: Theme.scaled(44)
    signal picked(string value)

    function labelFor(value) {
        const text = String(value || "").replace("-", " ");
        return text.charAt(0).toUpperCase() + text.slice(1);
    }

    function pick(value) {
        root.commit(value);
        root.picked(value);
    }

    wideHeight: screenHeight + Theme.scaled(8) + rowPad * 2
    narrowHeight: Theme.settingsStackOffset + screenHeight + Theme.scaled(4)

    controlLeft: root.narrow ? root.labelWidth : cornerLabel.x

    Rectangle {
        id: screen
        x: root.narrow ? root.markInset : root.contentRight - width
        y: root.narrow ? Theme.settingsStackOffset : (root.lineHeight - height) / 2
        width: root.screenWidth
        height: root.screenHeight
        radius: Theme.scaled(5)
        color: Theme.cardFill
        border.width: 1
        border.color: Theme.stroke
        opacity: root.controlOpacity

        Repeater {
            id: cornerRepeater
            model: root.corners

            delegate: Rectangle {
                id: corner

                required property string modelData
                required property int index
                readonly property bool selected: modelData === root.current
                readonly property bool onRight: modelData.endsWith("right")
                readonly property bool onBottom: modelData.startsWith("bottom")

                x: onRight ? screen.width - width - 4 : 4
                y: onBottom ? screen.height - height - 4 : 4
                width: Math.round(screen.width * 0.4)
                height: Math.round(screen.height * 0.32)
                radius: Theme.scaled(3)
                color: selected ? Theme.accent
                    : cornerMouse.containsMouse ? Theme.textLow : Theme.stroke
                border.width: activeFocus ? 2 : 0
                border.color: Theme.textHi
                activeFocusOnTab: selected || (root.corners.indexOf(root.current) === -1 && index === 0)
                Accessible.role: Accessible.RadioButton
                Accessible.name: root.labelFor(modelData)
                Accessible.checked: selected
                Accessible.onPressAction: root.pick(modelData)

                Keys.onPressed: event => {
                    let target = "";
                    const vertical = onBottom ? "bottom" : "top";
                    const horizontal = onRight ? "right" : "left";
                    if (event.key === Qt.Key_Left)
                        target = vertical + "-left";
                    else if (event.key === Qt.Key_Right)
                        target = vertical + "-right";
                    else if (event.key === Qt.Key_Up)
                        target = "top-" + horizontal;
                    else if (event.key === Qt.Key_Down)
                        target = "bottom-" + horizontal;
                    else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                            || event.key === Qt.Key_Space) {
                        root.pick(modelData);
                        event.accepted = true;
                        return;
                    } else {
                        return;
                    }
                    event.accepted = true;
                    if (target === modelData)
                        return;
                    // Focus before the pick: see PillRow.
                    cornerRepeater.itemAt(root.corners.indexOf(target)).forceActiveFocus();
                    root.pick(target);
                }

                MouseArea {
                    id: cornerMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        corner.forceActiveFocus();
                        root.pick(corner.modelData);
                    }
                }
            }
        }
    }

    // The chosen corner, named beside the miniature screen: after it when
    // the row stacks, before it when the screen sits on the right edge.
    // Each lane is computed from the screen alone, so x and width never
    // read each other.
    readonly property real cornerLabelWidth: root.narrow
        ? Math.max(0, root.contentRight - (screen.x + screen.width + Theme.controlSpacing + 4))
        : Math.min(Math.ceil(cornerMetrics.advanceWidth(root.labelFor(root.current))) + 1,
            Math.max(0, screen.x - Theme.controlSpacing - root.labelWidth))

    FontMetrics {
        id: cornerMetrics
        font.family: Theme.fontMenu
        font.pixelSize: Theme.typography.control
        font.weight: Theme.weightMedium
    }

    Text {
        id: cornerLabel
        x: root.narrow ? screen.x + screen.width + Theme.controlSpacing + 4
            : screen.x - Theme.controlSpacing - root.cornerLabelWidth
        y: screen.y + (screen.height - height) / 2
        width: root.cornerLabelWidth
        horizontalAlignment: root.narrow ? Text.AlignLeft : Text.AlignRight
        opacity: root.controlOpacity
        text: root.labelFor(root.current)
        font.family: Theme.fontMenu
        font.pixelSize: Theme.typography.control
        font.weight: Theme.weightMedium
        color: Theme.textMid
        elide: Text.ElideRight
        Accessible.ignored: true
    }
}
