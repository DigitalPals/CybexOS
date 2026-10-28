pragma ComponentBehavior: Bound
import QtQuick
import "../Common"

// The header's Changes chip (2026-10 redesign): present only while something
// waits. With drafts it counts them and opens their review; after a system
// change was prepared it follows it — preparing, ready to review, restart
// to finish — and opens Software Update, which owns that review. In the
// narrow window it keeps only the dot, the count and its action.
Item {
    id: root

    property bool compact: false
    signal reviewRequested()

    readonly property int count: SettingsChanges.count
    readonly property string deployment: SettingsChanges.deploymentState
    readonly property bool shown: count > 0 || deployment !== ""
    readonly property string text: count > 0
        ? (count === 1 ? I18n.tr("1 change waiting") : I18n.format("%1 changes waiting", [count]))
        : deployment === "restart" ? I18n.tr("Restart to finish")
        : deployment === "review" ? I18n.tr("System change ready")
        : I18n.tr("Preparing system change")
    readonly property string actionText: count > 0 ? I18n.tr("Review")
        : deployment === "restart" ? I18n.tr("Restart…")
        : deployment === "review" ? I18n.tr("Review…") : ""

    visible: shown
    implicitWidth: shown ? chip.width : 0
    implicitHeight: Theme.settingsControlHeight
    activeFocusOnTab: shown
    Accessible.role: Accessible.Button
    Accessible.name: root.text + (root.actionText !== "" ? ". " + root.actionText : "")
    Accessible.onPressAction: root.activate()
    Keys.onPressed: event => {
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
            root.activate();
            event.accepted = true;
        }
    }

    function activate() {
        if (count > 0)
            reviewRequested();
        else if (deployment === "review" || deployment === "restart")
            Updates.show();
    }

    Rectangle {
        id: chip
        width: chipRow.implicitWidth + Theme.scaled(root.actionText !== "" ? 14 : 22)
        height: parent.height
        radius: height / 2
        color: chipMouse.containsMouse ? Theme.chipHover : Theme.chip
        border.width: root.activeFocus ? 1 : 0
        border.color: Theme.accentText

        Row {
            id: chipRow
            x: Theme.scaled(11)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.scaled(8)

            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: 7
                height: 7
                radius: 3.5
                color: root.deployment === "preparing" && root.count === 0 ? Theme.amber : Theme.accent
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: root.compact ? (root.count > 0 ? String(root.count) : "") : root.text
                visible: text !== ""
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.control
                font.weight: Theme.weightMedium
                color: Theme.textHi
            }
            // While preparing, the chip says so and takes no action.
            Rectangle {
                visible: root.actionText !== ""
                anchors.verticalCenter: parent.verticalCenter
                width: actionLabel.implicitWidth + Theme.scaled(18)
                height: chip.height - Theme.scaled(8)
                radius: height / 2
                color: Theme.accent
                Text {
                    id: actionLabel
                    anchors.centerIn: parent
                    text: root.actionText
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.secondary
                    font.weight: Theme.weightSemibold
                    color: Theme.textOnAccent
                }
            }
        }

        MouseArea {
            id: chipMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: root.actionText !== "" ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: root.activate()
        }
    }
}
