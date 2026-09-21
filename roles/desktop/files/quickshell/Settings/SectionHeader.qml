import QtQuick
import QtQuick.Controls as Controls
import "../Common"

// The one section mark in the shell's dialogs: an uppercase label, indented
// to the settings rows' own label column, a hairline running to the edge,
// and — when any covered setting left its default — a right-aligned accent
// "Reset group" action (turn-3 settings design).
Item {
    id: root

    property string label
    property bool dirty: false
    signal resetRequested()

    width: parent ? parent.width : 0
    height: Theme.sectionHeaderHeight

    Text {
        id: labelText
        anchors.left: parent.left
        anchors.leftMargin: Theme.settingsMarkInset
        anchors.verticalCenter: parent.verticalCenter
        text: root.label
        font.family: Theme.fontMenu
        font.pixelSize: Theme.typography.section
        font.weight: Theme.weightSemibold
        font.letterSpacing: 1
        color: Theme.textFaint
    }

    Rectangle {
        anchors.left: labelText.right
        anchors.leftMargin: 10
        anchors.right: resetAction.visible ? resetAction.left : parent.right
        anchors.rightMargin: resetAction.visible ? 10 : 0
        anchors.verticalCenter: parent.verticalCenter
        height: 1
        color: Theme.hairlineSoft
    }

    Rectangle {
        id: resetAction
        visible: root.dirty
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        width: resetLabel.implicitWidth + 14
        height: Theme.chipHeight - 6
        radius: Theme.chipRadius
        color: resetMouse.containsMouse ? Theme.hoverFill : "transparent"
        border.width: activeFocus ? 1 : 0
        border.color: Theme.accent
        activeFocusOnTab: visible
        Accessible.role: Accessible.Button
        Accessible.name: "Reset " + root.label.toLowerCase() + " group"
        Accessible.onPressAction: root.resetRequested()
        Controls.ToolTip.visible: resetMouse.containsMouse
        Controls.ToolTip.text: "Reset this group to defaults"

        Keys.onPressed: event => {
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                    || event.key === Qt.Key_Space) {
                root.resetRequested(); event.accepted = true;
            }
        }

        Text {
            id: resetLabel
            anchors.centerIn: parent
            text: "Reset group"
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.control
            font.weight: Theme.weightSemibold
            color: Theme.accent
        }

        MouseArea {
            id: resetMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: { resetAction.forceActiveFocus(); root.resetRequested(); }
        }
    }
}
