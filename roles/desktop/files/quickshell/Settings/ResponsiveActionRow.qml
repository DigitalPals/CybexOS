import QtQuick
import "../Common"

// Bounded copy plus one or more actions. At small widths the two lanes stack,
// preventing paths and explanatory text from being squeezed under buttons.
Item {
    id: root

    default property alias actions: actionRow.data
    property string description: ""
    property bool descriptionMono: false
    property bool actionsFirst: false
    property int breakpoint: 460
    property int maximumLines: 2
    readonly property bool stacked: width < breakpoint
    readonly property int gap: 10

    implicitHeight: stacked
        ? actionRow.implicitHeight + descriptionText.implicitHeight + gap
        : Math.max(actionRow.implicitHeight, descriptionText.implicitHeight)
    height: implicitHeight

    Text {
        id: descriptionText
        x: root.stacked || !root.actionsFirst ? 0 : actionRow.width + root.gap
        y: root.stacked && root.actionsFirst ? actionRow.height + root.gap : 0
        width: root.stacked ? parent.width
            : Math.max(0, parent.width - actionRow.width - root.gap)
        text: root.description
        font.family: root.descriptionMono ? Theme.fontMono : Theme.fontMenu
        font.pixelSize: Theme.typography.secondary
        color: Theme.textFaint
        wrapMode: root.stacked ? Text.Wrap : Text.NoWrap
        maximumLineCount: root.maximumLines
        elide: Text.ElideMiddle
    }

    Row {
        id: actionRow
        x: root.stacked || root.actionsFirst ? 0 : parent.width - width
        y: root.stacked && !root.actionsFirst
            ? descriptionText.implicitHeight + root.gap : 0
        spacing: 6
    }
}
