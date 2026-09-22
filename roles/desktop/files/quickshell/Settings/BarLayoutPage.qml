import QtQuick
import "../Common"

// The persisted page id remains `bar`; only the visible name and grouping
// change. There is no preview strip: the live bar directly above the sheet
// is the preview (turn-3 design). Floating-only geometry stays on screen
// while another style is active, disabled and saying why.
SettingsPage {
    id: page

    readonly property bool floating: Settings.barStyle === "floating"
    readonly property var heightPresets: [
        { value: 30, label: "Compact" },
        { value: 34, label: "Classic" },
        { value: 42, label: "Roomy" }
    ]
    readonly property string heightPresetLabel: {
        const hit = heightPresets.find(preset => preset.value === Settings.barHeight);
        return hit ? hit.label : "";
    }

    Column {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Theme.settingsGroupSpacing

        SettingsGroup {
            width: parent.width
            title: "Layout"

            PickerRow {
                width: parent.width
                label: "Position"
                settingKey: "position"
                model: [
                    { value: "top", label: "Top" },
                    { value: "bottom", label: "Bottom" }
                ]
            }

            PickerRow {
                width: parent.width
                label: "Style"
                settingKey: "barStyle"
                model: [
                    { value: "hug", label: "Hug" },
                    { value: "floating", label: "Floating" },
                    { value: "attached", label: "Attached" }
                ]
            }

            // One control for one value. The presets that used to be a
            // second picker for the same key are ticks the drag settles on.
            SliderRow {
                width: parent.width
                label: "Height"
                settingKey: "barHeight"
                min: 28; max: 60; step: 1; unit: "px"
                marks: page.heightPresets.map(preset => preset.value)
                valueLabel: (page.heightPresetLabel !== "" ? page.heightPresetLabel + " " : "")
                    + Settings.barHeight + " px"
                valueWidth: 92
                hint: "Ticks mark Compact 30, Classic 34 and Roomy 42"
            }

            SliderRow {
                width: parent.width
                label: "Edge gap"
                settingKey: "gap"
                min: 4; max: 20; step: 1; unit: "px"
                disabledReason: page.floating ? "" : "Only applies to the Floating style"
            }
            SliderRow {
                width: parent.width
                label: "Corner radius"
                settingKey: "barRadius"
                min: 0; max: 30; step: 1; unit: "px"
                disabledReason: page.floating ? "" : "Only applies to the Floating style"
            }
        }

        SettingsGroup {
            width: parent.width
            title: "Behavior"

            SwitchRow {
                width: parent.width
                label: "Auto-hide"
                settingKey: "autoHide"
                description: "Hides when idle; point at the screen edge to bring it back"
            }
            SwitchRow {
                width: parent.width
                label: "Reserve space"
                settingKey: "exclusive"
                description: "Tiled windows stay clear of the bar instead of going under it"
            }
        }
    }
}
