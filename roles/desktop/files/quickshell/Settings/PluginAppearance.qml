import QtQuick
import "../Common"

SettingsGroup {
    id: root
    readonly property var keys: ["pluginScale", "pluginBorderMode", "pluginBorderColor", "pluginBorderWidth", "pluginBorderOpacity", "pluginRadius", "pluginThemeOverrides"]
    width: parent.width
    title: "Plugin appearance"
    dirty: keys.some(key => JSON.stringify(Settings[key]) !== JSON.stringify(Settings.defaults[key]))
    onResetRequested: Settings.resetKeys(root.keys, "Plugin appearance")
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
        leftPadding: Theme.settingsMarkInset
        wrapMode: Text.WordWrap
        text: "100% follows the shell font size, UI scale and control spacing. Shell borders follow Appearance. Changes apply to plugins using the shared Omarchy components."
        color: Theme.textMid
        font.family: Theme.fontMenu
        font.pixelSize: Theme.typography.secondary
    }
}
