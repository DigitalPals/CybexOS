import QtQuick
import "../../Common"

// One quick-toggle tile in the Overview grid: glyph over label, lit while
// on. A lit tile is a switch track, so it earns the accent-tinted fill and
// ring the design gives it (typography.test.cjs lists this file for that);
// the resting state stays a quiet chip.
Rectangle {
    id: root

    property string glyph: ""
    property string label: ""
    property bool on: false
    signal toggled()

    height: Math.max(Theme.scaled(60), tileContent.implicitHeight + Theme.controlSpacing * 2)
    radius: 10
    color: on ? Theme.accentAlpha(0.22) : Theme.chip
    activeFocusOnTab: true
    border.width: on || activeFocus ? 1 : 0
    border.color: activeFocus ? Theme.accentText : Theme.accentAlpha(0.52)
    Accessible.role: Accessible.CheckBox
    Accessible.checked: on
    Accessible.name: label
    Accessible.onToggleAction: root.toggled()

    Behavior on color {
        ColorAnimation { duration: Theme.chipFadeDuration }
    }

    Keys.onPressed: event => {
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                || event.key === Qt.Key_Space) {
            root.toggled();
            event.accepted = true;
        }
    }

    Column {
        id: tileContent
        anchors.centerIn: parent
        width: Math.max(0, parent.width - Theme.controlSpacing * 2)
        spacing: Theme.iconTextSpacing

        Sym {
            anchors.horizontalCenter: parent.horizontalCenter
            name: root.glyph
            size: Theme.iconLarge
            fill: root.on ? 1 : 0
            color: root.on ? Theme.accentText : Theme.textMid
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            text: root.label
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.control
            font.weight: Theme.weightSemibold
            color: root.on ? Theme.accentText : Theme.textMid
        }
    }

    StateLayer {
        anchors.fill: parent
        radius: parent.radius
        hovered: tileMouse.containsMouse
        pressed: tileMouse.pressed
        tint: Theme.textHi
        pressPoint: Qt.point(tileMouse.mouseX, tileMouse.mouseY)
    }

    MouseArea {
        id: tileMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: {
            root.forceActiveFocus();
            root.toggled();
        }
    }
}
