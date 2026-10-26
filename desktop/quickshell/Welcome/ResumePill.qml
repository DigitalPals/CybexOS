import QtQuick
import "../Common"

// What the guide leaves on screen while it steps aside: the mark, where the
// person was, Resume and a close button, in the installer's card style.
Rectangle {
    id: root
    readonly property string where: ({hello: I18n.tr("Hello"),
        wallpaper: I18n.format("%1, step %2 of %3", [I18n.tr("Wallpaper"), 1, 3]),
        style: I18n.format("%1, step %2 of %3", [I18n.tr("Style"), 2, 3]),
        shortcuts: I18n.format("%1, step %2 of %3", [I18n.tr("Shortcuts"), 3, 3]),
        finish: I18n.tr("Ready")})[Welcome.step] || ""
    width: row.implicitWidth + Kiosk.px(30)
    height: Kiosk.px(60)
    radius: height / 2
    color: Kiosk.card
    border.width: Math.max(1, Kiosk.px(1))
    border.color: Kiosk.line2
    Accessible.role: Accessible.Grouping
    Accessible.name: I18n.tr("Welcome guide")
    Row {
        id: row
        anchors.verticalCenter: parent.verticalCenter
        x: Kiosk.px(20)
        spacing: Kiosk.px(14)
        Image {
            anchors.verticalCenter: parent.verticalCenter
            height: Kiosk.px(20)
            width: height
            source: "../assets/cybexos.svg"
            sourceSize.height: Math.ceil(height * 2)
            fillMode: Image.PreserveAspectFit
        }
        Row {
            anchors.verticalCenter: parent.verticalCenter
            spacing: Kiosk.px(6)
            KioskText { text: I18n.tr("Welcome guide"); size: 15; font.weight: Font.Bold }
            KioskText { visible: root.where !== ""; text: "· " + root.where; size: 15; tone: "fog" } // i18n: untranslated (separator)
        }
        KioskButton {
            anchors.verticalCenter: parent.verticalCenter
            small: true
            kind: "primary"
            implicitHeight: Kiosk.px(40)
            text: I18n.tr("Resume")
            onClicked: Welcome.resume()
        }
        KioskChip {
            anchors.verticalCenter: parent.verticalCenter
            large: false
            implicitHeight: Kiosk.px(40)
            implicitWidth: Kiosk.px(40)
            icon: "close"
            Accessible.name: I18n.tr("Close welcome guide")
            onClicked: Welcome.dismiss()
        }
    }
}
