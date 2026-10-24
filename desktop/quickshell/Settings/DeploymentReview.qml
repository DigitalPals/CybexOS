import QtQuick
import "../Common"

SettingsGroup {
    id: root
    property string kind: ""
    title: I18n.tr("System change")
    visible: Updates.deployment.changeKind === kind
    SettingsHint { width: parent.width; text: Updates.runPhaseLabel }
    SettingsHint { width: parent.width; visible: Updates.deployment.error !== undefined && Updates.deployment.error !== ""; text: Updates.deployment.error || ""; tone: "error" }
    Text {
        width: parent.width; visible: Updates.ready
        text: Updates.deployment.changes || ""
        textFormat: Text.PlainText
        color: Theme.textMid; font.family: Theme.fontMono; font.pixelSize: Theme.typography.secondary
        wrapMode: Text.WrapAnywhere
    }
    ValueRow {
        width: parent.width; label: Updates.ready ? I18n.tr("Built changes") : I18n.tr("Deployment")
        SettingsAction { text: I18n.tr("View log"); onTriggered: Updates.openLog() }
        SettingsAction { text: I18n.tr("Apply reviewed change"); primary: true; visible: Updates.ready; onTriggered: Updates.apply() }
        SettingsAction { text: I18n.tr("Confirm this boot"); visible: Updates.deployment.state === "awaiting-login"; onTriggered: Updates.confirm() }
    }
}
