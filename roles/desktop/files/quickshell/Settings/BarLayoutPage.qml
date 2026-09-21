import QtQuick
import "../Common"

// The persisted page id remains `bar`; only the visible name and grouping
// change. There is no preview strip: the live bar directly above the sheet
// is the preview (turn-3 design). Floating-only geometry stays stored while
// its controls are dimmed.
SettingsPage {
    id: page

    Column {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Theme.settingsGroupSpacing

        SettingsGroup {
            width: parent.width
            title: "Placement"
            dirty: Settings.position !== Settings.defaults.position
            onResetRequested: Settings.resetKeys(["position"], "Bar placement")

            PickerRow {
                width: parent.width
                label: "Position"
                settingKey: "position"
                model: [
                    { value: "top", label: "Top" },
                    { value: "bottom", label: "Bottom" }
                ]
            }
        }

        SettingsGroup {
            width: parent.width
            title: "Shape"
            dirty: Settings.barStyle !== Settings.defaults.barStyle
                || Settings.gap !== Settings.defaults.gap
                || Settings.barHeight !== Settings.defaults.barHeight
                || Settings.barRadius !== Settings.defaults.barRadius
            onResetRequested: Settings.resetKeys(["barStyle", "gap", "barHeight", "barRadius"], "Bar shape")

            PickerRow {
                width: parent.width
                label: "Style"
                settingKey: "barStyle"
                caption: "edge treatment"
                captionMono: false
                model: [
                    { value: "hug", label: "Hug" },
                    { value: "floating", label: "Floating" },
                    { value: "attached", label: "Attached" }
                ]
            }

            SliderRow {
                width: parent.width
                label: "Height"
                settingKey: "barHeight"
                min: 28; max: 60; step: 1; unit: "px"
            }

            PickerRow {
                width: parent.width
                label: "Height presets"
                settingKey: "barHeight"
                model: [
                    { value: 30, label: "Compact 30" },
                    { value: 34, label: "Classic 34" },
                    { value: 42, label: "Roomy 42" }
                ]
            }

            // Floating-only geometry stays visible but dimmed when another
            // style is active (turn-3 design), so the rows never jump.
            SliderRow {
                width: parent.width
                label: "Edge gap"
                settingKey: "gap"
                min: 4; max: 20; step: 1; unit: "px"
                dimmed: Settings.barStyle !== "floating"
                enabled: Settings.barStyle === "floating"
                opacity: Settings.barStyle === "floating" ? 1 : 0.45
            }
            SliderRow {
                width: parent.width
                label: "Corner radius"
                settingKey: "barRadius"
                min: 0; max: 30; step: 1; unit: "px"
                dimmed: Settings.barStyle !== "floating"
                enabled: Settings.barStyle === "floating"
                opacity: Settings.barStyle === "floating" ? 1 : 0.45
            }
        }

        SettingsGroup {
            width: parent.width
            title: "Behavior"
            dirty: Settings.autoHide !== Settings.defaults.autoHide
                || Settings.exclusive !== Settings.defaults.exclusive
            onResetRequested: Settings.resetKeys(["autoHide", "exclusive"], "Bar behavior")

            SwitchRow {
                width: parent.width
                label: "Auto-hide"
                settingKey: "autoHide"
                description: "Bar slides away when idle — hover the screen edge to reveal"
            }
            SwitchRow {
                width: parent.width
                label: "Reserve space"
                settingKey: "exclusive"
                description: "Exclusive zone — tiled windows stop at the bar"
            }
        }

    }
}
