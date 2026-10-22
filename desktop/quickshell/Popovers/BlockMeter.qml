pragma ComponentBehavior: Bound
import QtQuick
import "../Common"
import "../Common/Format.js" as Format

// Shared "blocked" meter (Lumen language): a strip of fixed-width blocks
// with the filled fraction overlaid in color. One component for every
// level in the shell — usage windows, volume/brightness, CPU/RAM/temp.
Item {
    id: root

    property real value: 0 // 0..1
    property color fillColor: Theme.accent
    property color trackColor: Theme.hairline
    property int blockWidth: 4
    property int gap: 2
    property bool interactive: false
    property bool dimmed: false
    property real step: 0.05
    property string accessibleName: "Level"
    signal moved(real value)

    implicitHeight: 10
    activeFocusOnTab: root.interactive && !root.dimmed && root.visible
    Accessible.ignored: !root.interactive
    Accessible.role: Accessible.Slider
    Accessible.name: root.accessibleName
    Accessible.description: Math.round(Format.clamp01(root.value) * 100)
        + " percent"
    Accessible.onIncreaseAction: root.applyValue(root.value + root.step)
    Accessible.onDecreaseAction: root.applyValue(root.value - root.step)

    readonly property real pageStep: root.step > 0 ? root.step * 10 : 0.2

    function quantize(next) {
        const stepped = root.step > 0
            ? Math.round(next / root.step) * root.step : next;
        return Format.clamp01(stepped);
    }

    function applyValue(next) {
        const clamped = root.quantize(next);
        if (clamped !== root.value)
            root.moved(clamped);
    }

    Keys.onPressed: event => {
        if (event.key === Qt.Key_Left || event.key === Qt.Key_Down)
            root.applyValue(root.value - root.step);
        else if (event.key === Qt.Key_Right || event.key === Qt.Key_Up)
            root.applyValue(root.value + root.step);
        else if (event.key === Qt.Key_PageDown)
            root.applyValue(root.value - root.pageStep);
        else if (event.key === Qt.Key_PageUp)
            root.applyValue(root.value + root.pageStep);
        else if (event.key === Qt.Key_Home)
            root.applyValue(0);
        else if (event.key === Qt.Key_End)
            root.applyValue(1);
        else
            return;
        event.accepted = true;
    }

    // One rectangle per block, coloured by the side of the fill boundary it
    // sits on, plus a single rectangle for the block the boundary bisects.
    // The strip used to be built twice — a track row under a clipped fill row
    // — which cost 2N items for the same pixels; the Control Panel alone
    // instantiated ~380 of them on every open.
    readonly property int pitch: Math.max(1, root.blockWidth + root.gap)
    readonly property int blocks: Math.max(0, Math.ceil(root.width / root.pitch))
    readonly property int fillWidth: Math.round(
        Format.clamp01(root.value) * root.width)
    // Filled width of the bisected block; 0 when the boundary falls in a gap
    // or exactly on a block edge, in which case no partial block is drawn.
    readonly property int partialWidth: {
        const into = root.fillWidth - Math.floor(root.fillWidth / root.pitch) * root.pitch;
        return into > 0 && into < root.blockWidth ? into : 0;
    }

    Rectangle {
        anchors.fill: parent
        anchors.margins: -4
        radius: 3
        color: "transparent"
        border.width: root.activeFocus ? 1 : 0
        border.color: Theme.accentText
    }

    Repeater {
        model: root.blocks

        Rectangle {
            id: block
            required property int index

            x: block.index * root.pitch
            width: root.blockWidth
            height: root.height
            color: block.x + block.width <= root.fillWidth ? root.fillColor : root.trackColor
        }
    }

    Rectangle {
        visible: root.partialWidth > 0
        x: root.fillWidth - root.partialWidth
        width: root.partialWidth
        height: root.height
        color: root.fillColor
    }

    MouseArea {
        enabled: root.interactive && !root.dimmed
        visible: root.interactive
        anchors.fill: parent
        anchors.margins: -4
        cursorShape: Qt.PointingHandCursor
        onPressed: mouse => {
            root.forceActiveFocus();
            root.applyValue(mouse.x / root.width);
        }
        onPositionChanged: mouse => {
            if (pressed)
                root.applyValue(mouse.x / root.width);
        }
    }
}
