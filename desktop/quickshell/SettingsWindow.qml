import QtQuick
import Quickshell
import Quickshell.Hyprland
import "Common"
import "Settings" as SettingsUi

FloatingWindow {
    id: window

    // Stable compositor target; the workspace header carries localized copy.
    title: "Cybex OS Settings" // i18n: untranslated (compositor identity)
    visible: false
    color: Theme.panelSurface
    // 960 by 700 (2026-10 redesign): room for the rail's nineteen entries
    // without scrolling; smaller screens get a scrolling rail.
    implicitWidth: Math.min(Theme.scaled(960, Theme.contentScale),
        screen ? screen.width - Theme.panelPadding * 2 : 960)
    implicitHeight: Math.min(Theme.scaled(700),
        screen ? screen.height - Theme.barHeight - Theme.panelPadding * 2 : 700)
    minimumSize: Qt.size(480, 400)
    onClosed: Settings.closePanel()

    Connections {
        target: Settings

        function onPanelOpenChanged() {
            if (Settings.panelOpen) {
                window.screen = Screens.byName(Settings.panelScreenName) ?? Screens.focused;
                window.minimized = false;
            }
            window.visible = Settings.panelOpen;
        }

        function onPresentPanel() {
            window.minimized = false;
            Hyprland.dispatch('hl.dsp.focus({ window = "title:^Cybex OS Settings$" })');
        }
    }

    SettingsUi.SettingsView {
        id: view
        objectName: "settingsView"
        anchors.fill: parent
        implicitWidth: preferredWidth
        implicitHeight: preferredHeight
        availableWidth: window.width
        availableHeight: window.height
        onMoveRequested: window.startSystemMove()
        Keys.onEscapePressed: event => {
            if (!view.handleEscape())
                Settings.closePanel();
            event.accepted = true;
        }
    }
}
