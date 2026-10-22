import QtQuick
import "../Common"

// A settings button. Quiet by default: copy and an icon on a hover layer.
// `primary` fills it with the accent for the one action a bar or dialog
// leads with (Apply, Keep changes, Add account); `danger` inks it red.
Rectangle {
    id: root

    property string text: ""
    property string glyph: ""
    property bool compact: false
    property bool danger: false
    property bool primary: false
    // An icon-only action names itself in a tip; a labeled one needs none.
    property string tooltip: compact ? text : ""
    signal triggered()

    readonly property color ink: primary ? Theme.textOnAccent
        : danger ? Theme.redText : Theme.textMid

    width: compact ? Theme.chipHeight : actionRow.implicitWidth + (primary ? 24 : 16)
    height: Theme.chipHeight
    radius: Theme.chipRadius
    color: primary ? Theme.accent : "transparent"
    border.width: activeFocus ? (primary ? 2 : 1) : 0
    border.color: primary ? Theme.textHi : danger ? Theme.red : Theme.accentText
    opacity: enabled ? 1 : 0.4
    activeFocusOnTab: enabled && visible
    Accessible.role: Accessible.Button
    Accessible.name: root.text
    Accessible.onPressAction: {
        if (!root.enabled)
            return;
        actionState.pulseCenter();
        root.triggered();
    }

    SettingsTooltip {
        visible: root.tooltip !== "" && mouse.containsMouse
        text: root.tooltip
    }

    Keys.onPressed: event => {
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                || event.key === Qt.Key_Space) {
            if (!root.enabled)
                return;
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
        tint: root.primary ? Theme.textOnAccent : root.danger ? Theme.red : Theme.textHi
        pressPoint: Qt.point(mouse.mouseX, mouse.mouseY)
    }

    Row {
        id: actionRow
        anchors.centerIn: parent
        spacing: Theme.iconTextSpacing

        // One icon system. Undo, close and back used to be typographic arrows
        // drawn in the menu face, which only worked while that face happened
        // to carry them: JetBrains Mono has no ↺, so every reset control in
        // the workspace fell back to whatever glyph the fontconfig chain
        // offered. Tabler icons is a set the shell installs and checks.
        Sym {
            anchors.verticalCenter: parent.verticalCenter
            visible: root.glyph !== ""
            name: root.glyph
            size: Theme.iconSmall
            symWeight: 450
            color: root.ink
        }
        Text {
            visible: !root.compact
            text: root.text
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.control
            font.weight: root.primary ? Theme.weightSemibold : Theme.weightMedium
            color: root.ink
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
