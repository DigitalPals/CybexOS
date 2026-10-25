import QtQuick
import "../Settings" as SettingsUi
Item {
    // INTEGRATION: stream D replaces this container's WallpaperPage with
    // WallpaperPicker. The existing page embeds WallpaperOnlineView and the
    // library without duplicating their models or starting an online request.
    SettingsUi.WallpaperPage { anchors.fill: parent }
}
