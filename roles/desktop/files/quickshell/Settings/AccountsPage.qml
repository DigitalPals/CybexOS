pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import "../Common"

// Online accounts: the GNOME Online Accounts on this computer, and whether
// CybexOS reads their calendars. Signing in happens in the account window
// that Add account opens; this page lists what is connected, and removes.
//
// Status is hint text, not a standing control: loading and updating are
// read on the page, and an error brings its own Refresh.
SettingsPage {
    id: page
    readonly property SystemSettingsBackend service: SystemSettings.accounts
    readonly property var accounts: service.snapshot.accounts || []
    property string removing: ""

    Claim {
        active: page.visible && Settings.panelOpen
        onClaimed: page.service.acquire()
        onReleased: { page.removing = ""; page.service.release(); }
    }

    function openAccountWindow() {
        SystemSettings.openExternal("accounts");
    }

    Column {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Theme.settingsGroupSpacing

        SettingsGroup {
            width: parent.width
            title: I18n.tr("Online accounts")

            // The group's note, clear of the rule that opens the first row.
            Item {
                width: parent.width
                height: note.height + Theme.settingsContentSpacing

                SettingsHint {
                    id: note
                    width: parent.width
                    maximumLines: 5
                    text: I18n.tr("Connect an account to show its calendars in CybexOS. Signing in opens a separate account window and your browser.")
                }
            }
            SettingsHint {
                width: parent.width
                text: page.service.error !== "" ? ""
                    : page.service.busy ? "Updating…"
                    : !page.service.loaded ? "Loading accounts…" : ""
            }
            ValueRow {
                width: parent.width
                visible: page.service.error !== ""
                label: I18n.tr("Status")
                hint: page.service.error
                hintTone: "error"

                SettingsAction {
                    text: I18n.tr("Refresh")
                    glyph: "refresh"
                    enabled: !page.service.busy && !page.service.loading
                    onTriggered: {
                        page.service.error = "";
                        page.service.refresh();
                    }
                }
            }

            ValueRow {
                width: parent.width
                visible: page.service.loaded && page.accounts.length === 0
                label: I18n.tr("No accounts connected")

                SettingsAction {
                    text: I18n.tr("Add account")
                    glyph: "add"
                    primary: true
                    enabled: !SystemSettings.externalBusy
                    onTriggered: page.openAccountWindow()
                }
            }

            Repeater {
                model: ScriptModel { values: page.accounts.map(a => a.id) }

                delegate: RowCluster {
                    id: account
                    required property string modelData
                    readonly property var info: page.accounts.find(a => a.id === modelData)
                        || {id: "", provider: "", identity: "", locked: true, attention: false, calendar: false, calendarDisabled: true}
                    readonly property bool confirming: page.removing === info.id
                    width: parent.width

                    ValueRow {
                        width: parent.width
                        label: account.info.identity || account.info.provider
                        hint: [account.info.provider,
                            account.info.locked ? "Managed by your administrator"
                            : account.info.attention ? "Needs attention: sign in again"
                            : "Connected"].filter(part => part !== "").join(" · ")
                        hintTone: account.info.attention && !account.info.locked ? "warning" : "info"

                        SettingsAction {
                            visible: account.info.attention && !account.info.locked
                            text: I18n.tr("Reconnect")
                            glyph: "refresh"
                            enabled: !SystemSettings.externalBusy
                            Accessible.name: "Reconnect " + account.info.identity
                            onTriggered: page.openAccountWindow()
                        }
                        SettingsAction {
                            visible: !account.info.locked && !account.confirming
                            text: I18n.tr("Remove…")
                            glyph: "delete"
                            danger: true
                            enabled: !page.service.busy
                            Accessible.name: "Remove " + account.info.identity + " from this computer"
                            onTriggered: page.removing = account.info.id
                        }
                    }
                    SwitchRow {
                        width: parent.width
                        divider: false
                        visible: account.info.calendar
                        label: I18n.tr("Use calendars")
                        accessibleName: "Use calendars from " + (account.info.identity || account.info.provider)
                        checked: !account.info.calendarDisabled
                        disabledReason: account.info.locked ? "Managed account" : page.service.busy ? "Updating…" : ""
                        onToggled: value => page.service.run({action: "calendar", id: account.info.id, enabled: value})
                    }
                    ValueRow {
                        width: parent.width
                        divider: false
                        visible: account.confirming
                        label: I18n.tr("Remove from this computer?")
                        hint: account.info.identity
                            ? I18n.format("Other applications on this computer also lose access to %1. The online account and its data stay.", [account.info.identity])
                            : I18n.tr("Other applications on this computer also lose access to this account. The online account and its data stay.")
                        hintTone: "warning"

                        SettingsAction {
                            text: I18n.tr("Remove account")
                            danger: true
                            enabled: !page.service.busy
                            onTriggered: {
                                page.service.run({action: "remove", id: account.info.id, confirmed: true});
                                page.removing = "";
                            }
                        }
                        SettingsAction {
                            text: I18n.tr("Cancel")
                            onTriggered: page.removing = ""
                        }
                    }
                }
            }

            // With accounts listed, adding another is no longer the page's
            // one job, so the button stops leading.
            ValueRow {
                width: parent.width
                visible: page.accounts.length > 0
                label: I18n.tr("Connect another account")

                SettingsAction {
                    text: I18n.tr("Add account")
                    glyph: "add"
                    enabled: !SystemSettings.externalBusy
                    onTriggered: page.openAccountWindow()
                }
            }
        }
    }
}
