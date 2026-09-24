pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import "../Common"

// Region & formats: how the shell writes the time and the temperature. Each
// row's caption shows the result.
SettingsPage {
    id: page
    pageReset: true

    // The clock caption shows hours and minutes, so tick on the minute, and
    // only while the page is on screen.
    SystemClock {
        id: clock
        precision: SystemClock.Minutes
        enabled: page.visible
    }

    Column {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Theme.settingsGroupSpacing

        SettingsGroup {
            width: parent.width
            title: "Formats"

            PickerRow {
                width: parent.width
                label: "Clock"
                settingKey: "clock24"
                model: [
                    { value: true, label: "24 h" },
                    { value: false, label: "12 h" }
                ]
                caption: Qt.formatDateTime(clock.date, Settings.clock24 ? "HH:mm" : "h:mm AP")
            }
            PickerRow {
                width: parent.width
                label: "Temperature"
                settingKey: "unit"
                model: [
                    { value: "c", label: "°C" },
                    { value: "f", label: "°F" }
                ]
                caption: Weather.ready ? Weather.temp + "° outside" : ""
            }
        }
    }
}
