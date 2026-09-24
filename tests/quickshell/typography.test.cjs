const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { shellDir, load } = require("./shell.cjs");

const themePath = path.join(shellDir, "Common", "Theme.qml");
const theme = fs.readFileSync(themePath, "utf8");

// Recursive: the bar's modules live in Bar/Modules/, and a font literal
// hides just as well one directory down.
function qmlFiles(directory) {
    const out = [];
    const walk = dir => {
        for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
            const full = path.join(dir, entry.name);
            if (entry.isDirectory() && entry.name !== "tests")
                walk(full);
            else if (entry.name.endsWith(".qml"))
                out.push(full);
        }
    };
    walk(path.join(shellDir, directory));
    return out;
}

function intToken(name) {
    const alias = theme.match(new RegExp(`readonly property int ${name}:\\s*typography\\.(\\w+)`));
    if (alias) return load("Typography.js").resolve(12)[alias[1]];
    const match = theme.match(new RegExp(
        `readonly property int ${name}:\\s*(?:scaled\\(\\s*)?(\\d+)`));
    assert.ok(match, `Theme.${name} must be an integer token`);
    return Number(match[1]);
}

function stringToken(name) {
    const match = theme.match(new RegExp(`readonly property string ${name}:\\s*"([^"]+)"`));
    assert.ok(match, `Theme.${name} must be a string token`);
    return match[1];
}

function hexToken(name) {
    const match = theme.match(new RegExp(`readonly property color ${name}:\\s*"(#[0-9a-fA-F]{6})"`));
    assert.ok(match, `Theme.${name} must be a six-digit hex color`);
    return match[1];
}

function luminance(hex) {
    const channels = hex.slice(1).match(/../g).map(value => Number.parseInt(value, 16) / 255);
    const linear = channels.map(value => value <= 0.04045
        ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4);
    return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2];
}

function contrast(a, b) {
    const lighter = Math.max(luminance(a), luminance(b));
    const darker = Math.min(luminance(a), luminance(b));
    return (lighter + 0.05) / (darker + 0.05);
}

test("semantic typography tokens retain the intended logical-pixel scale", () => {
    // Reference sizes are multiplied by the common font scale.
    assert.deepEqual([
        intToken("fontMicro"),
        intToken("fontTiny"),
        intToken("fontCaption"),
        intToken("fontSecondary"),
        intToken("fontBody"),
        intToken("fontHeading"),
        intToken("fontProminent"),
        intToken("fontDisplay"),
        intToken("fontHero"),
    ], [10, 11, 10, 11, 12, 16, 14, 24, 28]);
});

test("menu typography keeps the bar's own compact metrics", () => {
    assert.equal(stringToken("fontSans"), "JetBrainsMono Nerd Font");
    assert.equal(stringToken("fontIcon"), "Cybex Tabler Outline");
    assert.deepEqual([
        intToken("chipHeight"),
        intToken("chipInnerHeight"),
        intToken("tooltipHeight"),
        intToken("barTextSize"),
        intToken("barIconSize"),
    ], [28, 24, 28, 12, 15]);
    assert.match(theme, /readonly property var tabularNumberFeatures:\s*\(\{\s*"tnum":\s*1\s*\}\)/);
});

