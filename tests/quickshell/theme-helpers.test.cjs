// Named themes in the shell: Common/ThemeHelpers.js (the catalogue, matching
// and the IPC payload), the theme palette in SettingsHelpers and Theme.qml
// (its contrast floors), and the Settings → Appearance wiring. The theme
// files and their mapping to settings come from scripts/theme_packs.py, run
// here as the shell runs it; tests/theme-packs.py covers that side alone.
const test = require("node:test");
const { untranslated } = require("./shell.cjs");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { shellDir, load } = require("./shell.cjs");

const H = load("SettingsHelpers.js");
const T = load("ThemeHelpers.js");
const python = spawnSync("sh", ["-c", "command -v python3"], { encoding: "utf8" })
    .stdout.trim() || "python3";

function read(relative) {
    return untranslated(fs.readFileSync(path.join(shellDir, relative), "utf8"));
}

function packs(args, input) {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), "cybexos-tests.themes."));
    try {
        const result = spawnSync(python, ["-B", path.join(shellDir, "scripts/theme-packs.py"), ...args], {
            encoding: "utf8", input,
            env: { ...process.env, CYBEXOS_THEME_ROOT: root, PYTHONDONTWRITEBYTECODE: "1",
                CYBEXOS_RUNTIME_HELPER: path.join(root, "absent") },
        });
        assert.equal(result.status, 0, result.stderr);
        return JSON.parse(result.stdout);
    } finally {
        fs.rmSync(root, { recursive: true, force: true });
    }
}

const listing = packs(["list", "--json"]);
const entries = T.catalogueIn(listing, H.normalizeKey);
const byId = id => entries.find(entry => entry.id === id);

function applied(id, base) {
    return { ...(base || H.defaults()), ...byId(id).patch };
}

test("every built-in theme maps to values the settings schema stores unchanged", () => {
    assert.equal(entries.length, listing.themes.length, "the shell drops no built-in theme");
    assert.ok(entries.length >= 8);
    assert.equal(entries[0].id, "cybexos");
    for (const entry of entries) {
        // patchIn accepts only values normalizeKey leaves as they are, so the
        // Python mapping and the JS schema agree key by key.
        assert.deepEqual(T.patchIn(entry.patch, H.normalizeKey), entry.patch, entry.id);
        for (const key of Object.keys(entry.patch))
            assert.ok(T.PATCH_KEYS.includes(key), `${entry.id}: ${key}`);
    }
});

test("the theme keys default-fill for existing settings, so nobody's look changes", () => {
    const d = H.defaults();
    assert.equal(d.theme, "");
    assert.deepEqual(d.themePalette, H.defaultThemePalette());
    // A settings file from before themes: merged, the keys take defaults.
    const old = H.merge({ v: H.VERSION, themeMode: "light", accent: "#9ecbeb" });
    assert.equal(old.theme, "");
    assert.equal(old.themePalette.mode, "");
    assert.deepEqual(H.overrideKeys({ v: H.VERSION, themeMode: "light" }), ["themeMode"]);
    // Normalization keeps only valid palette colours, lowercased.
    const palette = H.themePaletteIn({ mode: "dark", background: "#2E3440", text: "white",
        glow: "#ffffff" });
    assert.deepEqual(Object.keys(palette), ["mode", ...H.THEME_PALETTE_KEYS]);
    assert.equal(palette.background, "#2e3440");
    assert.equal(palette.text, "");
    assert.equal(H.themePaletteIn({ mode: "dim" }).mode, "");
    assert.equal(H.themeIdIn("../nord"), "");
    assert.equal(H.themeIdIn("tokyo-night"), "tokyo-night");
    // A stored palette is an explicit choice, like every other key.
    assert.deepEqual(H.overrideKeys({ v: H.VERSION, themePalette: byId("nord").patch.themePalette }),
        ["themePalette"]);
    // A fresh install shows the default theme, unmodified, with no dirty mark.
    assert.deepEqual(T.current(entries, d), { value: "cybexos", label: "CybexOS", modified: false });
    assert.equal(T.differsFromDefault(d, d), false);
});

