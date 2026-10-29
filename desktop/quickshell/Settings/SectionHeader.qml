import QtQuick
import "../Common"

// The one section mark in the shell's dialogs: an uppercase label, indented
// to the settings rows' own label column, and a hairline running to the edge.
//
// Resetting is a row's job (its undo chip) or the page's (the header's Reset
// page). A third, per-group level between them said the same thing again on
// every heading, so the header carries no action.
Item {
    id: root

    property string label
    // See SettingsGroup.changeTag.
    property string tag: ""
    readonly property string tagText: tag === "restart" ? I18n.tr("Administrator · restart")
        : tag === "admin" ? I18n.tr("Administrator") : ""

    width: parent ? parent.width : 0
    height: Math.max(Theme.sectionHeaderHeight, labelText.implicitHeight, tagPill.visible ? tagPill.height : 0)

    Text {
        id: labelText
        anchors.left: parent.left
        anchors.leftMargin: Theme.settingsMarkInset
        anchors.verticalCenter: parent.verticalCenter
        width: Math.min(implicitWidth, Math.max(0, root.width - Theme.settingsMarkInset))
        wrapMode: Text.Wrap
        text: root.label
        font.family: Theme.fontMenu
        font.pixelSize: Theme.typography.section
        font.weight: Theme.weightSemibold
        font.letterSpacing: 1
        color: Theme.textFaint
    }

    Rectangle {
        anchors.left: labelText.right
        anchors.leftMargin: Theme.controlSpacing
        anchors.right: tagPill.visible ? tagPill.left : parent.right
        anchors.rightMargin: tagPill.visible ? Theme.controlSpacing : 0
        anchors.verticalCenter: parent.verticalCenter
        visible: width > 0
        height: 1
        color: Theme.hairlineSoft
    }

    // An outline, not a fill: it describes the rows, it is not one of them.
    Rectangle {
        id: tagPill
        visible: root.tagText !== ""
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        width: tagRow.implicitWidth + Theme.scaled(14)
        height: Theme.scaled(20)
        radius: height / 2
        color: "transparent"
        border.width: 1
        border.color: Theme.hairline
        Accessible.role: Accessible.StaticText
        Accessible.name: root.tag === "restart"
            ? I18n.tr("Changing these settings needs an administrator and a restart")
            : I18n.tr("Changing these settings needs an administrator")

        Row {
            id: tagRow
            anchors.centerIn: parent
            spacing: Theme.scaled(5)
            Sym {
                anchors.verticalCenter: parent.verticalCenter
                name: "admin_panel_settings"
                size: Theme.typography.metadata
                color: Theme.textDim
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: root.tagText
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.metadata
                color: Theme.textDim
            }
        }
    }
}
