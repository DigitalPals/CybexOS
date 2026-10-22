import QtQuick

Rectangle {
    id: root
    property string text: ""
    signal triggered()
    implicitWidth: label.implicitWidth + Theme.controlSpacing * 2
    implicitHeight: Math.max(Theme.chipHeight, label.implicitHeight + 10)
    radius: Theme.chipRadius
    color: hover.hovered || activeFocus ? Theme.hoverFillStrong : Theme.hoverFill
    border.width: activeFocus ? 1 : 0
    border.color: Theme.accentText
    activeFocusOnTab: visible && enabled
    Accessible.role: Accessible.Button
    Accessible.name: text
    Accessible.onPressAction: if (root.enabled) root.triggered()
    Keys.onPressed: event => {
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
            root.triggered();
            event.accepted = true;
        }
    }
    HoverHandler { id: hover }
    Text {
        id: label
        anchors.centerIn: parent
        text: root.text
        textFormat: Text.PlainText
        font.family: Theme.fontMenu
        font.pixelSize: Theme.typography.metadata
        color: Theme.textMid
    }
    MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: {
            root.forceActiveFocus();
            root.triggered();
        }
    }
}
