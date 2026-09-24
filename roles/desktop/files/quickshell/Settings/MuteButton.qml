import QtQuick
import "../Common"

// A square mute toggle for one audio channel or application. Muted reads
// twice, as the crossed-out glyph and a red wash, so it is not told apart by
// colour alone.
Rectangle {
    id: root

    property bool muted: false
    property string glyph: "volume_up"
    property string mutedGlyph: "volume_off"
    // What the button mutes, for its accessible name: "output", "Firefox".
    property string channelName: "audio"
    signal toggled()

    width: Theme.settingsControlHeight
    height: Theme.settingsControlHeight
    radius: Theme.chipRadius
    color: muted ? Theme.redBgSoft : "transparent"
    border.width: activeFocus ? 1 : 0
    border.color: Theme.accentText
    opacity: enabled ? 1 : 0.45
    activeFocusOnTab: enabled && visible
    Accessible.role: Accessible.CheckBox
    Accessible.name: "Mute " + root.channelName
    Accessible.checkable: true
    Accessible.checked: root.muted
    Accessible.onToggleAction: root.trigger()
    Accessible.onPressAction: root.trigger()

    function trigger() {
        if (!root.enabled)
            return;
        muteState.pulseCenter();
        root.toggled();
    }

    Keys.onPressed: event => {
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                || event.key === Qt.Key_Space) {
            root.trigger();
            event.accepted = true;
        }
    }

    StateLayer {
        id: muteState
        anchors.fill: parent
        radius: parent.radius
        hovered: mouse.containsMouse
        pressed: mouse.pressed
        focused: root.activeFocus
        tint: root.muted ? Theme.redText : Theme.textHi
        pressPoint: Qt.point(mouse.mouseX, mouse.mouseY)
    }

    Sym {
        anchors.centerIn: parent
        name: root.muted ? root.mutedGlyph : root.glyph
        size: Theme.iconMedium
        color: root.muted ? Theme.redText : Theme.textMid
    }

    SettingsTooltip {
        visible: mouse.containsMouse
        text: root.muted ? "Unmute" : "Mute"
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: {
            root.forceActiveFocus(Qt.MouseFocusReason);
            root.toggled();
        }
    }
}
