pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import "../Common"

SettingsGroup {
    id: root
    readonly property SystemSettingsBackend service: SystemSettings.sshServer
    readonly property var sshState: service.snapshot
    readonly property string address: (sshState.addresses || [])[0] || ""
    readonly property string command: "ssh " + ((sshState.ports || [22])[0] !== 22
        ? "-p " + sshState.ports[0] + " " : "") + (sshState.user || "") + "@" + address
    title: I18n.tr("SSH Server")

    Claim {
        active: root.visible && Settings.panelOpen
        onClaimed: root.service.acquire()
        onReleased: root.service.release()
    }
    SystemServiceStatus { width: parent.width; service: root.service }
    SwitchRow {
        width: parent.width
        label: I18n.tr("Enable SSH Server")
        dirty: false
        resetKeys: []
        description: I18n.tr("Allow remote login with your account password or SSH key. Remembers your choice after restarting.")
        checked: root.sshState.enabled === true
        disabledReason: !root.service.loaded ? I18n.tr("Checking…")
            : !root.sshState.available ? I18n.tr("Unavailable")
            : root.service.busy ? I18n.tr("Applying…") : ""
        onToggled: value => root.service.run({action: "set-enabled", enabled: value})
    }
    ValueRow {
        width: parent.width
        label: I18n.tr("Status")
        value: !root.service.loaded ? I18n.tr("Checking…")
            : !root.sshState.available ? I18n.tr("Unavailable")
            : root.sshState.active ? I18n.tr("Running")
            : root.sshState.enabled ? I18n.tr("Not running") : I18n.tr("Off")
        SettingsAction {
            visible: root.sshState.enabled === true && !root.sshState.active
            text: I18n.tr("Try again")
            enabled: !root.service.busy
            onTriggered: root.service.run({action: "set-enabled", enabled: true})
        }
    }
    ValueRow {
        width: parent.width
        visible: root.sshState.active === true && root.address !== ""
        label: I18n.tr("Connect with")
        value: root.command
        SettingsAction {
            text: I18n.tr("Copy")
            onTriggered: Quickshell.clipboardText = root.command
        }
    }
}
