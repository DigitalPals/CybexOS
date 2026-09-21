import QtQuick
import QtQuick.Controls as Controls
import "../Common"

Rectangle {
    id: root

    property string text: ""
    property string glyph: ""
    property bool compact: false
    property bool danger: false
    signal triggered()

    width: compact ? Theme.chipHeight : actionRow.implicitWidth + 16
    height: Theme.chipHeight
    radius: Theme.chipRadius
    color: "transparent"
    border.width: activeFocus ? 1 : 0
    border.color: danger ? Theme.red : Theme.accent
    activeFocusOnTab: true
    Accessible.role: Accessible.Button
    Accessible.name: root.text
    Accessible.onPressAction: {
        actionState.pulseCenter();
        root.triggered();
    }
    Controls.ToolTip.visible: mouse.containsMouse && (root.compact || root.text.indexOf("Reset") === 0)
    Controls.ToolTip.text: root.text

    Keys.onPressed: event => {
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                || event.key === Qt.Key_Space) {
            actionState.pulseCenter();
            root.triggered(); event.accepted = true;
        }
    }

    StateLayer {
        id: actionState
        anchors.fill: parent
        radius: parent.radius
        hovered: mouse.containsMouse
        pressed: mouse.pressed
        focused: root.activeFocus
        tint: root.danger ? Theme.red : Theme.textHi
        pressPoint: Qt.point(mouse.mouseX, mouse.mouseY)
    }

    Row {
        id: actionRow
        anchors.centerIn: parent
        spacing: 6

        // One icon system. Undo, close and back used to be typographic arrows
        // drawn in the menu face, which only worked while that face happened
        // to carry them: JetBrains Mono has no ↺, so every reset control in
        // the workspace fell back to whatever glyph the fontconfig chain
        // offered. Material Symbols is a set the shell installs and checks.
        Sym {
            anchors.verticalCenter: parent.verticalCenter
            name: root.glyph
            size: Theme.iconSmall
            symWeight: 450
            color: root.danger ? Theme.redText : Theme.textMid
        }
        Text {
            visible: !root.compact
            text: root.text
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.control
            font.weight: Theme.weightMedium
            color: root.danger ? Theme.redText : Theme.textMid
        }
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: {
            root.forceActiveFocus();
            root.triggered();
        }
    }
}
