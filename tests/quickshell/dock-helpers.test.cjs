const test = require("node:test");
const assert = require("node:assert/strict");
const { load } = require("./shell.cjs");

const D = load("DockHelpers.js");
const S = load("SettingsHelpers.js");

const windows = [
    { address: "k1", appId: "kitty", entryId: "kitty" },
    { address: "f1", appId: "firefox", entryId: "firefox" },
    { address: "k2", appId: "kitty", entryId: "kitty" },
    { address: "x1", appId: "SomeTool", entryId: "" },
    { address: "x2", appId: "sometool", entryId: "" },
    { address: "s1", appId: "org.quickshell", entryId: "" },
    { address: "n1", appId: "", entryId: "" }
];

test("apps group by desktop entry, pins first, then running in order of appearance", () => {
    const apps = D.groupApps(windows, ["org.gnome.Nautilus", "kitty"], []);
    assert.deepEqual(apps.map(app => app.key),
        ["app:org.gnome.Nautilus", "app:kitty", "app:firefox", "class:sometool", "window:n1"]);
    const files = apps[0];
    assert.equal(files.pinned, true);
    assert.equal(files.running, false);
    assert.deepEqual(files.windows, []);
    const kitty = apps[1];
    assert.equal(kitty.pinned, true);
    assert.deepEqual(kitty.windows, ["k1", "k2"], "windows keep a stable order for cycling");
    assert.equal(kitty.appId, "kitty", "a pin learns its window class once it runs");
    assert.deepEqual(apps[3].windows, ["x1", "x2"], "one class, any capitalisation, one item");
    assert.ok(!apps.some(app => app.windows.includes("s1")), "the shell's own windows are not apps");
});

test("bad pins are ignored and duplicates collapse", () => {
    const apps = D.groupApps([], ["kitty", "kitty", "../etc", "", 7, "a b"], []);
    assert.deepEqual(apps.map(app => app.key), ["app:kitty"]);
});

test("a click launches, focuses the last window, or cycles", () => {
    const [, kitty, firefox] = D.groupApps(windows, ["org.gnome.Nautilus", "kitty"], ["f1", "k2"]);
    const files = D.groupApps([], ["org.gnome.Nautilus"], [])[0];
    assert.deepEqual(D.clickAction(files, "f1"), { kind: "launch" });
    assert.deepEqual(D.clickAction(kitty, "f1"), { kind: "focus", address: "k2" },
        "another app is active: the app's most recent window");
    assert.deepEqual(D.clickAction(kitty, "k2"), { kind: "focus", address: "k1" }, "cycle on");
    assert.deepEqual(D.clickAction(kitty, "k1"), { kind: "focus", address: "k2" });
    assert.deepEqual(D.clickAction(firefox, "f1"), { kind: "none" }, "its only window is already active");
    assert.deepEqual(D.clickAction({ key: "class:x", entryId: "", windows: [] }, ""), { kind: "none" },
        "nothing to launch without a desktop entry");
    assert.deepEqual(D.clickAction(null, ""), { kind: "none" });
});

test("the most recent window comes from focus history, else the first", () => {
    assert.equal(D.mostRecent(["a", "b", "c"], ["z", "c", "a"]), "c");
    assert.equal(D.mostRecent(["a", "b"], ["z"]), "a");
    assert.equal(D.mostRecent([], ["a"]), "");
    assert.deepEqual(D.touchRecent(["a", "b", "c"], "b"), ["b", "a", "c"]);
    assert.deepEqual(D.touchRecent(["a", "b"], "c", 2), ["c", "a"]);
    assert.deepEqual(D.touchRecent(undefined, "a"), ["a"]);
});

test("pinning appends once, unpinning removes, and the list is bounded", () => {
    assert.deepEqual(D.pin(["kitty"], "firefox"), ["kitty", "firefox"]);
    assert.deepEqual(D.pin(["kitty"], "kitty"), ["kitty"]);
    assert.deepEqual(D.pin(["kitty"], "bad id"), ["kitty"]);
    assert.deepEqual(D.unpin(["kitty", "firefox"], "kitty"), ["firefox"]);
    const full = Array.from({ length: D.MAX_PINS }, (_, index) => "app" + index);
    assert.equal(D.pin(full, "one-more").length, D.MAX_PINS);
    assert.equal(D.isPinned(["kitty"], "kitty"), true);
    assert.equal(D.isPinned(["kitty"], "firefox"), false);
});

test("suggested pins hold until the person pins or unpins anything", () => {
    const suggestions = D.suggestedPins("brave-origin");
    assert.deepEqual(suggestions, ["brave-origin", "org.gnome.Nautilus", "kitty"]);
    assert.deepEqual(D.suggestedPins(""), ["org.gnome.Nautilus", "kitty"]);
    assert.deepEqual(D.effectivePins([], false, suggestions), suggestions);
    assert.deepEqual(D.effectivePins([], true, suggestions), [], "an explicit empty dock stays empty");
    assert.deepEqual(D.effectivePins(["kitty"], true, suggestions), ["kitty"]);
});

