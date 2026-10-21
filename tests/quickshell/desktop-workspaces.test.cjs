// UI behavior under deterministic snapshots. These tests do not qualify a
// running compositor, native scrolling, decorations, hotplug, or an ISO.
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { load, shellDir } = require("./shell.cjs");
const H = load("WorkspaceHelpers.js");
const W = load("WindowCommands.js");
const O = load("OverviewHelpers.js");
const Tabler = load("TablerGlyphs.js");
const read = file => fs.readFileSync(path.join(shellDir, file), "utf8");

// The assigned IDs intentionally have no arithmetic relationship: the UI
// must not infer monitor blocks, local numbers, or identities from them.
function fixture() {
    return { v: 1, mode: "per-monitor", defaultLayout: "dwindle", titlebarsEnabled: false,
        capabilities: { scrolling: false, titlebars: false }, error: "",
        monitors: [
            { name: "eDP-1", identity: "physical-a", label: "Laptop", activeWorkspace: 41, workspaces: [41, 8, 901] },
            { name: "DP-3", identity: "physical-b", label: "External", activeWorkspace: 7, workspaces: [7, 65] }
        ], workspaces: [
            { id: 41, localNumber: 1, monitor: "eDP-1", label: "1", layout: "dwindle" },
            { id: 8, localNumber: 2, monitor: "eDP-1", label: "2", layout: "floating" },
            { id: 901, localNumber: 0, monitor: "eDP-1", label: "901 · DP-9", layout: "scrolling", guest: true, ownerIdentity: "offline" },
            { id: 7, localNumber: 1, monitor: "DP-3", label: "1", layout: "floating" },
            { id: 65, localNumber: 2, monitor: "DP-3", label: "2", layout: "dwindle" }
        ], minimized: [{ address: "0xABC", workspace: 8, monitor: "eDP-1" }] };
}
const snapshot = () => H.parseSnapshot(JSON.stringify(fixture()));
const live = (id, occupied = true) => ({ id, name: String(id), toplevels: { values: occupied ? [{}] : [] } });

test("all layout indicators use bundled theme icons", () => {
    for (const layout of ["dwindle", "scrolling", "floating", "unmanaged"])
        assert.ok(Tabler.has(H.layoutIcon(layout)), layout);
});

test("eval errors fail even when hyprctl exits zero", () => {
    assert.equal(H.commandSucceeded(0, 0, "ok\n"), true);
    for (const output of ["", "nil", "Lua error: stale window", "ok\nLua error", "error: unknown layout"])
        assert.equal(H.commandSucceeded(0, 0, output), false, output);
    assert.equal(H.commandSucceeded(1, 0, "ok"), false);
    assert.equal(H.commandSucceeded(0, 1, "ok"), false);
    assert.match(read("Common/DesktopWorkspaces.qml"),
        /WorkspaceHelpers\.commandSucceeded\(lastExit, lastStatus, outputText\)/);
});

test("snapshot reader rejects malformed, unsupported, unbounded and colliding data", () => {
    for (const text of ["{", "null", "[]", "x".repeat(1048577)])
        assert.equal(H.parseSnapshot(text), null);
    for (const mutate of [
        value => value.v = 2,
        value => value.mode = "execute",
        value => value.monitors[0].workspaces.push(777),
        value => value.workspaces.push(value.workspaces[0]),
        value => value.workspaces[0].id = "41;error()",
        value => value.workspaces[0].id = -98,
        value => value.minimized[0].address = 'abc"); error("x")',
        value => value.monitors.push(value.monitors[0])
    ]) {
        const value = fixture(); mutate(value);
        assert.equal(H.parseSnapshot(JSON.stringify(value)), null);
    }
    assert.equal(snapshot().titlebarsEnabled, false);
    assert.equal(snapshot().capabilities.scrolling, false);
});