test("the helper's appearance defaults are SettingsHelpers'", () => {
    const code = "import json, sys\nsys.path.insert(0, sys.argv[1])\nimport theme_packs as t\n"
        + "print(json.dumps({'defaults': t.APPEARANCE_DEFAULTS, 'fonts': t.FONTS,"
        + " 'bars': t.BAR_PRESETS, 'palette': t.PALETTE_KEYS}))";
    const result = spawnSync(python, ["-B", "-c", code, path.join(shellDir, "scripts")],
        { encoding: "utf8" });
    assert.equal(result.status, 0, result.stderr);
    const lists = JSON.parse(result.stdout);
    const d = H.defaults();
    for (const key of Object.keys(lists.defaults))
        assert.deepEqual(lists.defaults[key], d[key], key);
    assert.deepEqual(lists.fonts, H.FONT_IDS);
    assert.deepEqual(lists.bars, H.BAR_COLOR_IDS.filter(id => id !== "custom"));
    assert.deepEqual(lists.palette, H.THEME_PALETTE_KEYS);
});

test("a picked theme shows as itself until anything it set changes", () => {
    const nord = applied("nord");
    assert.deepEqual(T.current(entries, nord), { value: "nord", label: "Nord", modified: false });
    for (const change of [{ accent: "#ffffff" }, { themeMode: "light" }, { paletteMode: "wallpaper" },
        { barColorMode: "black" }, { barCustomHue: 10 }]) {
        const state = T.current(entries, { ...nord, ...change });
        assert.deepEqual(state, { value: "nord", label: "Nord (modified)", modified: true },
            JSON.stringify(change));
    }
    // Hex case, the wallpaper and anything the theme did not set are not changes.
    for (const change of [{ accent: "#88C0D0" }, { wall: "another.jpg" }, { font: "plex" },
        { glassEnabled: true }])
        assert.equal(T.current(entries, { ...nord, ...change }).modified, false,
            JSON.stringify(change));
    // Undoing the change makes it Nord again.
    assert.equal(T.current(entries, { ...nord, accent: "#88c0d0" }).label, "Nord");
});

test("without a picked theme the settings show a matching theme or Custom", () => {
    const tweaked = { ...H.defaults(), accent: "#123456" };
    assert.deepEqual(T.current(entries, tweaked), { value: "", label: "Custom", modified: false });
    const options = T.choices(entries, T.current(entries, tweaked));
    assert.deepEqual(options[0], { value: "", label: "Custom" });
    assert.equal(options.length, entries.length + 1);
    // Nord's values reached by hand are Nord.
    const byHand = { ...applied("nord"), theme: "" };
    assert.equal(T.current(entries, byHand).value, "nord");
    const state = T.current(entries, { ...applied("gruvbox"), accent: "#000000" });
    const labels = T.choices(entries, state).map(option => option.label);
    assert.ok(labels.includes("Gruvbox (modified)"));
    assert.ok(!labels.includes("Custom"));
    // A removed theme's settings stay; it is no longer offered by name.
    const removed = { ...applied("nord"), theme: "gone-theme" };
    assert.equal(T.current(entries, removed).value, "nord");
});

test("a palette counts only while it is drawn", () => {
    const nord = applied("nord");
    const lightened = { ...nord, themeMode: "light", theme: "" };
    // Nord's dark palette is inactive in light mode: the light defaults with
    // a stale dark palette still read as the plain light look.
    assert.equal(T.effectivePalette(lightened.themePalette, "light", "fixed"), "");
    const lightDefaults = { ...H.defaults(), themeMode: "light", paletteMode: "fixed",
        themePalette: nord.themePalette };
    assert.ok(T.matches({ themeMode: "light", paletteMode: "fixed",
        themePalette: H.defaultThemePalette() }, lightDefaults));
});

