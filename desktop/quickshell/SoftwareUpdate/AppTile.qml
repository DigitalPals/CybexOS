import QtQuick
import Quickshell
import Quickshell.Widgets
import "../Common"

// An updated, added or removed application with its own name and icon.
Rectangle {
    id: root

    property var app: ({})

    implicitHeight: Theme.scaled(48)
    radius: Theme.chipRadius + 3
    color: Theme.cardFill
    border.width: 1
    border.color: Theme.hairlineSoft

    IconImage {
        id: icon
        anchors.left: parent.left
        anchors.leftMargin: Theme.scaled(10)
        anchors.verticalCenter: parent.verticalCenter
        implicitSize: Theme.scaled(28)
        asynchronous: true
        source: {
            const name = root.app.icon || "";
            return /^(file:|image:|\/)/.test(name) ? name
                : Quickshell.iconPath(name || "application-x-executable", "application-x-executable");
        }
    }

    Text {
        anchors.left: icon.right
        anchors.leftMargin: Theme.scaled(10)
        anchors.right: versions.left
        anchors.rightMargin: Theme.scaled(8)
        anchors.verticalCenter: parent.verticalCenter
        text: root.app.title || root.app.name || ""
        color: Theme.textHi
        font.family: Theme.fontMenu
        font.pixelSize: Theme.typography.primary
        font.weight: Theme.weightSemibold
        elide: Text.ElideRight
        textFormat: Text.PlainText
    }

    VersionPair {
        id: versions
        anchors.right: parent.right
        anchors.rightMargin: Theme.scaled(10)
        anchors.verticalCenter: parent.verticalCenter
        compact: true
        before: root.app.before
        after: root.app.after
        kind: root.app.kind || "updated"
    }
}
