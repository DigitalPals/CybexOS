pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import "DockHelpers.js" as DockHelpers
import "WindowCommands.js" as WindowCommands

// The optional dock's shared model and actions (DockWindow.qml draws it on
// every output). Nothing names this singleton while the dock is off, so a
// disabled dock constructs nothing at all.
//
// Items are the pinned apps (desktop entry ids in Settings.dockPinned) and
// every running app, grouped by desktop entry. Running windows come from
// Hyprland's toplevels; their app id is the Wayland one, which stays current
// where `hyprctl clients` data would need a refresh.
Singleton {
    id: root

    // Focus history, most recent first, for "focus the app's last window".
    property var recent: []
    property string browserId: ""

    readonly property string activeAddress: Hyprland.activeToplevel
        ? Hyprland.activeToplevel.address : ""
    readonly property bool pinsExplicit: Settings.explicitOverrides.indexOf("dockPinned") !== -1
    readonly property var pins: DockHelpers.effectivePins(Settings.dockPinned, pinsExplicit,
        DockHelpers.suggestedPins(browserId))

    // Desktop entries load after the shell starts, and an app installed later
    // appears then too; reading the list makes both re-resolve.
    readonly property var installedPins: {
        void DesktopEntries.applications.values;
        return pins.filter(id => DesktopEntries.byId(id) !== null);
    }

    readonly property var windows: Hyprland.toplevels.values.map(toplevel => {
        void DesktopEntries.applications.values;
        const wayland = toplevel.wayland;
        const ipc = toplevel.lastIpcObject || {};
        const appId = (wayland && wayland.appId) || ipc.class || ipc.initialClass || "";
        return {
            address: toplevel.address,
            appId: appId,
            entryId: root.entryIdFor(appId)
        };
    })
    readonly property var apps: DockHelpers.groupApps(windows, installedPins, recent)
    // Items are recreated only when the set of apps changes, not when a
    // window opens in one that is already there.
    readonly property string appsKey: JSON.stringify(DockHelpers.displayKeys(apps))
    readonly property var appByKey: {
        const map = {};
        for (const app of apps)
            map[app.key] = app;
        return map;
    }

    function entryIdFor(appId) {
        if (appId === "" || DockHelpers.isShellWindow(appId))
            return "";
        const entry = DesktopEntries.heuristicLookup(appId);
        return entry ? entry.id : "";
    }

    function entryFor(app) {
        return app && app.entryId !== "" ? DesktopEntries.byId(app.entryId) : null;
    }

    function titleFor(app) {
        const entry = entryFor(app);
        if (entry && entry.name !== "")
            return entry.name;
        return app && app.appId !== "" ? app.appId : "Application";
    }

    function iconFor(app) {
        const entry = entryFor(app);
        const name = entry && entry.icon !== "" ? entry.icon : app ? app.appId : "";
        return Quickshell.iconPath(name, "application-x-executable");
    }

    function menuActions(key) {
        return DockHelpers.menuActions(appByKey[key], pins);
    }

    function runAction(key, action) {
        if (action === "launch")
            launch(key);
        else if (action === "pin" || action === "unpin")
            togglePin(key);
        else if (action === "close")
            closeApp(key);
    }

    function isLive(address) {
        return Hyprland.toplevels.values.some(toplevel => toplevel.address === address);
    }

    function launch(key) {
        const entry = entryFor(appByKey[key]);
        if (entry)
            entry.execute();
    }

    function activate(key) {
        const action = DockHelpers.clickAction(appByKey[key], activeAddress);
        if (action.kind === "launch") {
            launch(key);
        } else if (action.kind === "focus" && isLive(action.address)) {
            const command = WindowCommands.focusWindow(action.address);
            if (command !== "")
                Hyprland.dispatch(command);
        }
    }

    function togglePin(key) {
        const app = appByKey[key];
        if (!app || !DockHelpers.validId(app.entryId))
            return;
        Settings.set("dockPinned", DockHelpers.isPinned(pins, app.entryId)
            ? DockHelpers.unpin(pins, app.entryId) : DockHelpers.pin(pins, app.entryId));
    }

    // A graceful close request per window, as the title bar's close does:
    // an application with unsaved work still asks. Each address is checked
    // first because Hyprland closes the active window for one it cannot find.
    function closeApp(key) {
        const app = appByKey[key];
        if (!app)
            return;
        for (const address of app.windows) {
            const command = isLive(address) ? WindowCommands.closeWindow(address) : "";
            if (command !== "")
                Hyprland.dispatch(command);
        }
    }

    onActiveAddressChanged: {
        if (activeAddress !== "")
            recent = DockHelpers.touchRecent(recent, activeAddress);
    }

    // The default browser joins the suggested pins. mimeapps.list is the
    // file the session's xdg-open reads; a missing or unreadable one simply
    // leaves Files and the terminal.
    FileView {
        path: Quickshell.env("HOME") + "/.config/mimeapps.list"
        printErrors: false
        watchChanges: true
        onFileChanged: reload()
        onLoaded: root.browserId = DockHelpers.defaultBrowserId(text())
        onLoadFailed: root.browserId = ""
    }
}
