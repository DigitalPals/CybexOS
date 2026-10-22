import QtQuick
import "../Common"

// Night light on the Displays page: a shell setting, applied as it changes,
// beside display rows that wait for Apply.
SettingsGroup {
    width: parent.width
    title: I18n.tr("Night light")

    SwitchRow {
        width: parent.width
        label: I18n.tr("Night light")
        settingKey: "nightLight"
        description: SysInfo.nightLightError !== "" ? SysInfo.nightLightError
            : SysInfo.nightLightPending
                ? (Settings.nightLight ? "Starting…" : "Stopping…")
            : "Warms the screen to reduce blue light"
        hintTone: SysInfo.nightLightError !== "" ? "error" : "info"
    }
    SliderRow {
        width: parent.width
        label: I18n.tr("Warmth")
        settingKey: "warmth"
        min: 1900
        max: 4500
        step: 50
        unit: "K"
        gradientTrack: true
        hint: I18n.tr("Lower is warmer")
    }
}
