import QtQuick
import "../Common"

// The bar's own layout, background and behavior, beneath the widget editor
// on the Bar page.
Column {
    id: page

    readonly property bool floating: Settings.barStyle === "floating"
    // Named heights. Default is the shipped value, so a fresh bar reads as a
    // choice rather than as an unnamed number.
    readonly property var heightPresets: [
        { value: 30, label: I18n.tr("Compact") },
        { value: 34, label: I18n.tr("Classic") },
        { value: Settings.defaults.barHeight, label: I18n.tr("Default") },
        { value: 42, label: I18n.tr("Roomy") }
    ]
    // The bar never draws shorter than its controls (Theme.barHeight), so a
    // preset below that floor would change nothing at this text size and
    // density; offer only the heights the bar can actually take.
    readonly property int drawableFloor: Theme.chipHeight + 8
    readonly property var drawablePresets: heightPresets.filter(preset => preset.value >= drawableFloor)
    readonly property bool heightIsPreset: drawablePresets.some(preset => preset.value === Settings.barHeight)
    // View state, not a setting: Custom is what the picker shows for a height
    // no preset names, and what it keeps showing once picked — the slider
    // must not fold away under a drag that passes over 34 or 42.
    property bool customHeight: false
    readonly property bool showCustomHeight: customHeight || !heightIsPreset

    // A search result whose row is folded away lands on the row that
    // unfolds it instead: the same wash SettingsRow draws for its own key.
    readonly property bool floatingRowSought: !floating
        && (Settings.highlightKey === "gap" || Settings.highlightKey === "barRadius")
    component SearchWash: Rectangle {
        property bool active: false
        z: -1
        anchors.fill: parent
        anchors.leftMargin: -6
        anchors.rightMargin: -6
        radius: Theme.rowRadius
        color: Theme.accentAlpha(0.12)
        opacity: active ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: Theme.chipFadeDuration } }
    }

    spacing: Theme.settingsGroupSpacing

    // A reset that includes the height (its own chip, the page's reset,
    // Reset all) hands the picker back to the preset the restored value
    // names. A drag never does: set() drops the undo snapshot before it
    // writes, so the snapshot only holds barHeight during a reset or undo.
    Connections {
        target: Settings
        function onBarHeightChanged() {
            if (Settings.resetSnapshot !== null && Settings.resetSnapshot.barHeight !== undefined)
                page.customHeight = false;
        }
    }

    SettingsGroup {
        width: parent.width
        title: I18n.tr("Layout")

        PickerRow {
            width: parent.width
            label: I18n.tr("Position")
            settingKey: "position"
            model: [
                { value: "top", label: I18n.tr("Top") },
                { value: "bottom", label: I18n.tr("Bottom") }
            ]
        }

        // Gap and radius only mean something to a floating bar, so they
        // appear under Style for Floating instead of sitting there disabled.
        // Their values are kept while hidden; resetting Style restores them
        // with it.
        PickerRow {
            width: parent.width
            label: I18n.tr("Style")
            settingKey: "barStyle"
            resetKeys: ["barStyle", "gap", "barRadius"]
            hint: page.floatingRowSought ? "Edge gap and Corner radius appear for the Floating style" : ""
            model: [
                { value: "hug", label: I18n.tr("Hug") },
                { value: "floating", label: I18n.tr("Floating") },
                { value: "attached", label: I18n.tr("Attached") }
            ]

            SearchWash {
                active: page.floatingRowSought
            }
        }

        Revealer {
            id: floatingReveal
            width: parent.width
            reveal: page.floating
            Column {
                width: floatingReveal.width
                spacing: Theme.settingsRowSpacing
                SliderRow {
                    width: parent.width
                    label: I18n.tr("Edge gap")
                    settingKey: "gap"
                    min: 4; max: 20; step: 1; unit: "px"
                }
                SliderRow {
                    width: parent.width
                    label: I18n.tr("Corner radius")
                    settingKey: "barRadius"
                    min: 0; max: 30; step: 1; unit: "px"
                }
            }
        }

        // Presets for the common heights and Custom for the rest. The picker
        // writes barHeight itself; Custom only reveals the slider and keeps
        // the current value.
        PickerRow {
            id: heightRow
            width: parent.width
            label: I18n.tr("Height")
            model: page.drawablePresets.concat([{ value: "custom", label: I18n.tr("Custom") }])
            current: page.showCustomHeight ? "custom" : Settings.barHeight
            caption: page.showCustomHeight ? "" : Settings.barHeight + " px"
            // The bar never draws shorter than its controls; say so rather
            // than leave a preset that changes nothing unexplained.
            hint: Theme.barHeight > Settings.barHeight
                ? "Drawn at " + Theme.barHeight + " px: the bar grows to fit its controls at this text size" : ""
            dirty: Settings.barHeight !== Settings.defaults.barHeight
            resetKeys: ["barHeight"]
            onPicked: value => {
                if (value === "custom") {
                    page.customHeight = true;
                } else {
                    page.customHeight = false;
                    Settings.set("barHeight", value);
                }
            }

            // Search lands on the height through the slider's key. While the
            // slider is folded away, this row takes the highlight instead.
            SearchWash {
                active: Settings.highlightKey === "barHeight" && !page.showCustomHeight
            }
        }

        Revealer {
            id: customHeightReveal
            width: parent.width
            reveal: page.showCustomHeight
            SliderRow {
                width: customHeightReveal.width
                label: I18n.tr("Custom height")
                resetLabel: "Height"
                settingKey: "barHeight"
                min: 28; max: 60; step: 1; unit: "px"
            }
        }
    }

    BarBackgroundGroup {
        width: parent.width
    }

    SettingsGroup {
        width: parent.width
        title: I18n.tr("Behavior")

        SwitchRow {
            width: parent.width
            label: I18n.tr("Auto-hide")
            settingKey: "autoHide"
            description: I18n.tr("Hides when idle; point at the screen edge to bring it back")
        }
        SwitchRow {
            width: parent.width
            label: I18n.tr("Reserve space")
            settingKey: "exclusive"
            description: I18n.tr("Tiled windows stay clear of the bar instead of going under it")
        }
    }

    // The optional dock lives with the bar: both are edge furniture, and the
    // dock steps above a bottom bar rather than covering it. Pins are edited
    // from the dock itself (right-click an app).
    SettingsGroup {
        width: parent.width
        title: I18n.tr("Dock")

        SwitchRow {
            width: parent.width
            label: I18n.tr("Show dock")
            settingKey: "dock"
            description: I18n.tr("Pinned and running apps at the bottom of each screen; right-click an app to pin it")
        }

        Revealer {
            id: dockReveal
            width: parent.width
            reveal: Settings.dock
            SwitchRow {
                width: dockReveal.width
                label: I18n.tr("Auto-hide")
                resetLabel: "Dock auto-hide"
                settingKey: "dockAutoHide"
                description: I18n.tr("Hides until you point at the bottom edge")
            }
        }
    }
}