test("the default browser is read from mimeapps.list's default group only", () => {
    const text = [
        "[Added Associations]",
        "x-scheme-handler/https=chromium.desktop;",
        "[Default Applications]",
        "text/html=firefox.desktop",
        "x-scheme-handler/https=brave-origin.desktop;firefox.desktop;",
        ""
    ].join("\n");
    assert.equal(D.defaultBrowserId(text), "brave-origin");
    assert.equal(D.defaultBrowserId("[Default Applications]\nx-scheme-handler/https = firefox.desktop\n"), "firefox");
    assert.equal(D.defaultBrowserId("[Default Applications]\nx-scheme-handler/https=../evil.desktop\n"), "");
    assert.equal(D.defaultBrowserId(""), "");
    assert.equal(D.defaultBrowserId(null), "");
});

test("the dock reserves its height under a top bar and never overlaps a bottom one", () => {
    const base = { barDepth: 36, dockHeight: 60, gap: 8 };
    assert.deepEqual(D.placement({ ...base, barPosition: "top", barZone: 36, autoHide: false }),
        { offset: 8, stepOver: 0, exclusiveZone: 68 });
    assert.deepEqual(D.placement({ ...base, barPosition: "top", barZone: 36, autoHide: true }),
        { offset: 8, stepOver: 0, exclusiveZone: 0 }, "an auto-hiding dock reserves nothing");
    // A reserving bottom bar is laid out first; the dock's zero zone then
    // places it above the bar without depending on surface creation order.
    assert.deepEqual(D.placement({ ...base, barPosition: "bottom", barZone: 36, autoHide: false }),
        { offset: 8, stepOver: 0, exclusiveZone: 0 });
    // A bottom bar that reserves nothing (auto-hide, Reserve space off) is
    // stepped over by the offset.
    assert.deepEqual(D.placement({ ...base, barPosition: "bottom", barZone: 0, autoHide: true }),
        { offset: 44, stepOver: 36, exclusiveZone: 0 });
});

test("pinned and running groups are separated, and the menu fits the item", () => {
    const apps = D.groupApps(windows, ["kitty"], []);
    assert.deepEqual(D.displayKeys(apps).slice(0, 3), ["app:kitty", "|", "app:firefox"]);
    assert.deepEqual(D.displayKeys(D.groupApps([], ["kitty"], [])), ["app:kitty"]);
    assert.deepEqual(D.displayKeys([]), []);

    const [kitty, firefox, tool] = apps;
    assert.deepEqual(D.menuActions(kitty, ["kitty"]).map(action => action.label),
        ["New window", "Unpin from dock", "Close 2 windows"]);
    assert.deepEqual(D.menuActions(firefox, ["kitty"]).map(action => action.id),
        ["launch", "pin", "close"]);
    assert.equal(D.menuActions(firefox, ["kitty"])[2].label, "Close window");
    assert.deepEqual(D.menuActions(tool, []).map(action => action.id), ["close"],
        "without a desktop entry there is nothing to launch or pin");
    assert.deepEqual(D.menuActions(null, []), []);
});

test("the settings schema defaults the dock off and normalizes pins as the dock does", () => {
    const defaults = S.merge(null);
    assert.equal(defaults.dock, false);
    assert.equal(defaults.dockAutoHide, false);
    assert.deepEqual(defaults.dockPinned, []);
    const merged = S.merge({
        v: S.VERSION, dock: true, dockAutoHide: "yes",
        dockPinned: ["kitty", "kitty", "bad id", "../x", 3, "org.gnome.Nautilus"]
    });
    assert.equal(merged.dock, true);
    assert.equal(merged.dockAutoHide, false, "a non-boolean falls back to the default");
    assert.deepEqual(merged.dockPinned, ["kitty", "org.gnome.Nautilus"]);
    assert.deepEqual(merged.dockPinned, D.uniqueIds(["kitty", "kitty", "bad id", "../x", 3,
        "org.gnome.Nautilus"]), "schema and dock agree on what a pin is");
    assert.deepEqual(S.normalizeKey("dockPinned", "kitty"), [], "not a list: no pins");
    const many = Array.from({ length: 40 }, (_, index) => "app" + index);
    assert.equal(S.normalizeKey("dockPinned", many).length, D.MAX_PINS);
    // A file written before the dock existed keeps every other choice and
    // gains the defaults.
    const legacy = S.merge({ v: S.VERSION, position: "bottom" });
    assert.equal(legacy.position, "bottom");
    assert.equal(legacy.dock, false);
    assert.equal(legacy.drawerOverview.processes, true);
    assert.equal(S.merge({ v: S.VERSION, drawerOverview: { processes: false } }).drawerOverview.processes, false);
    assert.equal(S.merge({ v: 28, dock: false }).dock, false,
        "migrating a prior shell schema keeps the dock opt-out");
});
