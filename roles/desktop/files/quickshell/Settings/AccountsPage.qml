pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import "../Common"

SettingsPage {
    id: page
    readonly property SystemSettingsBackend service: SystemSettings.accounts
    property string removing: ""
    Claim {
        active: page.visible && Settings.panelOpen
        onClaimed: page.service.acquire()
        onReleased: { page.removing = ""; page.service.release(); }
    }
    Column {
        width: parent.width
        spacing: Theme.settingsGroupSpacing
        SystemServiceStatus { width: parent.width; service: page.service }
        SettingsGroup {
            width: parent.width
            title: "Online accounts"
            SettingsHint {
                width: parent.width
                maximumLines: 5
                text: "Connect your account to show its calendars in CybexOS. Account sign-in opens a separate account window and your browser."
            }
            SettingsAction {
                text: "Add or reconnect an account"
                enabled: !SystemSettings.externalBusy
                onTriggered: SystemSettings.openExternal("accounts")
            }
            SettingsHint {
                width: parent.width
                text: page.service.loaded && !(page.service.snapshot.accounts || []).length ? "No online accounts connected." : ""
            }
        }
        Repeater {
            model: ScriptModel { values: (page.service.snapshot.accounts || []).map(a => a.id) }
            delegate: SettingsGroup {
                id: account
                required property string modelData
                readonly property var info: (page.service.snapshot.accounts || []).find(a => a.id === modelData)
                    || {id: "", provider: "", identity: "", locked: true, attention: false, calendar: false, calendarDisabled: true}
                width: parent.width
                title: info.provider
                SettingsHint { width: parent.width; text: account.info.identity }
                SettingsHint {
                    width: parent.width
                    tone: account.info.attention ? "warning" : "info"
                    text: account.info.locked ? "Managed by your administrator"
                        : account.info.attention ? "This account needs attention. Open the account window to reconnect." : "Connected"
                }
                SwitchRow {
                    width: parent.width
                    visible: account.info.calendar
                    label: "Use calendars"
                    checked: !account.info.calendarDisabled
                    disabledReason: account.info.locked ? "Managed account" : page.service.busy ? "Updating…" : ""
                    onToggled: value => page.service.run({action: "calendar", id: account.info.id, enabled: value})
                }
                SettingsAction {
                    visible: !account.info.locked && page.removing !== account.info.id
                    text: "Remove from this computer"
                    danger: true
                    enabled: !page.service.busy
                    onTriggered: page.removing = account.info.id
                }
                Column {
                    width: parent.width
                    visible: page.removing === account.info.id
                    SettingsHint {
                        width: parent.width
                        maximumLines: 5
                        tone: "warning"
                        text: "Remove " + account.info.identity + "? Other applications on this computer will also lose access. Your online account and remote data will remain."
                    }
                    Flow {
                        width: parent.width
                        enabled: !page.service.busy
                        SettingsAction {
                            text: "Remove account"; danger: true
                            onTriggered: {
                                page.service.run({action: "remove", id: account.info.id, confirmed: true});
                                page.removing = "";
                            }
                        }
                        SettingsAction { text: "Cancel"; onTriggered: page.removing = "" }
                    }
                }
            }
        }
    }
}
