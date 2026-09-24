// Opening the settings window must not race its own map: Hyprland focuses a
// new window as it maps, and a focus-by-title sent alongside the map arrives
// before the window exists ("hl.focus: window not found" in the journal).
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { shellDir } = require("./shell.cjs");

function read(relative) {
    return fs.readFileSync(path.join(shellDir, relative), "utf8");
}

function functionSource(source, name) {
    const match = source.match(new RegExp("^    function " + name + "\\([^]*?^    }", "m"));
    assert.ok(match, `function ${name} not found`);
    return match[0];
}

test("only an already-open settings window is raised by title", () => {
    const source = read("Common/Settings.qml");
    let presented = 0;
    const context = {
        page: "appearance", panelOpen: false, panelScreenName: "", highlightKey: "",
        validPages: ["appearance", "power", "about", "bar"],
        legacyPages: { modules: "bar", system: "power" },
        keyPages: { recoveryPoints: "about" },
        openWidgetSettings() {},
        Popouts: { close() {} },
        Screens: { focused: { name: "DP-1" } },
        presentPanel() { presented++; }
    };
    context.closePanel = () => { context.panelOpen = false; };
    vm.createContext(context);
    for (const name of ["resolvePage", "showPanel", "showSetting", "togglePanel"])
        vm.runInContext(functionSource(source, name), context);

    context.showPanel("system", "eDP-1");
    assert.equal(context.page, "power", "the retired System id opens the Power page");
    assert.equal(context.panelOpen, true);
    assert.equal(context.panelScreenName, "eDP-1");
    assert.equal(presented, 0, "a window that is only now mapping cannot be focused by title");

    context.showSetting("appearance", "glassEnabled", "DP-2");
    assert.equal(context.page, "appearance");
    assert.equal(context.highlightKey, "glassEnabled");
    assert.equal(context.panelScreenName, "eDP-1", "an open window stays on its screen");
    assert.equal(presented, 1, "an open window is raised");

    // A legacy id that names a moved row lands on the row's new page.
    context.showSetting("system", "recoveryPoints", "");
    assert.equal(context.page, "about");
    context.showPanel("modules", "");
    assert.equal(context.page, "bar");
    context.showPanel("nonsense", "");
    assert.equal(context.page, "bar", "an unknown id leaves the page alone");

    context.togglePanel();
    assert.equal(context.panelOpen, false);
    context.togglePanel(undefined, "DP-2");
    assert.equal(context.panelScreenName, "DP-2");
    assert.equal(presented, 4);
});

test("the settings window maps unminimized and raises itself when asked", () => {
    const window = read("SettingsWindow.qml");
    assert.match(window,
        /function onPanelOpenChanged\(\) \{\s*if \(Settings\.panelOpen\) \{[^}]*window\.minimized = false;\s*\}\s*window\.visible = Settings\.panelOpen;/);
    assert.match(window,
        /function onPresentPanel\(\) \{\s*window\.minimized = false;\s*Hyprland\.dispatch\('hl\.dsp\.focus\(\{ window = "title:\^CybexOS Settings\$" \}\)'\);/);
});
