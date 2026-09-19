pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls as Controls
import "../Common"

SettingsPage {
    id: page
    function run(args) {
        UserPlugins.enqueue(["python3", UserPlugins.helper].concat(args));
    }
    Column {
        width: parent.width
        spacing: Theme.panelSectionSpacing
        Text {
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Plugins run as your desktop user. Install only packages you trust. New packages start disabled."
            color: Theme.textMid
            font.family: Theme.fontMenu
            font.pixelSize: Theme.fontCaption
        }
        Controls.TextField {
            id: repository
            width: parent.width
            placeholderText: "Git repository URL or local path"
            Accessible.name: "Plugin repository"
        }
        SettingsAction {
            text: UserPlugins.busy ? "Working…" : "Install plugin"
            glyph: "add"
            enabled: !UserPlugins.busy && repository.text.trim() !== ""
            onTriggered: page.run(["add", repository.text.trim()])
        }
        Text {
            width: parent.width
            wrapMode: Text.WrapAnywhere
            visible: text !== ""
            text: UserPlugins.error || UserPlugins.operationResult
            color: UserPlugins.error ? Theme.redText : Theme.textMid
            font.family: Theme.fontMenu
            font.pixelSize: Theme.fontCaption
        }
        Repeater {
            model: UserPlugins.plugins
            delegate: Column {
                id: row
                required property var modelData
                property bool confirmRemoval: false
                width: parent.width
                spacing: 8
                Text {
                    width: parent.width
                    text: row.modelData.name + " · " + row.modelData.id
                    color: Theme.textHi
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.fontCaption
                    wrapMode: Text.WrapAnywhere
                }
                Text {
                    width: parent.width
                    visible: text !== ""
                    text: row.modelData.error || Object.keys(OmarchyPlugins.errors)
                        .filter(key => key.startsWith(row.modelData.id + ":"))
                        .map(key => OmarchyPlugins.errors[key]).join("\n")
                    color: Theme.redText
                    wrapMode: Text.WrapAnywhere
                }
                Flow {
                    width: parent.width
                    spacing: 8
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
                Controls.TextField {
                    id: cloneId
                    width: parent.width
                    placeholderText: "New ID for a custom copy"
                    Accessible.name: "Clone ID for " + row.modelData.id
                }
                SettingsAction {
                    text: "Clone"
                    glyph: "content_copy"
                    enabled: !UserPlugins.busy && cloneId.text.trim() !== ""
                    onTriggered: page.run(["clone", row.modelData.id, cloneId.text.trim()])
                }
            }
        }
    }
}