test("each bar reads its own active ID and compositor local labels", () => {
    const state = snapshot();
    const windows = [live(41), live(7), live(901)];
    for (const [name, active, ids, labels] of [
        ["eDP-1", 41, [41, 8, 901], ["1", "2", "901 · DP-9"]],
        ["DP-3", 7, [7, 65], ["1", "2"]]
    ]) {
        assert.equal(H.monitor(state, name).activeWorkspace, active);
        const entries = H.barEntries(state, name, windows, 5, false, active);
        assert.deepEqual(entries.map(row => row.id), ids);
        assert.deepEqual(entries.map(row => row.label), labels);
    }
    assert.equal(H.workspace(state, 901).localNumber, 0);
    assert.equal(H.workspace(state, 901).ownerIdentity, "offline");
});

test("hide-empty keeps each display's empty active workspace and occupied guests", () => {
    const state = snapshot();
    const windows = [live(41, false), live(8, false), live(901), live(7)];
    const entries = H.barEntries(state, "eDP-1", windows, 10, true, 41);
    assert.deepEqual(entries.map(row => row.id), [41, 8, 901], "a workspace with minimized windows is occupied too");
});

test("connector changes and identical monitor descriptions never create UI identity guesses", () => {
    const value = fixture();
    value.monitors[1].name = "DP-8";
    value.monitors[1].label = value.monitors[0].label;
    value.workspaces.filter(row => row.monitor === "DP-3").forEach(row => row.monitor = "DP-8");
    const state = H.parseSnapshot(JSON.stringify(value));
    assert.equal(H.monitor(state, "DP-3"), null);
    assert.equal(H.monitor(state, "DP-8").identity, "physical-b");
    assert.deepEqual(H.barEntries(state, "DP-8", [live(7)], 5, false, 7).map(row => row.id), [7, 65]);
});

test("missing snapshots retain shared slots and leave scratchpads out", () => {
    const values = [live(1), live(3), { id: -98, name: "special:scratchpad" }, { id: 7, name: "special:odd" }];
    assert.deepEqual(H.barEntries(null, "DP-1", values, 5, false, 1).map(row => row.id), [1, 2, 3, 4, 5]);
    assert.deepEqual(H.barEntries(null, "DP-1", values.slice(0, 3), 5, true, 2).map(row => row.id), [1, 2, 3]);
});

test("overview uses module IDs and labels without allocating a free ID", () => {
    const entries = O.workspaceEntries([{ id: 7, name: "7", monitor: "DP-3", active: true },
        { id: -1337, name: "music", monitor: "DP-3", active: true }],
    [{ address: "abc", workspaceId: 8 }], { authoritative: true });
    assert.equal(entries.at(-1).id, 0);
    const decorated = H.decorateOverview(entries, snapshot(), "DP-3");
    assert.equal(decorated.find(row => row.id === 7).name, "1");
    assert.equal(decorated.find(row => row.id === 8).monitor, "eDP-1");
    assert.equal(decorated.find(row => row.id === -1337).name, "music");
    assert.equal(decorated.at(-1).monitor, "DP-3");
});

test("minimized address lookups normalize hex without admitting selectors", () => {
    assert.equal(H.minimizedWindow(snapshot(), "abc").workspace, 8);
    assert.equal(H.minimizedWindow(snapshot(), "0xAbC").monitor, "eDP-1");
    assert.equal(H.minimizedWindow(snapshot(), "address:0xabc"), null);
    assert.equal(H.minimizedWindow(null, "abc"), null);
});

test("module builders constrain operations, modes, IDs and addresses", () => {
    assert.equal(W.desktopActivate("0xABC"), 'require("workspaces").activate("0xabc")');
    assert.equal(W.desktopMove("abc", { id: 65 }), 'require("workspaces").move_id("0xabc", 65)');
    assert.equal(W.desktopFocus(901), 'require("workspaces").focus_id(901)');
    assert.equal(W.desktopNewAndMove("abc", "DP-3"),
        'require("workspaces").move_id("0xabc", require("workspaces").new_workspace("DP-3"))');
    assert.equal(W.desktopTitlebars(false), 'require("workspaces").set_titlebars_enabled(false)');
    for (const value of [0, -98, -1337, 1.5, "4", NaN, Infinity, 2147483647]) {
        assert.equal(W.desktopFocus(value), "");
        assert.equal(W.desktopMove("abc", value), "");
    }
    assert.equal(W.desktopDefaultLayout('floating");error("x")'), "");
    assert.equal(W.desktopMode("per_monitor"), "");
    assert.equal(W.desktopTitlebars("true"), "");
    assert.equal(W.desktopMinimize("abc;error()"), "");
    assert.equal(W.desktopNext(3, "DP-3"), "");
});

