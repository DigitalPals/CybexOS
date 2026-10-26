import QtQuick
import "../Common"

// installer/kiosk/ui/sheets.slint: a scrim over the guide and a 460 px panel
// from the right with a title, a line of help and a round close button.
// Escape and the scrim close it. The guide disables its page while a sheet
// is open, so Tab stays in here.
FocusScope {
    id: root
    property string title: ""
    property string subtitle: ""
    default property alias content: body.data
    signal closed()
    anchors.fill: parent
    focus: true
    Keys.onEscapePressed: event => { root.closed(); event.accepted = true; }
    Rectangle {
        anchors.fill: parent
        color: Kiosk.scrim
        MouseArea { anchors.fill: parent; onClicked: root.closed() }
    }
    Rectangle {
        id: panel
        anchors.right: parent.right
        anchors.rightMargin: Kiosk.px(24)
        y: Kiosk.px(72)
        width: Kiosk.px(460)
        height: parent.height - y - Kiosk.px(24)
        radius: Kiosk.px(22)
        color: Kiosk.card
        border.width: Math.max(1, Kiosk.px(1))
        border.color: Kiosk.line2
        Accessible.role: Accessible.Dialog
        Accessible.name: root.title
        // Swallow clicks so they do not reach the scrim.
        MouseArea { anchors.fill: parent }
        Column {
            id: head
            x: Kiosk.px(26)
            y: Kiosk.px(24)
            width: parent.width - Kiosk.px(26) * 2
            spacing: Kiosk.px(4)
            KioskText {
                width: parent.width - Kiosk.px(44)
                text: root.title
                size: 24
                font.weight: Font.Bold
                wrapMode: Text.WordWrap
            }
            KioskText {
                width: parent.width - Kiosk.px(44)
                visible: text !== ""
                text: root.subtitle
                size: 14.5
                tone: "fog"
                wrapMode: Text.WordWrap
            }
        }
        Rectangle {
            id: closeButton
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Kiosk.px(18)
            width: Kiosk.px(38)
            height: width
            radius: width / 2
            color: Kiosk.card2
            activeFocusOnTab: true
            Accessible.role: Accessible.Button
            Accessible.name: I18n.tr("Close")
            Accessible.onPressAction: root.closed()
            Keys.onPressed: event => {
                if ([Qt.Key_Return, Qt.Key_Enter, Qt.Key_Space].includes(event.key)) {
                    root.closed();
                    event.accepted = true;
                }
            }
            KioskFocusRing { visible: closeButton.activeFocus; gap: 3; baseRadius: closeButton.radius }
            KioskIcon { anchors.centerIn: parent; name: "close" }
            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.closed() }
        }
        Item {
            id: body
            anchors.left: head.left
            anchors.right: head.right
            anchors.top: head.bottom
            anchors.topMargin: Kiosk.px(16)
            anchors.bottom: parent.bottom
            anchors.bottomMargin: Kiosk.px(24)
        }
    }
}
