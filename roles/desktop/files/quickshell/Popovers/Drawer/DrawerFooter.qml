import QtQuick
import "../../Common"
import ".."

// A drawer tab's one-line footer: quiet context on the left, up to two
// actions on the right, above a hairline. Every tab ends in one, which is
// what makes six different bodies read as one surface.
Item {
    id: root

    property string info: ""
    property string secondaryText: ""
    property string actionText: ""
    signal secondaryClicked
    signal actionClicked

    width: parent ? parent.width : 0
    height: Theme.panelFooterHeight

    Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: 1
        color: Theme.hairlineSoft
    }

    Text {
        anchors.left: parent.left
        anchors.leftMargin: 2
        anchors.verticalCenter: parent.verticalCenter
        anchors.verticalCenterOffset: 4
        text: root.info
        font.family: Theme.fontMenu
        font.pixelSize: Theme.typography.secondary
        font.weight: Theme.weightMedium
        color: Theme.textFaint
        elide: Text.ElideRight
        width: Math.max(0, parent.width - actions.width - 16)
    }

    Row {
        id: actions
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.verticalCenterOffset: 4
        spacing: 14

        LinkText {
            visible: root.secondaryText !== ""
            text: root.secondaryText
            onClicked: root.secondaryClicked()
        }

        LinkText {
            visible: root.actionText !== ""
            text: root.actionText
            onClicked: root.actionClicked()
        }
    }
}