test("the IPC payload is held to the schema before anything changes", () => {
    const good = { id: "nord", name: "Nord", patch: byId("nord").patch };
    assert.deepEqual(T.payloadIn(good, H.normalizeKey), good);
    const withWall = { ...good, patch: { ...good.patch, wall: "theme-nord.jpg" } };
    assert.equal(T.payloadIn(withWall, H.normalizeKey).patch.wall, "theme-nord.jpg");
    const bad = [
        null, [], "nord",
        { ...good, id: "gruvbox" },
        { ...good, name: "" },
        { ...good, name: "x".repeat(49) },
        { ...good, patch: { ...good.patch, glassEnabled: true } },
        { ...good, patch: { ...good.patch, themeMode: "dim" } },
        { ...good, patch: { ...good.patch, accent: "red" } },
        { ...good, patch: { ...good.patch, accent: "#fff" } },
        { ...good, patch: { ...good.patch, font: "comic" } },
        { ...good, patch: { ...good.patch, wall: "../../.ssh/id_rsa" } },
        { ...good, patch: { ...good.patch, barCustomHue: 400 } },
        { ...good, patch: { ...good.patch, barCustomHue: undefined } },
        { ...good, patch: { ...good.patch, themePalette: { mode: "dark", text: "white" } } },
        { ...good, patch: { ...good.patch, theme: "" } },
        { ...good, patch: { theme: "nord" } },
        { id: "cybexos", name: "CybexOS",
            patch: { ...byId("cybexos").patch, barCustomHue: 10 } },
    ];
    for (const payload of bad)
        assert.equal(T.payloadIn(payload, H.normalizeKey), null, JSON.stringify(payload));
    assert.deepEqual(T.catalogueIn({ themes: [{ ...listing.themes[0], mode: "dim" }, null,
        listing.themes[1], listing.themes[1]] }, H.normalizeKey).map(e => e.id),
    [listing.themes[1].id]);
});

test("the dropdown previews each theme in its own colours", () => {
    const references = { dark: { background: "#1a1917", text: "#f2f0ea" },
        light: { background: "#eae9ef", text: "#1f1d2b" } };
    assert.deepEqual(T.swatches(byId("nord"), references), ["#2e3440", "#88c0d0", "#eceff4"]);
    assert.deepEqual(T.swatches(byId("cybexos"), references), ["#1a1917", "#d3d283", "#f2f0ea"]);
    assert.deepEqual(T.swatches(byId("catppuccin-latte"), references),
        ["#e6e9ef", "#8839ef", "#4c4f69"]);
    assert.deepEqual(T.swatches(null, references), []);
});

// ---- contrast ------------------------------------------------------------------

// Theme.qml holds a themed ladder against themeReference(): in dark mode the
// lightest surface, in light mode the darkest under a hovered chip of the
// theme's ink. Every plain surface must read as well.
const CHIP_HOVER = Number(read("Common/Theme.qml")
    .match(/readonly property real chipHoverAlpha:\s*([\d.]+)/)[1]);

function backdrops(palette) {
    const s = H.themeSurfaces(palette);
    const reference = H.themeReference(palette, CHIP_HOVER);
    return { reference, all: [reference, s.background, s.surface, s.surfaceRaised] };
}

function checkLadder(palette, label) {
    const { reference, all } = backdrops(palette);
    const ladder = H.themeTextPalette(reference, palette);
    for (const backdrop of all)
        assert.ok(H.contrastRatio(ladder.textHi, backdrop) >= 7, `${label} textHi on ${backdrop}`);
    for (const step of ["textMid", "textLow", "textDim", "textFaint", "icon"])
        for (const backdrop of all)
            assert.ok(H.contrastRatio(ladder[step], backdrop) >= 4.5,
                `${label} ${step} ${ladder[step]} on ${backdrop}`);
    for (const status of ["red", "amber", "green"]) {
        const ink = H.ensureContrast(H.themeSurfaces(palette)[status], reference, 4.5);
        for (const backdrop of all)
            assert.ok(H.contrastRatio(ink, backdrop) >= 4.5, `${label} ${status} on ${backdrop}`);
    }
    return ladder;
}

test("every built-in theme's text clears the shell's floors", () => {
    for (const entry of entries.filter(e => e.patch.themePalette.mode !== ""))
        checkLadder(entry.patch.themePalette, entry.id);
});

