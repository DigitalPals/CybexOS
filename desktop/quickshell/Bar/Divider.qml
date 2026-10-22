import QtQuick
import "../Common"

// Compact separation between adjacent modules. A rule recreates the original
// 14px hairline; a space keeps clock text and quick actions unruled.
Item {
    id: root

    // "rule" | "space"
    property string kind: "rule"

    width: kind === "space" ? 8 : 9
    height: Theme.chipHeight
    anchors.verticalCenter: parent ? parent.verticalCenter : undefined

    Rectangle {
        visible: root.kind === "rule"
        anchors.centerIn: parent
        width: 1
        height: 14
        color: Theme.barStroke
    }
}
