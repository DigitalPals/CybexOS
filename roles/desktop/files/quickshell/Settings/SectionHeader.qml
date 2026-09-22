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

    width: parent ? parent.width : 0
    height: Math.max(Theme.sectionHeaderHeight, labelText.implicitHeight)

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
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        visible: width > 0
        height: 1
        color: Theme.hairlineSoft
    }
}