test("monitor names are escaped as Lua data and never shell code", () => {
    const name = 'DP-3\\dock";error("x")';
    assert.equal(W.desktopNew(name), 'require("workspaces").new_workspace("DP-3\\\\dock\\";error(\\"x\\")")');
    assert.equal(W.desktopNew("DP-3\n"), "");
    assert.equal(W.desktopNew("a".repeat(257)), "");
    assert.match(W.maximizeWindow("abc"), /window = "address:0xabc"/);
    assert.equal(W.maximizeWindow('abc"'), "");
});

function functionSource(source, name) {
    const match = new RegExp(`function ${name}\\([^)]*\\)\\s*\\{`).exec(source);
    assert.ok(match, name);
    let depth = 1, index = match.index + match[0].length;
    while (depth && index < source.length) {
        if (source[index] === "{") depth++;
        if (source[index] === "}") depth--;
        index++;
    }
    return source.slice(match.index, index);
}

function owner(ready) {
    const context = { ready, pendingCommands: [], Settings: { loaded: true },
        scrollingAvailable: false, commandProc: { running: false },
        WindowCommands: W, Hyprland: { workspaces: { values: [] },
            toplevels: { values: [{ address: "abc", workspace: { id: 8, name: "8" } }] },
            dispatch: command => context.sent.push(command) },
        Qt: { callLater: fn => fn() }, sent: [] };
    context.root = context;
    vm.createContext(context);
    const source = read("Common/DesktopWorkspaces.qml");
    for (const name of ["isLive", "targetWorkspace", "canSetLayout", "canMinimize", "dispatch", "runNext", "focusCommand", "activateCommand", "moveCommand", "activate", "focus", "move",
        "minimize", "setMode", "setDefaultLayout", "setTitlebarsEnabled", "setLayout", "cycleLayout"])
        vm.runInContext(functionSource(source, name), context);
    return context;
}

test("activation uses eval with module and shared focus without it, ignoring stale rows", () => {
    const enabled = owner(true);
    assert.equal(enabled.activate("gone"), false);
    assert.equal(enabled.activate("0xAbC"), true);
    assert.deepEqual(Array.from(enabled.commandProc.command), ["hyprctl", "eval", W.desktopActivate("abc")]);
    assert.deepEqual(enabled.sent, []);
    const fallback = owner(false);
    assert.equal(fallback.activate("abc"), true);
    assert.deepEqual(fallback.sent, [W.focusWindow("abc")]);
    assert.equal(fallback.minimize("abc"), false);
});

test("queued window operations recheck existence before starting a process", () => {
    const context = owner(true);
    context.commandProc.running = true;
    context.minimize("abc");
    context.Hyprland.toplevels.values = [];
    context.commandProc.running = false;
    context.runNext();
    assert.equal(context.pendingCommands.length, 0);
    assert.equal(context.commandProc.command, undefined);
});

test("preference changes wait for Settings.loaded and honor scrolling capabilities", () => {
    const context = owner(true);
    context.Settings.loaded = false;
    assert.equal(context.setMode("per-monitor"), false);
    assert.equal(context.setTitlebarsEnabled(true), false);
    assert.equal(context.setDefaultLayout("floating"), false);
    assert.equal(context.commandProc.command, undefined);
    context.Settings.loaded = true;
    assert.equal(context.setDefaultLayout("scrolling"), false);
    assert.equal(context.setLayout(41, "scrolling"), false);
    assert.equal(context.setMode("per-monitor"), true);
    assert.equal(context.commandProc.command[2], W.desktopMode("per-monitor"));
    const source = read("Common/DesktopWorkspaces.qml");
    assert.doesNotMatch(source, /Settings\.(set|workspaceMode|workspaceDefaultLayout|floatingTitlebars)|Component\.onCompleted/);
});

