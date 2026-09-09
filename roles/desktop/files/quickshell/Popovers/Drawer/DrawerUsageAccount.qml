pragma ComponentBehavior: Bound
import QtQuick
import "../../Common"

// One CLIProxyAPI subscription: a compact, always-visible comparison row and
// the shared quota details when selected. DrawerUsage expands at most one
// sibling and lets the active one close, avoiding an unbounded wall of cards.
Column {
    id: root

    property var record: null
    property bool expanded: false
    property bool best: false
    property bool lastUsed: false
    property bool providerStale: false
    signal toggled()

    readonly property bool ok: record !== null && record.status === "ok"
    readonly property int remaining: Usage.readingRemaining(record)
    readonly property bool low: remaining >= 0
        && remaining <= Settings.modOpts.usage.warnAt
    readonly property bool exhausted: remaining >= 0
        && remaining <= Settings.modOpts.usage.critAt
    readonly property color tone: !ok || exhausted ? Theme.redText
        : low ? Theme.amber : Theme.textHi
    readonly property string stateText: [lastUsed ? "most recently used" : "",
        Usage.lastUsedText(record), quotaStateText].filter(part => part !== "").join(" · ")
    readonly property string quotaStateText: {
        if (!record)
            return "No reading";
        if (record.status !== "ok") {
            switch (record.kind) {
            case "expired": return "Token expired";
            case "rate": return "Rate limited";
            case "config": return "Configuration required";
            default: return "Usage unavailable";
            }
        }
        const parts = [];
        if (record.plan)
            parts.push(record.plan);
        if (best)
            parts.push("best available");
        if (providerStale || record.stale === true)
            parts.push("last known");
        return parts.length > 0 ? parts.join(" · ") : "Subscription";
    }

    width: parent ? parent.width : 0
    height: summary.height
        + (usageDetails.visible ? spacing + usageDetails.height : 0)
        + (errorPanel.visible ? spacing + errorPanel.height : 0)
    spacing: 4

    Rectangle {
        id: summary

        width: parent.width
        height: 52
        radius: 10
        color: root.expanded || summaryMouse.containsMouse || activeFocus
            ? Theme.chipHover : Theme.chip
        activeFocusOnTab: visible

        Behavior on color {
            ColorAnimation { duration: Theme.chipFadeDuration }
        }

        Column {
            anchors.left: parent.left
            anchors.leftMargin: 12
            anchors.right: metric.left
            anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2

            Text {
                width: parent.width
                text: root.record && root.record.label
                    ? root.record.label : "Account"
                font.family: Theme.fontMenu
                font.pixelSize: Theme.fontSecondary
                font.weight: Theme.weightSemibold
                color: Theme.textHi
                elide: Text.ElideRight
            }

            Text {
                width: parent.width
                text: root.stateText
                font.family: Theme.fontMenu
                font.pixelSize: Theme.fontMicro
                color: root.ok ? Theme.textFaint : Theme.redText
                elide: Text.ElideRight
            }
        }

        Row {
            id: metric
            anchors.right: disclosure.left
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            spacing: 3

            Text {
                text: root.remaining >= 0 ? root.remaining : "—"
                font.family: Theme.fontNumeric
                font.pixelSize: Theme.fontBody
                font.weight: Theme.weightSemibold
                font.features: Theme.tabularNumberFeatures
                color: root.tone
            }

            Text {
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 2
                text: root.remaining >= 0 ? "% left" : ""
                font.family: Theme.fontMenu
                font.pixelSize: Theme.fontMicro
                color: Theme.textFaint
            }
        }

        Sym {
            id: disclosure
            anchors.right: parent.right
            anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            name: root.expanded ? "expand_less" : "expand_more"
            size: Theme.fontBody
            color: root.expanded ? Theme.textMid : Theme.textFaint
        }

        MouseArea {
            id: summaryMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.toggled()
        }

        Keys.onPressed: event => {
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                    || event.key === Qt.Key_Space) {
                root.toggled();
                event.accepted = true;
            }
        }

        Accessible.role: Accessible.Button
        Accessible.name: (root.record && root.record.label
            ? root.record.label : "Account") + " usage details"
        Accessible.description: root.stateText
        Accessible.onPressAction: root.toggled()
    }

    DrawerUsageDetails {
        id: usageDetails

        visible: root.expanded && root.ok
        width: parent.width
        // Nested JSON arrays become QML sequence values inside a Repeater
        // delegate, so Array.isArray() rejects otherwise valid windows.
        windows: root.record && root.record.windows
            ? root.record.windows : []
        credits: root.record ? (root.record.credits ?? null) : null
        stale: root.providerStale || (root.record && root.record.stale === true)
    }

    Rectangle {
        id: errorPanel

        visible: root.expanded && !root.ok
        width: parent.width
        height: accountError.implicitHeight + 24
        radius: 10
        color: Theme.redBgSoft

        Text {
            id: accountError
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.margins: 12
            anchors.verticalCenter: parent.verticalCenter
            text: root.record && root.record.message
                ? root.record.message : "This subscription has no usable reading."
            font.family: Theme.fontMenu
            font.pixelSize: Theme.fontCaption
            color: Theme.textLow
            wrapMode: Text.WordWrap
        }
    }
}
