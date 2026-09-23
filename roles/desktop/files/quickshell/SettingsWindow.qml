import QtQuick
import Quickshell
import Quickshell.Hyprland
import "Common"
import "Settings" as SettingsUi

FloatingWindow {
    id: window

    title: "CybexOS Settings"
    visible: false
    color: Theme.panelSurface
    implicitWidth: Math.min(Theme.scaled(900, Theme.contentScale),
        screen ? screen.width - Theme.panelPadding * 2 : 900)
    implicitHeight: Math.min(Theme.scaled(664),
        screen ? screen.height - Theme.barHeight - Theme.panelPadding * 2 : 664)
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
            Hyprland.dispatch('hl.dsp.focus({ window = "title:^CybexOS Settings$" })');
        }
    }

    SettingsUi.SettingsView {
        id: view
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
