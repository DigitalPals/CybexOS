// The Mac-like desktop style (Settings → Appearance → Desktop style): its
// setting, the effective values it overrides, the pure layout helpers for the
// menubar, Mission Control and the dock, the menus' actions and the paths
// into the minimize animation. A real Hyprland session is checked by
// nix/tests/mac-style.nix.
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { load, shellDir } = require("./shell.cjs");
const { python, scriptsDir, darkTokens } = require("./system-theme.cjs");

const H = load("SettingsHelpers.js");
const L = load("LayoutHelpers.js");
const O = load("OverviewHelpers.js");
const W = load("WindowCommands.js");
const R = load("PanelRegistryData.js");

function read(relative) {
    return fs.readFileSync(path.join(shellDir, relative), "utf8");
}

const settings = read("Common/Settings.qml");
const mac = read("Common/MacDesktop.qml");

// ---- the setting --------------------------------------------------------

test("the desktop style is an Appearance choice that defaults to Cybex", () => {
    assert.deepEqual(H.DESKTOP_STYLES, ["cybex", "mac"]);
    const d = H.defaults();
    assert.equal(d.desktopStyle, "cybex");
    assert.equal(H.merge({ v: H.VERSION, desktopStyle: "mac" }).desktopStyle, "mac");
    for (const value of ["macos", "", 1, null, true])
        assert.equal(H.merge({ v: H.VERSION, desktopStyle: value }).desktopStyle, "cybex", String(value));
    assert.match(settings, /property string desktopStyle: defaults\.desktopStyle/);
    assert.match(settings, /"themePalette", "desktopStyle",/);
    assert.match(read("Settings/AppearancePage.qml"), /settingKey: "desktopStyle"/);
    const search = load("SettingsSearchData.js");
    assert.ok(search.search("traffic lights").some(row => row.key === "desktopStyle"));
});

