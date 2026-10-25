// Structure contracts for the window overview, the workspace dock and the
// Control Center's Top processes list. The pure rules are tested in
// overview-helpers, dock-helpers, process-list-helpers and window-commands;
// this holds the QML to the lifetimes those rules depend on — nothing runs
// while closed or off, captures exist only while the overview is mapped, and
// every Hyprland dispatch goes through the validated builders.
const test = require("node:test");
const { untranslated } = require("./shell.cjs");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { shellDir, load } = require("./shell.cjs");

const read = relative => untranslated(fs.readFileSync(path.join(shellDir, relative), "utf8"));
const shell = read("shell.qml");
const overviewWindow = read("OverviewWindow.qml");
const overviewView = read("OverviewView.qml");
const overview = read("Common/Overview.qml");
const dockWindow = read("DockWindow.qml");
const dock = read("Common/Dock.qml");
const processList = read("Common/ProcessList.qml");
const processes = read("Popovers/Drawer/DrawerProcesses.qml");
const drawerOverview = read("Popovers/Drawer/DrawerOverview.qml");
const bindings = untranslated(fs.readFileSync(path.resolve(shellDir, "../hypr/bindings.lua"), "utf8"));
const look = untranslated(fs.readFileSync(path.resolve(shellDir, "../hypr/looknfeel.lua"), "utf8"));

function functionBody(source, name) {
    const start = source.indexOf(`function ${name}(`);
    assert.notEqual(start, -1, `${name}() is missing`);
    let depth = 0;
    for (let index = source.indexOf("{", start); index < source.length; index++) {
        if (source[index] === "{") depth++;
        else if (source[index] === "}" && --depth === 0)
            return source.slice(start, index + 1);
    }
    return source.slice(start);
}

// ---- overview -------------------------------------------------------------

