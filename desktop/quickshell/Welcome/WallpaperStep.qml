import QtQuick
import "../Common"
import "../Settings" as SettingsUi
Item {
    // The guide sizes this step to its viewport. Below this floor (only at
    // the minimum window size with large text) the step scrolls instead of
    // squeezing the picker; its grid and preview already scroll inside.
    implicitHeight: Theme.scaled(240)
    // Applying needs no progress of its own: Finish reads Settings.wall.
    SettingsUi.WallpaperPicker {
        anchors.fill: parent
        embedded: true
        tab: "online"
        showSources: false
        automaticOnlineLoad: true
        applyOnSelect: true
        onEscapeRequested: Welcome.dismiss()
    }
}
