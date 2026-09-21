import QtQuick
import "../Common"
import "../Common/Format.js" as Format

// The shell's filled slider: a recessed well whose full accent fill is the
// value readout, at the bar's chip corner rather than a pill —
// the pill is reserved for the one mark the menubar fills. The glyph sits
// inside the track on the left — as a
// plain mark, or as a button when `glyphIsButton` (the volume mute) — and
// the percentage label on the right. Drag anywhere on the track to set the
// value; the wheel nudges it.
Rectangle {
    id: root

    // 0..1.
    property real value: 0
    property string glyph
    property bool glyphIsButton: false
    property string glyphAccessibleName: "Toggle"
    property string label: Math.round(Format.clamp01(value) * 100) + "%"
    property bool ready: true
    property string accessibleName: "Slider"
    property real step: 0.05
    signal moved(real value)
    signal glyphClicked

    // The glyph occupies the first control-height-wide lane. A non-zero fill
    // narrower than that turns into a detached vertical lozenge and leaves
    // the glyph floating beside it. Keep the leading fill circular until the
    // actual value grows past that lane; zero still has no fill at all.
    readonly property real fillExtent: {
        const exact = Format.clamp01(value) * width;
        return exact <= 0 ? 0 : Math.min(width, Math.max(height, exact));
    }

    height: Theme.listRowHeight
    radius: Theme.chipRadius
    color: Theme.chip
    opacity: ready ? 1 : 0.4
    activeFocusOnTab: ready
    border.width: activeFocus ? 2 : 0
    border.color: Theme.accent

    Accessible.role: Accessible.Slider
    Accessible.name: accessibleName
    Accessible.description: root.label
    Accessible.onIncreaseAction: applyValue(value + step)
    Accessible.onDecreaseAction: applyValue(value - step)

    function applyValue(next) {
        const clamped = Format.clamp01(next);
        if (clamped !== root.value)
            root.moved(clamped);
    }

    Keys.onPressed: event => {
        if (event.key === Qt.Key_Left || event.key === Qt.Key_Down)
            applyValue(value - step);
        else if (event.key === Qt.Key_Right || event.key === Qt.Key_Up)
            applyValue(value + step);
        else if (event.key === Qt.Key_PageDown)
            applyValue(value - step * 4);
        else if (event.key === Qt.Key_PageUp)
            applyValue(value + step * 4);
        else if (event.key === Qt.Key_Home)
            applyValue(0);
        else if (event.key === Qt.Key_End)
            applyValue(1);
        else
            return;
        event.accepted = true;
    }

    Behavior on color {
        ColorAnimation { duration: Theme.surfaceDuration }
    }

    Rectangle {
        width: root.fillExtent
        height: parent.height
        radius: parent.radius
        color: Theme.accent

        Behavior on width {
            NumberAnimation {
                duration: Theme.reducedMotion ? 0 : 140
                easing.type: Easing.OutCubic
            }
        }
    }

    MouseArea {
        anchors.fill: parent
        enabled: root.ready
        cursorShape: Qt.PointingHandCursor
        onPressed: mouse => {
            root.forceActiveFocus();
            root.moved(Format.clamp01(mouse.x / root.width));
        }
        onPositionChanged: mouse => {
            if (pressed)
                root.moved(Format.clamp01(mouse.x / root.width));
        }
        onWheel: wheel => root.moved(Format.clamp01(root.value + (wheel.angleDelta.y / 120) * 0.05))
    }

    Sym {
        visible: !root.glyphIsButton
        x: 15
        anchors.verticalCenter: parent.verticalCenter
        name: root.glyph
        size: 18
        fill: 1
        color: Theme.textHi
    }

    Rectangle {
        visible: root.glyphIsButton
        x: 8
        anchors.verticalCenter: parent.verticalCenter
        width: 30
        height: 30
        radius: 15
        color: glyphMouse.containsMouse ? Theme.chipHover : "transparent"
        activeFocusOnTab: visible && root.ready
        border.width: activeFocus ? 2 : 0
        border.color: Theme.accent
        Accessible.role: Accessible.Button
        Accessible.name: root.glyphAccessibleName
        Accessible.onPressAction: root.glyphClicked()

        Keys.onPressed: event => {
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                    || event.key === Qt.Key_Space) {
                root.glyphClicked();
                event.accepted = true;
            }
        }

        Sym {
            anchors.centerIn: parent
            name: root.glyph
            size: 18
            fill: 1
            color: Theme.textHi
        }

        MouseArea {
            id: glyphMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                parent.forceActiveFocus();
                root.glyphClicked();
            }
        }
    }

    Text {
        anchors.right: parent.right
        anchors.rightMargin: 15
        anchors.verticalCenter: parent.verticalCenter
        text: root.label
        font.family: Theme.fontMenu
        font.pixelSize: Theme.typography.secondary
        font.weight: Theme.weightMedium
        color: Theme.textHi
    }
}
