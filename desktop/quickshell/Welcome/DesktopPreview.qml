pragma ComponentBehavior: Bound
import QtQuick
import "../Common"

// A miniature of the person's real desktop: the current wallpaper and a bar,
// and with `detailed`, a Settings-like window and a notification drawn with
// the shell's live theme (mode, accent, glass and text size). Only this
// preview follows the theme; the guide around it keeps the installer palette.
Rectangle {
    id: root
    property bool detailed: false
    // Shell sizes are shown at this fraction, so the text stays readable.
    readonly property real ratio: 0.72
    function shellPx(value) { return Kiosk.px(value * ratio); }
    radius: Kiosk.px(12)
    color: Kiosk.bgDeep
    border.width: Math.max(1, Kiosk.px(1))
    border.color: Kiosk.line2
    clip: true
    Accessible.role: Accessible.Graphic
    Accessible.name: I18n.tr("Preview of your desktop")
    Image {
        anchors.fill: parent
        anchors.margins: parent.border.width
        source: Wallpaper.current
        asynchronous: true
        fillMode: Image.PreserveAspectCrop
        sourceSize.width: 960
    }
    Rectangle {
        id: bar
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: parent.border.width
        height: Math.max(Kiosk.px(18), root.shellPx(Theme.typography.secondary + 14))
        color: Theme.barBg
        Row {
            anchors.left: parent.left
            anchors.leftMargin: Kiosk.px(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Kiosk.px(5)
            Rectangle {
                width: Kiosk.px(18)
                height: Kiosk.px(12)
                radius: Kiosk.px(4)
                color: Theme.barAccent
                Text {
                    anchors.centerIn: parent
                    text: "1" // i18n: untranslated (workspace number)
                    color: Theme.barAccentFg
                    font.family: Theme.fontNumeric
                    font.pixelSize: Math.max(6, Math.round(Kiosk.px(8)))
                    font.weight: Font.Bold
                }
            }
            Repeater {
                model: 3
                delegate: Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: Kiosk.px(4)
                    height: width
                    radius: width / 2
                    color: Theme.textFaint
                }
            }
        }
        Text {
            anchors.centerIn: parent
            text: Qt.formatTime(new Date(), "HH:mm")
            color: Theme.textHi
            font.family: Theme.fontNumeric
            font.pixelSize: Math.max(6, Math.round(root.shellPx(Theme.typography.secondary)))
            font.weight: Font.Bold
        }
    }
    Rectangle {
        id: window
        visible: root.detailed
        x: parent.width * 0.06
        y: bar.height + parent.height * 0.08
        width: parent.width * 0.6
        height: parent.height - y - parent.height * 0.08
        radius: Math.max(Kiosk.px(6), root.shellPx(Theme.panelRadius))
        color: Theme.panelSurface
        border.width: Math.max(1, Kiosk.px(1))
        border.color: Theme.stroke
        clip: true
        Column {
            id: side
            x: Kiosk.px(8)
            y: Kiosk.px(10)
            width: parent.width * 0.32 - Kiosk.px(8)
            spacing: Kiosk.px(4)
            Repeater {
                model: [I18n.tr("Network"), I18n.tr("Appearance"), I18n.tr("Wallpaper"), I18n.tr("Keyboard"), I18n.tr("Sound")]
                delegate: Rectangle {
                    id: entry
                    required property string modelData
                    required property int index
                    width: side.width
                    height: label.implicitHeight + Kiosk.px(6)
                    radius: Kiosk.px(4)
                    color: index === 1 ? Theme.chipHover : "transparent"
                    Text {
                        id: label
                        x: Kiosk.px(6)
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - Kiosk.px(8)
                        text: entry.modelData
                        elide: Text.ElideRight
                        color: entry.index === 1 ? Theme.accentText : Theme.textMid
                        font.family: Theme.fontMenu
                        font.pixelSize: Math.max(6, Math.round(root.shellPx(Theme.typography.secondary)))
                    }
                }
            }
        }
        Rectangle {
            x: side.width + Kiosk.px(14)
            width: Math.max(1, Kiosk.px(1))
            height: parent.height
            color: Theme.stroke
        }
        Column {
            x: side.width + Kiosk.px(26)
            y: Kiosk.px(12)
            width: parent.width - x - Kiosk.px(12)
            spacing: Kiosk.px(8)
            Text {
                width: parent.width
                text: I18n.tr("Appearance")
                elide: Text.ElideRight
                color: Theme.textHi
                font.family: Theme.fontMenu
                font.pixelSize: Math.max(7, Math.round(root.shellPx(Theme.typography.title)))
                font.weight: Font.Bold
            }
            Text {
                width: parent.width
                text: I18n.tr("Colours, text and effects for the whole desktop.")
                wrapMode: Text.WordWrap
                maximumLineCount: 2
                elide: Text.ElideRight
                color: Theme.textMid
                font.family: Theme.fontMenu
                font.pixelSize: Math.max(6, Math.round(root.shellPx(Theme.typography.secondary)))
            }
            Item {
                width: parent.width
                height: Math.max(darkLabel.implicitHeight, Kiosk.px(14))
                Text {
                    id: darkLabel
                    anchors.verticalCenter: parent.verticalCenter
                    text: I18n.tr("Dark mode")
                    color: Theme.textHi
                    font.family: Theme.fontMenu
                    font.pixelSize: Math.max(6, Math.round(root.shellPx(Theme.typography.primary)))
                }
                Rectangle {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    width: Kiosk.px(24)
                    height: Kiosk.px(14)
                    radius: height / 2
                    color: Theme.dark ? Theme.accent : Theme.stroke
                    Rectangle {
                        width: Kiosk.px(10)
                        height: width
                        radius: width / 2
                        y: Kiosk.px(2)
                        x: Theme.dark ? parent.width - width - Kiosk.px(2) : Kiosk.px(2)
                        color: Theme.dark ? Theme.accentFg : Theme.textHi
                    }
                }
            }
            Rectangle {
                width: parent.width
                height: Kiosk.px(4)
                radius: height / 2
                color: Theme.stroke
                Rectangle { width: parent.width * 0.62; height: parent.height; radius: parent.radius; color: Theme.accent }
            }
            Rectangle {
                width: applyLabel.implicitWidth + Kiosk.px(18)
                height: applyLabel.implicitHeight + Kiosk.px(8)
                radius: Math.max(Kiosk.px(4), root.shellPx(Theme.chipRadius))
                color: Theme.accent
                Text {
                    id: applyLabel
                    anchors.centerIn: parent
                    text: I18n.tr("Apply")
                    color: Theme.accentFg
                    font.family: Theme.fontMenu
                    font.pixelSize: Math.max(6, Math.round(root.shellPx(Theme.typography.secondary)))
                    font.weight: Font.Bold
                }
            }
        }
    }
    Rectangle {
        visible: root.detailed
        anchors.right: parent.right
        anchors.rightMargin: parent.width * 0.04
        y: bar.height + Kiosk.px(10)
        width: parent.width * 0.32
        height: toast.implicitHeight + Kiosk.px(16)
        radius: Math.max(Kiosk.px(6), root.shellPx(Theme.panelRadius))
        color: Theme.panelSurface
        border.width: Math.max(1, Kiosk.px(1))
        border.color: Theme.stroke
        Row {
            id: toast
            x: Kiosk.px(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Kiosk.px(8)
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: Kiosk.px(18)
                height: width
                radius: width / 2
                color: Theme.accent
            }
            Column {
                width: parent.parent.width - Kiosk.px(46)
                Text {
                    width: parent.width
                    text: I18n.tr("Wallpaper set")
                    elide: Text.ElideRight
                    color: Theme.textHi
                    font.family: Theme.fontMenu
                    font.pixelSize: Math.max(6, Math.round(root.shellPx(Theme.typography.secondary)))
                    font.weight: Font.DemiBold
                }
                Text {
                    width: parent.width
                    text: Welcome.wallpaperName
                    elide: Text.ElideRight
                    color: Theme.textMid
                    font.family: Theme.fontMenu
                    font.pixelSize: Math.max(6, Math.round(root.shellPx(Theme.typography.metadata)))
                }
            }
        }
    }
}
