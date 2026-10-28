pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Hyprland
import "WindowCommands.js" as WindowCommands

// The Mac-like desktop style's menubar menus (Settings → Appearance → Desktop
// style): the system menu behind the Cybex symbol, the front app's menu under
// its name, and the Window menu. Each menu is a list of rows the popover
// draws (Popovers/MacMenuPopover.qml) and every row runs through run().
//
// Linux applications do not publish their own File, Edit and View menus to a
// Wayland menubar, so the app and Window menus hold what the desktop can do
// for any application: open another window, hide it (minimize every window),
// quit (ask every window to close), zoom, move it to another workspace.
//
// Nothing here is constructed until a Mac-like menubar or its popover names
// it; the app identity comes from the dock's model, which the Mac-like style
// shows on every output anyway.
Singleton {
    id: root

    readonly property string activeAddress: Dock.activeAddress
    // The app the focused window belongs to; null on an empty desktop.
    readonly property var app: {
        const address = activeAddress;
        if (address === "")
            return null;
        return Dock.apps.find(app => app.windows.indexOf(address) !== -1) || null;
    }
    readonly property string appName: app ? Dock.titleFor(app) : I18n.tr("Desktop")
    readonly property var appEntry: app ? Dock.entryFor(app) : null
    readonly property var filesEntry: DesktopEntries.byId("org.gnome.Nautilus")
    // The focused window's toplevel: its title and floating state.
    readonly property var activeWindow: Hyprland.activeToplevel
    readonly property bool activeFloating: !!(activeWindow && activeWindow.lastIpcObject
        && activeWindow.lastIpcObject.floating)

    // Regular numbered workspaces a window can move to, in order.
    readonly property var workspaces: Hyprland.workspaces.values
        .filter(workspace => workspace.id > 0)
        .sort((a, b) => a.id - b.id)
        .map(workspace => ({ id: workspace.id, label: workspace.name || String(workspace.id) }))
    readonly property int activeWorkspace: Hyprland.focusedWorkspace
        ? Hyprland.focusedWorkspace.id : 0

    function liveWindows(app) {
        return app ? app.windows.filter(address => Dock.isLive(address)) : [];
    }

    function toplevel(address) {
        return Hyprland.toplevels.values.find(toplevel => toplevel.address === address) || null;
    }

    function windowWorkspace(address) {
        const window = toplevel(address);
        return window && window.workspace ? window.workspace.id : 0;
    }

    function item(id, label, enabled, extra) {
        return Object.assign({ kind: "item", id: id, label: label, enabled: enabled !== false,
            checked: false, detail: "", arg: "" }, extra || {});
    }

    function separator() {
        return { kind: "separator", id: "", label: "", enabled: false, checked: false, detail: "", arg: "" };
    }

    function header(label) {
        return { kind: "header", id: "", label: label, enabled: false, checked: false, detail: "", arg: "" };
    }

    // ---- menus ----------------------------------------------------------

    function menu(name) {
        if (name === "macsystem")
            return systemMenu();
        if (name === "macapp")
            return appMenu();
        if (name === "macwindow")
            return windowMenu();
        return [];
    }

    function systemMenu() {
        return [
            item("about", I18n.tr("About Cybex OS")),
            separator(),
            item("settings", I18n.tr("System Settings…")),
            item("update", I18n.tr("Software Update…")),
            separator(),
            item("sleep", I18n.tr("Sleep")),
            item("restart", I18n.tr("Restart")),
            item("shutdown", I18n.tr("Shut Down")),
            separator(),
            item("lock", I18n.tr("Lock Screen")),
            item("logout", I18n.tr("Log Out"))
        ];
    }

    function minimizedOnWorkspace() {
        const workspace = activeWorkspace;
        return Hyprland.toplevels.values
            .map(toplevel => toplevel.address)
            .filter(address => {
                const row = DesktopWorkspaces.minimizedWindow(address);
                return row !== null && (workspace === 0 || row.workspace === workspace);
            });
    }

    function appMenu() {
        const showAll = item("showAll", I18n.tr("Show All"), minimizedOnWorkspace().length > 0);
        if (!app) {
            return [
                item("newFiles", I18n.tr("New Files Window"), filesEntry !== null),
                separator(),
                showAll
            ];
        }
        const windows = liveWindows(app);
        const visible = windows.filter(address => !DesktopWorkspaces.isMinimized(address)
            && DesktopWorkspaces.canMinimize(address));
        return [
            item("newWindow", I18n.tr("New Window"), appEntry !== null),
            separator(),
            item("hide", I18n.format("Hide %1", [appName]), visible.length > 0),
            item("hideOthers", I18n.tr("Hide Others"), othersOnWorkspace().length > 0),
            showAll,
            separator(),
            item("quit", I18n.format("Quit %1", [appName]), windows.length > 0)
        ];
    }

    // Other apps' windows that can be hidden on the focused workspace.
    function othersOnWorkspace() {
        const own = app ? app.windows : [];
        const workspace = activeWorkspace;
        return Hyprland.toplevels.values
            .filter(toplevel => own.indexOf(toplevel.address) === -1
                && toplevel.workspace && toplevel.workspace.id === workspace
                && !DesktopWorkspaces.isMinimized(toplevel.address)
                && DesktopWorkspaces.canMinimize(toplevel.address))
            .map(toplevel => toplevel.address);
    }

    function windowMenu() {
        const address = activeAddress;
        const has = address !== "" && Dock.isLive(address);
        const rows = [
            item("minimize", I18n.tr("Minimize"), has && DesktopWorkspaces.canMinimize(address)),
            item("zoom", I18n.tr("Zoom"), has),
            item("fullscreen", I18n.tr("Enter Full Screen"), has),
            item("float", activeFloating ? I18n.tr("Tile Window") : I18n.tr("Float Window"),
                has && DesktopWorkspaces.canMinimize(address)),
            separator(),
            header(I18n.tr("Move to Workspace"))
        ];
        const current = has ? windowWorkspace(address) : 0;
        for (const workspace of workspaces) {
            rows.push(item("move", I18n.format("Workspace %1", [workspace.label]),
                has && workspace.id !== current, { checked: workspace.id === current, arg: workspace.id }));
        }
        rows.push(item("moveNew", I18n.tr("New Workspace"), has && DesktopWorkspaces.ready));
        rows.push(separator());
        rows.push(item("bringAll", I18n.tr("Bring All to Front"), !!app && liveWindows(app).length > 0));
        const windows = liveWindows(app);
        if (windows.length > 0) {
            rows.push(separator());
            for (const window of windows) {
                const toplevel = root.toplevel(window);
                rows.push(item("focus", toplevel && toplevel.title !== "" ? toplevel.title : appName, true, {
                    checked: window === address,
                    detail: DesktopWorkspaces.isMinimized(window) ? I18n.tr("Minimized") : "",
                    arg: window
                }));
            }
        }
        rows.push(separator());
        rows.push(item("close", I18n.tr("Close Window"), has));
        return rows;
    }

    // ---- actions --------------------------------------------------------

    function dispatch(command) {
        if (command !== "")
            Hyprland.dispatch(command);
    }

    function run(row, screenName) {
        if (!row || row.kind !== "item" || !row.enabled)
            return;
        const address = activeAddress;
        switch (row.id) {
        case "about":
            Settings.showPanel("about", screenName);
            break;
        case "settings":
            // Opens on the page last shown, as System Settings does.
            Settings.showPanel("", screenName);
            break;
        case "update":
            Updates.show();
            break;
        case "sleep":
            Session.suspend();
            break;
        case "restart":
            Session.reboot();
            break;
        case "shutdown":
            Session.shutdown();
            break;
        case "lock":
            Session.lock();
            break;
        case "logout":
            Session.logout();
            break;
        case "newFiles":
            if (filesEntry)
                filesEntry.execute();
            break;
        case "newWindow":
            if (appEntry)
                appEntry.execute();
            break;
        case "hide":
            for (const window of liveWindows(app)) {
                if (!DesktopWorkspaces.isMinimized(window))
                    Minimizer.minimize(window);
            }
            break;
        case "hideOthers":
            for (const window of othersOnWorkspace())
                Minimizer.minimize(window);
            break;
        case "showAll":
            for (const window of minimizedOnWorkspace())
                DesktopWorkspaces.activate(window);
            break;
        case "quit":
            if (app)
                Dock.closeApp(app.key);
            break;
        case "minimize":
            Minimizer.minimize(address);
            break;
        case "zoom":
            dispatch(Dock.isLive(address) ? WindowCommands.maximizeWindow(address) : "");
            break;
        case "fullscreen":
            dispatch(Dock.isLive(address) ? WindowCommands.fullscreenWindow(address) : "");
            break;
        case "float":
            DesktopWorkspaces.dispatch(WindowCommands.desktopToggleFloating(address), address);
            break;
        case "move":
            DesktopWorkspaces.move(address, row.arg);
            break;
        case "moveNew": {
            const monitor = Hyprland.focusedMonitor;
            DesktopWorkspaces.newWorkspaceAndMove(address, monitor ? monitor.name : "");
            break;
        }
        case "bringAll": {
            const windows = liveWindows(app);
            for (const window of windows) {
                if (DesktopWorkspaces.isMinimized(window))
                    DesktopWorkspaces.activate(window);
            }
            const last = app ? app.recent : "";
            if (last && Dock.isLive(last))
                DesktopWorkspaces.activate(last);
            break;
        }
        case "focus":
            DesktopWorkspaces.activate(row.arg);
            break;
        case "close":
            dispatch(Dock.isLive(address) ? WindowCommands.closeWindow(address) : "");
            break;
        }
    }

    // A menu belongs to the Mac-like menubar; switching style away while one
    // is open would leave it hanging under a title that no longer exists.
    Connections {
        target: Settings
        function onMacStyleChanged() {
            if (!Settings.macStyle && Popouts.currentName.indexOf("mac") === 0)
                Popouts.close();
        }
    }
}
