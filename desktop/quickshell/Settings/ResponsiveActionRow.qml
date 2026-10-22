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
    readonly property int gap: description === "" ? 0 : Theme.settingsContentSpacing
    readonly property real contentInset: Theme.settingsMarkInset
    readonly property real availableWidth: Math.max(0, width - contentInset)
    readonly property real naturalActionWidth: {
        let total = 0;
        let count = 0;
        for (const child of actionRow.children) {
            if (child.visible && child.width > 0) {
                total += child.width;
                count++;
            }
        }
        return total + Math.max(0, count - 1) * Theme.iconTextSpacing;
    }

    implicitHeight: stacked
        ? actionRow.implicitHeight + descriptionText.implicitHeight + gap
        : Math.max(actionRow.implicitHeight, descriptionText.implicitHeight)
    height: implicitHeight

    Text {
        id: descriptionText
        x: root.contentInset + (root.stacked || !root.actionsFirst ? 0 : actionRow.width + root.gap)
        y: root.stacked ? (root.actionsFirst ? actionRow.height + root.gap : 0)
            : (root.height - height) / 2
        width: root.stacked ? root.availableWidth
            : Math.max(0, root.availableWidth - actionRow.width - root.gap)
        text: root.description
        font.family: root.descriptionMono ? Theme.fontMono : Theme.fontMenu
        font.pixelSize: Theme.typography.secondary
        color: Theme.textFaint
        wrapMode: root.stacked ? Text.Wrap : Text.NoWrap
        maximumLineCount: root.maximumLines
        elide: Text.ElideMiddle
    }

    Flow {
        id: actionRow
        width: Math.min(root.availableWidth, root.naturalActionWidth)
        x: root.stacked || root.actionsFirst ? root.contentInset : parent.width - width
        y: root.stacked ? (!root.actionsFirst ? descriptionText.implicitHeight + root.gap : 0)
            : (root.height - height) / 2
        spacing: Theme.iconTextSpacing
    }
}
