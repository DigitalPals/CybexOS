pragma ComponentBehavior: Bound
import QtQuick
import "../Common"
Row {
    id: root
    property var combos: []
    property bool large: false
    spacing: Theme.controlSpacing
    Repeater {
        model: root.combos
        delegate: Row {
            id: combo
            required property var modelData
            spacing: Theme.controlSpacing
            Repeater {
                model: combo.modelData
                delegate: Rectangle {
                    id: cap
                    required property string modelData
                    width: label.implicitWidth + Theme.scaled(root.large ? 28 : 16)
                    height: Theme.scaled(root.large ? 56 : 28)
                    radius: Theme.chipRadius
                    color: Theme.cardFill
                    border.width: 1
                    border.color: Theme.stroke
                    GuideText {
                        id: label
                        anchors.centerIn: parent
                        text: cap.modelData
                        font.family: Theme.fontMono
                        font.pixelSize: root.large ? Theme.typography.title : Theme.typography.secondary
                    }
                }
            }
        }
    }
}
