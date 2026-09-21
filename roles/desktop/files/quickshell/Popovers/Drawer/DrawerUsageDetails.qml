pragma ComponentBehavior: Bound
import QtQuick
import "../../Common"
import ".."

// Quota details shared by a direct provider reading and each expanded
// CLIProxyAPI account. Keeping the account wrapper separate lets the drawer
// compare every subscription without duplicating the window presentation.
Column {
    id: root

    property var windows: []
    property var credits: null
    property bool stale: false

    readonly property var resetRows: windows.filter(w => w.resetsAt)
    readonly property real contentHeight: {
        let total = stale ? 38 : 0;
        let blocks = stale ? 1 : 0;
        for (const window of windows) {
            total += windowCardHeight(window);
            blocks++;
        }
        if (credits !== null) {
            total += 44;
            blocks++;
        }
        if (resetRows.length > 0) {
            total += resetSectionHeight();
            blocks++;
        }
        return total + Math.max(0, blocks - 1) * spacing;
    }

    width: parent ? parent.width : 0
    height: contentHeight
    spacing: 4

    function windowCardHeight(window) {
        const hasUsage = typeof window.used === "number"
            && isFinite(window.used);
        const hasReset = window.resetsAt !== null
            && window.resetsAt !== undefined;
        let content = 30;
        let additions = 0;
        if (hasUsage) {
            content += 6;
            additions++;
        }
        if (hasReset) {
            content += 14;
            additions++;
        }
        return content + additions * 8 + 20;
    }

    function resetSectionHeight() {
        const header = Theme.sectionHeaderHeight + 8;
        return header + resetRows.length * 28
            + resetRows.length * 2;
    }

    function windowSpan(window) {
        if (!window.windowSecs)
            return window.label;
        const hours = window.windowSecs / 3600;
        if (hours < 24)
            return Math.round(hours) + "-hour window";
        return Math.round(hours / 24) + "-day window";
    }

    Rectangle {
        visible: root.stale
        width: parent ? parent.width : 0
        height: 38
        radius: 10
        color: Theme.amberBgSoft

        Row {
            anchors.left: parent.left
            anchors.leftMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            spacing: 8

            Sym {
                anchors.verticalCenter: parent.verticalCenter
                name: "schedule"
                size: Theme.fontSecondary
                color: Theme.amber
            }

            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "Showing last known usage"
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.secondary
                font.weight: Theme.weightMedium
                color: Theme.textMid
            }
        }
    }

    Repeater {
        model: root.windows

        delegate: Rectangle {
            id: windowCard

            required property var modelData
            readonly property bool hasUsage: typeof modelData.used === "number"
                && isFinite(modelData.used)
            readonly property int remaining: hasUsage ? Math.max(0,
                Math.round(100 - Number(modelData.used))) : -1
            readonly property bool low: hasUsage
                && remaining <= Settings.modOpts.usage.warnAt
            readonly property bool exhausted: hasUsage
                && remaining <= Settings.modOpts.usage.critAt

            width: parent ? parent.width : 0
            height: root.windowCardHeight(modelData)
            radius: 10
            color: Theme.chip

            Column {
                id: cardColumn
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.margins: 12
                anchors.verticalCenter: parent.verticalCenter
                spacing: 8

                Item {
                    width: parent.width
                    height: 30

                    Column {
                        anchors.left: parent.left
                        anchors.right: usageValue.left
                        anchors.rightMargin: 12
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 1

                        Text {
                            width: parent.width
                            text: windowCard.modelData.label
                            font.family: Theme.fontMenu
                            font.pixelSize: Theme.typography.primary
                            font.weight: Theme.weightSemibold
                            color: Theme.textHi
                            elide: Text.ElideRight
                        }

                        Text {
                            width: parent.width
                            text: root.windowSpan(windowCard.modelData)
                            font.family: Theme.fontMenu
                            font.pixelSize: Theme.typography.metadata
                            color: Theme.textFaint
                            elide: Text.ElideRight
                        }
                    }

                    Row {
                        id: usageValue
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        spacing: 3

                        Text {
                            text: windowCard.hasUsage ? windowCard.remaining : "—"
                            font.family: Theme.fontNumeric
                            font.pixelSize: Theme.typography.title
                            font.weight: Theme.weightSemibold
                            font.letterSpacing: -0.5
                            font.features: Theme.tabularNumberFeatures
                            color: windowCard.exhausted ? Theme.redText
                                : windowCard.low ? Theme.amber : Theme.textHi
                        }

                        Text {
                            anchors.bottom: parent.bottom
                            anchors.bottomMargin: 3
                            text: windowCard.hasUsage ? "% left" : "unavailable"
                            font.family: Theme.fontMenu
                            font.pixelSize: Theme.typography.metadata
                            color: Theme.textFaint
                        }
                    }
                }

                Rectangle {
                    visible: windowCard.hasUsage
                    width: parent.width
                    height: 6
                    radius: 3
                    color: Qt.rgba(1, 1, 1, 0.10)

                    Rectangle {
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        width: parent.width * windowCard.remaining / 100
                        radius: 3
                        color: windowCard.exhausted ? Theme.red
                            : windowCard.low ? Theme.amber : Theme.accent
                    }
                }

                Item {
                    visible: windowCard.modelData.resetsAt ? true : false
                    width: parent.width
                    height: 14

                    Text {
                        anchors.left: parent.left
                        text: windowCard.modelData.resetsAt
                            ? "resets in " + Usage.formatReset(
                                windowCard.modelData.resetsAt) : ""
                        font.family: Theme.fontMenu
                        font.pixelSize: Theme.typography.metadata
                        color: Theme.textMid
                    }

                    Text {
                        anchors.right: parent.right
                        text: windowCard.modelData.resetsAt
                            ? Usage.formatResetAbs(
                                windowCard.modelData.resetsAt) : ""
                        font.family: Theme.fontNumeric
                        font.pixelSize: Theme.typography.metadata
                        font.features: Theme.tabularNumberFeatures
                        color: Theme.textFaint
                    }
                }
            }
        }
    }

    // Pay-as-you-go / banked credits, when the provider reports them.
    Item {
        id: creditsRow

        readonly property bool hasMeter: root.credits !== null
            && root.credits.used !== null && root.credits.used !== undefined
            && root.credits.limit !== null && root.credits.limit !== undefined
        readonly property string displayValue: {
            if (!root.credits)
                return "";
            if (root.credits.unlimited)
                return "Unlimited";
            if (hasMeter)
                return "$" + Number(root.credits.used).toFixed(2);
            if (root.credits.remaining !== null
                    && root.credits.remaining !== undefined)
                return Number(root.credits.remaining).toLocaleString(
                    Qt.locale("en_US"), "f",
                    root.credits.remaining % 1 === 0 ? 0 : 2);
            return "—";
        }
        readonly property string displaySuffix: !root.credits
            || root.credits.unlimited ? ""
            : hasMeter ? " / $" + Number(root.credits.limit).toFixed(2)
            : root.credits.remaining !== null
                && root.credits.remaining !== undefined ? " left" : ""

        visible: root.credits !== null
        width: parent ? parent.width : 0
        height: 44

        Column {
            anchors.left: parent.left
            anchors.leftMargin: 12
            anchors.right: creditsValue.left
            anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            spacing: 1

            Text {
                width: parent.width
                text: root.credits && root.credits.label
                    ? root.credits.label : "Extra usage"
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.primary
                font.weight: Theme.weightMedium
                color: Theme.textHi
                elide: Text.ElideRight
            }

            Text {
                width: parent.width
                text: creditsRow.hasMeter ? "beyond plan limits" : "available balance"
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.metadata
                color: Theme.textFaint
            }
        }

        Text {
            id: creditsValue
            anchors.right: parent.right
            anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.StyledText
            text: "<b>" + creditsRow.displayValue + "</b>"
                + creditsRow.displaySuffix
            font.family: Theme.fontNumeric
            font.pixelSize: Theme.typography.primary
            font.features: Theme.tabularNumberFeatures
            color: Theme.textHi
        }
    }

    Column {
        visible: root.resetRows.length > 0
        width: parent ? parent.width : 0
        height: visible ? root.resetSectionHeight() : 0
        spacing: 2

        SectionLabel {
            width: parent.width
            text: "UPCOMING RESETS"
        }

        Repeater {
            model: root.resetRows

            delegate: Item {
                id: resetRow

                required property var modelData

                width: parent ? parent.width : 0
                height: 28

                Text {
                    anchors.left: parent.left
                    anchors.leftMargin: 12
                    anchors.verticalCenter: parent.verticalCenter
                    text: resetRow.modelData.label
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.secondary
                    color: Theme.textMid
                }

                Text {
                    anchors.right: parent.right
                    anchors.rightMargin: 12
                    anchors.verticalCenter: parent.verticalCenter
                    text: Usage.formatResetAbs(resetRow.modelData.resetsAt)
                    font.family: Theme.fontNumeric
                    font.pixelSize: Theme.typography.secondary
                    font.weight: Theme.weightSemibold
                    font.features: Theme.tabularNumberFeatures
                    color: Theme.textHi
                }
            }
        }
    }
}
