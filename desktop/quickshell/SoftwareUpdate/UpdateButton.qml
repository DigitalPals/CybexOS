import QtQuick
import "../Common"

// The app's buttons: one accent-filled primary action per page, quiet
// secondary ones. Taller than a settings action, as a dialog's are.
Rectangle {
    id: root

    property string text: ""
    property string glyph: ""
    property bool primary: false
    signal triggered()

    readonly property color ink: primary ? Theme.textOnAccent : Theme.textHi

    implicitWidth: content.implicitWidth + Theme.scaled(32)
    implicitHeight: Theme.scaled(38)
    radius: Theme.chipRadius + 3
    color: primary ? Theme.accent : Theme.hoverFill
    border.width: activeFocus ? 2 : 0
    border.color: primary ? Theme.textHi : Theme.accentText
    opacity: enabled ? 1 : 0.45
    activeFocusOnTab: enabled && visible
    Accessible.role: Accessible.Button
    Accessible.name: root.text
    Accessible.onPressAction: {
        if (root.enabled)
            root.triggered();
    }

    Keys.onPressed: event => {
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
            if (root.enabled)
                root.triggered();
            event.accepted = true;
        }
    }

    StateLayer {
        anchors.fill: parent
        radius: parent.radius
        hovered: mouse.containsMouse && root.enabled
        pressed: mouse.pressed
        focused: root.activeFocus
        tint: root.ink
        pressPoint: Qt.point(mouse.mouseX, mouse.mouseY)
    }

    Row {
        id: content
        anchors.centerIn: parent
        spacing: Theme.scaled(7)
        Sym {
            visible: root.glyph !== ""
            anchors.verticalCenter: parent.verticalCenter
            name: root.glyph
            size: Theme.iconMedium
            color: root.ink
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.text
            color: root.ink
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.control
            font.weight: Theme.weightSemibold
        }
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: root.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: {
            if (root.enabled)
                root.triggered();
        }
    }
}
