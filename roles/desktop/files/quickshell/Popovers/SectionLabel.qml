import QtQuick
import "../Common"

// The shared section mark, in the shape Settings/SectionHeader.qml draws and
// the T3 and GitHub inboxes draw inline: an uppercase micro label and a
// hairline running from it to the panel edge. It is what separates one group
// from the next now that nothing is a filled, bordered card.
Item {
    id: root

    property alias text: label.text
    // A count, a state, or anything else that belongs to the label rather than
    // to the rows under it — drawn a step quieter, before the rule.
    property string detail: ""

    width: parent ? parent.width : 0
    height: Theme.sectionHeaderHeight + 8

    Text {
        id: label
        anchors.left: parent.left
        anchors.leftMargin: 2
        anchors.verticalCenter: parent.verticalCenter
        font.family: Theme.fontMenu
        font.pixelSize: Theme.typography.section
        font.weight: Theme.weightSemibold
        font.letterSpacing: 1
        color: Theme.textFaint
    }

    Text {
        id: detailText
        anchors.left: label.right
        anchors.leftMargin: root.detail === "" ? 0 : 7
        anchors.verticalCenter: parent.verticalCenter
        text: root.detail
        font.family: Theme.fontMenu
        font.pixelSize: Theme.typography.secondary
        font.weight: Theme.weightMedium
        font.features: Theme.tabularNumberFeatures
        color: Theme.textDim
    }

    Rectangle {
        anchors.left: detailText.right
        anchors.leftMargin: 10
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        height: 1
        color: Theme.hairlineSoft
    }
}
