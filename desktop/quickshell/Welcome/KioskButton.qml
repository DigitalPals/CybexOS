import QtQuick

// installer/kiosk/ui/widgets.slint, Btn: a 52 px button, or 38 px small.
// Return, Enter and Space activate it; a held key does not repeat it.
Rectangle {
    id: root
    property string text: ""
    property string icon: ""
    property bool iconRight: false
    // ghost, primary or danger.
    property string kind: "ghost"
    property bool small: false
    signal clicked()
    readonly property color ink: kind === "ghost" ? Kiosk.ink : Kiosk.accentInk
    readonly property real pad: Kiosk.px(small ? 14 : 26)
    implicitHeight: Kiosk.px(small ? 38 : 52)
    implicitWidth: content.implicitWidth + pad * 2
    radius: Kiosk.px(small ? 10 : 12)
    color: kind === "primary" ? Kiosk.accent : kind === "danger" ? Kiosk.red : "transparent"
    border.width: Math.max(1, Kiosk.px(1))
    border.color: kind === "primary" ? Kiosk.accent : kind === "danger" ? Kiosk.red
        : (mouse.containsMouse || activeFocus) && enabled ? Kiosk.fog : Kiosk.line2
    opacity: enabled ? 1 : 0.35
    activeFocusOnTab: enabled && visible
    Accessible.role: Accessible.Button
    Accessible.name: text
    Accessible.onPressAction: if (root.enabled) root.clicked()
    Keys.onPressed: event => {
        if ([Qt.Key_Return, Qt.Key_Enter, Qt.Key_Space].includes(event.key)) {
            if (!event.isAutoRepeat && root.enabled)
                root.clicked();
            event.accepted = true;
        }
    }
    KioskFocusRing { visible: root.activeFocus; baseRadius: root.radius }
    Row {
        id: content
        anchors.centerIn: parent
        spacing: Kiosk.px(9)
        layoutDirection: root.iconRight ? Qt.RightToLeft : Qt.LeftToRight
        KioskIcon {
            anchors.verticalCenter: parent.verticalCenter
            visible: root.icon !== ""
            name: root.icon
            color: root.ink
        }
        KioskText {
            anchors.verticalCenter: parent.verticalCenter
            visible: root.text !== ""
            text: root.text
            size: root.small ? 14 : 17
            font.weight: root.small ? Font.Medium : Font.Bold
            color: root.ink
        }
    }
    MouseArea {
        id: mouse
        anchors.fill: parent
        enabled: root.enabled
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.clicked()
    }
}
