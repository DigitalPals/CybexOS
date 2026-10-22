pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import "../Common"

Surface {
    id: root
    implicitWidth: Theme.drawerWidth
    spacing: 16
    Text { width: parent.width; text: I18n.tr("Updates"); color: Theme.textHi; font.pixelSize: Theme.typography.heading; font.bold: true }
    Text { width: parent.width; text: Updates.summary; color: Theme.textHi; wrapMode: Text.Wrap }
    Text {
        width: parent.width
        text: "NixOS packages: " + (Updates.sources.upstream.state || "Checking…")
            + "\nNerdOS: " + Updates.installedVersion + (Updates.projectVersion ? " → " + Updates.projectVersion : "")
            + " · " + (Updates.sources.nerdos.state || "Checking…")
        color: Theme.textHi; wrapMode: Text.Wrap
    }
    Text { width: parent.width; visible: text !== ""; text: Updates.error; color: Theme.textHi; wrapMode: Text.Wrap; textFormat: Text.PlainText }
    Row {
        spacing: 8
        Repeater {
            model: [{label:"Upstream", scope:"upstream"}, {label:"NerdOS", scope:"nerdos"}, {label:"Both", scope:"both"}]
            ActionButton {
                required property var modelData
                width: 106; height: 38
                label: I18n.tr("Preview") + " " + modelData.label
                tint: Theme.textHi
                enabled: !Updates.runActive && !["awaiting-boot", "awaiting-login", "recovery-failed"].includes(Updates.deployment.state)
                onTriggered: Updates.stage(modelData.scope)
            }
        }
    }
    Text { width: parent.width; text: Updates.runPhaseLabel; color: Theme.textHi; wrapMode: Text.Wrap }
    ScrollView {
        width: parent.width
        height: Math.min(240, details.implicitHeight + 8)
        visible: Updates.projectNotes !== "" || Updates.ready
        clip: true
        contentWidth: availableWidth
        Column {
            id: details
            width: parent.width
            spacing: 12
            Text {
                width: parent.width; text: Updates.projectNotes
                color: Theme.textHi; wrapMode: Text.Wrap; textFormat: Text.PlainText
            }
            Text {
                width: parent.width; visible: Updates.ready
                text: I18n.tr("Built package changes") + "\n" + (Updates.deployment.changes || I18n.tr("No package closure changes"))
                color: Theme.textHi; font.family: "monospace"; font.pixelSize: Theme.typography.metadata
                wrapMode: Text.Wrap; textFormat: Text.PlainText
            }
        }
    }
    ActionButton {
        width: parent.width; height: 42; visible: Updates.ready
        label: I18n.tr("Apply reviewed generation"); tint: Theme.textHi
        onTriggered: Updates.apply()
    }
    Text {
        width: parent.width; visible: text !== ""; text: Updates.deployment.recovery || ""
        color: Theme.textHi; wrapMode: Text.Wrap
    }
    Row {
        spacing: 8
        Repeater {
            model: [{label:"Check sources", action:"check"}, {label:"Recovery", action:"openRecoveryPoints"}, {label:"Rollback", action:"rollback"}]
            ActionButton {
                required property var modelData
                width: 106; height: 36
                label: I18n.tr(modelData.label); tint: Theme.textHi
                enabled: !Updates.runActive
                onTriggered: Updates[modelData.action]()
            }
        }
    }
    ActionButton {
        width: parent.width; height: 40; visible: Updates.deployment.state === "awaiting-login"
        label: I18n.tr("Confirm this boot and desktop"); tint: Theme.textHi
        onTriggered: Updates.confirm()
    }
    ActionButton {
        width: parent.width; visible: Boolean(Updates.deployment.transaction)
        label: I18n.tr("Open private build log"); tint: Theme.textHi
        onTriggered: Updates.openLog()
    }
    ActionButton {
        width: parent.width; height: 40; enabled: !Updates.runActive
        label: I18n.tr("Device firmware…"); tint: Theme.textHi
        onTriggered: Updates.openFirmware()
    }
    Text {
        width: parent.width; color: Theme.textHi; font.pixelSize: Theme.typography.secondary
        text: I18n.tr("Review firmware separately in a terminal. Firmware changes are not reverted by a system rollback.")
        wrapMode: Text.Wrap
    }
    Text { width: parent.width; text: "Updates preserve your personal modules, widgets, preferences and data. Reboots are always your choice."; color: Theme.textHi; font.pixelSize: Theme.typography.secondary; wrapMode: Text.Wrap }
}
