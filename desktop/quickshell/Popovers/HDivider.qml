import QtQuick
import "../Common"

// A rule between two runs of rows inside one section. Sections themselves are
// separated by SectionLabel's own rule; this is the quieter one.
Item {
    width: parent.width
    height: 11

    Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        x: 2
        width: parent.width - 4
        height: 1
        color: Theme.hairlineSoft
    }
}
