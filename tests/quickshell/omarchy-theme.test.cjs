const test = require("node:test");
const assert = require("node:assert/strict");
const { load } = require("./shell.cjs");
const settings = load("SettingsHelpers.js");
const theme = load("OmarchyTheme.js");
const metrics = load("ShellMetrics.js");
const palette = { accent: "#123456", outline: "#456789", foreground: "#ffffff",
    background: "#000000", bar: "#111111", surfaceBorder: "#123456",
    surfaceBorderWidth: 2, surfaceBorderAlpha: 1 };
const prefs = (patch = {}) => settings.merge({ ...settings.defaults(),
    ...patch });
const values = (p, colors = palette, session) => theme.values(p, colors, metrics.calculate(p), session);

test("Omarchy adapter maps the default font, geometry and supplied palette border", () => {
    const p = prefs();
    assert.equal(p.font, "mono");
    assert.equal(p.surfaceCornerRadius, 16);
    const v = values(p);
    assert.equal(Math.round(420 * Number(v["font.base-size"]) / 12), 420);
    for (const surface of ["popups", "tooltip", "menu", "launcher", "notifications"]) {
        assert.equal(v[surface + ".border"], palette.surfaceBorder);
        assert.equal(v[surface + ".border-width"], "2");
        assert.equal(v[surface + ".border-alpha"], "1");
    }
});

test("all density and accessibility combinations share font and geometry scaling", () => {
    for (const shellFontSize of [10, 12, 14, 24])
        for (const shellScale of [75, 100, 150, 200])
            for (const textScale of ["default", "large", "larger"])
                for (const interfaceDensity of ["compact", "default", "comfortable"]) {
                    const p = prefs({ shellFontSize, shellScale, textScale, interfaceDensity });
                    const m = metrics.calculate(p), v = values(p);
                    assert.equal(Number(v["font.base-size"]), m.fontBase);
                    assert.ok(Math.abs(Number(v["spacing.scale"]) * m.fontScale - m.spacingScale) < 1e-9);
                    const preferred = 408 * m.spacingScale;
                    for (const available of [320, 900, 1440, 2560]) {
                        const width = metrics.fitWidth(preferred, available, 14);
                        assert.ok(width > 0 && width <= available - 28);
                    }
                }
    const normal = metrics.calculate(prefs());
    const compact = metrics.calculate(prefs({ interfaceDensity: "compact" }));
    const roomy = metrics.calculate(prefs({ interfaceDensity: "comfortable" }));
    assert.ok(compact.spacingScale < normal.spacingScale);
    assert.ok(roomy.spacingScale > normal.spacingScale);
    assert.equal(compact.fontBase, normal.fontBase);
    assert.equal(roomy.fontBase, normal.fontBase);
});

test("plugin overrides stay independent and shared border opacity is applied once", () => {
    const p = prefs({ pluginScale: 150, textScale: "large", pluginBorderMode: "custom",
        pluginBorderColor: "#abcdef", pluginBorderWidth: 4, pluginBorderOpacity: 50, pluginRadius: 0 });
    const v = values(p);
    assert.equal(v["font.base-size"], "21");
    assert.equal(v["popups.border"], "#abcdef");
    assert.equal(v["popups.border-alpha"], "0.5");
    const shared = values(prefs(), { ...palette, surfaceBorder: "#fedcba",
        surfaceBorderWidth: 3, surfaceBorderAlpha: .4 });
    assert.equal(shared["popups.border"], "#fedcba");
    assert.equal(shared["popups.border-width"], "3");
    assert.equal(shared["popups.border-alpha"], "0.4");
});

test("persistent advanced tokens beat session imports and preserve gradient side widths", () => {
    const p = prefs({ pluginThemeOverrides: {
        "popups.border": "#123456 #abcdef 45deg", "popups.border-width": "1 2 3 4",
        "spacing.scale-with-font": false, "font.base-size": 16,
        bad: "no", "popups.object": {}, "font.nan": NaN
    } });
    const v = values(p, palette, { "popups.border": "#000000", "menu.border": "#888888" });
    assert.equal(v["popups.border"], "#123456 #abcdef 45deg");
    assert.equal(v["popups.border-width"], "1 2 3 4");
    assert.equal(v["spacing.scale-with-font"], "false");
    assert.equal(v["font.base-size"], "16");
    assert.equal(v["menu.border"], "#888888");
    assert.equal(Object.keys(p.pluginThemeOverrides).length, 4);
    assert.deepEqual(settings.merge({ pluginThemeOverrides: [] }).pluginThemeOverrides, {});
});