test("settings-driven tokens default to the selected menu face", () => {
    // fontMenu / barHeight / clusterRadius moved from literals to Shell
    // settings bindings; the defaults must still reproduce the design values
    // and Theme must actually bind to Settings rather than re-hardcode.
    const H = load("SettingsHelpers.js");
    const d = H.defaults();
    assert.equal(d.barHeight, 36);
    assert.equal(d.barRadius, 11);
    assert.equal(d.gap, 8);
    assert.equal(d.barStyle, "hug");
    assert.equal(d.accent, "#d3d283");
    const menuChoice = H.FONT_CHOICES.find(choice => choice.id === d.font);
    assert.equal(menuChoice.family, "JetBrainsMono Nerd Font");

    assert.match(theme,
        /readonly property int barHeight:\s*Math\.max\(Settings\.barHeight, chipHeight \+ 8\)/);
    assert.match(theme, /readonly property bool barFloating:\s*Settings\.barStyle === "floating"/);
    assert.match(theme, /readonly property int clusterRadius:\s*barFloating \? Settings\.barRadius : 0/);
    assert.match(theme, /readonly property color accent:\s*paletteActive \? Common\.Palette\.primary/);
    assert.match(theme, /Settings\.fontChoices/);
    // Derived accent fills must track the dynamic accent, not a literal.
    assert.doesNotMatch(theme, /158 \/ 255/);
    assert.match(theme, /readonly property color accentSoft:\s*paletteActive/);
    assert.match(theme, /readonly property color accentContainer:/);
    assert.match(theme, /readonly property color accentContainerFg:/);
});

test("shared surfaces carry the roomier density tokens", () => {
    assert.deepEqual([
        intToken("popWidth"),
        intToken("popWideWidth"),
        intToken("surfacePadding"),
        intToken("rowHeight"),
        intToken("tileHeight"),
    ], [408, 448, 16, 52, 64]);
});

test("every dialog shares the menubar's face, including T3", () => {
    // T3 used to hold a product face of its own. Beside a monospace menubar
    // that reads as a second application docked inside the shell, so its views
    // now take the same setting-driven face — through T3Theme.fontUi, which is
    // the one place the indirection lives.
    const t3Theme = fs.readFileSync(path.join(shellDir, "Common", "T3Theme.qml"), "utf8");
    assert.match(t3Theme, /readonly property string fontUi:\s*Theme\.fontMenu/,
        "T3's UI face must follow the shell's Typography setting");
    assert.doesNotMatch(t3Theme, /property string fontSans/,
        "the renamed token must not linger beside its replacement");

    for (const file of [...qmlFiles("Bar"), ...qmlFiles("Popovers"), ...qmlFiles("Settings")]) {
        const source = fs.readFileSync(file, "utf8");
        const label = path.relative(shellDir, file);
        assert.doesNotMatch(source, /(?<!T3)Theme\.fontSans/,
            `${label} bypasses Theme.fontMenu`);
        if (/^Popovers\/T3.*\.qml$/.test(label))
            assert.match(source, /T3Theme\.fontUi/,
                `${label} must draw its copy through the shared T3 UI face`);
    }

    // Nothing draws the default family directly any more: it is what fontMenu
    // falls back to, and naming it in a view is how a surface opts out of the
    // Typography setting. That is the whole bug this pass closed.
    assert.match(theme, /return choice \? choice\.family : fontSans;/,
        "fontMenu must fall back to the shipped default rather than a literal");
    const walk = dir => {
        const out = [];
        for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
            const full = path.join(dir, entry.name);
            if (entry.isDirectory() && entry.name !== "tests") out.push(...walk(full));
            else if (entry.name.endsWith(".qml")) out.push(full);
        }
        return out;
    };
    for (const file of walk(shellDir)) {
        if (path.relative(shellDir, file) === path.join("Common", "Theme.qml"))
            continue;
        const source = fs.readFileSync(file, "utf8");
        assert.doesNotMatch(source, /(?<!T3)Theme\.fontSans/,
            `${path.relative(shellDir, file)} bypasses Theme.fontMenu`);
        // The widget editor once drew a fixed Figtree through Theme.fontUi,
        // so Widgets read as a different face from every other settings page.
        assert.doesNotMatch(source, /(?<![A-Za-z0-9])Theme\.fontUi/,
            `${path.relative(shellDir, file)} bypasses Theme.fontMenu`);
    }
    assert.doesNotMatch(theme, /property string fontUi/,
        "Theme must not offer a second, fixed UI face beside fontMenu");
});

