import QtQuick
import "../Common"

// The installer's footer: Back on the left, a note in the middle, the
// primary action on the right, under a hairline. Steps put their note (or
// their pending-changes bar) inside it.
Item {
    id: root
    property string nextText: I18n.tr("Continue")
    property bool nextEnabled: true
    default property alias note: middle.data
    signal next()
    height: Kiosk.px(88)
    Rectangle { width: parent.width; height: Math.max(1, Kiosk.px(1)); color: Kiosk.line }
    KioskButton {
        id: back
        x: Kiosk.px(64)
        anchors.verticalCenter: parent.verticalCenter
        text: I18n.tr("Back")
        onClicked: Welcome.move(-1)
    }
    Item {
        id: middle
        anchors.left: back.right
        anchors.leftMargin: Kiosk.px(16)
        anchors.right: primary.left
        anchors.rightMargin: Kiosk.px(16)
        anchors.top: parent.top
        anchors.bottom: parent.bottom
    }
    KioskButton {
        id: primary
        anchors.right: parent.right
        anchors.rightMargin: Kiosk.px(64)
        anchors.verticalCenter: parent.verticalCenter
        kind: "primary"
        text: root.nextText
        icon: "chevron_right"
        iconRight: true
        enabled: root.nextEnabled
        onClicked: root.next()
    }
}
