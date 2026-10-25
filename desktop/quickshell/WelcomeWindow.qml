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
    // Reconcile the compositor's observed pin, rather than toggling blindly.
    // A crashed shell loses its window (and pin); a QML reload/new mapping is
    // reconciled too, including the saved step having moved away from practice.
    property bool pinned: false
    function syncPin() {
        if (Welcome.hasHyprland && !pinRequest.running) pinRequest.running = true;
    }
    Connections {
        target: Welcome
        function onOpenChanged() {
            if (Welcome.open) {
                window.screen = Screens.byName(Welcome.screenName) ?? Screens.focused;
                window.minimized = false;
            }
            window.visible = Welcome.open;
            Qt.callLater(() => { view.focusInitial(); window.syncPin(); });
        }
        function onPresent() {
            window.minimized = false;
            if (window.visible && Welcome.hasHyprland)
                Hyprland.dispatch('hl.dsp.focus({ window = "title:^Welcome to Cybex OS$" })');
        }
        function onPracticingChanged() { window.syncPin(); }
    }
    // Live keycaps: the backend's process and 15-second refresh run only
    // while the guide is shown; closing or destroying the window releases it.
    Claim {
        active: window.visible
        onClaimed: Keybindings.acquire()
        onReleased: Keybindings.release()
    }
    Timer { interval: 350; repeat: true; running: Welcome.open && Welcome.hasHyprland; onTriggered: window.syncPin() }
    CommandRequest {
        id: pinRequest
        command: ["hyprctl", "clients", "-j"]
        onCompleted: (code, body, error) => {
            if (code !== 0) return;
            try {
                const client = JSON.parse(body).find(item => item.title === "Welcome to Cybex OS");
                if (!client) { window.pinned = false; return; }
                window.pinned = !!client.pinned;
                if (window.pinned !== Welcome.practicing)
                    Hyprland.dispatch('hl.dsp.window.pin({ action = "' + (Welcome.practicing ? "on" : "off")
                        + '", window = "title:^Welcome to Cybex OS$" })');
            } catch (_) {}
        }
    }
    Guide.WelcomeView { id: view; anchors.fill: parent }
    Component.onDestruction: {
        if (pinned && Welcome.hasHyprland)
            Hyprland.dispatch('hl.dsp.window.pin({ action = "off", window = "title:^Welcome to Cybex OS$" })');
    }
}
