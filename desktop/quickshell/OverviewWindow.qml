pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import "Common"

// The window overview: every occupied workspace as a tile of live window
// thumbnails on the focused output (Super+Tab, `overview` IPC). The surface
// is mapped only while the overview is open or fading out, and the view —
// with every screen capture in it — exists only while the surface is mapped,
// so a closed overview costs nothing.
//
// The overview covers the whole output on the overlay layer, so it also sits
// above fullscreen windows. Its backdrop is the wallpaper itself rather than
// a blurred view of the windows: the windows are shown as thumbnails, and a
// blur pass behind live content would have to be redrawn on every frame.
PanelWindow {
    id: root

    // Opacity of the whole view; the surface stays mapped until it reaches 0
    // so the closing fade is visible. Reduced motion makes it a cut.
    property real presence: Overview.open ? 1 : 0

    Behavior on presence {
        NumberAnimation {
            duration: Overview.open ? Theme.panelFadeDuration : Theme.panelCloseDuration
            easing.type: Easing.OutCubic
        }
    }

    visible: Overview.open || presence > 0.001
    screen: Overview.screen
    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"

    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "qs-overview"
    WlrLayershell.keyboardFocus: Overview.open
        ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    // The surface covers its output, so this clears only on a click on
    // another output or when another surface takes the keyboard.
    HyprlandFocusGrab {
        active: Overview.open
        windows: [root]
        onCleared: Overview.close()
    }

    // Shell-wide and registered once. `nerdos-runtime ipc overview toggle`
    // is also what the touchpad's three-finger swipe up runs.
    IpcHandler {
        target: "overview"

        function toggle(): void {
            Overview.toggle();
        }

        function open(): void {
            Overview.show();
        }

        function close(): void {
            Overview.close();
        }
    }

    // Another modal surface opening — the launcher, a bar panel, the
    // shortcut sheet — takes over from the overview rather than stacking
    // two keyboard grabs.
    Connections {
        target: Launcher

        function onOpenChanged() {
            if (Launcher.open)
                Overview.close();
        }
    }

    Connections {
        target: Popouts

        function onOpenChanged() {
            if (Popouts.open)
                Overview.close();
        }
    }

    Connections {
        target: Session

        function onKeysOpenChanged() {
            if (Session.keysOpen)
                Overview.close();
        }
    }

    // An output that goes away under an open overview takes it with it.
    readonly property bool outputPresent: Overview.screen !== null
        && Screens.hasBar(Overview.screen)
    onOutputPresentChanged: {
        if (!outputPresent && Overview.open)
            Overview.close();
    }

    Loader {
        id: viewLoader
        anchors.fill: parent
        // A Loader is a focus scope: the filter field inside must be able
        // to take the keyboard the overlay holds.
        focus: true
        active: root.visible && root.screen !== null
        sourceComponent: OverviewView {
            output: root.screen
            opacity: root.presence
        }
    }
}
