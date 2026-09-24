pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls as Controls
import "../Common"

// A long capability list belongs in a dropdown rather than wrapping pills.
Column {
    id: root
    property string label: ""
    property var choices: []
    property var current: ""
    signal picked(var value)
    spacing: Theme.settingsRowSpacing
    Text {
        text: root.label
        color: Theme.textMid
        font.family: Theme.fontMenu
        font.pixelSize: Theme.typography.primary
    }
    Controls.ComboBox {
        id: combo
        width: parent.width
        model: root.choices
        textRole: "label"
        valueRole: "value"
        currentIndex: root.choices.findIndex(choice => choice.value === root.current)
        implicitHeight: Theme.settingsControlHeight
        Accessible.name: root.label
        onActivated: index => root.picked(root.choices[index].value)
        leftPadding: Theme.controlSpacing
        rightPadding: Theme.settingsControlHeight
        contentItem: Text {
            text: combo.displayText
            color: Theme.textHi
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.control
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
        }
        indicator: Sym {
            x: combo.width - width - Theme.controlSpacing
            y: (combo.height - height) / 2
            name: "expand_more"
            size: Theme.iconSmall
            color: Theme.textDim
        }
        background: Rectangle {
            color: combo.hovered ? Theme.hoverFillStrong : Theme.cardFill
            radius: Theme.chipRadius
            border.width: combo.activeFocus || Settings.highContrast ? 1 : 0
            border.color: combo.activeFocus ? Theme.accentText : Theme.stroke
        }
        delegate: Controls.ItemDelegate {
            id: option
            required property var modelData
            required property int index
            width: combo.width - 8
            height: Theme.settingsControlHeight
            highlighted: combo.highlightedIndex === index
            contentItem: Text {
                text: option.modelData.label
                color: Theme.textHi
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.control
                verticalAlignment: Text.AlignVCenter
                elide: Text.ElideRight
            }
            background: Rectangle {
                radius: Theme.chipRadius
                color: option.highlighted || option.hovered ? Theme.hoverFillStrong : "transparent"
            }
        }
        popup: Controls.Popup {
            y: combo.height + 4
            width: combo.width
            padding: 4
            implicitHeight: Math.min(contentItem.implicitHeight + 8, Theme.scaled(260))
            contentItem: ListView {
                clip: true
                implicitHeight: contentHeight
                model: combo.popup.visible ? combo.delegateModel : null
                currentIndex: combo.highlightedIndex
                Controls.ScrollIndicator.vertical: Controls.ScrollIndicator {}
            }
            background: Rectangle {
                color: Theme.panelSurface
                radius: Theme.chipRadius
                border.width: 1
                border.color: Theme.stroke
            }
        }
    }
}
