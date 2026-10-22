pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Hyprland

// The window overview's lifecycle (OverviewWindow.qml, Super+Tab, the
// `overview` IPC target and the touchpad's three-finger swipe up). The output
// is captured when it opens, so the overview never jumps to another screen
// while it is up.
//
// Hyprland fills HyprlandToplevel.lastIpcObject — the window geometry the
// overview scales into its tiles — only when the toplevel list is refreshed,
// and Quickshell refreshes it on its own only at start. Opening asks for a
// fresh read; the view asks again as windows open, close or move while it is
// up, and never otherwise.
Singleton {
    id: root

    property bool open: false
    property var screen: null

    function show(targetScreen) {
        if (open)
            return;
        Popouts.close();
        Launcher.close();
        Session.closeKeys();
        screen = targetScreen ?? Screens.focused;
        Hyprland.refreshToplevels();
        Hyprland.refreshWorkspaces();
        open = true;
    }

    function close() {
        open = false;
    }

    function toggle(targetScreen) {
        if (open)
            close();
        else
            show(targetScreen);
    }
}
