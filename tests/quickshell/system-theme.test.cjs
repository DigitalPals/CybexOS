const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { shellDir } = require("./shell.cjs");
const {
    python, scriptsDir, darkTokens, lightTokens, scratch, runDriver,
} = require("./system-theme.cjs");

function read(relative) {
    return fs.readFileSync(path.join(shellDir, relative), "utf8");
}

function tokensModule(code, input) {
    const result = spawnSync(python, ["-c", "import json, sys, theme_tokens as t\n" + code], {
        cwd: scriptsDir, input: input === undefined ? "" : JSON.stringify(input),
        encoding: "utf8", env: { ...process.env, PYTHONDONTWRITEBYTECODE: "1" },
    });
    assert.equal(result.status, 0, result.stderr);
    return JSON.parse(result.stdout);
}

test("SystemTheme exports exactly the colour keys the renderer validates", () => {
    const qml = read("Common/SystemTheme.qml");
    const block = qml.match(/colors: \{([^]*?)\n {8}\}/);
    assert.ok(block, "colors block not found");
    const exported = [...block[1].matchAll(/^\s+(\w+):/gm)].map(m => m[1]);
    const keys = tokensModule("print(json.dumps(list(t.COLOR_KEYS)))");
    assert.deepEqual(exported, keys);
    assert.deepEqual(Object.keys(darkTokens().colors), keys);
    assert.deepEqual(Object.keys(lightTokens().colors), keys);
});

test("the shell constructs SystemTheme at startup and exposes the theme IPC", () => {
    const shell = read("shell.qml");
    assert.match(shell, /void SystemTheme\.settled;/);
    assert.match(shell, /target: "theme"[^]*?function apply\(\): void[^]*?SystemTheme\.apply\(true\)/);
    assert.match(shell, /function status\(\): string \{\s+return SystemTheme\.status\(\);/);
    assert.match(read("Common/qmldir"), /^singleton SystemTheme SystemTheme\.qml$/m);
});

test("apply validates tokens and saves the normalized copy", t => {
    const state = scratch(t);
    const tokens = darkTokens();
    tokens.colors.accent = "#D3D283";
    const result = runDriver(state, ["apply"], JSON.stringify(tokens) + "\n");
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.report.success, true);
    assert.deepEqual(Object.keys(result.report.targets), ["kitty", "hyprland", "gtk", "hyprlock"]);
    const saved = JSON.parse(fs.readFileSync(path.join(state, "tokens.json"), "utf8"));
    assert.equal(saved.colors.accent, "#d3d283");
    assert.equal(fs.statSync(path.join(state, "tokens.json")).mode & 0o777, 0o644);
});

test("apply rejects malformed exports without touching saved tokens", t => {
    const state = scratch(t);
    assert.equal(runDriver(state, ["apply"], JSON.stringify(darkTokens()) + "\n").status, 0);
    const before = fs.readFileSync(path.join(state, "tokens.json"), "utf8");
    const bad = [
        "not json",
        JSON.stringify({ ...darkTokens(), v: 2 }),
        JSON.stringify({ ...darkTokens(), mode: "dim" }),
        JSON.stringify({ ...darkTokens(), radius: 16.5 }),
        JSON.stringify({ ...darkTokens(), glass: "yes" }),
        JSON.stringify({ ...darkTokens(), colors: { ...darkTokens().colors, text: "red" } }),
        JSON.stringify({ ...darkTokens(), colors: { ...darkTokens().colors, text: "#fff" } }),
        JSON.stringify({ ...darkTokens(), font: { ui: "Evil\"; rm", mono: "Mono" } }),
    ];
    for (const input of bad) {
        const result = runDriver(state, ["apply"], input + "\n");
        assert.equal(result.status, 1, input);
        assert.equal(result.report.success, false);
        assert.ok(result.report.error);
    }
    assert.equal(fs.readFileSync(path.join(state, "tokens.json"), "utf8"), before);
});

test("an unsafe wallpaper path is dropped instead of failing the export", () => {
    for (const wallpaper of ["relative.jpg", "/a\"b.jpg", "/a\\b.jpg", "/a\nb.jpg", 42]) {
        const out = tokensModule("print(json.dumps(t.validate(json.loads(sys.stdin.read()))))",
            { ...darkTokens(), wallpaper });
        assert.equal(out.wallpaper, "");
    }
});

test("render needs saved tokens and usage errors exit 2", t => {
    const state = scratch(t);
    assert.equal(runDriver(state, ["render"]).status, 1);
    assert.equal(runDriver(state, ["apply", "--now"]).status, 2);
    assert.equal(runDriver(state, ["render", "--force"]).status, 2);
    assert.equal(runDriver(state, []).status, 2);
    assert.equal(runDriver(state, ["apply"], JSON.stringify(lightTokens()) + "\n").status, 0);
    const result = runDriver(state, ["render"]);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.report.success, true);
});

