import QtQuick
import Quickshell
import Quickshell.Hyprland
import "Common"
import "Welcome" as Guide
FloatingWindow {
    id: window
    title: "Welcome to Cybex OS" // i18n: untranslated (compositor identity)
    visible: false
    color: "transparent"
    implicitWidth: Math.min(Math.max(Theme.scaled(1080), screen ? screen.width * 0.5 : 1080),
        screen ? screen.width - Theme.panelPadding * 2 : 1080)
    implicitHeight: Math.min(Theme.scaled(800), screen ? screen.height - Theme.barHeight - Theme.panelPadding * 2 : 800)
    minimumSize: Qt.size(640, 480)
    onClosed: Welcome.dismiss()
    Connections {
        target: Welcome
        function onOpenChanged() {
            if (Welcome.open) {
                window.screen = Screens.byName(Welcome.screenName) ?? Screens.focused;
                window.minimized = false;
            }
            window.visible = Welcome.open;
            Qt.callLater(view.focusInitial);
        }
        function onPresent() {
            window.minimized = false;
            if (window.visible && Welcome.hasHyprland)
                Hyprland.dispatch('hl.dsp.focus({ window = "title:^Welcome to Cybex OS$" })');
        }
    }
    Guide.WelcomeView { id: view; anchors.fill: parent }
}
