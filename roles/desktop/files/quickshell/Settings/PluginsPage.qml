pragma ComponentBehavior: Bound
import QtQuick
import "../Common"

SettingsPage {
    id: page
    function run(args) {
        UserPlugins.enqueue(["python3", UserPlugins.helper].concat(args));
    }
    Column {
        width: parent.width
        spacing: Theme.settingsGroupSpacing
        SettingsAction {
            text: "Configure bar widgets"
            glyph: "widgets"
            onTriggered: Settings.page = "bar"
        }
        SettingsGroup {
            width: parent.width
            title: "Install plugin"
            rowSpacing: Theme.settingsContentSpacing
            Text {
                width: parent.width
                leftPadding: Theme.settingsMarkInset
                wrapMode: Text.WordWrap
                text: "Plugins run as your desktop user. Install only packages you trust. New packages start disabled."
                color: Theme.textMid
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.secondary
            }
            SettingsField {
                id: repository
                x: Theme.settingsMarkInset
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.control
                font.weight: Theme.weightRegular
                width: parent.width - x
                placeholderText: "Git repository URL or local path"
                Accessible.name: "Plugin repository"
            }
            SettingsAction {
                x: Theme.settingsMarkInset
                text: UserPlugins.busy ? "Working…" : "Install plugin"
                glyph: "add"
                enabled: !UserPlugins.busy && repository.text.trim() !== ""
                onTriggered: page.run(["add", repository.text.trim()])
            }
            Text {
                width: parent.width
                wrapMode: Text.WrapAnywhere
                visible: text !== ""
                leftPadding: Theme.settingsMarkInset
                text: UserPlugins.error || UserPlugins.operationResult
                color: UserPlugins.error ? Theme.redText : Theme.textMid
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.secondary
            }
        }
        Repeater {
            model: UserPlugins.plugins
            delegate: SettingsGroup {
                id: row
                required property var modelData
                property bool confirmRemoval: false
                width: parent.width
                title: row.modelData.name
                rowSpacing: Theme.settingsContentSpacing
                Text {
                    width: parent.width
                    leftPadding: Theme.settingsMarkInset
                    text: row.modelData.id + " · " + (row.modelData.version || "Unknown version")
                    color: Theme.textDim
                    font.family: Theme.fontMono
                    font.pixelSize: Theme.typography.secondary
                    wrapMode: Text.WrapAnywhere
                }
                Text {
                    width: parent.width
                    visible: text !== ""
                    leftPadding: Theme.settingsMarkInset
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.secondary
                    text: row.modelData.error || Object.keys(OmarchyPlugins.errors)
                        .filter(key => key.startsWith(row.modelData.id + ":"))
                        .map(key => OmarchyPlugins.errors[key]).join("\n")
                    color: Theme.redText
                    wrapMode: Text.WrapAnywhere
                }
                Flow {
                    x: Theme.settingsMarkInset
                    width: parent.width - x
                    spacing: Theme.settingsContentSpacing
                    enabled: !UserPlugins.busy
                    SettingsAction {
                        text: row.modelData.enabled ? "Disable" : "Enable"
                        glyph: "power_settings_new"
                        onTriggered: page.run([row.modelData.enabled ? "disable" : "enable", row.modelData.id])
                    }
                    SettingsAction {
                        text: "Preview update"
                        glyph: "difference"
                        onTriggered: page.run(["update", row.modelData.id, "--preview"])
                    }
                    SettingsAction {
                        text: "Update"
                        glyph: "update"
                        onTriggered: page.run(["update", row.modelData.id])
                    }
                    SettingsAction {
                        text: row.confirmRemoval ? "Confirm remove files" : "Remove"
                        glyph: "delete"
                        danger: true
                        onTriggered: {
                            if (row.confirmRemoval) page.run(["remove", row.modelData.id]);
                            else row.confirmRemoval = true;
                        }
                    }
                    SettingsAction {
                        visible: row.confirmRemoval
                        text: "Cancel"
                        glyph: "close"
                        onTriggered: row.confirmRemoval = false
                    }
                }
                SettingsField {
                    id: cloneId
                    x: Theme.settingsMarkInset
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.control
                    font.weight: Theme.weightRegular
                    width: parent.width - x
                    placeholderText: "New ID for a custom copy"
                    Accessible.name: "Clone ID for " + row.modelData.id
                }
                SettingsAction {
                    x: Theme.settingsMarkInset
                    text: "Clone"
                    glyph: "content_copy"
                    enabled: !UserPlugins.busy && cloneId.text.trim() !== ""
                    onTriggered: page.run(["clone", row.modelData.id, cloneId.text.trim()])
                }
            }
        }
    }
}
