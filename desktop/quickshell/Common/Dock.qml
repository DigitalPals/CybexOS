pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import "DockHelpers.js" as DockHelpers
import "WindowCommands.js" as WindowCommands
import "LauncherProviders.js" as ProviderHelpers

// The dock's shared model and actions (DockWindow.qml draws it on each
// eligible output). No eligible output means this singleton is not constructed.
//
// Items are the pinned apps (desktop entry ids in Settings.dockPinned) and
// every running app, grouped by desktop entry. Running windows come from
// Hyprland's toplevels; their app id is the Wayland one, which stays current
// where `hyprctl clients` data would need a refresh.
Singleton {
    id: root

    // Focus history, most recent first, for "focus the app's last window".
    property var recent: []
    property var effectiveDefaults: ({})
    property int defaultsEpoch: 0
    readonly property string browserId: String(effectiveDefaults.browser || "").replace(/\.desktop$/, "")
    readonly property string terminalId: String(effectiveDefaults.terminal || "").replace(/\.desktop$/, "")
    property var webApps: []
    readonly property var desktopApps: DesktopEntries.applications.values

    // One local registry read on construction and when desktop entries change,
    // coalesced across installs/removals. No network or per-window subprocess.
    onDesktopAppsChanged: { webAppRefresh.restart(); DefaultApplications.refresh(); }
    Component.onCompleted: { webAppRefresh.restart(); refreshDefaults(); }

    function refreshDefaults() {
        if (defaultsRequest.busy)
            return;
        defaultsRequest.epoch = defaultsEpoch;
        defaultsRequest.run(["cybexos-apps", "effective-defaults"]);
    }

    // Settings already obtains full status after a selection. Publish it
    // immediately, and prevent an earlier periodic query from replacing it.
    Connections {
        target: DefaultApplications
        function onRolesChanged() {
            root.defaultsEpoch++;
            root.effectiveDefaults = {
                browser: (DefaultApplications.roles.browser || {}).effective || "",
                terminal: (DefaultApplications.roles.terminal || {}).effective || ""
            };
        }
    }

    readonly property string activeAddress: Hyprland.activeToplevel
        ? Hyprland.activeToplevel.address : ""
    readonly property bool pinsExplicit: Settings.explicitOverrides.indexOf("dockPinned") !== -1
    readonly property var pins: DockHelpers.effectivePins(Settings.dockPinned, pinsExplicit,
        DockHelpers.suggestedPins(browserId, terminalId))

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
        const webId = DockHelpers.webAppEntryId(appId, webApps);
        const entry = DesktopEntries.byId(appId)
            || (webId !== "" ? DesktopEntries.byId(webId) : null)
            || DesktopEntries.heuristicLookup(appId);
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
        const app = appByKey[key];
        const actions = DockHelpers.menuActions(app, pins);
        if (DesktopWorkspaces.ready && app && app.windows.length > 0) {
            const hidden = app.windows.some(address => DesktopWorkspaces.isMinimized(address));
            if (hidden)
                actions.unshift({ id: "restore", label: I18n.tr("Restore window"), glyph: "open_in_full" });
            else if (app.windows.some(address => DesktopWorkspaces.canMinimize(address)))
                actions.unshift({ id: "minimize", label: I18n.tr("Minimize"), glyph: "remove" });
        }
        return actions;
    }

    function runAction(key, action) {
        if (action === "launch")
            launch(key);
        else if (action === "pin" || action === "unpin")
            togglePin(key);
        else if (action === "close")
            closeApp(key);
        else if (action === "minimize" || action === "restore") {
            const app = appByKey[key];
            if (!app)
                return;
            const address = action === "restore"
                ? app.windows.find(address => DesktopWorkspaces.isMinimized(address))
                : app.windows.indexOf(activeAddress) !== -1 && DesktopWorkspaces.canMinimize(activeAddress) ? activeAddress
                    : app.windows.find(address => DesktopWorkspaces.canMinimize(address));
            if (isLive(address)) {
                if (action === "restore")
                    DesktopWorkspaces.activate(address);
                else
                    Minimizer.minimize(address);
            }
        }
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
        const app = appByKey[key];
        if (action.kind === "none" && app && app.windows.length === 1
                && app.windows[0] === activeAddress && DesktopWorkspaces.canMinimize(activeAddress)) {
            Minimizer.minimize(activeAddress);
            return;
        }
        if (action.kind === "launch") {
            launch(key);
        } else if (action.kind === "focus" && isLive(action.address)) {
            // Clicking a focused, single-window app minimizes it. Multiple
            // windows keep the existing cycling behavior. Layout changes
            // never write the dock's auto-hide or pin preferences.
            if (DesktopWorkspaces.ready && app && app.windows.length === 1
                    && action.address === activeAddress && !DesktopWorkspaces.isMinimized(action.address)
                    && DesktopWorkspaces.canMinimize(action.address)) {
                Minimizer.minimize(action.address);
                return;
            }
            const command = DesktopWorkspaces.activateCommand(action.address);
            if (command !== "")
                DesktopWorkspaces.dispatch(command, action.address);
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

    Timer {
        id: webAppRefresh
        interval: 100
        onTriggered: {
            if (!webAppList.running)
                webAppList.running = true;
            else
                restart();
        }
    }
    Process {
        id: webAppList
        command: ["cybexos-webapp", "list", "--json"]
        stdout: StdioCollector {
            onStreamFinished: root.webApps = ProviderHelpers.parseWebApps(text)
        }
    }

    // GIO and xdg-terminal-exec resolve personal and system defaults together.
    // This shared singleton queries only the effective IDs on periodic ticks;
    // installed-app changes above still refresh the Settings catalog.
    JsonCommand {
        id: defaultsRequest
        property int epoch: 0
        onCompleted: value => {
            if (epoch === root.defaultsEpoch)
                root.effectiveDefaults = value;
        }
    }
    Timer { interval: 30000; repeat: true; running: true; onTriggered: root.refreshDefaults() }
}
