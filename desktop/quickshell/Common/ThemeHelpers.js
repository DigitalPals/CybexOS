// Named appearance themes in Settings → Appearance (docs/shell-appearance.md).
// scripts/theme_packs.py owns the theme schema and maps each theme to the
// shell.json values applying it sets — its "patch". The shell lists those
// entries, tells which one the current settings show, and applies a patch as
// one undoable change. Keep this file free of Qt APIs: theme-helpers.test.cjs
// runs it under Node with SettingsHelpers.

// Every key a theme may set, which is all `theme use` accepts. The wallpaper
// is part of applying a theme but not of resetting one.
var PATCH_KEYS = ["theme", "themeMode", "paletteMode", "accent", "font", "barColorMode",
    "barCustomHue", "barCustomSaturation", "barCustomLightness", "themePalette", "wall"];
var REQUIRED_KEYS = ["theme", "themeMode", "paletteMode", "accent", "barColorMode",
    "themePalette"];
var RESET_KEYS = PATCH_KEYS.filter(function(key) { return key !== "wall"; });
var NAME_MAX = 48;

function plainObject(value) {
    return !!value && typeof value === "object" && !Array.isArray(value);
}

// A patch held to the settings schema: only theme keys, each already a value
// the settings file stores unchanged. `normalizeKey` is
// SettingsHelpers.normalizeKey; anything it would alter is refused rather
// than silently replaced by a default. Returns null for an invalid patch.
function patchIn(raw, normalizeKey) {
    if (!plainObject(raw))
        return null;
    var keys = Object.keys(raw);
    if (keys.some(function(key) { return PATCH_KEYS.indexOf(key) === -1; })
            || REQUIRED_KEYS.some(function(key) { return keys.indexOf(key) === -1; }))
        return null;
    var custom = ["barCustomHue", "barCustomSaturation", "barCustomLightness"];
    var hasCustom = custom.filter(function(key) { return keys.indexOf(key) !== -1; }).length;
    if (raw.barColorMode === "custom" ? hasCustom !== 3 : hasCustom !== 0)
        return null;
    var out = {};
    for (var i = 0; i < keys.length; i++) {
        var key = keys[i];
        var normalized = normalizeKey(key, raw[key]);
        if (JSON.stringify(normalized) !== JSON.stringify(raw[key]))
            return null;
        out[key] = normalized;
    }
    return out.theme === "" ? null : out;
}

function nameIn(value) {
    if (typeof value !== "string")
        return "";
    var trimmed = value.trim();
    return trimmed !== "" && trimmed.length <= NAME_MAX && !/[\u0000-\u001f\u007f]/.test(trimmed)
        ? trimmed : "";
}

// What `theme-packs.py resolve` prints and `theme use` receives:
// {id, name, patch}. Returns null unless every part is valid.
function payloadIn(raw, normalizeKey) {
    if (!plainObject(raw))
        return null;
    var name = nameIn(raw.name);
    var patch = patchIn(raw.patch, normalizeKey);
    if (name === "" || patch === null || raw.id !== patch.theme)
        return null;
    return { id: patch.theme, name: name, patch: patch };
}

// One listed theme (`theme-packs.py list --json`), or null.
function entryIn(raw, normalizeKey) {
    if (!plainObject(raw))
        return null;
    var payload = payloadIn({ id: raw.id, name: raw.name, patch: raw.patch }, normalizeKey);
    if (payload === null || payload.patch.wall !== undefined
            || (raw.mode !== "dark" && raw.mode !== "light"))
        return null;
    return {
        id: payload.id,
        name: payload.name,
        mode: raw.mode,
        builtin: raw.builtin === true,
        hasWallpaper: raw.hasWallpaper === true,
        patch: payload.patch
    };
}

function catalogueIn(raw, normalizeKey) {
    var themes = plainObject(raw) && Array.isArray(raw.themes) ? raw.themes : [];
    var seen = {};
    var out = [];
    themes.forEach(function(item) {
        var entry = entryIn(item, normalizeKey);
        if (entry !== null && !seen[entry.id]) {
            seen[entry.id] = true;
            out.push(entry);
        }
    });
    return out;
}

function sameValue(a, b) {
    if (typeof a === "string" && typeof b === "string")
        return a.toLowerCase() === b.toLowerCase();
    return JSON.stringify(a) === JSON.stringify(b);
}

// The palette that is actually drawn: none unless it was made for the
// current mode and the accent source is fixed (Theme.themePaletteActive).
function effectivePalette(palette, mode, paletteMode) {
    if (!plainObject(palette) || palette.mode !== mode || paletteMode !== "fixed")
        return "";
    return JSON.stringify(palette).toLowerCase();
}

