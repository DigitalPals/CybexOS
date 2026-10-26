import QtQuick

// The installer's 48×28 switch.
Rectangle {
    id: root
    property bool checked: false
    property string label: ""
    signal toggled()
    implicitWidth: Kiosk.px(48)
    implicitHeight: Kiosk.px(28)
    radius: height / 2
    color: checked ? Kiosk.accent : Kiosk.line2
    opacity: enabled ? 1 : 0.4
    activeFocusOnTab: enabled && visible
    Accessible.role: Accessible.CheckBox
    Accessible.name: label
    Accessible.checkable: true
    Accessible.checked: checked
    Accessible.onToggleAction: if (root.enabled) root.toggled()
    Accessible.onPressAction: if (root.enabled) root.toggled()
    Keys.onPressed: event => {
        if ([Qt.Key_Return, Qt.Key_Enter, Qt.Key_Space].includes(event.key)) {
            if (!event.isAutoRepeat && root.enabled)
                root.toggled();
            event.accepted = true;
        }
    }
    KioskFocusRing { visible: root.activeFocus; gap: 3; baseRadius: root.radius }
    Rectangle {
        width: Kiosk.px(22)
        height: width
        radius: width / 2
        y: Kiosk.px(3)
        x: root.checked ? root.width - width - Kiosk.px(3) : Kiosk.px(3)
        color: root.checked ? Kiosk.accentInk : Kiosk.fog
    }
    MouseArea {
        anchors.fill: parent
        enabled: root.enabled
        cursorShape: Qt.PointingHandCursor
        onClicked: root.toggled()
    }
}