test("the semantic copy ladder keeps a real step at every level", () => {
    // Material's on-surface-variant role already clears the highest target on
    // a deep container, and `ensureContrast` only ever raises a colour, so the
    // wallpaper palette used to return one tone for all five steps: metadata,
    // labels and values rendered identically. Each step must land on its own
    // floor, and be visibly quieter than the step above it.
    const H = load("SettingsHelpers.js");
    const cases = [
        ["wallpaper dark", "#292a2f", "#e3e1e9", "#c6c5d0"],
        ["wallpaper light", "#e9e7ef", "#1b1b21", "#45464f"],
        ["fixed dark", "#171526", "#f5f4fb", "#a1a0a9"]
    ];
    const floors = { textMid: 7.0, icon: 6.0, textLow: 5.5, textDim: 4.8, textFaint: 4.5 };
    for (const [label, bg, onSurface, onVariant] of cases) {
        const ladder = H.semanticPalette(bg, onSurface, onVariant);
        const seen = new Set();
        for (const [step, floor] of Object.entries(floors)) {
            const ratio = H.contrastRatio(ladder[step], bg);
            assert.ok(ratio >= floor,
                `${label}: ${step} falls to ${ratio.toFixed(2)}:1, below its ${floor}:1 floor`);
            assert.ok(ratio < floor + 1.5,
                `${label}: ${step} sits at ${ratio.toFixed(2)}:1, far above its ${floor}:1 floor`);
            seen.add(ladder[step]);
        }
        assert.equal(seen.size, Object.keys(floors).length,
            `${label}: the ladder collapsed to ${seen.size} tone(s)`);
        assert.ok(H.contrastRatio(ladder.textHi, bg) >= 7.0, `${label}: textHi`);
    }
});

test("all visible bar values use the menu face with tabular figures", () => {
    for (const file of qmlFiles("Bar")) {
        const source = fs.readFileSync(file, "utf8");
        const label = path.relative(shellDir, file);
        assert.doesNotMatch(source, /font\.family:\s*Theme\.fontMono/,
            `${label} still uses the monospace face`);
    }

    // Every bar file that draws a changing number. The four modules joined
    // the list when Bar.qml stopped drawing any of them itself.
    for (const name of ["BarIcon.qml", "T3Chip.qml", "UsageChips.qml", "Workspaces.qml",
                        "Modules/Clock.qml", "Modules/Weather.qml",
                        "Modules/Battery.qml", "Modules/Volume.qml"]) {
        const source = fs.readFileSync(path.join(shellDir, "Bar", name), "utf8");
        assert.match(source, /Theme\.tabularNumberFeatures/,
            `${name} must opt dynamic values into tabular figures`);
    }
});

test("bar and popovers use semantic sizes with an Omarchy ten-pixel caption floor", () => {
    const files = [...qmlFiles("Bar"), ...qmlFiles("Popovers"), ...qmlFiles("Settings"),
        path.join(shellDir, "OsdWindow.qml")];
    for (const [name, value] of Object.entries(load("Typography.js").resolve(12)))
        assert.ok(value >= 10, `${name} falls below the 10 px caption floor`);

    for (const file of files) {
        const source = fs.readFileSync(file, "utf8");
        const label = path.relative(shellDir, file);
        assert.doesNotMatch(source, /font\.pixelSize:\s*\d+(?:\.\d+)?/,
            `${label} contains a raw numeric text size`);
        assert.doesNotMatch(source, /font-size\s*:/i,
            `${label} contains an inline HTML text size`);
        assert.doesNotMatch(source, /font\.weight:\s*\d+/,
            `${label} contains a weight that does not map to an installed face`);
    }
});

test("soft shell chrome does not use the display-heavy text weight", () => {
    // Google Sans Flex makes 750 conspicuous at compact shell sizes. Keep the
    // token available for a deliberate future display treatment, but require
    // current chrome to express hierarchy with medium, semibold, or bold.
    for (const file of qmlFiles(".")) {
        const source = fs.readFileSync(file, "utf8");
        const label = path.relative(shellDir, file);
        assert.doesNotMatch(source, /Theme\.weightHeavy/,
            `${label} uses the display-heavy weight in shell chrome`);
    }
});

