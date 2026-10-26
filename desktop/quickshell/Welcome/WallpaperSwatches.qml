pragma ComponentBehavior: Bound
import QtQuick
import "../Common"
import "../Common" as Common

// The colours Matugen reads from the current wallpaper, as round swatches,
// from the page tone up to the accent. Palette runs only while the colours
// follow the wallpaper; otherwise this says so. Qualified as Common.Palette:
// a bare `Palette` is QtQuick's own palette type.
Item {
    id: root
    property real size: 22
    readonly property bool shown: Settings.paletteMode === "wallpaper" && Common.Palette.ready
    implicitWidth: shown ? swatches.implicitWidth : note.implicitWidth
    implicitHeight: Math.max(Kiosk.px(size) + Kiosk.px(4), note.implicitHeight)
    Accessible.role: Accessible.StaticText
    Accessible.name: shown ? I18n.tr("Colours from your wallpaper") : note.text
    Row {
        id: swatches
        anchors.verticalCenter: parent.verticalCenter
        visible: root.shown
        spacing: Kiosk.px(root.size > 24 ? 8 : 6)
        Repeater {
            model: [Common.Palette.background, Common.Palette.surfaceContainerHigh, Common.Palette.outlineVariant,
                Common.Palette.primaryContainer, Common.Palette.primary]
            delegate: Rectangle {
                required property color modelData
                width: Kiosk.px(root.size)
                height: width
                radius: width / 2
                color: modelData
                border.width: Math.max(1, Kiosk.px(1))
                border.color: "#24ffffff"
            }
        }
    }
    KioskText {
        id: note
        anchors.verticalCenter: parent.verticalCenter
        visible: !root.shown
        text: Settings.paletteMode !== "wallpaper" ? I18n.tr("Your colours are fixed for now.")
            : String(Common.Palette.error || "") || I18n.tr("Reading its colours…")
        size: 13
        tone: "faint"
    }
}
