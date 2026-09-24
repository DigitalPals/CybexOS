import QtQuick
import "../Common"

// Touchpad: how far a two-finger scroll moves. Pointer and keyboard settings
// would join it here.
SettingsPage {
    id: page
    pageReset: true

    Column {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Theme.settingsGroupSpacing

        SettingsGroup {
            width: parent.width
            title: "Touchpad"

            SliderRow {
                width: parent.width
                label: "Scroll speed"
                settingKey: "scrollFactor"
                resetLabel: "Touchpad scroll speed"
                min: 0.2
                max: 2.0
                step: 0.1
                decimals: 1
                unit: "×"
                marks: [1.0]
                hint: "1.0× is Hyprland's default"
                dirty: Math.abs(Settings.scrollFactor - Settings.defaults.scrollFactor) > 0.001
            }
        }
    }
}
