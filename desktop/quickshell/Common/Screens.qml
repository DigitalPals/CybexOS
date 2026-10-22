pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Hyprland

// Maps Hyprland output names to Quickshell screens. Every connected screen has
// a bar; focused is still used for keyboard/IPC overlays with no pointer-owned
// output of their own.
Singleton {
    id: root

    // A surviving output can move when another output disappears. Hyprland
    // keeps an already-mapped layer surface at its old global coordinates in
    // that case, so include geometry in the Variants identity and make the
    // shell remap its persistent wallpaper/bar surfaces at the new origin.
    readonly property var layerSurfaceModel: Quickshell.screens.map(screen => ({
        "screen": screen,
        "geometry": screen.name + ":" + screen.x + ":" + screen.y + ":"
            + screen.width + "x" + screen.height + "@" + screen.devicePixelRatio
    }))

    readonly property var focused: {
        const screens = Quickshell.screens;
        const monitor = Hyprland.focusedMonitor;
        if (monitor !== null) {
            const match = screens.find(screen => screen.name === monitor.name);
            if (match !== undefined)
                return match;
        }
        return screens.length > 0 ? screens[0] : null;
    }

    function byName(name) {
        if (!name)
            return null;
        return Quickshell.screens.find(screen => screen.name === name) ?? null;
    }

    function hasBar(screen) {
        return screen !== null
            && Quickshell.screens.some(candidate => candidate === screen);
    }
}
