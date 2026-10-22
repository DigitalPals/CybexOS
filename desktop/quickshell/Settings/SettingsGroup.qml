import QtQuick
import "../Common"

// One coherent group of settings. Not a card: the menubar separates its
// modules with a hairline and a gap rather than by giving each one a filled,
// bordered container, and a settings page reads the same way. The group owns
// its section label and the rule that runs from it to the page edge; callers
// only supply the rows.
Item {
    id: root

    default property alias content: contentColumn.data
    property string title: ""
    property int rowSpacing: Theme.settingsRowSpacing

    readonly property real headingHeight: title === "" ? 0 : heading.height
    readonly property int headingGap: title === "" ? 0 : Theme.settingsContentSpacing
    readonly property real availableContentHeight: Math.max(0,
        height - headingHeight - headingGap)

    // Positioner height excludes hidden rows; childrenRect keeps their stale bounds.
    implicitHeight: headingHeight + headingGap + contentColumn.implicitHeight

    SectionHeader {
        id: heading
        visible: root.title !== ""
        width: parent.width
        label: root.title.toUpperCase()
    }

    Column {
        id: contentColumn
        y: root.headingHeight + root.headingGap
        width: parent.width
        spacing: root.rowSpacing
    }
}