test("oversized input is refused", t => {
    const tokens = darkTokens();
    tokens.padding = "x".repeat(70000);
    const result = runDriver(scratch(t), ["apply"], JSON.stringify(tokens) + "\n");
    assert.equal(result.status, 1);
    assert.match(result.report.error, /too large/);
});

test("the terminal palette keeps every hue readable on the base", () => {
    for (const tokens of [darkTokens(), lightTokens()]) {
        const out = tokensModule(
            "tok = t.validate(json.loads(sys.stdin.read()))\n"
            + "p = t.ansi_palette(tok)\n"
            + "print(json.dumps([p, [t.contrast(c, tok['colors']['background']) for c in p]]))",
            tokens);
        const [palette, ratios] = out;
        assert.equal(palette.length, 16);
        for (const c of palette)
            assert.match(c, /^#[0-9a-f]{6}$/);
        for (const i of [1, 2, 3, 4, 5, 6, 9, 10, 11, 12, 13, 14])
            assert.ok(ratios[i] >= 4.5, `${tokens.mode} color${i} ${palette[i]} ${ratios[i]}`);
        const fg = tokens.mode === "dark" ? 15 : 0;
        assert.equal(palette[fg], tokens.colors.text);
    }
});

test("colour helpers agree with SettingsHelpers", () => {
    const H = require(path.join(shellDir, "Common/SettingsHelpers.js"));
    const cases = [["#d3d283", "#eae9ef", 4.5], ["#9ecbeb", "#f8f7fa", 4.5],
        ["#3a3936", "#1a1917", 3], ["#e8837a", "#1a1917", 7]];
    const out = tokensModule(
        "print(json.dumps([[t.ensure_contrast(v, b, r), t.contrast(v, b), t.mix(v, b, 0.3)]"
        + " for v, b, r in json.loads(sys.stdin.read())]))", cases);
    cases.forEach(([value, background, target], i) => {
        assert.equal(out[i][0], H.ensureContrast(value, background, target));
        assert.ok(Math.abs(out[i][1] - H.contrastRatio(value, background)) < 1e-9);
        assert.equal(out[i][2], H.mixHex(value, background, 0.3));
    });
});

test("SystemTheme exports the effective text size the shell draws", () => {
    const qml = read("Common/SystemTheme.qml");
    assert.match(qml, /font: \{ui: Common\.Theme\.fontMenu, mono: Common\.Theme\.fontMono,\s+size: Common\.Theme\.fontBaseSize\}/);
    // Theme.fontBaseSize is ShellMetrics' base x interface scale x text size.
    assert.match(read("Common/Theme.qml"), /readonly property int fontBaseSize: metrics\.fontBase/);
    const metrics = require(path.join(shellDir, "Common/ShellMetrics.js"));
    const size = (shellFontSize, shellScale, textScale) => metrics.calculate({
        shellFontSize, shellScale, textScale, interfaceDensity: "default" }).fontBase;
    assert.equal(size(14, 100, "default"), 14);
    assert.equal(size(14, 100, "large"), 16);
    assert.equal(size(14, 100, "larger"), 18);
    assert.equal(size(14, 150, "default"), 21);
    assert.equal(size(24, 200, "larger"), 62);
    assert.equal(size(10, 75, "default"), 8);
});

test("the text size is validated, defaults for older exports, and maps to one ratio", () => {
    const valid = tokensModule("print(json.dumps([t.validate(json.loads(sys.stdin.read()))['font']['size']]))",
        { ...darkTokens(), font: { ...darkTokens().font, size: 21 } });
    assert.deepEqual(valid, [21]);
    const older = tokensModule("print(json.dumps(t.validate(json.loads(sys.stdin.read()))['font']))",
        darkTokens());
    assert.equal(older.size, 14, "tokens saved before the size was exported render as before");
    for (const size of [5, 97, 14.5, "14", true, null]) {
        const out = tokensModule(
            "raw = json.loads(sys.stdin.read())\n"
            + "try:\n    t.validate(raw)\n    print('null')\n"
            + "except t.TokenError as e:\n    print(json.dumps(str(e)))",
            { ...darkTokens(), font: { ...darkTokens().font, size } });
        if (size === null)
            assert.equal(out, null, "an explicit null is an older export");
        else
            assert.match(out, /font size/, String(size));
    }
    const scales = tokensModule(
        "print(json.dumps([t.text_scale({'font': {'size': s}}) for s in (6, 8, 14, 16, 21, 28, 62, 96)]))");
    assert.deepEqual(scales, [0.5, 8 / 14, 1, 16 / 14, 1.5, 2, 3, 3]);
    assert.deepEqual(tokensModule(
        "print(json.dumps([t.scaled(v, {'font': {'size': 21}}) for v in (84, 85, 18, 1)]))"),
    [126, 128, 27, 2]);
});