test("overview restores minimized records while keeping scratchpad and inactive group tabs out", () => {
    const source = functionSource(read("OverviewView.qml"), "record");
    const context = { DesktopWorkspaces: { minimizedWindow: address => H.minimizedWindow(snapshot(), address) }, OverviewHelpers: O,
        WindowCommands: W };
    vm.createContext(context);
    vm.runInContext(source, context);
    const hidden = { address: "abc", workspace: { id: -98, name: "special:cybexos-minimized" },
        title: "Editor", lastIpcObject: { hidden: true, size: [200, 100], fullscreen: 2, floating: true } };
    const record = context.record(hidden);
    assert.equal(record.workspaceId, 8);
    assert.equal(record.minimized, true);
    assert.equal(record.size, undefined, "a minimized window gets a readable fallback tile");
    assert.equal(record.fullscreen, false, "old fullscreen state must not obscure the whole workspace tile");
    assert.equal(context.record({ ...hidden, address: "def" }), null);
    assert.equal(context.record({ ...hidden, address: "def", workspace: { id: 8, name: "8" } }), null);
});

test("window churn cannot turn a keyboard-selected workspace into an unrelated window action", () => {
    const context = { selectedTileIndex: 1, selected: "abc", OverviewHelpers: O,
        items: [{ address: "abc", enabled: true }], scores: null, initialActive: "abc", query: "" };
    vm.createContext(context);
    vm.runInContext(functionSource(read("OverviewView.qml"), "settleSelection"), context);
    context.settleSelection();
    assert.equal(context.selected, "");
    context.selectedTileIndex = -1;
    context.settleSelection();
    assert.equal(context.selected, "abc");
});

