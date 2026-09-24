import QtQuick
import "../Common"

// Night light on the Displays page: a shell setting, applied as it changes,
// beside display rows that wait for Apply.
SettingsGroup {
    width: parent.width
    title: "Night light"

    SwitchRow {
        width: parent.width
        label: "Night light"
        settingKey: "nightLight"
        description: SysInfo.nightLightError !== "" ? SysInfo.nightLightError
            : SysInfo.nightLightPending
                ? (Settings.nightLight ? "Starting…" : "Stopping…")
            : "Warms the screen to reduce blue light"
        hintTone: SysInfo.nightLightError !== "" ? "error" : "info"
    }
    SliderRow {
        width: parent.width
        label: "Warmth"
        settingKey: "warmth"
        min: 1900
        max: 4500
        step: 50
        unit: "K"
        gradientTrack: true
        hint: "Lower is warmer"
    }
}