test("only the classic floating bar and internal glows draw shadows", () => {
    // The compositor blurs the whole layer, and each of these layers is bigger
    // than the shape it draws. A shadow painted into that margin is blurred
    // with it and reads as a haze band the height of the surface, not as a
    // shadow. Glows *inside* a surface composite over the glass and are fine —
    // hence the allow-list rather than a blanket ban.
    const insideASurface = [
        "Bar/Bar.qml",               // the screenshot's floating slab shadow
        "Bar/T3Chip.qml",            // the running dot's bloom, inside the bar
        "Settings/ModulesPage.qml"   // the drag proxy, over an opaque page
    ];
    const offenders = [];
    for (const file of [...qmlFiles("Bar"), ...qmlFiles("Popovers"),
                        ...qmlFiles("Settings"),
                        ...["LauncherWindow.qml", "LauncherView.qml",
                            "NotificationToasts.qml", "OsdWindow.qml",
                            "ShortcutsOverlay.qml"]
                            .map(name => path.join(shellDir, name))]) {
        const label = path.relative(shellDir, file);
        if (insideASurface.includes(label))
            continue;
        if (/RectangularShadow/.test(fs.readFileSync(file, "utf8")))
            offenders.push(label);
    }
    assert.deepEqual(offenders, []);
});

test("views paint semantic surfaces rather than their opaque variants", () => {
    // `popBg`/`barBg` are selected by Theme's semantic aliases in solid mode
    // and serve as fixed contrast references in glass mode. Painting one in a
    // view would bypass the Glass effect switch.
    //
    // `Settings/` is exempt: its bar and toast previews are *pictures of*
    // those surfaces, and its drag proxy floats over the settings page.
    const offenders = [];
    for (const file of [...qmlFiles("Bar"), ...qmlFiles("Popovers"),
                        ...["LauncherWindow.qml", "LauncherView.qml",
                            "NotificationToasts.qml", "OsdWindow.qml",
                            "ShortcutsOverlay.qml"]
                            .map(name => path.join(shellDir, name))]) {
        const label = path.relative(shellDir, file);
        fs.readFileSync(file, "utf8").split("\n").forEach((line, index) => {
            if (/^\s*color:\s*Theme\.(popBg|barBg)\s*$/.test(line))
                offenders.push(`${label}:${index + 1}`);
        });
    }
    assert.deepEqual(offenders, [],
        "these bypass the semantic glass/solid surface token");
});

test("low-emphasis text remains WCAG AA in both palettes", () => {
    // Glass has no fixed background, so contrast is checked against the opaque
    // reference each palette declares: what a panel reads as over the shell's
    // own dimmed wallpaper. The design's own low tone lands at 3.2:1 there,
    // which is why these are lifted rather than copied.
    for (const mode of ["dark", "light"]) {
        const background = hexToken(`${mode}PopBg`);
        for (const step of ["TextMid", "TextLow", "TextDim", "TextFaint", "Icon"]) {
            const name = mode + step;
            assert.ok(contrast(hexToken(name), background) >= 4.5,
                `Theme.${name} must have at least 4.5:1 contrast against ${mode}PopBg`);
        }
    }
    // The one decorative token, and the reason the others cannot be lowered
    // to meet the design: it exists so nothing else has to be.
    assert.match(theme, /\/\/ Decorative only[\s\S]*?readonly property color dotDim/);
});