test("a theme's own readable colours are kept, not replaced", () => {
    // Real themes sit inside the surface bounds: their surfaces are drawn as given.
    for (const entry of entries.filter(e => e.patch.themePalette.mode !== "")) {
        const palette = entry.patch.themePalette;
        const surfaces = H.themeSurfaces(palette);
        for (const key of ["background", "surface", "surfaceRaised"])
            if (palette[key] !== "")
                assert.equal(surfaces[key], palette[key], `${entry.id} ${key}`);
    }
    const mocha = byId("catppuccin-mocha").patch.themePalette;
    const ladder = checkLadder(mocha, "mocha");
    // Already far above the floors over the raised surface: used as given.
    assert.equal(ladder.textHi, "#cdd6f4");
    assert.equal(ladder.textMid, "#bac2de");
    assert.equal(ladder.textDim, "#a6adc8");
    // Rosé Pine's muted tone sits below 4.5:1 and is lifted toward white.
    const rose = checkLadder(byId("rose-pine").patch.themePalette, "rose");
    assert.notEqual(rose.textDim, "#6e6a86");
});

test("no palette, however hostile, produces unreadable text", () => {
    const hostile = [
        { mode: "dark", background: "#202020", text: "#202020", textMuted: "#202020",
            textDim: "#202020", red: "#202020", amber: "#202020", green: "#202020" },
        { mode: "light", background: "#f0f0f0", surface: "#ffffff", text: "#f8f8f8",
            textMuted: "#eeeeee" },
        { mode: "dark", background: "#777777", surfaceRaised: "#888888", text: "#999999" },
        { mode: "light", background: "#7f7f7f", text: "#808080" },
        { mode: "dark" },
        { mode: "light" },
    ];
    hostile.forEach((palette, index) => checkLadder(palette, "hostile " + index));
    // A pseudo-random sweep across mid-grey and saturated bases.
    let seed = 7;
    const next = () => (seed = (seed * 1103515245 + 12345) % 2147483648) / 2147483648;
    const hex = () => "#" + [0, 0, 0].map(() => Math.floor(next() * 256)
        .toString(16).padStart(2, "0")).join("");
    for (let i = 0; i < 300; i++) {
        const palette = { mode: next() < 0.5 ? "dark" : "light" };
        for (const key of H.THEME_PALETTE_KEYS)
            if (next() < 0.7)
                palette[key] = hex();
        checkLadder(palette, "sweep " + i);
    }
});

test("Theme.qml draws the theme palette only in its mode, with fixed accents", () => {
    const theme = read("Common/Theme.qml");
    assert.match(theme, /readonly property bool themePaletteActive: !paletteActive\s+&& Settings\.paletteMode === "fixed"\s+&& Settings\.themePalette\.mode === \(dark \? "dark" : "light"\)/);
    assert.match(theme, /themeColors: themePaletteActive\s+\? SettingsHelpers\.themeSurfaces\(Settings\.themePalette\) : null/);
    for (const [token, key] of [["background", "background"], ["popBg", "surface"],
        ["menuBg", "surfaceRaised"]])
        assert.match(theme, new RegExp(`readonly property color ${token}: paletteActive[^]*?`
            + `: themePaletteActive \\? themeColors\\.${key}\\n`), token);
    assert.match(theme, /: themePaletteActive\s+\? SettingsHelpers\.themeTextPalette\(copyReferenceBg\.toString\(\), Settings\.themePalette\)/);
    for (const token of ["textHi", "textMid", "textLow", "textDim", "textFaint", "icon"])
        assert.match(theme, new RegExp(`readonly property color ${token}: textPalette \\? textPalette\\.${token}`));
    assert.match(theme, /: themePaletteActive\s+\? SettingsHelpers\.ensureContrast\(themeColors\.red, copyReferenceBg\.toString\(\), 4\.5\)/);
    assert.match(theme, /amberSeed: themePaletteActive \? themeColors\.amber/);
    assert.match(theme, /okSeed: themePaletteActive \? themeColors\.green/);
    assert.match(theme, /ensureContrast\(\s*amberSeed\.toString\(\), copyReferenceBg\.toString\(\), 4\.5\)/);
    assert.match(theme, /ensureContrast\(\s*okSeed\.toString\(\), copyReferenceBg\.toString\(\), 4\.5\)/);
    // The fixed references stay the fallback, untouched.
    assert.match(theme, /: dark \? darkBackground : lightBackground/);
    assert.match(theme, /: dark \? "#ff8f8f" : "#c22f2f"/);
    assert.match(theme, /: dark \? "#ffc26e" : "#b5761e"/);
    assert.match(theme, /: dark \? "#63d68c" : "#1f9d57"/);
    // The fallback references are Theme.qml's own literals.
    const literal = name => theme.match(new RegExp(`readonly property color ${name}: "(#[0-9a-f]{6})"`))[1];
    const fallbacks = H.themeSurfaces({ mode: "dark" });
    assert.equal(fallbacks.background, literal("darkBackground"));
    assert.equal(fallbacks.text, literal("darkTextHi"));
    assert.equal(H.themeSurfaces({ mode: "light" }).background, literal("lightBackground"));
    assert.equal(H.themeSurfaces({ mode: "light" }).text, literal("lightTextHi"));
});