test("workspace page uses compositor preferences and a link to the dock owner", () => {
    const page = read("Settings/WorkspacesPage.qml");
    assert.doesNotMatch(page, /settingKey:/);
    for (const setter of ["setMode", "setDefaultLayout", "setTitlebarsEnabled", "setLayout"])
        assert.ok(page.includes(`DesktopWorkspaces.${setter}(`));
    assert.match(page, /if \(DesktopWorkspaces\.scrollingAvailable\)/);
    assert.match(page, /Settings\.showSetting\("bar", "dock"\)/);
    const overview = read("OverviewView.qml");
    for (const key of ["PageUp", "PageDown", "M", "L", "N", "W"])
        assert.ok(overview.includes(`Qt.Key_${key}`), key);
    assert.doesNotMatch(read("Common/DesktopWorkspaces.qml"), /Settings\.set\("dock/);
});

test("native custom layouts and ownership survive parsing without becoming Tiled", () => {
    const value = fixture();
    value.defaultLayout = "unmanaged";
    value.defaultLayoutManaged = false;
    value.nativeDefaultLayout = "master";
    Object.assign(value.workspaces[0], { layout: "unmanaged", nativeLayout: "master", layoutManaged: false });
    const state = H.parseSnapshot(JSON.stringify(value));
    assert.equal(state.defaultLayout, "unmanaged");
    assert.equal(state.defaultLayoutManaged, false);
    assert.equal(state.nativeDefaultLayout, "master");
    assert.equal(H.workspace(state, 41).layout, "unmanaged");
    assert.equal(H.workspace(state, 41).nativeLayout, "master");
    assert.equal(H.workspace(state, 41).layoutManaged, false);
    const entry = H.decorateOverview(O.workspaceEntries([{ id: 41, name: "41", active: true }], []), state, "eDP-1")[0];
    assert.equal(entry.layout, "unmanaged");
    assert.equal(entry.nativeLayout, "master");
    const old = snapshot();
    assert.equal(old.defaultLayoutManaged, true, "older v1 snapshots remain managed");
    assert.equal(old.nativeDefaultLayout, "dwindle");
    assert.equal(H.workspace(old, 8).layoutManaged, true);
    value.workspaces[0].layout = "third-party-layout";
    assert.equal(H.parseSnapshot(JSON.stringify(value)).workspaces[0].layout, "unmanaged");
    const context = { I18n: { tr: text => text, format: (text, args) => text.replace("%1", args[0]) } };
    vm.createContext(context);
    vm.runInContext(functionSource(read("Common/DesktopWorkspaces.qml"), "layoutLabel"), context);
    assert.equal(context.layoutLabel("unmanaged", "master"), "Custom (master)");
});

test("Default is a transient clear-override action, including unmanaged native defaults", () => {
    assert.equal(W.desktopLayout(41, "default"), 'require("workspaces").set_layout(41, "default")');
    assert.equal(W.desktopDefaultLayout("default"), "");
    assert.equal(W.desktopDefaultLayout("unmanaged"), "");
    const context = owner(true);
    assert.equal(context.setLayout(41, "default"), true);
    assert.equal(context.commandProc.command[2], W.desktopLayout(41, "default"));
    const page = read("Settings/WorkspacesPage.qml");
    assert.match(page, /value: "default", label: I18n\.tr\("Default"\)/);
    assert.match(page, /onResetRequested: DesktopWorkspaces\.setLayout\(page\.selectedId, "default"\)/);
    assert.match(page, /I18n\.format\("Unmanaged \(%1\)"/);
    // Evaluate the actual picker binding for unmanaged inheritance/overrides.
    const expression = page.match(/readonly property string selectedLayout: ([\s\S]*?)\n\n/)[1];
    const picker = { selectedWorkspace: { layout: "unmanaged", layoutManaged: false },
        DesktopWorkspaces: { defaultLayout: "unmanaged", defaultLayoutManaged: false } };
    assert.equal(vm.runInNewContext(expression, picker), "default");
    picker.selectedWorkspace = { layout: "dwindle", layoutManaged: true };
    assert.equal(vm.runInNewContext(expression, picker), "dwindle", "an override remains explicit even with an unmanaged default");
});

test("renameworkspace 1 research preserves tile identity and native selection/drop with or without a snapshot", () => {
    const named = { id: 1, name: "research", monitor: "DP-3", active: true };
    const value = fixture();
    value.mode = "shared";
    value.workspaces.push({ id: 1, localNumber: 1, monitor: "eDP-1", label: "1", layout: "floating" });
    const stale = H.parseSnapshot(JSON.stringify(value));
    for (const state of [null, stale]) {
        const context = owner(state !== null);
        context.Hyprland.workspaces.values = [named];
        const entries = H.decorateOverview(O.workspaceEntries([named], [], { authoritative: !!state }), state, "DP-3");
        const tile = JSON.parse(JSON.stringify(entries[0]));
        assert.equal(tile.kind, "named");
        assert.equal(tile.workspaceName, "research");
        assert.equal(tile.name, "research");
        assert.equal(tile.monitor, "DP-3", "stale numbered ownership cannot replace native metadata");
        assert.equal(context.focusCommand(tile), W.focusWorkspace(named));
        assert.equal(context.moveCommand("abc", tile), W.moveWindow("abc", named));
        // Exercise the actual overview selection and drag handlers.
        const view = { DesktopWorkspaces: context, WindowCommands: W,
            Overview: { close: () => {} }, output: { name: "DP-3" }, dragAddress: "abc", dropIndex: 0,
            tiles: [tile], toplevelByAddress: { abc: {} }, windowFor: () => ({ workspaceId: 8 }) };
        view.root = view;
        vm.createContext(view);
        for (const name of ["activateWorkspace", "finishDrag"])
            vm.runInContext(functionSource(read("OverviewView.qml"), name), view);
        view.activateWorkspace(tile);
        view.finishDrag();
        assert.deepEqual(context.sent, [W.focusWorkspace(named), W.moveWindow("abc", named)]);
        assert.equal(context.commandProc.command, undefined, "named actions never call the numbered module API");
        assert.equal(context.canSetLayout(1), false);
        assert.equal(context.setLayout(1, "floating"), false);
        assert.equal(context.cycleLayout(1), false);
        assert.equal(context.moveCommand("dead", tile), "");
    }
    assert.match(read("OverviewView.qml"), /kind: entry\.kind, workspaceName: entry\.workspaceName/);
});

test("native window metadata prevents stale ID-only targets and missing workspace lists from losing names", () => {
    const context = owner(true);
    context.Hyprland.toplevels.values[0].workspace = { id: 1, name: "research" };
    assert.equal(context.focusCommand({ id: 1, kind: "numbered", name: "1" }),
        W.focusWorkspace({ id: 1, name: "research" }));
    assert.equal(context.activateCommand("abc"), W.focusWindow("abc"));
    assert.equal(context.canMinimize("abc"), false);
    assert.equal(context.minimize("abc"), false);
    const recordContext = { DesktopWorkspaces: { minimizedWindow: () => null }, WindowCommands: W, OverviewHelpers: O };
    vm.createContext(recordContext);
    vm.runInContext(functionSource(read("OverviewView.qml"), "record"), recordContext);
    const window = recordContext.record(context.Hyprland.toplevels.values[0]);
    assert.equal(window.workspaceKind, "named");
    assert.equal(window.workspaceName, "research");
    for (const workspaces of [[], [{ id: 1, name: "1", kind: "numbered", active: true }]]) {
        const tile = O.workspaceEntries(workspaces, [window])[0];
        assert.equal(tile.kind, "named");
        assert.equal(tile.workspaceName, "research");
    }
    const command = context.activateCommand("abc");
    context.Hyprland.toplevels.values = [];
    assert.equal(context.dispatch(command, "abc"), false, "native dispatch rechecks closed windows too");
    assert.deepEqual(context.sent, []);
});

test("named positive IDs cannot become numbered bar entries from a stale snapshot", () => {
    const state = snapshot();
    const renamed = { id: 41, name: "research" };
    for (const candidate of [null, state]) {
        const rows = H.barEntries(candidate, "eDP-1", [renamed, live(8)], 2, false, 41);
        assert.ok(!rows.some(row => row.id === 41));
    }
});

test("launcher describes named positive-ID workspaces without stale numbered labels", () => {
    const context = { WindowCommands: W, I18n: { tr: text => text }, DesktopWorkspaces: {
        minimizedWindow: () => null, workspace: () => ({ label: "1", monitor: "eDP-1" }) } };
    vm.createContext(context);
    vm.runInContext(functionSource(read("Common/LauncherProviders.qml"), "workspaceDescription"), context);
    assert.equal(context.workspaceDescription({ address: "abc", workspace: { id: 1, name: "research" } }),
        " · Workspace research");
});

test("dock activates named windows, avoids unsupported minimize, and minimizes a focused numbered window", () => {
    const desktop = owner(true);
    desktop.isMinimized = () => false;
    desktop.Hyprland.toplevels.values[0].workspace = { id: 1, name: "research" };
    const dock = { appByKey: { editor: { key: "editor", windows: ["abc"], recent: "abc" } },
        activeAddress: "", pins: [], DesktopWorkspaces: desktop, DockHelpers: load("DockHelpers.js"),
        Hyprland: desktop.Hyprland, I18n: { tr: text => text } };
    vm.createContext(dock);
    for (const name of ["isLive", "activate", "menuActions"])
        vm.runInContext(functionSource(read("Common/Dock.qml"), name), dock);
    dock.activate("editor");
    assert.deepEqual(desktop.sent, [W.focusWindow("abc")]);
    assert.ok(!dock.menuActions("editor").some(action => action.id === "minimize"));
    dock.activeAddress = "abc";
    dock.activate("editor");
    assert.equal(desktop.commandProc.command, undefined);
    desktop.Hyprland.toplevels.values[0].workspace = { id: 8, name: "8" };
    assert.ok(dock.menuActions("editor").some(action => action.id === "minimize"));
    dock.activate("editor");
    assert.equal(desktop.commandProc.command[2], W.desktopMinimize("abc"));
});