test("the style overrides without changing what it covers", () => {
    // Effective values, never assignments: switching back restores each choice.
    for (const [name, expression] of [
        ["effectiveAccent", /macStyle\s*\? SettingsHelpers\.macAccent\(themeMode\) : accent/],
        ["effectiveBarColor", /SettingsHelpers\.resolveBarColor\(\s*macStyle \? "macos" : barColorMode/],
        ["effectiveFont", /macStyle \? SettingsHelpers\.MAC_FONT : font/],
        ["effectivePaletteMode", /macStyle \? "fixed" : paletteMode/],
        ["effectiveThemePalette", /macStyle\s*\? SettingsHelpers\.macPalette\(themeMode\) : themePalette/],
        ["effectiveBarStyle", /macStyle \? "attached" : barStyle/],
        ["effectiveGlass", /glassEnabled \|\| macStyle/],
        ["effectiveDock", /dock \|\| macStyle/],
    ])
        assert.match(settings, new RegExp(`readonly property \\w+ ${name}:\\s*${expression.source}`), name);
    assert.doesNotMatch(settings, /Settings\.set\("(accent|font|paletteMode|barStyle|glassEnabled|dock)"/);
});

test("the Mac palette is Apple's system colours, held to the shell's floors", () => {
    assert.equal(H.macAccent("dark"), "#0a84ff");
    assert.equal(H.macAccent("light"), "#007aff");
    for (const mode of ["dark", "light"]) {
        const palette = H.macPalette(mode);
        assert.equal(palette.mode, mode);
        const surfaces = H.themeSurfaces(palette);
        // The palette passes the theme floors unchanged.
        for (const key of ["background", "surface", "surfaceRaised"])
            assert.equal(surfaces[key], palette[key], `${mode} ${key}`);
    }
    assert.equal(H.FONT_CHOICES.find(choice => choice.id === H.MAC_FONT).family, "Inter");
});

test("Inter is an interface font of its own, mirrored by the theme packs", () => {
    assert.ok(H.FONT_IDS.includes("inter"));
    const packs = fs.readFileSync(path.join(scriptsDir, "theme_packs.py"), "utf8");
    assert.match(packs, /FONTS = \([^)]*'inter'/);
});

// ---- the menubar ----------------------------------------------------------

test("the split menubar fits side by side and never shifts a centre", () => {
    const entries = [
        { id: "batt", col: "right", width: 60, saving: 30, policy: "auto" },
        { id: "clock", col: "center", width: 120, saving: 50, policy: "auto", centerSide: "right" },
    ];
    const roomy = L.fitBar({ width: 1000, sideMargin: 6, gutter: 8, split: true,
        widths: { left: 200, center: 120, right: 300 }, entries: entries, overflowWidth: 30 });
    assert.ok(roomy.fits);
    assert.deepEqual(roomy.compact, []);
    assert.equal(roomy.centerOffset, 0);
    // Too narrow for both sides: labels compact before anything overflows.
    const tight = L.fitBar({ width: 600, sideMargin: 6, gutter: 8, split: true,
        widths: { left: 200, center: 120, right: 330 }, entries: entries, overflowWidth: 30 });
    assert.ok(tight.compact.length > 0);
    assert.equal(tight.centerOffset, 0);
});

test("the three menus are ownerless, start-aligned panels the bar draws", () => {
    for (const name of ["macsystem", "macapp", "macwindow"]) {
        assert.equal(R.byName(name).source, "Popovers/MacMenuPopover.qml");
        assert.ok(R.ownerless(name) && R.alignStart(name), name);
    }
    assert.equal(R.alignStart("calendar"), false);
    const bar = read("Bar/Bar.qml");
    for (const name of ["macsystem", "macapp", "macwindow"])
        assert.match(bar, new RegExp(`panelName: Theme\\.macStyle \\? "${name}" : ""`));
    assert.match(bar, /split: Theme\.macStyle/);
    assert.match(read("Bar/PopoutHost.qml"), /PanelRegistry\.alignStart\(Popouts\.currentName\)\s*\? anchor\.x/);
});

test("every menu row the menus offer has an action", () => {
    const offered = new Set([...mac.matchAll(/item\("(\w+)"/g)].map(m => m[1]));
    const handled = new Set([...mac.matchAll(/case "(\w+)":/g)].map(m => m[1]));
    assert.ok(offered.size >= 20, [...offered].join(" "));
    for (const id of offered)
        assert.ok(handled.has(id), `${id} has no action`);
    // Menus only reach windows through the validated builders and the
    // workspace module, and minimize through the animation.
    assert.doesNotMatch(mac, /Hyprland\.dispatch\(["'`]/);
    assert.doesNotMatch(mac, /DesktopWorkspaces\.minimize\(/);
});

// ---- Mission Control ------------------------------------------------------

test("Mission Control puts the other workspaces in a strip above the current one", () => {
    const layout = O.missionLayout(4, 1, 1600, 900, 16 / 9, { spacing: 28, labelHeight: 32 });
    assert.equal(layout.cells.length, 4);
    const current = layout.cells[1];
    assert.equal(current.x, 0);
    assert.equal(current.width, 1600);
    assert.equal(current.tileY, 0);
    const strip = layout.cells.filter((cell, index) => index !== 1);
    for (const cell of strip) {
        assert.equal(cell.y, 0);
        assert.ok(cell.y + cell.height <= current.y, "the strip sits above the current workspace");
    }
    // In order and centred.
    assert.ok(strip[0].x < strip[1].x && strip[1].x < strip[2].x);
    assert.ok(Math.abs(strip[0].x - (1600 - (strip[2].x + strip[2].width))) <= 1);
    // A strip too long for the width shrinks to fit.
    const many = O.missionLayout(13, 0, 1200, 800, 16 / 9, { spacing: 20, labelHeight: 24 });
    const last = many.cells[12];
    assert.ok(last.x + last.width <= 1200);
    // Without a current workspace on the output it is the ordinary grid.
    assert.deepEqual(O.missionLayout(3, -1, 1200, 800, 16 / 9, {}), O.gridLayout(3, 1200, 800, 16 / 9, {}));
});

test("exposé spreads windows without overlap, growth or distortion", () => {
    const windows = [
        { address: "a", at: [0, 0], size: [1200, 800] },
        { address: "b", at: [400, 300], size: [800, 600] },
        { address: "c", at: [100, 500], size: [500, 700] },
        { address: "d", at: [900, 20], size: [300, 200] },
    ];
    const rects = O.exposeRects(windows, 1500, 700, { gap: 28 });
    assert.deepEqual(Object.keys(rects).sort(), ["a", "b", "c", "d"]);
    const list = Object.entries(rects);
    for (const [address, rect] of list) {
        const source = windows.find(window => window.address === address);
        assert.ok(rect.x >= 0 && rect.y >= 0 && rect.x + rect.width <= 1500 && rect.y + rect.height <= 700, address);
        assert.ok(rect.width <= source.size[0] + 1, `${address} never grows`);
        assert.ok(Math.abs(rect.width / rect.height - source.size[0] / source.size[1]) < 0.05, `${address} keeps its shape`);
    }
    for (let i = 0; i < list.length; i++) {
        for (let j = i + 1; j < list.length; j++) {
            const [, p] = list[i];
            const [, q] = list[j];
            const apart = p.x + p.width <= q.x || q.x + q.width <= p.x
                || p.y + p.height <= q.y || q.y + q.height <= p.y;
            assert.ok(apart, `${list[i][0]} and ${list[j][0]} overlap`);
        }
    }
    assert.deepEqual(O.exposeRects([], 100, 100), {});
    // One small window keeps its own size, centred.
    const single = O.exposeRects([{ address: "x", at: [0, 0], size: [400, 300] }], 1000, 800)["x"];
    assert.deepEqual([single.width, single.height, single.x, single.y], [400, 300, 300, 250]);
});

test("the overview switches to Mission Control only in the Mac-like style", () => {
    const view = read("OverviewView.qml");
    assert.match(view, /readonly property bool mission: Theme\.macStyle/);
    assert.match(view, /OverviewHelpers\.missionLayout\(tiles\.length, missionIndex/);
    assert.match(view, /OverviewHelpers\.exposeRects\(inTile, box\.width, box\.height/);
});

// ---- dock, launcher and minimize -----------------------------------------

test("the Mac-like dock adds minimized windows and the Trash after a divider", () => {
    const dock = read("DockWindow.qml");
    assert.match(dock, /keys\.concat\(keys\.length > 0 \? \["\|"\] : \[\], minimizedKeys, \["trash"\]\)/);
    assert.match(dock, /readonly property real magnifyMax: mac && !Theme\.reducedMotion \? 1\.6 : 1/);
    assert.match(dock, /Quickshell\.execDetached\(\["gio", "open", "trash:\/\/\/"\]\)/);
    // Pointing at it never resizes the layer surface.
    assert.match(dock, /implicitWidth: \(mac \? restLayout\.total/);
});

test("Spotlight is the launcher without tabs, wider and higher", () => {
    const view = read("LauncherView.qml");
    assert.match(view, /readonly property bool spotlight: Theme\.macStyle/);
    assert.match(view, /visible: !root\.spotlight/);
    assert.match(read("LauncherWindow.qml"), /Math\.round\(root\.outputHeight \* 0\.18\)/);
});

test("every shell-owned minimize goes through the animation, which falls back", () => {
    const dock = read("Common/Dock.qml");
    assert.doesNotMatch(dock, /DesktopWorkspaces\.minimize\(/);
    assert.match(dock, /Minimizer\.minimize\(/);
    const minimizer = read("Common/Minimizer.qml");
    assert.match(minimizer, /if \(!animates \|\| flight !== null \|\| clients\.running\)\s*return DesktopWorkspaces\.minimize\(address\);/);
    const overlay = read("MinimizeOverlay.qml");
    assert.match(overlay, /target: "window"/);
    assert.match(overlay, /WlrLayershell\.namespace: "qs-minimize"/);
    assert.match(overlay, /mask: Region \{\}/, "the overlay never takes a click");
    // The title bar's button asks the shell, then the compositor.
    const workspaces = fs.readFileSync(path.join(shellDir, "../hypr/workspaces.lua"), "utf8");
    assert.match(workspaces, /cybexos-runtime ipc window minimize "%WINDOW%" >\/dev\/null 2>&1 \|\| \]\] \.\. minimize/);
});

test("window commands for the Window menu are validated", () => {
    assert.equal(W.desktopToggleFloating("0xABC"), 'require("workspaces").toggle_floating("0xabc")');
    assert.equal(W.desktopToggleFloating("nope"), "");
    assert.equal(W.fullscreenWindow("abc"),
        'hl.dsp.window.fullscreen({ mode = "fullscreen", action = "toggle", window = "address:0xabc" })');
    assert.equal(W.fullscreenWindow(""), "");
});

// ---- the system theme -----------------------------------------------------

test("tokens carry the style, and older ones mean the Cybex style", () => {
    const code = [
        "import json, sys, theme_tokens",
        "out = []",
        "for raw in json.loads(sys.stdin.read()):",
        "    try:",
        "        out.append(theme_tokens.validate(raw)['style'])",
        "    except theme_tokens.TokenError as error:",
        "        out.append('error: ' + str(error))",
        "print(json.dumps(out))",
    ].join("\n");
    const base = darkTokens();
    const cases = [{ ...base }, { ...base, style: "mac" }, { ...base, style: "cybex" }, { ...base, style: "aqua" }];
    const result = spawnSync(python, ["-c", code], { cwd: scriptsDir, input: JSON.stringify(cases),
        encoding: "utf8", env: { ...process.env, PYTHONDONTWRITEBYTECODE: "1" } });
    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(JSON.parse(result.stdout), ["cybex", "mac", "cybex", "error: style is neither cybex nor mac"]);
    assert.match(read("Common/SystemTheme.qml"), /style: Settings\.desktopStyle,/);
});