// ---- wiring ---------------------------------------------------------------------

test("settings, IPC and search know the theme keys", () => {
    const settings = read("Common/Settings.qml");
    assert.match(settings, /property string theme: defaults\.theme/);
    assert.match(settings, /property var themePalette: defaults\.themePalette/);
    assert.match(settings, /appearance: \[[^\]]*"theme", "themePalette"/);
    assert.match(settings, /function applyValues\(values, label, message\) \{[^]*?markExplicit\(key\);\s+root\[key\] = SettingsHelpers\.normalizeKey\(key, values\[key\]\);[^]*?resetSnapshot = previous;[^]*?resetTimer\.restart\(\);/);
    const shell = read("shell.qml");
    assert.match(shell, /target: "theme"[^]*?function use\(theme: string\): string \{\s+return Themes\.use\(theme\);/);
    assert.match(shell, /function refresh\(\): void \{\s+Themes\.refresh\(\);/);
    assert.match(read("Common/qmldir"), /^singleton Themes Themes\.qml$/m);
    const themes = read("Common/Themes.qml");
    assert.match(themes, /ThemeHelpers\.payloadIn\(parseReply\(text\), SettingsHelpers\.normalizeKey\)/);
    assert.match(themes, /Settings\.applyValues\(payload\.patch, "Theme",/);
    assert.match(themes, /"resolve", id,\s+"--wall-dir", Wallpaper\.dir\]/);
    const search = load("SettingsSearchData.js");
    const rows = search.ROWS || search.rows || search;
    assert.ok(JSON.stringify(rows).includes('"key":"theme"'), "the Theme row is searchable");
});

test("Appearance leads with one Theme row and keeps saving out of sight", () => {
    const page = read("Settings/AppearancePage.qml");
    const theme = page.indexOf('label: "Theme"');
    const mode = page.indexOf('label: "Mode"');
    assert.ok(theme > 0 && theme < mode, "the Theme row comes first, before Mode");
    assert.equal(page.indexOf('title: "Theme"') < theme, true);
    assert.match(page, /onPicked: value => \{\s+if \(value !== ""\)\s+Themes\.apply\(value\);/);
    assert.match(page, /swatchesFor: value => page\.themeSwatches\(value\)/);
    assert.match(page, /resetKeys: ThemeHelpers\.RESET_KEYS/);
    assert.match(page, /text: "Save current as theme…"/);
    assert.match(page, /id: saveThemeReveal[^]*?reveal: page\.savingTheme[^]*?FieldRow \{/);
    assert.doesNotMatch(page, /Component\.onCompleted:/);
    assert.doesNotMatch(page, /barColorMode|barCustomHue/, "bar keys stay on the Bar page");
    assert.deepEqual(T.RESET_KEYS.filter(key => !T.PATCH_KEYS.includes(key)), []);
    assert.ok(!T.RESET_KEYS.includes("wall"), "a reset never touches the wallpaper");
    const select = read("Settings/SettingsSelect.qml");
    assert.match(select, /property var swatchesFor: null/);
    assert.match(select, /leftPadding: combo\.swatchInset/);
});
