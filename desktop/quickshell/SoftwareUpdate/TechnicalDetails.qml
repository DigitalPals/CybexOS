pragma ComponentBehavior: Bound
import QtQuick
import "../Common"
import "../Common/UpdatesHelpers.js" as Helpers

// The layer for people who want it: sources, programs without a window,
// the size change, the exact closure diff, logs and source choices.
Rectangle {
    id: root

    property var service: Updates
    property bool fullList: false
    readonly property var review: service.review
    readonly property var tools: review.tools.slice(0, 40)
    readonly property string size: Helpers.sizeChange(review.sizeChange)
    readonly property bool sourcesChanged: service.selectedScope !== ""
        && service.selectedScope !== (service.deployment.scope || "")

    function scopeName(scope) {
        return scope === "both" ? I18n.tr("NixOS packages and Cybex OS")
            : scope === "upstream" ? I18n.tr("NixOS packages")
            : scope === "cybexos" ? I18n.tr("Cybex OS") : I18n.tr("Your system configuration");
    }

    implicitHeight: body.implicitHeight + Theme.scaled(28)
    radius: Theme.chipRadius + 3
    color: Theme.insetSurface
    border.width: 1
    border.color: Theme.hairlineSoft

    component Label: Text {
        width: parent ? parent.width : 0
        color: Theme.textMid
        font.family: Theme.fontMenu
        font.pixelSize: Theme.typography.secondary
        wrapMode: Text.Wrap
        textFormat: Text.PlainText
    }
    component Heading: Text {
        color: Theme.textDim
        font.family: Theme.fontMenu
        font.pixelSize: Theme.typography.metadata
        font.weight: Theme.weightSemibold
        font.capitalization: Font.AllUppercase
        font.letterSpacing: 0.6
        textFormat: Text.PlainText
    }

    Column {
        id: body
        x: Theme.scaled(14)
        y: Theme.scaled(14)
        width: parent.width - Theme.scaled(28)
        spacing: Theme.scaled(10)

        Label {
            text: I18n.format("Sources: %1", [root.scopeName(root.service.deployment.scope || "")])
        }
        Label {
            visible: root.size !== ""
            text: I18n.format("Size change on disk: %1", [root.size])
        }

        Heading {
            visible: root.tools.length > 0
            text: I18n.tr("Programs without a window")
        }
        Repeater {
            model: root.tools
            delegate: Item {
                id: toolRow
                required property var modelData
                width: body.width
                height: Math.max(toolName.implicitHeight, toolVersion.height) + Theme.scaled(2)
                Text {
                    id: toolName
                    anchors.left: parent.left
                    anchors.right: toolVersion.left
                    anchors.rightMargin: Theme.scaled(8)
                    anchors.verticalCenter: parent.verticalCenter
                    text: toolRow.modelData.name
                    color: Theme.textMid
                    font.family: Theme.fontNumeric
                    font.pixelSize: Theme.typography.secondary
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                }
                VersionPair {
                    id: toolVersion
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    compact: true
                    before: toolRow.modelData.before
                    after: toolRow.modelData.after
                    kind: toolRow.modelData.kind
                }
            }
        }
        Label {
            visible: root.review.tools.length > root.tools.length
            text: I18n.format("And %1 more", [root.review.tools.length - root.tools.length])
        }

        Heading {
            visible: root.service.sourcesLoaded && root.service.sources.upstream.state === "available"
                && root.service.sources.cybexos.state === "available"
            text: I18n.tr("Sources to include")
        }
        Repeater {
            model: root.service.sourcesLoaded && root.service.sources.upstream.state === "available"
                && root.service.sources.cybexos.state === "available" ? ["upstream", "cybexos"] : []
            delegate: Row {
                id: sourceRow
                required property string modelData
                readonly property string name: root.scopeName(modelData)
                spacing: Theme.scaled(10)
                Toggle {
                    objectName: sourceRow.modelData === "upstream" ? "updateSelectUpstream" : "updateSelectCybexOS"
                    metrics: Theme.switchCompact
                    checked: root.service.selectedSources.includes(sourceRow.modelData)
                    enabled: !root.service.runActive
                    accessibleName: I18n.format("Include %1", [sourceRow.name])
                    onToggled: value => root.service.selectSource(sourceRow.modelData, value)
                }
                Text {
                    objectName: sourceRow.modelData === "upstream" ? "updateUpstreamLabel" : "updateCybexOSLabel"
                    anchors.verticalCenter: parent.verticalCenter
                    text: sourceRow.name
                    color: Theme.textHi
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.primary
                    textFormat: Text.PlainText
                }
            }
        }

        Flow {
            width: parent.width
            spacing: Theme.scaled(8)
            UpdateButton {
                objectName: "updatePrepareSources"
                visible: root.sourcesChanged
                primary: true
                text: I18n.tr("Prepare Again With These Sources")
                enabled: !root.service.runActive
                onTriggered: root.service.restage()
            }
            UpdateButton {
                objectName: "updateFullList"
                text: root.fullList ? I18n.tr("Hide Full Change List") : I18n.tr("Full Change List")
                onTriggered: root.fullList = !root.fullList
            }
            UpdateButton {
                visible: !!root.service.deployment.transaction
                text: I18n.tr("Build Log")
                onTriggered: root.service.openLog()
            }
            UpdateButton {
                text: I18n.tr("Update History")
                onTriggered: root.service.openRecoveryPoints()
            }
            UpdateButton {
                objectName: "updateDiscard"
                visible: root.service.actions.discard
                text: I18n.tr("Discard Prepared Update")
                onTriggered: root.service.discard()
            }
        }

        Text {
            objectName: "updateChanges"
            width: parent.width
            visible: root.fullList
            text: root.service.deployment.changes || I18n.tr("No package changes")
            color: Theme.textMid
            font.family: Theme.fontMono
            font.pixelSize: Theme.typography.metadata
            wrapMode: Text.WrapAnywhere
            textFormat: Text.PlainText
        }
    }
}
