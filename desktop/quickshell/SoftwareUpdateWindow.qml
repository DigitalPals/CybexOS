import QtQuick
import Quickshell
import Quickshell.Hyprland
import "Common"
import "SoftwareUpdate" as SoftwareUpdateUi

// Software Update: opened from the menubar indicator, Control Center and the
// launcher. Closing it never interrupts an update; the worker owns that.
FloatingWindow {
    id: window

    title: "Software Update" // i18n: untranslated (compositor identity)
    visible: Updates.appOpen
    color: Theme.panelSurface
    implicitWidth: Math.min(Theme.scaled(720, Theme.contentScale),
        screen ? screen.width - Theme.panelPadding * 2 : 720)
    implicitHeight: Math.min(Theme.scaled(700),
        screen ? screen.height - Theme.barHeight - Theme.panelPadding * 2 : 700)
    minimumSize: Qt.size(600, 460)
    onClosed: Updates.close()
    onVisibleChanged: {
        if (visible) {
            screen = Screens.focused;
            minimized = false;
        }
    }

    Connections {
        target: Updates
        function onPresent() {
            window.minimized = false;
            Hyprland.dispatch('hl.dsp.focus({ window = "title:^Software Update$" })');
        }
    }

    SoftwareUpdateUi.UpdateView {
        anchors.fill: parent
        focus: true
        Keys.onEscapePressed: Updates.close()
    }
}