// Whether the settings show exactly what `patch` sets. The wallpaper is not
// compared — rotation would otherwise un-pick every theme with one — and a
// palette counts only while it is drawn.
function matches(patch, settings) {
    if (!plainObject(patch) || !settings)
        return false;
    return Object.keys(patch).every(function(key) {
        if (key === "theme" || key === "wall")
            return true;
        if (key === "themePalette")
            return effectivePalette(patch.themePalette, patch.themeMode, patch.paletteMode)
                === effectivePalette(settings.themePalette, settings.themeMode,
                    settings.paletteMode);
        return sameValue(patch[key], settings[key]);
    });
}

// The settings a fresh install shows, as a patch: the look the Theme row's
// reset returns to.
function defaultPatch(defaults) {
    var patch = { theme: "", themeMode: defaults.themeMode, paletteMode: defaults.paletteMode,
        accent: defaults.accent, font: defaults.font, barColorMode: defaults.barColorMode,
        themePalette: defaults.themePalette };
    if (defaults.barColorMode === "custom") {
        patch.barCustomHue = defaults.barCustomHue;
        patch.barCustomSaturation = defaults.barCustomSaturation;
        patch.barCustomLightness = defaults.barCustomLightness;
    }
    return patch;
}

function differsFromDefault(settings, defaults) {
    return !matches(defaultPatch(defaults), settings);
}

// The theme the settings show: the one applied last, marked "(modified)"
// once anything it set has changed; otherwise the first theme they match
// exactly; otherwise "Custom". { value, label, modified }.
function current(entries, settings) {
    var list = Array.isArray(entries) ? entries : [];
    var named = list.find(function(entry) { return entry.id === settings.theme; });
    if (named) {
        var same = matches(named.patch, settings);
        return { value: named.id, label: same ? named.name : named.name + " (modified)",
            modified: !same };
    }
    var match = list.find(function(entry) { return matches(entry.patch, settings); });
    if (match)
        return { value: match.id, label: match.name, modified: false };
    return { value: "", label: "Custom", modified: false };
}

// Options for the Theme dropdown. "Custom" is listed only while it is the
// current state, as the place the selection rests; it applies nothing.
function choices(entries, state) {
    var list = Array.isArray(entries) ? entries : [];
    var out = list.map(function(entry) {
        return { value: entry.id, label: entry.id === state.value ? state.label : entry.name };
    });
    if (state.value === "")
        out.unshift({ value: "", label: state.label });
    return out;
}

// A theme in three dots: its base, its accent and its text. `references`
// holds the shell's fixed {background, text} per mode for a theme that keeps
// the shell's own surfaces.
function swatches(entry, references) {
    if (!entry || !entry.patch)
        return [];
    var patch = entry.patch;
    var mode = patch.themeMode === "light" ? "light" : "dark";
    var reference = references && references[mode] ? references[mode] : { background: "", text: "" };
    var palette = patch.themePalette && patch.themePalette.mode === mode ? patch.themePalette : {};
    return [palette.background || reference.background, patch.accent,
        palette.text || reference.text];
}

// A theme as Appearance's gallery draws it: a desktop in miniature with its
// base, a bar, a raised panel, two lines of text and the accent. Missing
// roles fall back to `references[mode]`, the shell's own surfaces, as the
// theme itself does when it keeps them.
function preview(entry, references) {
    if (!entry || !entry.patch)
        return null;
    var patch = entry.patch;
    var mode = patch.themeMode === "light" ? "light" : "dark";
    var reference = references && references[mode] ? references[mode] : {};
    var palette = patch.themePalette && patch.themePalette.mode === mode ? patch.themePalette : {};
    var background = palette.background || reference.background || "";
    var surface = palette.surface || reference.surface || background;
    return {
        mode: mode,
        background: background,
        surface: surface,
        raised: palette.surfaceRaised || reference.raised || surface,
        accent: patch.accent || "",
        text: palette.text || reference.text || "",
        dim: palette.textDim || palette.textMuted || reference.dim || reference.text || ""
    };
}

var exported = {
    PATCH_KEYS: PATCH_KEYS,
    REQUIRED_KEYS: REQUIRED_KEYS,
    RESET_KEYS: RESET_KEYS,
    NAME_MAX: NAME_MAX,
    patchIn: patchIn,
    nameIn: nameIn,
    payloadIn: payloadIn,
    entryIn: entryIn,
    catalogueIn: catalogueIn,
    effectivePalette: effectivePalette,
    matches: matches,
    defaultPatch: defaultPatch,
    differsFromDefault: differsFromDefault,
    current: current,
    choices: choices,
    swatches: swatches,
    preview: preview
};

if (typeof module !== "undefined" && module.exports)
    module.exports = exported;
