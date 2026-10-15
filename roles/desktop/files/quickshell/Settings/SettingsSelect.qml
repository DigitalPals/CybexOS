pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls as Controls
import "../Common"

// The settings dropdown: one framed button that names the current choice and
// opens a list. It takes over from a segmented control once the choices stop
// fitting on one line (display scale, idle delays, fonts, profiles).
//
// `model` is a list of { value, label }. `fontFor(value)`, when set, returns
// the family an option's label is drawn in — the font picker shows every
// face in itself. `swatchesFor(value)`, when set, returns up to three colours
// drawn as dots before the label — the theme picker previews every theme in
// its own. The button sizes to its longest option, capped at
// `maximumWidth`, so choosing does not make it jump.
Controls.ComboBox {
    id: combo

    property var current
    property var fontFor: null
    property var swatchesFor: null
    readonly property int swatchSize: Theme.scaled(11, Theme.typeScale)
    // Three dots overlapping by a third, then a gap before the label.
    readonly property int swatchInset: swatchesFor
        ? Math.round(swatchSize * 7 / 3) + Theme.controlSpacing : 0
    property int maximumWidth: Theme.scaled(280, Theme.typeScale)
    property int minimumWidth: Theme.scaled(96, Theme.typeScale)
    property string accessibleName: ""
    signal picked(var value)

    readonly property real naturalWidth: {
        let widest = 0;
        for (const item of model || [])
            widest = Math.max(widest, Math.ceil(metrics.advanceWidth(String(item.label))));
        return Math.min(maximumWidth, Math.max(minimumWidth,
            widest + swatchInset + leftPadding + rightPadding + 2));
    }

    model: []
    textRole: "label"
    valueRole: "value"
    currentIndex: (model || []).findIndex(choice => choice.value === combo.current)
    implicitWidth: naturalWidth
    implicitHeight: Theme.settingsControlHeight
    leftPadding: Theme.controlSpacing + Theme.scaled(3)
    rightPadding: Theme.settingsControlHeight
    Accessible.name: accessibleName
    onActivated: index => combo.picked(combo.model[index].value)

    component SwatchDots: Row {
        id: dots
        property var colors: []
        property int size: 11
        spacing: -Math.round(size / 3)
        Accessible.ignored: true

        Repeater {
            model: dots.colors
            delegate: Rectangle {
                required property var modelData
                width: dots.size
                height: width
                radius: width / 2
                color: modelData
                border.width: 1
                border.color: Theme.stroke
            }
        }
    }

    FontMetrics {
        id: metrics
        font.family: Theme.fontMenu
        font.pixelSize: Theme.typography.control
    }

    contentItem: Text {
        text: I18n.tr(combo.displayText)
        textFormat: Text.PlainText
        leftPadding: combo.swatchInset
        color: Theme.textHi
        font.family: combo.fontFor && combo.currentIndex >= 0
            ? combo.fontFor(combo.model[combo.currentIndex].value) : Theme.fontMenu
        font.pixelSize: Theme.typography.control
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight

        SwatchDots {
            visible: combo.swatchesFor !== null
            anchors.verticalCenter: parent.verticalCenter
            size: combo.swatchSize
            colors: combo.swatchesFor && combo.currentIndex >= 0
                ? combo.swatchesFor(combo.model[combo.currentIndex].value) : []
        }
    }
    indicator: Sym {
        x: combo.width - width - Theme.controlSpacing
        y: (combo.height - height) / 2
        name: "expand_more"
        size: Theme.iconSmall
        color: Theme.textDim
    }
    background: Rectangle {
        color: combo.hovered || combo.popup.visible ? Theme.hoverFillStrong : Theme.cardFill
        radius: Theme.chipRadius
        border.width: 1
        border.color: combo.activeFocus ? Theme.accentText : Theme.stroke
    }
    delegate: Controls.ItemDelegate {
        id: option
        required property var modelData
        required property int index
        readonly property bool chosen: option.modelData.value === combo.current
        width: ListView.view ? ListView.view.width : combo.width
        height: Theme.settingsControlHeight
        highlighted: combo.highlightedIndex === index
        leftPadding: Theme.controlSpacing
        rightPadding: Theme.controlSpacing
        Accessible.name: option.modelData.label
        contentItem: Item {
            Text {
                anchors.left: parent.left
                anchors.right: check.left
                anchors.rightMargin: Theme.controlSpacing
                anchors.verticalCenter: parent.verticalCenter
                text: I18n.tr(option.modelData.label)
                textFormat: Text.PlainText
                leftPadding: combo.swatchInset
                color: Theme.textHi
                font.family: combo.fontFor ? combo.fontFor(option.modelData.value) : Theme.fontMenu
                font.pixelSize: Theme.typography.control
                font.weight: option.chosen ? Theme.weightSemibold : Theme.weightRegular
                elide: Text.ElideRight

                SwatchDots {
                    visible: combo.swatchesFor !== null
                    anchors.verticalCenter: parent.verticalCenter
                    size: combo.swatchSize
                    colors: combo.swatchesFor ? combo.swatchesFor(option.modelData.value) : []
                }
            }
            Sym {
                id: check
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                visible: option.chosen
                name: "check"
                size: Theme.iconSmall
                color: Theme.accentText
            }
        }
        background: Rectangle {
            radius: Theme.chipRadius
            color: option.highlighted || option.hovered ? Theme.hoverFillStrong : "transparent"
        }
    }
    popup: Controls.Popup {
        y: combo.height + 4
        width: Math.max(combo.width, Math.min(combo.maximumWidth + Theme.scaled(60),
            combo.naturalWidth + Theme.scaled(40)))
        x: combo.width - width
        padding: 4
        implicitHeight: Math.min(contentItem.implicitHeight + 8, Theme.scaled(300))
        contentItem: ListView {
            clip: true
            implicitHeight: contentHeight
            model: combo.popup.visible ? combo.delegateModel : null
            currentIndex: combo.highlightedIndex
            Controls.ScrollIndicator.vertical: Controls.ScrollIndicator {}
        }
        background: Rectangle {
            color: Theme.popBg
            radius: Theme.chipRadius + 2
            border.width: 1
            border.color: Theme.stroke
        }
    }
}