test("Super+Tab and the overview IPC target reach one overview", () => {
    assert.match(bindings,
        /bind\(mainMod \.\. " \+ TAB", hl\.dsp\.global\("quickshell:overviewToggle"\), \{ description = "Windows: Overview" \}, "windows.overview"\)/);
    assert.match(shell, /GlobalShortcut \{\s*appid: "quickshell"\s*name: "overviewToggle"[\s\S]{0,120}?onPressed: Overview\.toggle\(\)/);
    assert.match(shell, /^\s*OverviewWindow \{\}$/m);
    assert.equal((shell.match(/target: "overview"/g) || []).length, 0,
        "the IPC target is registered once, in OverviewWindow");
    const ipc = overviewWindow.slice(overviewWindow.indexOf("IpcHandler {"));
    assert.match(ipc, /target: "overview"/);
    for (const name of ["toggle", "open", "close"])
        assert.match(ipc, new RegExp(`function ${name}\\(\\): void`), `overview ${name}() is missing`);
});

test("a closed overview maps nothing and captures nothing", () => {
    assert.match(overviewWindow, /visible: Overview\.open \|\| presence > 0\.001/);
    assert.match(overviewWindow, /Loader \{[\s\S]*?active: root\.visible && root\.screen !== null[\s\S]*?OverviewView \{/,
        "the view, and every capture in it, exists only while the surface is mapped");
    assert.match(overviewWindow, /WlrLayershell\.layer: WlrLayer\.Overlay/);
    assert.match(overviewWindow, /WlrLayershell\.namespace: "qs-overview"/);
    assert.match(overviewWindow,
        /keyboardFocus: Overview\.open\s*\? WlrKeyboardFocus\.Exclusive : WlrKeyboardFocus\.None/);
    assert.match(overviewWindow, /HyprlandFocusGrab \{\s*active: Overview\.open/);
    assert.match(overviewWindow, /onOutputPresentChanged:[\s\S]{0,120}?Overview\.close\(\)/,
        "an unplugged output takes its overview with it");
    assert.match(overviewView, /ScreencopyView \{[\s\S]{0,200}?captureSource: thumb\.info && thumb\.info\.minimized \? null\s*: thumb\.toplevel \? thumb\.toplevel\.wayland : null[\s\S]{0,80}?live: Overview\.open/);
    assert.doesNotMatch(overviewView, /ClippingRectangle \{[^}]*ScreencopyView/,
        "an offscreen-clipped capture would re-render its clip on every frame");
});

test("opening refreshes window geometry, and only an open overview refreshes it again", () => {
    assert.match(functionBody(overview, "show"), /Hyprland\.refreshToplevels\(\)/);
    assert.match(functionBody(overview, "show"), /Popouts\.close\(\);\s*Launcher\.close\(\);\s*Session\.closeKeys\(\);/);
    assert.match(overviewView, /function onRawEvent\(event\) \{[\s\S]{0,160}?refreshTimer\.restart\(\)/);
    assert.match(overviewView, /id: refreshTimer[\s\S]{0,80}?onTriggered: Hyprland\.refreshToplevels\(\)/);
    for (const name of ["openwindow", "closewindow", "movewindowv2", "changefloatingmode", "fullscreen"])
        assert.ok(overviewView.includes(`"${name}"`), `${name} re-reads geometry`);
});

test("the overview leaves special workspaces out and keys delegates structurally", () => {
    assert.match(overviewView, /OverviewHelpers\.isSpecialWorkspace\(\{ id: workspace\.id, name: workspace\.name \}\)/);
    assert.match(overviewView, /OverviewHelpers\.workspaceEntries\(workspaceRecords, windows, \{ authoritative: DesktopWorkspaces\.ready \}\)/);
    assert.match(overviewView, /readonly property string tilesKey: JSON\.stringify/);
    assert.match(overviewView, /readonly property var tiles: JSON\.parse\(tilesKey\)/);
    assert.match(overviewView, /model: root\.tiles/);
    assert.match(overviewView, /model: tile\.addresses/,
        "thumbnails are keyed by address, so a title change never restarts a capture");
    assert.match(overviewView, /readonly property string addressesKey: placement \? placement\.key : "\[\]"\s*readonly property var addresses: JSON\.parse\(addressesKey\)/,
        "the model goes through a string, which notifies only when the set changes");
    assert.match(overviewView, /OverviewHelpers\.filterScores\(windows, query,\s*LauncherHelpers\.windowScore\)/,
        "the filter ranks as the launcher's window provider does");
});

test("every overview dispatch is validated and checks the window still exists", () => {
    assert.doesNotMatch(overviewView, /Hyprland\.dispatch\(["'`]/, "no hand-built dispatch strings");
    assert.match(functionBody(overviewView, "activateWindow"),
        /root\.toplevelByAddress\[address\] \? DesktopWorkspaces\.activateCommand\(address\) : ""/);
    const finish = functionBody(overviewView, "finishDrag");
    assert.match(finish, /!root\.toplevelByAddress\[address\]/);
    assert.match(finish, /DesktopWorkspaces\.moveCommand\(address, tile\)/);
    assert.match(finish, /WindowCommands\.desktopNewAndMove\(address, root\.output\.name\)/);
    assert.match(functionBody(overviewView, "activateWorkspace"), /DesktopWorkspaces\.focusCommand\(tile\)/);
    assert.match(overviewView, /onToplevelByAddressChanged:[\s\S]{0,160}?dragAddress = ""/,
        "a window closing mid-drag cancels the drag");
});

test("the overview's keys: arrows, Tab, Enter, and Esc clears before it closes", () => {
    const keys = overviewView.slice(overviewView.indexOf("Keys.onPressed"));
    for (const [key, action] of [["Left", "left"], ["Right", "right"], ["Up", "up"],
        ["Down", "down"], ["Tab", "next"], ["Backtab", "previous"]])
        assert.match(keys, new RegExp(`Qt\\.Key_${key}:\\s*root\\.move\\("${action}"\\)`));
    assert.match(keys, /Qt\.Key_Escape:\s*if \(filterInput\.text !== ""\)\s*filterInput\.text = "";\s*else\s*Overview\.close\(\);/);
    assert.match(keys, /Qt\.Key_Enter:[\s\S]{0,250}?root\.activateWorkspace\(root\.tiles\[root\.selectedTileIndex\]\)[\s\S]{0,80}?root\.activateWindow\(root\.selected\)/);
});

test("overview motion uses the shared tokens, which reduced motion zeroes", () => {
    assert.match(overviewWindow, /duration: Overview\.open \? Theme\.panelFadeDuration : Theme\.panelCloseDuration/);
    assert.match(overviewView, /Behavior on scale \{\s*NumberAnimation \{\s*duration: Theme\.panelMotionDuration/);
    assert.doesNotMatch(overviewView + overviewWindow, /duration:\s*\d/, "no literal durations");
});

// ---- dock -----------------------------------------------------------------

test("the dock follows each monitor's live workspace and saved layout", () => {
    assert.match(shell, /model: Screens\.layerSurfaceModel\.filter\(output => \{/);
    assert.match(shell, /const monitor = Hyprland\.monitorFor\(output\.screen\)/);
    assert.match(shell, /DockHelpers\.showOnWorkspace\(Settings\.dock, active,\s*DesktopWorkspaces\.workspace\(active \? active\.id : 0\)\)/);
    assert.equal((shell.match(/\bDock\./g) || []).length, 0, "naming the singleton would construct it");
    assert.match(dockWindow, /WlrLayershell\.namespace: "qs-dock"/);
    assert.match(dockWindow, /anchors\.bottom: true/);
    assert.match(dockWindow, /exclusionMode: ExclusionMode\.Normal/);
    assert.match(dockWindow, /exclusiveZone: place\.exclusiveZone/);
    assert.match(dockWindow, /DockHelpers\.placement\(\{\s*barPosition: barShown \? Settings\.position : "top"/,
        "a bottom bar is stepped over, never overlapped");
    assert.match(dockWindow, /barZone: BarGeometry\.exclusiveZone\(/);
});

test("dock auto-hide reveals at the edge and keeps clicks off hidden pixels", () => {
    assert.match(dockWindow, /readonly property bool hidden: Settings\.dockAutoHide && !revealed && menuKey === ""/);
    assert.match(dockWindow, /mask: Region \{\s*item: root\.hidden \? revealStrip : dockArea/);
    assert.match(dockWindow, /function onDockAutoHideChanged\(\)/);
    assert.match(dockWindow, /Component\.onCompleted: \{\s*if \(Settings\.dockAutoHide\)\s*hideTimer\.restart\(\)/);
    assert.match(dockWindow, /width: shown \? menuCard\.width : 0/, "a closed menu adds nothing to the mask");
});

test("dock items are keyed by app and act through the Dock singleton", () => {
    assert.match(dock, /readonly property string appsKey: JSON\.stringify\(DockHelpers\.displayKeys\(apps\)\)/);
    assert.match(dockWindow, /readonly property var keys: JSON\.parse\(Dock\.appsKey\)/);
    assert.match(dockWindow, /Qt\.LeftButton \| Qt\.MiddleButton \| Qt\.RightButton/);
    assert.match(dock, /readonly property bool pinsExplicit: Settings\.explicitOverrides\.indexOf\("dockPinned"\) !== -1/);
    assert.match(functionBody(dock, "togglePin"), /Settings\.set\("dockPinned"/);
    assert.match(functionBody(dock, "closeApp"), /isLive\(address\) \? WindowCommands\.closeWindow\(address\) : ""/,
        "a vanished window must not turn into closing the active one");
    assert.match(functionBody(dock, "activate"), /isLive\(action\.address\)/);
    assert.doesNotMatch(dock + dockWindow, /Hyprland\.dispatch\(["'`]/);
    assert.match(dock, /void DesktopEntries\.applications\.values;/,
        "pins resolve again once desktop entries have loaded");
});

test("running web apps reuse their launcher's icon, name and pinned group", () => {
    const entries = {
        "brave": { id: "brave", name: "Brave", icon: "brave" },
        "cybexos-webapp-whatsapp": { id: "cybexos-webapp-whatsapp", name: "WhatsApp",
            icon: "/home/alice/.local/share/cybexos/webapps/whatsapp/icon.png" }
    };
    const context = {
        DockHelpers: load("DockHelpers.js"),
        webApps: [{ id: "whatsapp", url: "https://web.whatsapp.com/" }],
        DesktopEntries: { byId: id => entries[id] || null,
            heuristicLookup: () => entries["brave"] },
        Quickshell: { iconPath: name => name }
    };
    context.root = context;
    vm.createContext(context);
    for (const name of ["entryIdFor", "entryFor", "titleFor", "iconFor"])
        vm.runInContext(functionBody(dock, name), context);
    const appId = "brave-web.whatsapp.com__-Default";
    const entryId = context.entryIdFor(appId);
    const apps = context.DockHelpers.groupApps([{ address: "w1", appId, entryId }],
        ["cybexos-webapp-whatsapp"], []);
    assert.equal(apps.length, 1, "a running web app joins its pin rather than adding a fallback item");
    assert.equal(apps[0].running, true);
    assert.equal(context.titleFor(apps[0]), "WhatsApp");
    assert.equal(context.iconFor(apps[0]), entries[entryId].icon);
    assert.equal(context.entryIdFor("brave"), "brave");
    delete entries[entryId];
    assert.equal(context.entryIdFor(appId), "brave", "removed desktop entries fall back to the native resolver");
    assert.match(dock, /onDesktopAppsChanged: \{ webAppRefresh\.restart\(\)/,
        "install/remove causes a fresh registry read");
    assert.match(dock, /command: \["cybexos-webapp", "list", "--json"\]/);
});

test("the dock's all-layout preference and auto-hide sit in the Bar page and are searchable", () => {
    const groups = read("Settings/BarLayoutGroups.qml");
    assert.match(groups, /SettingsGroup \{\s*width: parent\.width\s*title: "Dock"/);
    assert.match(groups, /settingKey: "dock"/);
    assert.match(groups, /label: "Show in all layouts"/);
    assert.match(groups, /settingKey: "dockAutoHide"/);
    assert.doesNotMatch(groups, /reveal: Settings\.dock/,
        "auto-hide is available for automatic floating docks too");
    const search = require(path.join(shellDir, "Common/SettingsSearchData.js"));
    for (const key of ["dock", "dockAutoHide"])
        assert.ok(search.ROWS.some(row => row.key === key && row.page === "bar"), key);
    assert.ok(search.search("taskbar").some(row => row.key === "dock"));
    const settings = read("Common/Settings.qml");
    assert.match(settings, /"mods", "modOpts", "dock", "dockAutoHide", "dockPinned"\]/);
});

// ---- top processes ----------------------------------------------------------

test("Top processes samples only while it is on screen", () => {
    assert.match(drawerOverview,
        /DrawerProcesses \{\s*visible: Settings\.drawerOverview\.processes === true/);
    assert.ok(drawerOverview.indexOf("DrawerSystemHero {") < drawerOverview.indexOf("DrawerProcesses {"));
    assert.match(processes, /Claim \{\s*active: root\.visible\s*onClaimed: ProcessList\.acquire\(\)\s*onReleased: ProcessList\.release\(\)/);
    assert.match(processList, /interval: 2000\s*running: root\.watchers > 0\s*repeat: true/);
    assert.match(processList, /command: \["bash", root\.helper, "list"\]\s*timeoutMs: 5000/,
        "a sample is one bounded process");
    assert.match(functionBody(processList, "release"), /confirming = null;\s*ending = null;/,
        "closing the drawer drops a pending question");
    const settingsPage = read("Settings/DrawerPage.qml");
    assert.match(settingsPage, /\{ key: "processes", label: "Top processes"/);
});

test("ending a process is confirmed, signals by start time, and escalates only when asked", () => {
    assert.match(functionBody(processList, "requestEnd"), /if \(!canEnd\(row\) \|\| ending !== null\)/);
    assert.match(functionBody(processList, "confirmEnd"), /send\(target, "TERM"\)/);
    const force = functionBody(processList, "forceQuit");
    assert.match(force, /ending\.stage !== "stuck"/, "force quit is only offered after SIGTERM was ignored");
    assert.match(force, /send\(ending, "KILL"\)/);
    assert.match(functionBody(processList, "send"),
        /\["bash", helper, "signal", String\(target\.pid\),\s*String\(target\.start\), signalName\]/);
    assert.match(processes, /onClicked: ProcessList\.requestEnd\(slot\.row\)/,
        "the row button only asks; the confirmation acts");
    assert.match(processes, /ProcessList\.confirmEnd\(\);\s*else\s*ProcessList\.forceQuit\(\);/);
    assert.match(processes, /"Open system monitor"/);
    assert.match(processes, /Quickshell\.execDetached\(\["cybexos-apps", "terminal", "--", "btop"\]\)/);
    assert.match(bindings, /hl\.dsp\.exec_cmd\(terminal \.\. " btop"\)/,
        "the row opens what Super+Shift+T opens");
});

// ---- compositor rules -------------------------------------------------------

test("both surfaces skip layer animations; only the dock is blurred", () => {
    const noAnim = look.match(/name = "quickshell-no-animation",\s*match = \{ namespace = \[\[([^\]]+)\]\] \}/);
    assert.ok(noAnim);
    assert.match(noAnim[1], /\|overview\|dock\|assistant\)\$$/);
    const blur = look.match(/name = "quickshell-blur",[\s\S]*?namespace = \[\[([^\]]+)\]\]/);
    assert.ok(blur);
    assert.match(blur[1], /\|dock\)\$$/);
    assert.doesNotMatch(blur[1], /overview/, "a blur behind live captures redraws every frame");
});
