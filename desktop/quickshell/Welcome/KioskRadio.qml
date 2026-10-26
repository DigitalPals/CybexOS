import QtQuick

// A 24 px radio mark: an empty ring, or filled accent with a tick.
Rectangle {
    property bool checked: false
    implicitWidth: Kiosk.px(24)
    implicitHeight: implicitWidth
    radius: width / 2
    color: checked ? Kiosk.accent : "transparent"
    border.width: checked ? 0 : Math.max(1, Kiosk.px(1.5))
    border.color: Kiosk.line2
    KioskIcon {
        anchors.centerIn: parent
        visible: parent.checked
        name: "check"
        designSize: 14
        color: Kiosk.accentInk
    }
}
