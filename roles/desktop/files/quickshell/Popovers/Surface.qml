pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects
import "../Common"

// Shared popover surface: semantic width, the bar's own corner, a hairline
// border and a comfortable inner gutter. A panel sits on the shell's deepest
// surface rather than on a lighter card stacked over it — everything inside is
// separated by hairlines and space instead.
//
// The popout host normally paints the card itself and clears `drawBackground`,
// so what this contributes there is the layout and the padding. The background
// below is for a panel drawn anywhere else.
PopoutPanel {
    id: root

    property int padding: Theme.panelPadding
    property alias backdrop: backdropLayer.data
    // The corner the backdrop is clipped to is the panel's own. A panel whose
    // field also has to end somewhere paints that falloff into the same mask,
    // rather than stacking a second masked layer inside it.
    property alias backdropMaskGradient: backdropMask.gradient
    readonly property Item backdropMaskItem: backdropMask
    property alias spacing: column.spacing
    default property alias content: column.data

    implicitWidth: availableWidth > 0
        ? Math.min(Theme.popWidth, availableWidth) : Theme.popWidth
    implicitHeight: column.implicitHeight + padding * 2

    Rectangle {
        id: bg
        visible: root.drawBackground
        anchors.fill: parent
        radius: Theme.panelRadius
        color: root.surfaceColor
        border.width: Theme.surfaceBorderWidth
        border.color: root.surfaceBorderColor

        Behavior on color {
            ColorAnimation { duration: Theme.surfaceDuration }
        }
    }

    // A field painted behind every section, for the one panel that wants its
    // content to sit on something other than the flat surface — the media
    // view's artwork wash. It is a sibling of the column rather than its first
    // item, so it spans the whole panel instead of taking a slot in the
    // layout, and the panel's own corner is what clips it.
    Item {
        id: backdropLayer
        anchors.fill: parent
        visible: backdropLayer.children.length > 0
        layer.enabled: backdropLayer.visible
        layer.effect: MultiEffect {
            maskEnabled: true
            maskSource: root.backdropMaskItem
        }
    }

    Rectangle {
        id: backdropMask
        anchors.fill: parent
        radius: Theme.panelRadius
        color: "white"
        visible: false
        layer.enabled: backdropLayer.visible
    }

    Column {
        id: column
        x: root.padding
        y: root.padding
        width: Math.max(0, parent.width - root.padding * 2)
        spacing: Theme.panelSectionSpacing
    }
}
