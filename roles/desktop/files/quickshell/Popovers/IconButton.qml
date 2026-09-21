import QtQuick
import "../Common"

// Compact T3 header icon button. Material Symbols avoid the baseline and
// weight inconsistencies of typographic arrows while retaining a text-only
// accessible name at every call site.
Rectangle {
    id: iconButton
    property string symbol: ""
    // 0 outline, 1 solid. Sym animates the axis, so a toggle here lights the
    // same glyph rather than cutting to a second one — see Common/Sym.qml.
    property real symbolFill: 0
    property color tint: T3Theme.textMuted
    property int controlSize: T3Theme.iconButtonSize
    // A glyph is not a label. Every call site names itself, because a
    // focus ring on an unnamed arrow is worse than no focus ring.
    property string accessibleName: ""
    // What the glyph stands for right now, when the name alone ("Run
    // settings") does not say what is currently selected.
    property string accessibleDescription: ""
    signal triggered()

    Accessible.role: Accessible.Button
    Accessible.name: iconButton.accessibleName
    Accessible.description: iconButton.accessibleDescription
    Accessible.onPressAction: {
        if (iconButton.enabled) {
            iconState.pulseCenter();
            iconButton.triggered();
        }
    }

    width: controlSize
    height: controlSize
    radius: T3Theme.controlRadius
    color: iconMouse.containsMouse || activeFocus ? T3Theme.hoverStrong : "transparent"
    opacity: enabled ? 1 : 0.4
    activeFocusOnTab: enabled && visible
    border.width: activeFocus ? 1 : 0
    border.color: T3Theme.focus

    Keys.onPressed: event => {
        if (!iconButton.enabled)
            return;
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                || event.key === Qt.Key_Space) {
            iconState.pulseCenter();
            iconButton.triggered();
            event.accepted = true;
        }
    }

    StateLayer {
        id: iconState
        anchors.fill: parent
        radius: parent.radius
        hovered: iconMouse.containsMouse && iconButton.enabled
        pressed: iconMouse.pressed
        focused: iconButton.activeFocus
        tint: iconButton.tint
        pressPoint: Qt.point(iconMouse.mouseX, iconMouse.mouseY)
    }

    Sym {
        anchors.centerIn: parent
        name: iconButton.symbol
        fill: iconButton.symbolFill
        size: Theme.iconMedium
        symWeight: 450
        color: iconButton.tint
    }

    MouseArea {
        id: iconMouse
        anchors.fill: parent
        enabled: iconButton.enabled
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: iconButton.triggered()
    }
}
