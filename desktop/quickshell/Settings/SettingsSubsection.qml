import QtQuick
import "../Common"

// Related content within a group. Leading space travels with the content
// through a Revealer, so a collapsed subsection leaves no empty spacer.
Item {
    id: root
    default property alias content: contentColumn.data
    property string title: ""
    // Rows already reserve the modified-state gutter; rich content opts in.
    property bool insetContent: false
    property int spacing: Theme.settingsRowSpacing
    implicitHeight: Theme.settingsSubsectionSpacing + heading.height
        + Theme.settingsContentSpacing + contentColumn.implicitHeight

    SectionHeader {
        id: heading
        y: Theme.settingsSubsectionSpacing
        width: parent.width
        label: root.title.toUpperCase()
    }
    Column {
        id: contentColumn
        x: root.insetContent ? Theme.settingsMarkInset : 0
        y: heading.y + heading.height + Theme.settingsContentSpacing
        width: Math.max(0, parent.width - x)
        spacing: root.spacing
    }
}
