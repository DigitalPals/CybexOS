// Pure validation for Matugen output and the wallpaper-palette cache. Keep Qt
// APIs out of this file so malformed-output and stale-result behavior can be
// tested without starting the shell.

// v2 holds a small most-recent-first list instead of a single wallpaper, so
// shuffling back to a recent image is a cache hit, and keys each palette by
// the file's mtime and size as well as its path, so a wallpaper replaced
// under the same name is regenerated.
var CACHE_VERSION = 2;
var CACHE_LIMIT = 12;

var ROLE_MAP = {
    background: "background",
    surface: "surface",
    surface_container_low: "surfaceContainerLow",
    surface_container: "surfaceContainer",
    surface_container_high: "surfaceContainerHigh",
    on_surface: "onSurface",
    on_surface_variant: "onSurfaceVariant",
    primary: "primary",
    primary_container: "primaryContainer",
    on_primary: "onPrimary",
    outline_variant: "outlineVariant",
    error: "error",
    error_container: "errorContainer",
    on_error: "onError"
};

var ROLE_KEYS = Object.keys(ROLE_MAP);

function parseObject(value) {
    if (typeof value !== "string")
        return value && typeof value === "object" && !Array.isArray(value) ? value : null;
    try {
        var parsed = JSON.parse(value);
        return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : null;
    } catch (error) {
        return null;
    }
}

function colorIn(value) {
    return typeof value === "string" && /^#[0-9a-fA-F]{6}$/.test(value)
        ? value.toLowerCase() : "";
}

// Matugen emits { colors: { role: { dark, default, light } } }. Unknown roles
// are ignored and all required light/dark values must be present.
function sanitizeMatugen(value) {
    var parsed = parseObject(value);
    var colors = parsed && parsed.colors;
    if (!colors || typeof colors !== "object" || Array.isArray(colors))
        return null;
    var palette = { dark: {}, light: {} };
    for (var i = 0; i < ROLE_KEYS.length; i++) {
        var inputName = ROLE_KEYS[i];
        var outputName = ROLE_MAP[inputName];
        var role = colors[inputName];
        if (!role || typeof role !== "object")
            return null;
        var dark = colorIn(role.dark);
        var light = colorIn(role.light);
        if (dark === "" || light === "")
            return null;
        palette.dark[outputName] = dark;
        palette.light[outputName] = light;
    }
    return palette;
}

function sanitizePalette(value) {
    if (!value || typeof value !== "object" || Array.isArray(value)
            || !value.dark || !value.light)
        return null;
    var out = { dark: {}, light: {} };
    for (var variantIndex = 0; variantIndex < 2; variantIndex++) {
        var variant = variantIndex === 0 ? "dark" : "light";
        for (var i = 0; i < ROLE_KEYS.length; i++) {
            var name = ROLE_MAP[ROLE_KEYS[i]];
            var color = colorIn(value[variant][name]);
            if (color === "")
                return null;
            out[variant][name] = color;
        }
    }
    return out;
}

function activeVariant(palette, themeMode) {
    var clean = sanitizePalette(palette);
    if (!clean)
        return null;
    return themeMode === "light" ? clean.light : clean.dark;
}

// The file half of a cache key from `stat -L -c "%Y %s"` output: "mtime
// size", or "" when the file could not be read — which callers treat as
// uncacheable rather than as a match for anything.
function fingerprint(statText) {
    if (typeof statText !== "string")
        return "";
    var text = statText.trim();
    return /^\d+ \d+$/.test(text) ? text : "";
}

function cacheEntries(value) {
    var parsed = parseObject(value);
    if (!parsed || parsed.v !== CACHE_VERSION || !Array.isArray(parsed.entries))
        return [];
    var out = [];
    for (var i = 0; i < parsed.entries.length && out.length < CACHE_LIMIT; i++) {
        var entry = parsed.entries[i];
        if (!entry || typeof entry.identity !== "string" || entry.identity === ""
                || typeof entry.fingerprint !== "string" || entry.fingerprint === "")
            continue;
        var palette = sanitizePalette(entry.palette);
        if (palette)
            out.push({ identity: entry.identity, fingerprint: entry.fingerprint, palette: palette });
    }
    return out;
}

function makeCache(identity, palette, stamp, previous, limit) {
    var clean = sanitizePalette(palette);
    if (typeof identity !== "string" || identity === "" || !clean
            || typeof stamp !== "string" || stamp === "")
        return null;
    var max = limit === undefined ? CACHE_LIMIT : limit;
    var entries = [{ identity: identity, fingerprint: stamp, palette: clean }];
    var older = cacheEntries(previous);
    for (var i = 0; i < older.length && entries.length < max; i++) {
        // One entry per path: a replaced file supersedes its old palette.
        if (older[i].identity !== identity)
            entries.push(older[i]);
    }
    return { v: CACHE_VERSION, entries: entries };
}

// The cached palette for a wallpaper path. With a fingerprint the entry must
// also match the file's current mtime and size; without one this is the
// optimistic lookup that keeps a known palette on screen while that check
// runs.
function readCache(value, identity, stamp) {
    var entries = cacheEntries(value);
    for (var i = 0; i < entries.length; i++) {
        if (entries[i].identity !== identity)
            continue;
        if (stamp !== undefined && entries[i].fingerprint !== stamp)
            return null;
        return entries[i].palette;
    }
    return null;
}

// Serialized cache with this result first, `previous` (the current cache
// text) behind it, and the least recently generated entries dropped.
function serializeCache(identity, palette, stamp, previous, limit) {
    var cache = makeCache(identity, palette, stamp, previous, limit);
    return cache ? JSON.stringify(cache, null, 2) + "\n" : "";
}

function resultIsCurrent(resultIdentity, currentIdentity) {
    return typeof resultIdentity === "string" && resultIdentity !== ""
        && resultIdentity === currentIdentity;
}

function selectOrFallback(palette, themeMode, fallback, enabled) {
    var selected = enabled ? activeVariant(palette, themeMode) : null;
    return selected || fallback;
}

var exported = {
    CACHE_VERSION: CACHE_VERSION,
    CACHE_LIMIT: CACHE_LIMIT,
    ROLE_MAP: ROLE_MAP,
    ROLE_KEYS: ROLE_KEYS,
    colorIn: colorIn,
    sanitizeMatugen: sanitizeMatugen,
    sanitizePalette: sanitizePalette,
    activeVariant: activeVariant,
    fingerprint: fingerprint,
    cacheEntries: cacheEntries,
    makeCache: makeCache,
    readCache: readCache,
    serializeCache: serializeCache,
    resultIsCurrent: resultIsCurrent,
    selectOrFallback: selectOrFallback
};

if (typeof module !== "undefined" && module.exports)
    module.exports = exported;
