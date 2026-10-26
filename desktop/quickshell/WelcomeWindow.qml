import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import "Common"
import "Welcome" as Guide

// The welcome guide fills the focused screen like the installer did: an
// overlay layer with the installer's palette, its 1280×800 canvas centred
// and zoomed by the installer's rule. While the person uses something the
// guide opened, or any window or shell surface appears, the guide steps
// aside and leaves a resume pill at the bottom of the screen.
Scope {
    id: root
    readonly property Item contentItem: guide.contentItem
    readonly property bool shown: Welcome.open && !Welcome.aside
    // Shell surfaces a shortcut can open over the guide. They are transient:
    // the guide comes back when they close, unless a window opened meanwhile.
    readonly property bool shellSurface: Launcher.open || Overview.open || Session.keysOpen
    onShellSurfaceChanged: {
        if (shellSurface && root.shown) Welcome.stepAside(true);
        else if (!shellSurface && Welcome.aside && Welcome.asideTransient) resumeLater.restart();
    }
    Timer {
        id: resumeLater
        interval: 700
        onTriggered: { if (Welcome.aside && Welcome.asideTransient && !root.shellSurface) Welcome.resume(); }
    }
    Connections {
        target: Hyprland
        enabled: Welcome.hasHyprland && Welcome.open
        function onRawEvent(event) {
            if (event.name === "openwindow") {
                resumeLater.stop();
                Welcome.stepAside(false);
            }
        }
    }
    Connections {
        target: Welcome
        function onOpenChanged() {
            if (Welcome.open)
                guide.screen = Screens.byName(Welcome.screenName) ?? Screens.focused;
            Qt.callLater(view.focusInitial);
        }
        function onPresent() { Qt.callLater(view.focusInitial); }
    }

    PanelWindow {
        id: guide
        visible: root.shown
        screen: Screens.focused
        anchors { top: true; left: true; right: true; bottom: true }
        exclusionMode: ExclusionMode.Ignore
        color: "transparent"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "qs-welcome"
        WlrLayershell.keyboardFocus: root.shown ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
        onVisibleChanged: if (visible) Qt.callLater(view.focusInitial)
        Binding {
            target: Guide.Kiosk
            property: "zoom"
            value: Guide.Kiosk.zoomFor(guide.width, guide.height, guide.screen ? guide.screen.devicePixelRatio : 1)
        }
        // The installer's page colour beyond the canvas, gone while peeking.
        Rectangle {
            anchors.fill: parent
            color: Guide.Kiosk.bg
            opacity: view.peeking ? 0 : 1
            Behavior on opacity { NumberAnimation { duration: 140 } }
        }
        Guide.WelcomeView {
            id: view
            x: Math.round((parent.width - width) / 2)
            y: Math.max(0, Math.round((parent.height - height) / 2))
        }
    }

    PanelWindow {
        id: pill
        visible: Welcome.open && Welcome.aside
        screen: guide.screen
        anchors.bottom: true
        // PanelWindow.margins is a Quickshell group qmllint cannot resolve.
        // qmllint disable unqualified
        margins { bottom: Guide.Kiosk.px(28) }
        // qmllint enable unqualified
        implicitWidth: resume.width
        implicitHeight: resume.height
        exclusionMode: ExclusionMode.Ignore
        color: "transparent"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "qs-welcome-resume"
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        Guide.ResumePill { id: resume }
    }
}
