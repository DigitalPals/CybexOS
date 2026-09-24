pragma ComponentBehavior: Bound
import QtQuick
import "../Common"

// Responsive fallback for narrow outputs. Hidden modules keep their live
// instances and state in the bar; this is only their reachable menu.
Surface {
    id: root

    implicitWidth: availableWidth > 0 ? Math.min(300, availableWidth) : 300
    spacing: 4
    focus: visible

    SectionLabel {
        text: "MORE WIDGETS"
        detail: String(BarOverflow.items.length)
    }

    Repeater {
        model: BarOverflow.items
        delegate: Rectangle {
            id: row
            required property var modelData
            required property int index

            width: parent.width
            height: Theme.listRowHeight
            radius: Theme.rowRadius
            color: rowMouse.containsMouse || activeFocus
                ? Theme.hoverFill : "transparent"
            activeFocusOnTab: true
            Accessible.role: Accessible.Button
            Accessible.name: modelData.label
            Accessible.description: modelData.panel === ""
                ? "Open widget settings" : "Open widget details"
            Accessible.onPressAction: row.activate()

            function activate() {
                if (modelData.panel !== "")
                    Popouts.openPanel(modelData.panel, "right", Popouts.anchorRect,
                        Popouts.hostScreenName);
                else
                    Settings.showPanel("bar", Popouts.hostScreenName);
            }

            Keys.onPressed: event => {
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                        || event.key === Qt.Key_Space) {
                    row.activate();
                    event.accepted = true;
                }
            }

            Text {
                anchors.left: parent.left
                anchors.leftMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                text: row.modelData.label
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.primary
                font.weight: Theme.weightMedium
                color: Theme.textHi
            }

            Sym {
                anchors.right: parent.right
                anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                name: "chevron_right"
                size: Theme.iconMedium
                color: Theme.textLow
            }

            MouseArea {
                id: rowMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: row.activate()
            }
        }
    }
}
