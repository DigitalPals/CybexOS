import QtQuick

// A notification's source icon: the desktop entry's icon where one resolves,
// otherwise a browser-cached site favicon and finally a glyph — a warning for
// critical, a globe for a web origin, a bell for everything else. Toasts opt
// into a compact well so icons with very different silhouettes keep the same
// visual weight — the shell's resting chip rather than an accent tint, which
// made every toast look like an alert.
Item {
    id: root

    required property var entry
    property int iconSize: 28
    property bool urgent: false
    property bool framed: false
    property bool primaryFailed: false
    readonly property string primarySource: brand.available
        ? "" : Notifs.iconSource(entry)
    readonly property string siteSource: WebIcons.sourceFor(entry.webOrigin || "")

    function requestSiteIcon() {
        if (entry.webOrigin && !entry.brandIcon)
            WebIcons.request(entry.webOrigin);
    }

    onEntryChanged: {
        primaryFailed = false;
        requestSiteIcon();
    }
    onPrimarySourceChanged: primaryFailed = false
    Component.onCompleted: requestSiteIcon()

    Rectangle {
        anchors.fill: parent
        radius: Theme.chipRadius
        color: root.framed
            ? (root.urgent ? Theme.redBgSoft : Theme.chip)
            : "transparent"
        border.width: root.framed && root.urgent ? 1 : 0
        border.color: Theme.redBorder

        BrandIcon {
            id: brand
            anchors.centerIn: parent
            width: root.iconSize
            height: root.iconSize
            name: root.entry.brandIcon || ""
            visible: available && status === Image.Ready
        }

        Image {
            id: image
            anchors.centerIn: parent
            width: root.iconSize
            height: root.iconSize
            source: brand.available ? ""
                : root.primarySource !== "" && !root.primaryFailed
                    ? root.primarySource : root.siteSource
            sourceSize: Qt.size(root.iconSize, root.iconSize)
            fillMode: Image.PreserveAspectFit
            asynchronous: true
            visible: !brand.visible && status === Image.Ready
            onStatusChanged: {
                if (status === Image.Error && root.primarySource !== ""
                        && source.toString() === root.primarySource)
                    root.primaryFailed = true;
            }
        }

        Sym {
            anchors.centerIn: parent
            visible: !brand.visible && !image.visible
            name: root.urgent ? "warning" : root.entry.webOrigin ? "public" : "notifications"
            size: Math.max(Theme.fontCaption, root.iconSize - (root.framed ? 3 : 8))
            fill: root.framed ? 1 : 0
            color: root.urgent ? Theme.redText : Theme.accentText
        }
    }
}
