import QtQuick
import QtQuick.Controls as Controls
import "../../Common"

// A 32px glyph button for the drawer's footers and inline actions. A glyph
// is not a label, so every call site names itself.
Rectangle {
    id: root

    property string glyph: ""
    property real fill: 0
    property real glyphSize: Theme.iconMedium
    property color tint: Theme.textMid
    property string accessibleName: ""
    signal clicked()
    Controls.ToolTip.visible: mouse.containsMouse || activeFocus
    Controls.ToolTip.text: accessibleName

    width: Theme.inlineActionHeight
    height: Theme.inlineActionHeight
    radius: Theme.rowRadius
    color: "transparent"
    opacity: enabled ? 1 : 0.4
    activeFocusOnTab: enabled && visible
    border.width: activeFocus ? 1 : 0
    border.color: Theme.accentText
    Accessible.role: Accessible.Button
    Accessible.name: accessibleName
    Accessible.onPressAction: if (root.enabled) root.clicked()

    Keys.onPressed: event => {
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                || event.key === Qt.Key_Space) {
            root.clicked();
            event.accepted = true;
        }
    }

    StateLayer {
        anchors.fill: parent
        radius: parent.radius
        hovered: mouse.containsMouse
        pressed: mouse.pressed
        focused: root.activeFocus
        tint: Theme.textHi
        pressPoint: Qt.point(mouse.mouseX, mouse.mouseY)
    }

    Sym {
        anchors.centerIn: parent
        name: root.glyph
        size: root.glyphSize
        fill: root.fill
        color: mouse.containsMouse ? Theme.textHi : root.tint
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: {
            root.forceActiveFocus();
            root.clicked();
        }
    }
}
