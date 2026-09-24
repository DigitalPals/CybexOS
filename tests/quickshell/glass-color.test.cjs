const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { shellDir } = require("./shell.cjs");

function read(relative) {
    return fs.readFileSync(path.join(shellDir, relative), "utf8");
}

function qmlFiles(directory) {
    const out = [];
    const walk = current => {
        for (const entry of fs.readdirSync(current, { withFileTypes: true })) {
            const full = path.join(current, entry.name);
            if (entry.isDirectory())
                walk(full);
            else if (entry.name.endsWith(".qml"))
                out.push(full);
        }
    };
    walk(path.join(shellDir, directory));
    return out;
}

test("Appearance exposes live glass, wallpaper accents, and independent bar colors", () => {
    const appearance = read("Settings/AppearancePage.qml");
    const settings = read("Common/Settings.qml");
    const slider = read("Common/HSlider.qml");

    for (const [type, key] of [
        ["bool", "glassEnabled"],
        ["string", "barColorMode"],
        ["int", "barCustomHue"],
        ["int", "barCustomSaturation"],
        ["int", "barCustomLightness"]
    ])
        assert.match(settings, new RegExp(`property ${type} ${key}: defaults\\.${key}`));
    assert.match(settings, /readonly property string effectiveBarColor:/);
    assert.match(settings, /SettingsHelpers\.resolveBarColor/);
    assert.match(settings, /onGlassEnabledChanged:[\s\S]{0,100}?applyGlassEffect\(\)/);

    assert.match(appearance,
        /label:\s*"Glass effect"[\s\S]{0,100}?settingKey:\s*"glassEnabled"/);
    assert.match(appearance, /title:\s*"Colors"/);
    assert.match(appearance,
        /label:\s*"Accent source"[\s\S]{0,100}?settingKey:\s*"paletteMode"/);
    assert.match(appearance,
        /accentChoices:\s*\[Settings\.defaults\.accent,/,
        "the shipped accent must always have a selectable preset");
    assert.match(appearance,
        /readonly property bool selected:\s*Settings\.accent === modelData/,
        "the accent preset must visibly track the stored accent");
    assert.match(appearance, /Common\.Palette\.busy/);
    assert.match(appearance, /Common\.Palette\.error/);
    // The menubar's own color is the Bar page's, independent of the accent.
    const barColors = read("Settings/BarBackgroundGroup.qml");
    assert.match(read("Settings/BarLayoutGroups.qml"), /BarBackgroundGroup \{/);
    assert.doesNotMatch(appearance, /barColorMode|barCustomHue/,
        "the bar background moved from Appearance to the Bar page");
    assert.match(barColors, /SettingsGroup \{\s*id: barColorControls[\s\S]*?title: "Background"/);
    assert.match(barColors, /model:\s*Settings\.barColorChoices/);
    assert.match(barColors, /Accessible\.role:\s*Accessible\.RadioButton/);
    assert.match(barColors, /Accessible\.checked:\s*selected/);
    assert.match(barColors, /Settings\.previewBarColor\(modelData\.id\)/);
    for (const key of ["barCustomHue", "barCustomSaturation", "barCustomLightness"])
        assert.match(barColors, new RegExp(`settingKey: "${key}"`));
    assert.match(barColors, /hueTrack:\s*true/);
    assert.match(barColors, /colorTrack:\s*true/);
    assert.match(appearance, /id:\s*fixedColorReveal[\s\S]{0,100}?reveal:\s*page\.fixedPalette/,
        "wallpaper mode must collapse only the manual accent choices");
    assert.match(appearance,
        /id:\s*wallpaperPaletteReveal[\s\S]{0,100}?reveal:\s*!page\.fixedPalette/,
        "the non-interactive palette preview must not look disabled in Fixed mode");
    assert.match(barColors,
        /id:\s*customColorReveal[\s\S]{0,100}?reveal:\s*Settings\.barColorMode === "custom"/,
        "custom HSL controls must be progressively disclosed");
    assert.match(read("Common/Revealer.qml"), /enabled:\s*root\.reveal/,
        "collapsed choices must immediately leave keyboard traversal");
    assert.match(slider, /property bool colorTrack:\s*false/);
    assert.match(slider, /GradientStop \{ position: 0\.5; color: root\.trackMiddle \}/);
});

test("glass switches every shell surface through semantic fills", () => {
    const theme = read("Common/Theme.qml");
    assert.match(theme,
        /readonly property bool glassActive:\s*Settings\.glassEnabled && !Settings\.highContrast/);
    assert.match(theme,
        /readonly property color barSurface:\s*glassActive \? glass : barBg/);
    assert.match(theme,
        /readonly property color surfaceStrong:\s*glassActive \? glassStrong : popBg/);
    assert.match(theme,
        /readonly property color surfaceMenu:\s*glassActive \? glassMenu : menuBg/);

    assert.match(theme,
        /readonly property color panelSurface:\s*glassActive \? glassPanel : background/);

    // Every surface that hangs off the bar is a panel now and shares one fill.
    // A menu floating *above* a panel still needs to stay legible over it, so
    // the tooltip and the folder picker keep the denser variant.
    const expected = {
        "Bar/Bar.qml": "barSurface",
        "Bar/PopoutHost.qml": "barSurface",
        "Bar/BarTooltip.qml": "surfaceMenu",
        "LauncherWindow.qml": "panelSurface",
        "NotificationToasts.qml": "panelSurface",
        "OsdWindow.qml": "panelSurface",
        "ShortcutsOverlay.qml": "panelSurface",
        "Popovers/PopoutPanel.qml": "barSurface",
        "Settings/FolderDialog.qml": "surfaceMenu"
    };
    for (const [file, token] of Object.entries(expected))
        assert.match(read(file), new RegExp(`Theme\\.${token}\\b`),
            `${file} does not follow the glass setting`);

    assert.match(read("Popovers/Surface.qml"), /color:\s*root\.surfaceColor\b/,
        "shared surfaces must honor the panel-specific surface contract");
    assert.match(read("Bar/PopoutHost.qml"),
        /host\.activePanel \? host\.activePanel\.surfaceColor : Theme\.barSurface/,
        "the host must preserve global glass as the default while allowing product canvases");

    for (const file of qmlFiles(".")) {
        if (file === path.join(shellDir, "Common", "Theme.qml"))
            continue;
        assert.doesNotMatch(fs.readFileSync(file, "utf8"), /Theme\.glass(?:Strong|Menu)?\b/,
            `${path.relative(shellDir, file)} bypasses the semantic glass tokens`);
    }
});

test("menubar content uses its colour-derived palette", () => {
    const exempt = new Set(["BarTooltip.qml", "PopoutHost.qml"]);
    const globalPalette = /Theme\.(?:glass|chip|chipHover|wsOccupied|dotDim|stroke|icon|textHi|textMid|textLow|textDim|textFaint|accent|accentFg|accentGlow|red|redText|redBg|amber|amberBg|wxSun|wxMoon|wxCloud|wxFog|wxRain|wxSnow|wxStorm)\b/;

    for (const file of qmlFiles("Bar")) {
        if (exempt.has(path.basename(file)))
            continue;
        assert.doesNotMatch(fs.readFileSync(file, "utf8"), globalPalette,
            `${path.relative(shellDir, file)} bypasses the automatic menubar palette`);
    }

    const theme = read("Common/Theme.qml");
    assert.match(theme,
        /readonly property color barBg:\s*Settings\.effectiveBarColor/,
        "wallpaper accents must not replace the selected menubar background");
    assert.match(theme,
        /readonly property var barPalette:\s*SettingsHelpers\.barPalette\(barBg\.toString\(\)\)/);
    assert.match(theme, /readonly property color barAccent:\s*SettingsHelpers\.ensureContrast/);
    assert.match(read("Common/Weather.qml"), /function barGlyphColor/);
    assert.match(read("Bar/Modules/Weather.qml"), /Weather\.barGlyphColor/);
    assert.match(read("Bar/T3Chip.qml"),
        /BarBrandIcon\s*\{[\s\S]{0,500}?highlighted:\s*root\.held \|\| root\.hovered/);
    assert.match(read("Bar/UsageChips.qml"),
        /BarBrandIcon\s*\{[\s\S]{0,500}?highlighted:\s*root\.held \|\| emptyHover\.over/);
});

test("the named Hyprland blur rule persists and applies without remapping surfaces", () => {
    const look = fs.readFileSync(
        path.resolve(shellDir, "../../templates/looknfeel.lua.j2"), "utf8");
    const settings = read("Common/Settings.qml");

    assert.match(look, /local function persisted_glass_enabled\(\)/);
    assert.match(look, /\[,\{\]%s\*"glassEnabled"%s\*:%s\*\(%a\+\)/);
    assert.match(look,
        /quickshell_blur_rule = hl\.layer_rule\(\{[\s\S]*?enabled = persisted_glass_enabled\(\)/);
    assert.match(look,
        /namespace = \[\[\^qs-\(bar\|bar-popout\|launcher\|notifications\|osd\|shortcuts\)\$\]\]/);
    assert.match(settings,
        /"hyprctl", "eval",[\s\S]{0,120}?"quickshell_blur_rule:set_enabled\("/);
    assert.match(settings, /exitSeen \? lastExit : ProcHelpers\.NOT_STARTED/,
        "a missing hyprctl binary must surface as an apply error");
    assert.match(settings,
        /if \(root\.dispatchedGlassEnabled !== \(root\.glassEnabled && !root\.highContrast\)\)\s*glassReplayTimer\.restart\(\)/,
        "a second toggle while hyprctl is busy must be replayed");

    for (const file of ["Bar/Bar.qml", "Bar/BarPopoutWindow.qml", "LauncherWindow.qml",
        "NotificationToasts.qml", "OsdWindow.qml", "ShortcutsOverlay.qml"])
        assert.doesNotMatch(read(file), /WlrLayershell\.namespace:\s*Settings\./,
            `${file} must keep a stable namespace when glass changes`);
});
