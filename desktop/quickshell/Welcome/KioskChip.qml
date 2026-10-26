import QtQuick

// installer/kiosk/ui/widgets.slint, Chip: the top bar's 36 px pills. Without
// text it is a round icon button.
Rectangle {
    id: root
    property string text: ""
    property string icon: ""
    property bool warn: false
    property bool large: false
    property bool done: false
    signal clicked()
    readonly property real side: Kiosk.px(large ? 44 : 36)
    implicitHeight: side
    implicitWidth: text === "" ? side : content.implicitWidth + Kiosk.px(large ? 36 : 28)
    radius: height / 2
    color: Kiosk.card
    border.width: Math.max(1, Kiosk.px(1))
    border.color: warn ? Kiosk.amberLine : mouse.containsMouse ? Kiosk.line2 : Kiosk.line
    opacity: enabled ? 1 : 0.55
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
    KioskFocusRing { visible: root.activeFocus; gap: 3; baseRadius: root.radius }
    Row {
        id: content
        anchors.centerIn: parent
        spacing: Kiosk.px(8)
        KioskIcon {
            anchors.verticalCenter: parent.verticalCenter
            visible: root.icon !== ""
            name: root.icon
            designSize: root.large ? 18 : 16
            color: root.warn ? Kiosk.amber : mouse.containsMouse && !root.large ? Kiosk.ink : Kiosk.fog
        }
        KioskText {
            anchors.verticalCenter: parent.verticalCenter
            visible: root.text !== ""
            text: root.text
            size: root.large ? 15 : 14
            tone: root.warn ? "amber" : root.large || mouse.containsMouse ? "ink" : "fog"
        }
        KioskIcon {
            anchors.verticalCenter: parent.verticalCenter
            visible: root.done
            name: "check"
            designSize: 18
            color: Kiosk.accent
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
