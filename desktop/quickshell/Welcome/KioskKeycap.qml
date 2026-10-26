import QtQuick

// The installer's keycap: mono on the deep well with a heavier lower edge.
// Small caps label shortcut rows; locked ones are drawn hollow and faint.
Rectangle {
    id: root
    property string text: ""
    property bool small: false
    property bool locked: false
    implicitWidth: Math.max(implicitHeight, label.implicitWidth + Kiosk.px(small ? 16 : 22))
    implicitHeight: Kiosk.px(small ? 24 : 34)
    radius: Kiosk.px(small ? 6 : 8)
    color: Kiosk.line2
    Rectangle {
        anchors.fill: parent
        anchors.bottomMargin: Kiosk.px(root.small ? 2 : 3)
        anchors.margins: Math.max(1, Kiosk.px(1))
        anchors.topMargin: Math.max(1, Kiosk.px(1))
        radius: root.radius - Math.max(1, Kiosk.px(1))
        color: root.locked ? Kiosk.card : Kiosk.bgDeep
    }
    KioskText {
        id: label
        anchors.centerIn: parent
        anchors.verticalCenterOffset: -Kiosk.px(root.small ? 1 : 1.5)
        text: root.text
        mono: true
        size: root.small ? 12 : 15
        font.weight: Font.DemiBold
        tone: root.locked ? "fog" : "ink"
    }
}
