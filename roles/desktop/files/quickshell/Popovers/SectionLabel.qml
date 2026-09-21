import QtQuick
import "../Common"

// The shared section mark, in the shape Settings/SectionHeader.qml draws and
// the T3 and GitHub inboxes draw inline: an uppercase micro label and a
// hairline running from it to the panel edge. It is what separates one group
// from the next now that nothing is a filled, bordered card.
Item {
    id: root

    property alias text: label.text
    property color tint: Theme.textFaint
    property color detailColor: Theme.textDim
    property color rule: Theme.hairlineSoft
    // A count, a state, or anything else that belongs to the label rather than
    // to the rows under it — drawn a step quieter, before the rule.
    property string detail: ""

    width: parent ? parent.width : 0
    height: Math.max(Theme.sectionHeaderHeight, label.implicitHeight, detailText.implicitHeight)
        + Theme.settingsContentSpacing

    Text {
        id: label
        anchors.left: parent.left
        anchors.leftMargin: 2
        anchors.verticalCenter: parent.verticalCenter
        width: Math.min(implicitWidth, Math.max(0, root.width - 2
            - (root.detail === "" ? 0 : detailText.width + Theme.iconTextSpacing)))
        elide: Text.ElideRight
        font.family: Theme.fontMenu
        font.pixelSize: Theme.typography.section
        font.weight: Theme.weightSemibold
        font.letterSpacing: 1
        color: root.tint
    }

    Text {
        id: detailText
        anchors.left: label.right
        anchors.leftMargin: root.detail === "" ? 0 : Theme.iconTextSpacing
        anchors.verticalCenter: parent.verticalCenter
        width: Math.min(implicitWidth, root.width * 0.4)
        elide: Text.ElideRight
        text: root.detail
        font.family: Theme.fontMenu
        font.pixelSize: Theme.typography.secondary
        font.weight: Theme.weightMedium
        font.features: Theme.tabularNumberFeatures
        color: root.detailColor
    }

    Rectangle {
        anchors.left: detailText.right
        anchors.leftMargin: Theme.controlSpacing
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        visible: width > 0
        height: 1
        color: root.rule
    }
}