// The one accent, enforced shell-wide. It is allowed on a mark — a glyph, a
// dot, a piece of copy, a meter — and on exactly four fills: the current
// workspace pill, a switch or quick-toggle track, a value readout, and a
// primary action. Everywhere else a fill is the bar's own chip, because a
// selected row, a taken segment, a connected device and an open tab are all
// the same idea and the shell only has one way of saying it.
test("no surface paints an accent field where a chip belongs", () => {
    const ALLOWED = new Set([
        // the value readout inside a slider track
        "Popovers/FillSlider.qml",
        // a switch track, and the quick toggles that are switches
        "Popovers/ControlCenterPopover.qml",
        "Popovers/Drawer/DrawerTile.qml",
        "Common/Toggle.qml",
        // the one primary action per panel
        "Popovers/UpdatesPopover.qml",
        // the current day, which is the calendar's workspace pill
        "Popovers/CalendarPopover.qml",
        // T3 and GitHub carry their own reviewed treatment
        "Popovers/T3Composer.qml",
        "Popovers/T3ThreadPage.qml",
        "Popovers/T3InboxPage.qml",
        "Popovers/T3ModelPicker.qml",
        "Popovers/T3RequestCard.qml",
        "Popovers/T3InlineSelect.qml",
        "Popovers/T3Picker.qml",
        "Popovers/T3NewThreadPage.qml",
        "Popovers/T3CodePopover.qml",
        "Popovers/GitHubPopover.qml",
        // the bar's own workspace pill and status marks
        "Bar/Workspaces.qml",
        "Bar/BarIcon.qml",
        "Bar/T3Chip.qml",
        "Bar/Modules/Indicators.qml"
    ]);
    const walk = dir => {
        const out = [];
        for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
            const full = path.join(dir, entry.name);
            if (entry.isDirectory() && entry.name !== "tests") out.push(...walk(full));
            else if (entry.name.endsWith(".qml")) out.push(full);
        }
        return out;
    };
    const offenders = [];
    for (const file of walk(shellDir)) {
        const label = path.relative(shellDir, file).split(path.sep).join("/");
        if (ALLOWED.has(label) || label === "Common/Theme.qml")
            continue;
        fs.readFileSync(file, "utf8").split("\n").forEach((line, index) => {
            if (/^\s*(?:color|border\.color):[^\n]*Theme\.(?:accentBg|accentBgSoft|accentSoft|accentSubtle|accentContainer)\b/.test(line))
                offenders.push(`${label}:${index + 1}`);
        });
    }
    assert.deepEqual(offenders, [],
        "these paint an accent field; use Theme.chip / Theme.chipHover");
});


test("default body size is shared by settings controls and plugin typography", () => {
    const d = load("SettingsHelpers.js").defaults();
    assert.equal(d.shellFontSize, 12);
    assert.equal(d.shellScale, 100);
    assert.equal(d.pluginScale, 100);
    // The plugin install and clone fields are FieldRows.
    const plugins = ["PluginsPage", "PluginRow", "FieldRow"].map(name =>
        fs.readFileSync(path.join(shellDir, "Settings", name + ".qml"), "utf8")).join("\n");
    assert.match(plugins, /SettingsField\s*\{/, "the plugin forms must keep a field to check");
    for (const field of plugins.matchAll(/SettingsField\s*\{([^}]+)\}/g)) {
        assert.match(field[1], /font\.family: Theme\.fontMenu/);
        assert.match(field[1], /font\.pixelSize: Theme\.typography\.control/);
    }
    assert.match(fs.readFileSync(path.join(shellDir, "Settings", "SettingsTextRow.qml"), "utf8"), /SettingsField \{/);
    const widgets = fs.readFileSync(path.join(shellDir, "Bar", "UserWidgets.qml"), "utf8");
    assert.match(widgets, /fontSize: Theme\.typography\.bar/);
    assert.equal(load("ShellMetrics.js").calculate(d).fontBase, 12);
    for (const name of ["SettingsRow", "SettingsField", "SettingsAction",
        "PickerRow", "PillRow", "SliderRow"]) {
        const source = fs.readFileSync(path.join(shellDir, "Settings", name + ".qml"), "utf8");
        assert.match(source, /font\.pixelSize: Theme\.typography\.control/, name);
        assert.doesNotMatch(source, /font\.pixelSize: Theme\.font(?:Caption|Tiny)/, name);
    }
});
