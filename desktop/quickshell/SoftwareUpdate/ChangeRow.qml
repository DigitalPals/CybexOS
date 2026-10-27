import QtQuick
import "../Common"

// One recognisable change: what it is, what it does, and old → new.
Item {
    id: root

    property string glyph: "package-export"
    property string title: ""
    property string detail: ""
    property string component: ""
    property var before: null
    property var after: null
    property string kind: "updated"
    property bool divider: false

    implicitHeight: Math.max(Theme.scaled(56), copy.implicitHeight + Theme.scaled(18))

    Rectangle {
        visible: root.divider
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: 1
        color: Theme.hairlineSoft
    }

    Rectangle {
        id: tile
        anchors.left: parent.left
        anchors.leftMargin: Theme.scaled(12)
        anchors.verticalCenter: parent.verticalCenter
        width: Theme.scaled(34)
        height: width
        radius: Theme.chipRadius + 2
        color: Theme.chip
        Sym {
            anchors.centerIn: parent
            name: root.glyph
            size: Theme.iconLarge
            color: Theme.textMid
        }
    }

    Column {
        id: copy
        anchors.left: tile.right
        anchors.leftMargin: Theme.scaled(12)
        anchors.right: versions.left
        anchors.rightMargin: Theme.scaled(12)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Theme.scaled(2)
        Text {
            width: parent.width
            text: root.title
            color: Theme.textHi
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.primary
            font.weight: Theme.weightSemibold
            elide: Text.ElideRight
            textFormat: Text.PlainText
        }
        Text {
            width: parent.width
            visible: text !== ""
            text: root.detail
            color: Theme.textDim
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.secondary
            wrapMode: Text.Wrap
            maximumLineCount: 2
            elide: Text.ElideRight
            textFormat: Text.PlainText
        }
    }

    VersionPair {
        id: versions
        anchors.right: parent.right
        anchors.rightMargin: Theme.scaled(12)
        anchors.verticalCenter: parent.verticalCenter
        component: root.component
        before: root.before
        after: root.after
        kind: root.kind
    }
}
