pragma Singleton
import QtQuick
import Quickshell
import "PanelRegistryData.js" as PanelRegistry

// Shared state for the bar's detached popouts. Every view hangs from its
// triggering module, the host morphs one card between modules, and only one
// popout is open shell-wide. hostScreenName selects which output's detached
// host presents it, so always-visible bars do not duplicate the panel.
Singleton {
    id: root

    property bool open: false
    property string currentName: ""
    property string island: ""
    property string hostScreenName: ""

    // Window-coordinate rect of the module the popout hangs under, so the
    // surface can sit at the module instead of at the edge of the section
    // that happens to hold it. Zero width means "no anchor given" — fall
    // back to the island alignment. Snapshotted at open: a bar re-layout
    // while a panel is open leaves it where it was drawn.
    property rect anchorRect: Qt.rect(0, 0, 0, 0)

    // Emitted once per state change, after every property has settled, so
    // the island hosts never observe a half-updated (name, island) pair.
    signal changed

    // Island a popout opens on when the caller does not say (IPC, bar
    // modules). Panels opened from inside another popout may override —
    // e.g. the Control Panel morphs to Wi-Fi details on the right island.
    // Derived, not hand-maintained: see Common/PanelRegistryData.js.
    readonly property var defaultIsland: PanelRegistry.islandMap()

    function resolvedHostName(requestedName, preserveCurrent) {
        if (requestedName && Screens.byName(requestedName))
            return requestedName;
        if (preserveCurrent && Screens.byName(hostScreenName))
            return hostScreenName;
        return Screens.focused ? Screens.focused.name : "";
    }

    function openPanel(name, isle, anchor, targetScreenName) {
        if (name === PanelRegistry.SETTINGS) {
            Settings.showPanel(undefined, targetScreenName);
            return;
        }
        // IPC accepts an arbitrary string. Mapping a one-pixel focus-grabbing
        // layer for an unknown name leaves an invisible ghost surface because
        // the host has no component to present.
        if (PanelRegistry.byName(name) === null) {
            console.warn("Ignoring unknown popout:", name);
            return;
        }
        const nextHost = resolvedHostName(targetScreenName, open);
        island = isle ?? defaultIsland[name] ?? "right";
        // Callers with no module to point at — the IPC handler, or one
        // popover morphing into another — keep the surface where it is
        // rather than making it jump to the section edge.
        if (anchor !== undefined)
            anchorRect = anchor;
        else if (!open)
            anchorRect = Qt.rect(0, 0, 0, 0);
        currentName = name;
        open = true;
        // Set this last during a handoff: the newly live host then observes a
        // fully settled name/island/anchor tuple on its first sync.
        hostScreenName = nextHost;
        changed();
    }

    function toggle(name, isle, anchor, targetScreenName) {
        if (name === PanelRegistry.SETTINGS) {
            Settings.togglePanel(undefined, targetScreenName);
            return;
        }
        const nextHost = resolvedHostName(targetScreenName, open);
        if (open && currentName === name && hostScreenName === nextHost)
            close();
        else
            openPanel(name, isle, anchor, targetScreenName);
    }

    function close() {
        if (!open)
            return;
        open = false;
        changed();
    }

    // Quickshell briefly substitutes a FALLBACK screen when the compositor
    // drops every real output. Waiting for the owning Bar Scope to be destroyed
    // can leave its mapped layer surface polishing against that placeholder.
    // Retire the popout as soon as its named output disappears; a surviving
    // output that merely moves keeps the same name and stays open.
    Connections {
        target: Screens

        function onLayerSurfaceModelChanged() {
            if (root.open && !Screens.byName(root.hostScreenName))
                root.close();
        }
    }
}
