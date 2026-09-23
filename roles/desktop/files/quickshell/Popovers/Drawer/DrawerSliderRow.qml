import QtQuick
import "../../Common"

// A drawer slider row: a filled glyph in a fixed lane, the shared HSlider,
// and an optional Geist Mono readout. Overview stacks two of these (light and
// volume); Sound reuses the shape with the readout on.
Item {
    id: root

    property string glyph: "sunny"
    property real value: 0
    property bool ready: true
    property bool showValue: false
    property string accessibleName: "Slider"
    signal moved(real value)

    width: parent ? parent.width : 0
    height: Theme.inlineActionHeight
    opacity: ready ? 1 : 0.4

    Sym {
        id: mark
        anchors.left: parent.left
        anchors.leftMargin: 4
        anchors.verticalCenter: parent.verticalCenter
        name: root.glyph
        size: Theme.iconLarge
        color: Theme.textMid
    }

    HSlider {
        anchors.left: mark.right
        anchors.leftMargin: Theme.controlSpacing
        anchors.right: readout.visible ? readout.left : parent.right
        anchors.rightMargin: readout.visible ? Theme.controlSpacing : 4
        anchors.verticalCenter: parent.verticalCenter
        height: parent.height
        value: root.value
        enabled: root.ready
        accessibleName: root.accessibleName
        onMoved: v => root.moved(v)
    }

    Text {
        id: readout
        visible: root.showValue
        anchors.right: parent.right
        anchors.rightMargin: 4
        anchors.verticalCenter: parent.verticalCenter
        width: Math.max(Theme.scaled(36), implicitWidth)
        horizontalAlignment: Text.AlignRight
        text: Math.round(root.value * 100) + "%"
        font.family: Theme.fontNumeric
        font.pixelSize: Theme.typography.metadata
        font.weight: Theme.weightSemibold
        font.features: Theme.tabularNumberFeatures
        color: Theme.textMid
    }
}
