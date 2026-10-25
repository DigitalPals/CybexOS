pragma ComponentBehavior: Bound
import QtQuick
import "../Common"
Row {
    id: root
    property var combos: []
    // One flag per combination: a protected action's reserved default,
    // drawn dimmed with a lock because it cannot be removed.
    property var locked: []
    property bool large: false
    spacing: Theme.controlSpacing
    Repeater {
        model: root.combos
        delegate: Row {
            id: combo
            required property var modelData
            spacing: Theme.controlSpacing
            required property int index
            readonly property bool locked: !!root.locked[index]
            Repeater {
                model: combo.modelData
                delegate: Rectangle {
                    id: cap
                    required property string modelData
                    width: label.implicitWidth + Theme.scaled(root.large ? 28 : 16)
                    height: Theme.scaled(root.large ? 56 : 28)
                    radius: Theme.chipRadius
                    color: combo.locked ? "transparent" : Theme.cardFill
                    border.width: 1
                    border.color: Theme.stroke
                    GuideText {
                        id: label
                        anchors.centerIn: parent
                        text: cap.modelData
                        tone: combo.locked ? "muted" : "normal"
                        font.family: Theme.fontMono
                        font.pixelSize: root.large ? Theme.typography.title : Theme.typography.secondary
                    }
                }
            }
            Sym {
                visible: combo.locked
                anchors.verticalCenter: parent.verticalCenter
                name: "lock"; size: Theme.iconSmall; color: Theme.textFaint
            }
        }
    }
}
