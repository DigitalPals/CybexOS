pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import "WindowCommands.js" as WindowCommands

// Minimizing a window. In the Mac-like desktop style (Settings → Appearance)
// the window's last frame shrinks into the dock first, as a Mac's does
// (MinimizeOverlay.qml draws it); otherwise, with reduced motion, or while
// another window is still on its way, it is minimized at once.
//
// Every path into a minimize that the shell owns comes through here: the dock,
// the Mac-like menus and the title bar's minimize button, which calls the
// `window minimize` IPC (desktop/hypr/workspaces.lua) and falls back to the
// compositor when no shell answers. Keyboard shortcuts minimize directly.
Singleton {
    id: root

    // Where a minimized window lands on each output, in that output's own
    // coordinates: the start of the dock's Trash, where its thumbnail will
    // appear (DockWindow.qml publishes it).
    property var targets: ({})
    // The flight in progress: { address, screen, from, to } or null.
    property var flight: null
    property string pendingAddress: ""

    readonly property bool animates: Settings.macStyle && !Theme.reducedMotion

    function setTarget(screenName, rect) {
        const next = Object.assign({}, targets);
        next[screenName] = rect;
        targets = next;
    }

    function minimize(address) {
        if (!DesktopWorkspaces.canMinimize(address))
            return false;
        if (!animates || flight !== null || clients.running)
            return DesktopWorkspaces.minimize(address);
        pendingAddress = WindowCommands.bareAddress(address);
        clients.running = true;
        return true;
    }

    // Reads the window's frame and output from Hyprland, then hands the
    // flight to the overlay; anything missing minimizes without it.
    function begin(text) {
        const address = pendingAddress;
        pendingAddress = "";
        let client = null;
        try {
            const rows = JSON.parse(text);
            client = Array.isArray(rows) ? rows.find(row =>
                WindowCommands.bareAddress(row.address) === address) || null : null;
        } catch (error) {
            client = null;
        }
        const monitor = client ? Hyprland.monitors.values.find(monitor => monitor.id === client.monitor) : null;
        const screen = monitor ? Quickshell.screens.find(screen => screen.name === monitor.name) : null;
        if (!client || !screen || !Array.isArray(client.at) || !Array.isArray(client.size)) {
            DesktopWorkspaces.minimize(address);
            return;
        }
        const from = Qt.rect(client.at[0] - screen.x, client.at[1] - screen.y,
            client.size[0], client.size[1]);
        const target = targets[screen.name];
        const size = Theme.scaled(48);
        const to = target ? Qt.rect(target.x, target.y, target.width, target.height)
            : Qt.rect(screen.width / 2 - size / 2, screen.height - size, size, size);
        flight = { address: address, screen: screen, from: from, to: to };
    }

    // The overlay has the frame on screen over the window: hide the window.
    function captured() {
        if (flight !== null)
            DesktopWorkspaces.minimize(flight.address);
    }

    function finished() {
        flight = null;
    }

    Process {
        id: clients
        command: ["hyprctl", "clients", "-j"]
        stdout: StdioCollector {
            onStreamFinished: root.begin(text)
        }
        onExited: (code, status) => {
            if (code !== 0 && root.pendingAddress !== "") {
                const address = root.pendingAddress;
                root.pendingAddress = "";
                DesktopWorkspaces.minimize(address);
            }
        }
    }
}
