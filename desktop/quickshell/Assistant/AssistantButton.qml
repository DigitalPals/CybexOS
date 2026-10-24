import QtQuick
import "../Common"

// The assistant box's one button: a glyph, a label, or both. `primary` is
// the action the card exists for (Send, Allow, Apply…); `danger` stops or
// refuses. A glyph-only button still names itself for screen readers.
Rectangle {
    id: root

    property string glyph: ""
    property string label: ""
    property string accessibleName: label
    property bool primary: false
    property bool danger: false
    property bool round: label === ""
    property real controlHeight: Theme.scaled(30)
    readonly property color ink: primary ? Theme.accentFg
        : danger ? Theme.redText : Theme.textMid

    signal triggered()

    implicitHeight: controlHeight
    implicitWidth: round ? controlHeight
        : content.implicitWidth + Theme.scaled(label !== "" && glyph !== "" ? 20 : 22)
    radius: round ? height / 2 : Theme.chipRadius
    color: primary ? Theme.accent : danger ? Theme.redBgSoft : Theme.chip
    opacity: enabled ? 1 : 0.45
    activeFocusOnTab: enabled && visible
    border.width: activeFocus ? 1 : 0
    border.color: Theme.accentText

    Accessible.role: Accessible.Button
    Accessible.name: root.accessibleName
    Accessible.onPressAction: {
        if (root.enabled)
            root.triggered();
    }

    Keys.onPressed: event => {
        if (root.enabled && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                || event.key === Qt.Key_Space)) {
            pressState.pulseCenter();
            root.triggered();
            event.accepted = true;
        }
    }

    StateLayer {
        id: pressState
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
        spacing: Theme.scaled(6)

        Sym {
            anchors.verticalCenter: parent.verticalCenter
            visible: root.glyph !== ""
            name: root.glyph
            size: Theme.iconMedium
            color: root.ink
        }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            visible: root.label !== ""
            text: root.label
            color: root.ink
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.secondary
            font.weight: root.primary ? Theme.weightSemibold : Theme.weightMedium
        }
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        enabled: root.enabled
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.triggered()
    }
}
