import QtQuick
import "../Common"

// "Advanced …": a quiet toggle under a group's everyday rows that reveals the
// less-used ones beneath it. The revealed rows keep the page's grid; they
// only move out of the way until they are asked for.
//
// `open` is view state, not a setting. A search jump to a row inside opens
// it: set `keys` to the setting keys the disclosure holds.
Column {
    id: root

    default property alias content: body.data
    property string text: "Advanced"
    property bool open: false
    property var keys: []

    spacing: 0

    Connections {
        target: Settings
        function onHighlightKeyChanged() {
            if (Settings.highlightKey !== "" && root.keys.indexOf(Settings.highlightKey) !== -1)
                root.open = true;
        }
    }
    Component.onCompleted: {
        if (Settings.highlightKey !== "" && keys.indexOf(Settings.highlightKey) !== -1)
            open = true;
    }

    Item {
        width: parent.width
        height: Theme.panelRowHeight

        Rectangle {
            id: toggle
            x: Theme.settingsMarkInset - Theme.scaled(4)
            anchors.verticalCenter: parent.verticalCenter
            width: toggleRow.implicitWidth + Theme.scaled(12)
            height: Theme.chipHeight
            radius: Theme.chipRadius
            color: "transparent"
            border.width: activeFocus ? 1 : 0
            border.color: Theme.accentText
            activeFocusOnTab: true
            Accessible.role: Accessible.Button
            Accessible.name: root.text
            Accessible.description: root.open ? "Expanded" : "Collapsed"
            Accessible.onPressAction: root.open = !root.open
            Keys.onPressed: event => {
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                        || event.key === Qt.Key_Space) {
                    root.open = !root.open;
                    event.accepted = true;
                }
            }

            StateLayer {
                anchors.fill: parent
                radius: parent.radius
                hovered: toggleMouse.containsMouse
                pressed: toggleMouse.pressed
                focused: toggle.activeFocus
                tint: Theme.textHi
            }

            Row {
                id: toggleRow
                anchors.left: parent.left
                anchors.leftMargin: Theme.scaled(4)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.iconTextSpacing

                Sym {
                    anchors.verticalCenter: parent.verticalCenter
                    name: "chevron_right"
                    size: Theme.iconSmall
                    color: Theme.textFaint
                    rotation: root.open ? 90 : 0
                    Behavior on rotation { NumberAnimation { duration: Theme.chipFadeDuration } }
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.text
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.control
                    color: Theme.textLow
                }
            }

            MouseArea {
                id: toggleMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    toggle.forceActiveFocus();
                    root.open = !root.open;
                }
            }
        }
    }

    Revealer {
        width: parent.width
        reveal: root.open

        Column {
            id: body
            width: root.width
            spacing: Theme.settingsRowSpacing
        }
    }
}
