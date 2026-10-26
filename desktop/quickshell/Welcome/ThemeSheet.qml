pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import "../Common"
import "../Common/ThemeHelpers.js" as ThemeHelpers

// The Cybex OS themes as installer list rows with their swatches. Choosing
// one applies it straight away, as Settings → Appearance does.
KioskSheet {
    id: root
    title: I18n.tr("Cybex OS themes")
    subtitle: I18n.tr("A starting point for colours and contrast. Your wallpaper stays.")
    onClosed: Welcome.closeSheet()
    Component.onCompleted: { if (!Themes.loaded) Themes.refresh(); }
    ListView {
        id: list
        anchors.top: parent.top
        anchors.bottom: status.top
        anchors.bottomMargin: Kiosk.px(10)
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: -Kiosk.px(8)
        anchors.rightMargin: -Kiosk.px(8)
        clip: true
        focus: true
        boundsBehavior: Flickable.StopAtBounds
        spacing: Kiosk.px(2)
        keyNavigationEnabled: true
        highlightFollowsCurrentItem: false
        model: ScriptModel { values: Themes.entries }
        Keys.onReturnPressed: event => { if (currentItem) Themes.apply(Themes.entries[currentIndex].id); event.accepted = true; }
        Keys.onEnterPressed: event => { if (currentItem) Themes.apply(Themes.entries[currentIndex].id); event.accepted = true; }
        delegate: Rectangle {
            id: row
            required property var modelData
            required property int index
            readonly property bool chosen: Themes.current.value === modelData.id && !Themes.current.modified
            readonly property bool focused: list.activeFocus && list.currentIndex === index
            readonly property var swatches: ThemeHelpers.swatches(modelData, {
                dark: {background: Theme.darkBackground.toString(), text: Theme.darkTextHi.toString()},
                light: {background: Theme.lightBackground.toString(), text: Theme.lightTextHi.toString()}})
            x: Kiosk.px(8)
            width: list.width - Kiosk.px(16)
            height: Kiosk.px(58)
            radius: Kiosk.px(12)
            color: chosen ? Kiosk.accentSoft : rowMouse.containsMouse || focused ? Kiosk.card2 : "transparent"
            border.width: chosen || focused ? Math.max(1, Kiosk.px(1)) : 0
            border.color: focused ? Kiosk.accent : Kiosk.accentLine
            Accessible.role: Accessible.ListItem
            Accessible.name: modelData.name
            Accessible.selected: chosen
            Accessible.onPressAction: Themes.apply(modelData.id)
            Row {
                id: dots
                x: Kiosk.px(14)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Kiosk.px(5)
                Repeater {
                    model: row.swatches
                    delegate: Rectangle {
                        required property string modelData
                        width: Kiosk.px(20)
                        height: width
                        radius: width / 2
                        color: modelData
                        border.width: Math.max(1, Kiosk.px(1))
                        border.color: "#33ffffff"
                    }
                }
            }
            KioskText {
                anchors.left: dots.right
                anchors.leftMargin: Kiosk.px(14)
                anchors.right: tick.left
                anchors.rightMargin: Kiosk.px(10)
                anchors.verticalCenter: parent.verticalCenter
                text: row.modelData.name
                font.weight: Font.DemiBold
                elide: Text.ElideRight
            }
            KioskIcon {
                id: tick
                anchors.right: parent.right
                anchors.rightMargin: Kiosk.px(14)
                anchors.verticalCenter: parent.verticalCenter
                visible: row.chosen
                name: "check"
                color: Kiosk.accent
            }
            MouseArea {
                id: rowMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: { list.currentIndex = row.index; Themes.apply(row.modelData.id); }
            }
        }
    }
    KioskText {
        id: status
        anchors.bottom: actions.top
        anchors.bottomMargin: visible ? Kiosk.px(12) : 0
        width: parent.width
        visible: text !== ""
        text: Themes.error || (Themes.busy ? I18n.tr("Applying…") : "")
        size: 13.5
        tone: Themes.error ? "red" : "fog"
        wrapMode: Text.WordWrap
    }
    Row {
        id: actions
        anchors.bottom: parent.bottom
        anchors.right: parent.right
        KioskButton { small: true; kind: "primary"; text: I18n.tr("Done"); onClicked: Welcome.closeSheet() }
    }
}
