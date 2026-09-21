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
        SettingsGroup {
            width: parent.width
            title: "Omarchy plugin appearance"
            dirty: Settings.sectionDirty("plugins")
            onResetRequested: Settings.resetSection("plugins")
            SliderRow {
                width: parent.width
                label: "UI scale"
                settingKey: "pluginScale"
                min: 75; max: 200; step: 5; unit: "%"
            }
            PickerRow {
                width: parent.width
                label: "Border"
                settingKey: "pluginBorderMode"
                model: [
                    { value: "inherit", label: "Shell" },
                    { value: "accent", label: "Accent" },
                    { value: "subtle", label: "Subtle" },
                    { value: "custom", label: "Custom" }
                ]
            }
            SettingsTextRow {
                width: parent.width
                visible: Settings.pluginBorderMode === "custom"
                label: "Border color"
                value: Settings.pluginBorderColor
                dirty: Settings.pluginBorderColor !== Settings.defaults.pluginBorderColor
                resetKeys: ["pluginBorderColor"]
                onCommitted: text => {
                    if (/^#[0-9a-fA-F]{6}$/.test(text)) Settings.set("pluginBorderColor", text);
                }
                placeholder: "#9ecbeb"
            }
            SliderRow {
                width: parent.width
                label: "Border width"
                settingKey: "pluginBorderWidth"
                visible: Settings.pluginBorderMode !== "inherit"
                min: 0; max: 8; step: 1
            }
            SliderRow {
                width: parent.width
                label: "Border opacity"
                settingKey: "pluginBorderOpacity"
                visible: Settings.pluginBorderMode !== "inherit"
                min: 0; max: 100; step: 5; unit: "%"
            }
            SliderRow {
                width: parent.width
                label: "Corners"
                settingKey: "pluginRadius"
                min: -1; max: 30; step: 1
                valueLabel: Settings.pluginRadius < 0 ? "Theme" : Settings.pluginRadius + " px"
            }
            Text {
                width: parent.width
                wrapMode: Text.WordWrap
                text: "100% follows the shell font size, UI scale and control spacing. Shell borders follow Appearance. Changes apply to plugins using the shared Omarchy components."
                color: Theme.textMid
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.secondary
            }
        }
        Text {
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Plugins run as your desktop user. Install only packages you trust. New packages start disabled."
            color: Theme.textMid
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.secondary
        }
        Controls.TextField {
            id: repository
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.control
            font.weight: Theme.weightRegular
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
            font.pixelSize: Theme.typography.secondary
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
                    font.pixelSize: Theme.typography.primary
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
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.control
                    font.weight: Theme.weightRegular
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
