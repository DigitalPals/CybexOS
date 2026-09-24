import QtQuick
import "../Common"

// Plugin chrome follows the shell unless asked not to. One switch says so;
// the overrides it hides are the same controls the Panels group has, so
// showing both copies all the time repeated the whole border setup. The
// border rows that only mean something under one border mode are revealed
// beneath the Border row, like the Panels group's.
//
// "Matching" is derived from the stored values, never persisted: a plugin
// scale of 100 %, the Shell border and the theme corner radius, with no
// theme overrides. Switching it on resets the plugin keys (with the usual
// undo); switching it off only reveals the overrides for editing.
SettingsGroup {
    id: root
    readonly property var keys: ["pluginScale", "pluginBorderMode", "pluginBorderColor", "pluginBorderWidth", "pluginBorderOpacity", "pluginRadius", "pluginThemeOverrides"]
    readonly property bool matchesShell: Settings.pluginScale === 100
        && Settings.pluginBorderMode === "inherit"
        && Settings.pluginRadius === -1
        && Object.keys(Settings.pluginThemeOverrides || {}).length === 0
    property bool customizing: false
    readonly property bool showOverrides: customizing || !matchesShell

    width: parent.width
    title: "Plugins"

    SwitchRow {
        width: parent.width
        label: "Match shell style"
        checked: !root.showOverrides
        description: "Plugins that use the shared components take the shell's size, borders and corners"
        // Derived, not stored: the overrides below carry their own resets.
        dirty: false
        resetKeys: []
        onToggled: value => {
            root.customizing = !value;
            if (value && !root.matchesShell)
                Settings.resetKeys(root.keys, "Plugin appearance");
        }
    }

    Revealer {
        id: overrides
        width: parent.width
        reveal: root.showOverrides

        Column {
            width: overrides.width
            spacing: Theme.settingsRowSpacing

            // The same name as the shell's own scale above, so the two read
            // as one control applied to different things.
            SliderRow {
                width: parent.width
                label: "Interface scale"
                settingKey: "pluginScale"
                resetLabel: "Plugin interface scale"
                min: 75; max: 200; step: 5; unit: "%"
                marks: [100]
                hint: "100% follows the shell's text and size settings"
            }
            PickerRow {
                width: parent.width
                label: "Border"
                settingKey: "pluginBorderMode"
                resetLabel: "Plugin border"
                // The custom color only means something under Custom.
                resetKeys: ["pluginBorderMode", "pluginBorderColor"]
                model: [
                    { value: "inherit", label: "Shell" },
                    { value: "accent", label: "Accent" },
                    { value: "subtle", label: "Subtle" },
                    { value: "custom", label: "Custom" }
                ]
            }
            Revealer {
                id: borderColorReveal
                width: parent.width
                reveal: Settings.pluginBorderMode === "custom"

                SettingsTextRow {
                    width: borderColorReveal.width
                    label: "Border color"
                    settingKey: "pluginBorderColor"
                    resetLabel: "Plugin border color"
                    hexColor: true
                    placeholder: "#9ecbeb"
                }
            }
            // Shell borrows the shell's whole border, width and opacity
            // included; any other mode draws its own.
            Revealer {
                id: borderShapeReveal
                width: parent.width
                reveal: Settings.pluginBorderMode !== "inherit"

                Column {
                    width: borderShapeReveal.width
                    spacing: Theme.settingsRowSpacing

                    SliderRow {
                        width: parent.width
                        label: "Border width"
                        settingKey: "pluginBorderWidth"
                        resetLabel: "Plugin border width"
                        min: 0; max: 8; step: 1
                    }
                    SliderRow {
                        width: parent.width
                        label: "Border opacity"
                        settingKey: "pluginBorderOpacity"
                        resetLabel: "Plugin border opacity"
                        min: 0; max: 100; step: 5; unit: "%"
                        disabledReason: Settings.pluginBorderWidth === 0 ? "No border at width 0" : ""
                    }
                }
            }
            SliderRow {
                width: parent.width
                label: "Corners"
                settingKey: "pluginRadius"
                resetLabel: "Plugin corners"
                min: -1; max: 30; step: 1
                valueLabel: Settings.pluginRadius < 0 ? "Shell" : Settings.pluginRadius + " px"
                valueWidth: 52
                hint: "All the way left follows the shell's corners"
            }
        }
    }
}
