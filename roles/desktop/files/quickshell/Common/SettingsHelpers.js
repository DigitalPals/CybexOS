// Pure settings-schema helpers shared by QML and Node tests.
// Keep this file free of Qt APIs so persistence stays deterministic.

var VERSION = 23;

var BAR_STYLES = ["hug", "floating", "attached"];
var PALETTE_MODES = ["wallpaper", "fixed"];

// The edge drawer's tabs, in default strip order. Overview is the drawer's
// front door — the Fedora button and the session footer live there — so it
// can be reordered but never disabled.
var DRAWER_TAB_IDS = ["overview", "sound", "network", "bluetooth", "power",
    "notifications", "usage"];

// How hovering a status glyph treats the drawer. "open" is the desktop-menu
// default: a click latches the session, then crossing switches tabs in place.
var DRAWER_HOVER_MODES = ["off", "open", "always"];

// The Overview tab's optional sections; machine stats and the session footer
// are fixed.
var DRAWER_OVERVIEW_KEYS = ["media", "sliders", "tiles", "updates"];

// Reads in default layout order: left, then center, then right. The order
// only decides where an id the settings file has never seen is appended, but
// keeping the two lists in step is what makes that placement predictable.
//
// Schema 4 (the glass menubar) retired three ids. `bell` was absorbed by the
// old combined centre pill; schema 11 deliberately introduces the distinct
// `notifications` id rather than reviving that historical key. `idle` became
// a Control Panel toggle, and `control` is fixed bar furniture rather than a
// configurable widget, so neither historical id returns to the schema.
var MODULE_IDS = [
    "ws", "media", "indicators", "clock", "weather", "notes", "updates", "gh", "t3", "hermes",
    "usage", "tray",
    "notifications", "vol", "wifi", "bt", "batt"
];

var RETIRED_MODULE_IDS = ["bell", "idle", "control"];

var DETAIL_IDS = ["media", "weather", "clock", "t3", "hermes", "usage", "gh", "updates",
    "notifications", "vol", "batt"];
var DETAIL_POLICIES = ["auto", "prefer", "compact"];

var FONT_CHOICES = [
    { id: "figtree", label: "Figtree", family: "Figtree" },
    { id: "google", label: "Google Sans Flex", family: "Google Sans Flex" },
    { id: "urbanist", label: "Urbanist", family: "Urbanist" },
    { id: "oppo", label: "OPPO Sans 4.0", family: "OPPO Sans 4.0" },
    { id: "plex", label: "IBM Plex Sans", family: "IBM Plex Sans" },
    { id: "mono", label: "JetBrainsMono Nerd Font", family: "JetBrainsMono Nerd Font" }
];

var FONT_IDS = FONT_CHOICES.map(function(choice) { return choice.id; });

// Named menubar colours. `default` and `macos` are adaptive pairs; the
// remaining presets are intentionally fixed so changing the shell theme does
// not silently change a colour the user chose explicitly. Custom is stored as
// HSL components so hue survives even at zero saturation/lightness.
var BAR_COLOR_CHOICES = [
    { id: "default", label: "Shell Default" },
    { id: "macos", label: "macOS" },
    { id: "black", label: "Black" },
    { id: "graphite", label: "Graphite" },
    { id: "slate", label: "Slate" },
    { id: "white", label: "White" },
    { id: "custom", label: "Custom" }
];

var BAR_COLOR_IDS = BAR_COLOR_CHOICES.map(function(choice) { return choice.id; });

var BAR_COLOR_PRESETS = {
    // The 2026-09 "edge drawer" redesign (Claude Design project 8cf85161,
    // direction 2) rests the shell on a warm charcoal instead of the earlier
    // cool near-black. The light half stays adaptive.
    "default": { dark: "#1a1917", light: "#ffffff" },
    "macos": { dark: "#1d1d1f", light: "#f5f5f7" },
    "black": { dark: "#000000", light: "#000000" },
    "graphite": { dark: "#2c2c2e", light: "#2c2c2e" },
    "slate": { dark: "#344054", light: "#344054" },
    "white": { dark: "#ffffff", light: "#ffffff" }
};

// How a module draws itself in the bar, which is also how the bar groups a
// run of them. `chip` modules retain their shared ordering and separator
// contract; `solo` modules bring their own independent pointer target.
// `time` (clock + weather) and `status` (notifications plus the
// vol/wifi/bt/batt glyph run) group the same way but rest on a filled pill,
// per the edge-drawer design. Notifications can opt back out in modOpts.
var MODULE_GROUPS = {
    ws: "solo", media: "solo", indicators: "solo", clock: "time", weather: "time",
    notes: "solo", updates: "solo", gh: "chip", t3: "chip", hermes: "chip", usage: "chip", tray: "solo",
    notifications: "status",
    vol: "status", wifi: "status", bt: "status", batt: "status"
};

var NOTIFICATION_GROUPS = ["solo", "status"];

// The clock-side action inventory is schema, not presentation: persisted
// order and visibility lists are normalized against it so an upgrade can add
// an action without losing the user's existing arrangement. Labels and glyphs
// are shared by the bar and its settings editor to keep both surfaces honest.
var INDICATOR_ACTION_CHOICES = [
    { id: "dictation", label: "Dictation", glyph: "mic" },
    { id: "recording", label: "Screen recording", glyph: "radio_button_checked" },
    { id: "ocr", label: "OCR", glyph: "document_scanner" },
    { id: "reminder", label: "Reminders", glyph: "notifications_active" },
    { id: "night-light", label: "Night light", glyph: "nightlight" },
    { id: "dnd", label: "Do Not Disturb", glyph: "do_not_disturb_on" },
    { id: "stay-awake", label: "Stay awake", glyph: "coffee" }
];
var INDICATOR_ACTION_IDS = INDICATOR_ACTION_CHOICES.map(
    function(choice) { return choice.id; });

var DICTATION_MODEL_CHOICES = [
    { value: "tiny", label: "Tiny" },
    { value: "base", label: "Base" },
    { value: "small", label: "Small" },
    { value: "medium", label: "Medium" },
    { value: "large-v3", label: "Large v3" },
    { value: "large-v3-turbo", label: "Large v3 Turbo" }
];
var DICTATION_MODELS = DICTATION_MODEL_CHOICES.map(
    function(choice) { return choice.value; });

// Notes title generation deliberately uses a small, reviewed model catalog.
// Besides making the settings selectable, this prevents a typo from reaching
// either CLI. Claude's aliases are the ones advertised by the installed CLI;
// the Codex tiers and effort support come from the OpenAI model catalog.
var NOTE_CODEX_MODEL_CHOICES = [
    { value: "gpt-5.6-luna", label: "Luna" },
    { value: "gpt-5.6-terra", label: "Terra" },
    { value: "gpt-5.6-sol", label: "Sol" }
];
var NOTE_CLAUDE_MODEL_CHOICES = [
    { value: "fable", label: "Fable" },
    { value: "sonnet", label: "Sonnet" },
    { value: "opus", label: "Opus" }
];
var NOTE_CODEX_EFFORT_CHOICES = [
    { value: "none", label: "None" },
    { value: "low", label: "Low" },
    { value: "medium", label: "Medium" },
    { value: "high", label: "High" },
    { value: "xhigh", label: "XHigh" },
    { value: "max", label: "Max" }
];
var NOTE_CLAUDE_EFFORT_CHOICES = NOTE_CODEX_EFFORT_CHOICES.filter(
    function(choice) { return choice.value !== "none"; });
var NOTE_CODEX_MODELS = NOTE_CODEX_MODEL_CHOICES.map(
    function(choice) { return choice.value; });
var NOTE_CLAUDE_MODELS = NOTE_CLAUDE_MODEL_CHOICES.map(
    function(choice) { return choice.value; });
var NOTE_CODEX_EFFORTS = NOTE_CODEX_EFFORT_CHOICES.map(
    function(choice) { return choice.value; });
var NOTE_CLAUDE_EFFORTS = NOTE_CLAUDE_EFFORT_CHOICES.map(
    function(choice) { return choice.value; });

// Group kinds that rest on a visible pill fill rather than transparent
// furniture. Cluster.qml reads this so the decision lives beside the map.
var FILLED_GROUP_KINDS = ["time", "status"];

function groupFilled(kind) {
    return FILLED_GROUP_KINDS.indexOf(kind) !== -1;
}

function moduleGroup(id, options) {
    var fallback = MODULE_GROUPS[id] || "solo";
    if (id !== "notifications")
        return fallback;
    var entry = options && options.notifications;
    return entry ? enumIn(entry.group, NOTIFICATION_GROUPS, fallback) : fallback;
}

function defaultMods() {
    function mod(id, on) {
        return { id: id, on: on, detail: "auto" };
    }
    return {
        left: [mod("ws", true), mod("media", true)],
        center: [mod("indicators", true), mod("clock", true), mod("weather", false),
            mod("notes", true)],
        right: [
            mod("updates", true), mod("gh", false), mod("t3", false), mod("hermes", false),
            mod("usage", false), mod("tray", false), mod("notifications", true), mod("vol", true),
            mod("wifi", true), mod("bt", false), mod("batt", true)
        ]
    };
}

// Per-module options: one object per configurable module id. Modules absent
// here have no option controls; a detail-only module may still get a settings
// page for its compaction policy.
function defaultModOpts() {
    return {
        ws: { minSlots: 5, hideEmpty: false, style: "numbers" },
        media: { titleFormat: "title-artist", maxWidth: 180 },
        indicators: {
            mode: "hover",
            order: INDICATOR_ACTION_IDS.slice(),
            enabled: INDICATOR_ACTION_IDS.slice(),
            dictationPrimaryLanguage: "en",
            dictationSecondaryLanguage: "nl",
            dictationModel: "base",
            recordingMode: "region",
            recordingShowElapsed: true,
            reminderDisplay: "icon",
            reminderClick: "list",
            reminderMinutes: 15,
            nightLightStartup: "remember",
            dndStartup: "remember",
            dndDefaultMode: "always",
            idleStartup: "off",
            idleDefaultMode: "1h",
            idleShowRemaining: false
        },
        clock: {
            seconds: false, showDate: true, dateFormat: "ddd dd",
            showEvents: true, daysAhead: 14, pollMins: 15
        },
        weather: { place: "", lat: 0, lon: 0, pollMins: 20 },
        notes: {
            titleProvider: "off",
            codexModel: "gpt-5.6-luna",
            codexEffort: "none",
            claudeModel: "fable",
            claudeEffort: "low"
        },
        t3: { showLabel: true },
        hermes: { showLabel: true, activityDetail: "verb" },
        usage: {
            source: "cliproxy",
            cliproxyUrl: "",
            cliproxyTlsVerify: true,
            sub2apiUrl: "",
            sub2apiTlsVerify: true,
            gemini: true,
            claude: true, claudeAutoRefresh: true, codex: true, kimi: true,
            xai: true,
            warnAt: 25, critAt: 10
        },
        gh: {
            badge: "dot", repos: 8, pollMins: 5, ciActivity: true,
            toasts: true, watch: []
        },
        updates: { pollMins: 30, flatpak: true, notify: true },
        tray: { expanded: false },
        notifications: { group: "status" },
        vol: { step: 5, showPct: true, middleClick: "mute" },
        batt: { showPct: true, warnAt: 20, critAt: 10 }
    };
}

function defaultDrawerTabs() {
    return DRAWER_TAB_IDS.map(function(id) {
        return { id: id, on: true };
    });
}

function defaultDrawerOverview() {
    var out = {};
    DRAWER_OVERVIEW_KEYS.forEach(function(key) { out[key] = true; });
    return out;
}

// Sanitize the persisted drawer tab strip: known ids only, first occurrence
// wins, ids the file has never seen are appended in default order, and
// Overview can never be switched off.
function normalizeDrawerTabs(raw) {
    var list = Array.isArray(raw) ? raw : [];
    var seen = {};
    var next = [];
    list.forEach(function(entry) {
        var id = entry ? entry.id : undefined;
        if (DRAWER_TAB_IDS.indexOf(id) === -1 || seen[id])
            return;
        seen[id] = true;
        next.push({
            id: id,
            on: id === "overview" ? true
                : typeof entry.on === "boolean" ? entry.on : true
        });
    });
    DRAWER_TAB_IDS.forEach(function(id) {
        if (!seen[id]) {
            // Introduce Bluetooth beside Network without disturbing saved order
            // or visibility. An explicitly positioned Bluetooth stays put.
            var networkIndex = next.findIndex(function(tab) { return tab.id === "network"; });
            if (id === "bluetooth" && networkIndex !== -1)
                next.splice(networkIndex + 1, 0, { id: id, on: true });
            else
                next.push({ id: id, on: true });
        }
    });
    return next;
}

function normalizeDrawerOverview(raw) {
    var next = defaultDrawerOverview();
    if (!raw || typeof raw !== "object")
        return next;
    DRAWER_OVERVIEW_KEYS.forEach(function(key) {
        next[key] = boolIn(raw[key], next[key]);
    });
    return next;
}

function defaults() {
    return {
        wall: "",
        wallDir: "~/Pictures/Wallpapers",
        shuffle: "Off",
        themeMode: "dark",
        glassEnabled: false,
        highContrast: false,
        reducedMotion: false,
        shellFontSize: 12,
        shellScale: 100,
        surfaceBorderMode: "accent",
        surfaceBorderColor: "#9ecbeb",
        surfaceBorderWidth: 2,
        surfaceBorderOpacity: 100,
        surfaceCornerRadius: 16,
        pluginScale: 100,
        pluginBorderMode: "inherit",
        pluginBorderColor: "#9ecbeb",
        pluginBorderWidth: 2,
        pluginBorderOpacity: 100,
        pluginRadius: -1,
        pluginThemeOverrides: {},
        textScale: "default",
        interfaceDensity: "default",
        barColorMode: "default",
        barCustomHue: 230,
        barCustomSaturation: 14,
        barCustomLightness: 9,
        barHeight: 36,
        barRadius: 11,
        font: "mono",
        accent: "#d3d283",
        paletteMode: "wallpaper",
        position: "top",
        barStyle: "hug",
        gap: 8,
        autoHide: false,
        exclusive: true,
        clock24: true,
        unit: "c",
        warmth: 3400,
        osd: "bottom",
        pollMax: 300,
        scrollFactor: 1.0,
        nightLight: false,
        // Runtime choices are persisted so a Quickshell service reload can
        // resume them. The Indicators startup policy decides what survives a
        // new login; timed modes retain an absolute deadline rather than
        // receiving a fresh duration after every reload.
        idleInhibitMode: "off",
        idleInhibitUntilMs: 0,
        notifDnd: false,
        notifDndUntilMs: 0,
        notifQuiet: "off",
        notifQuietStart: 1320,
        notifQuietEnd: 420,
        notifDuration: 8,
        notifPosition: "top-right",
        notifDensity: "default",
        notifIcons: true,
        notifProgress: true,
        notifBodyLines: 2,
        drawerTabs: defaultDrawerTabs(),
        drawerOverview: defaultDrawerOverview(),
        drawerHover: "open",
        drawerWidth: 400,
        mods: defaultMods(),
        modOpts: defaultModOpts()
    };
}

// Presets are explicit, undoable patches; account, palette and layout stay intact.
function appearancePreset(name) {
    if (name !== "omarchy" && name !== "cybex") return null;
    return { font: "mono",
        shellFontSize: 12, shellScale: 100,
        interfaceDensity: "default", surfaceCornerRadius: 16,
        surfaceBorderMode: "accent", surfaceBorderWidth: 2, surfaceBorderOpacity: 100,
        pluginScale: 100, pluginBorderMode: "inherit", pluginRadius: -1,
        pluginThemeOverrides: {} };
}

function pluginThemeOverridesIn(value) {
    var out = {};
    if (!value || typeof value !== "object" || Array.isArray(value)) return out;
    Object.keys(value).slice(0, 256).forEach(function(key) {
        var v = value[key];
        if (!/^[a-z][a-z0-9-]*\.[a-z][a-z0-9-]*$/.test(key)) return;
        if (typeof v === "string" && v.length <= 512
            || typeof v === "boolean" || typeof v === "number" && isFinite(v))
            out[key] = String(v);
    });
    return out;
}

function intIn(value, min, max, step, fallback) {
    if (typeof value !== "number" || !isFinite(value))
        return fallback;
    var snapped = step > 1 ? Math.round(value / step) * step : Math.round(value);
    return Math.min(max, Math.max(min, snapped));
}

function realIn(value, min, max, step, fallback) {
    if (typeof value !== "number" || !isFinite(value))
        return fallback;
    var snapped = Math.round(value / step) * step;
    return Math.min(max, Math.max(min, Number(snapped.toFixed(6))));
}

function enumIn(value, options, fallback) {
    return options.indexOf(value) !== -1 ? value : fallback;
}

function boolIn(value, fallback) {
    return typeof value === "boolean" ? value : fallback;
}

function textIn(value, maxLen, fallback) {
    if (typeof value !== "string")
        return fallback;
    if (value.indexOf("\0") !== -1 || value.indexOf("\n") !== -1 || value.indexOf("\r") !== -1)
        return fallback;
    var trimmed = value.trim();
    return trimmed !== "" && trimmed.length <= maxLen ? trimmed : fallback;
}

function orderedIdsIn(value, known, fallback, appendMissing) {
    if (!Array.isArray(value))
        return fallback.slice();
    var seen = {};
    var next = [];
    value.forEach(function(id) {
        if (typeof id === "string" && known.indexOf(id) !== -1 && !seen[id]) {
            seen[id] = true;
            next.push(id);
        }
    });
    if (appendMissing) {
        known.forEach(function(id) {
            if (!seen[id])
                next.push(id);
        });
    }
    return next;
}

// Voxtype accepts ISO-like language tags, `auto`, and comma-separated
// candidates. Keeping this validation deliberately narrower than arbitrary
// command text makes the value safe to pass as one argv item.
function dictationLanguageIn(value, fallback, allowOff) {
    if (typeof value !== "string")
        return fallback;
    var normalized = value.trim().toLowerCase();
    if (allowOff && normalized === "off")
        return normalized;
    var tag = "(?:auto|[a-z]{2,3}(?:-[a-z0-9]{2,8})?)";
    return new RegExp("^" + tag + "(?:," + tag + ")*$").test(normalized)
        ? normalized : fallback;
}

function timestampIn(value, fallback) {
    return typeof value === "number" && isFinite(value)
        && value >= 0 && value <= 1000000000000000
        ? Math.floor(value) : fallback;
}

function hexIn(value, fallback) {
    return typeof value === "string" && /^#[0-9a-fA-F]{6}$/.test(value) ? value : fallback;
}

function channelHex(value) {
    return Math.round(Math.min(1, Math.max(0, value)) * 255)
        .toString(16).padStart(2, "0");
}

function hslToHex(hue, saturation, lightness) {
    var h = ((Number(hue) % 360) + 360) % 360 / 360;
    var s = Math.min(100, Math.max(0, Number(saturation))) / 100;
    var l = Math.min(100, Math.max(0, Number(lightness))) / 100;
    if (!isFinite(h) || !isFinite(s) || !isFinite(l))
        return "#000000";

    if (s === 0)
        return "#" + channelHex(l) + channelHex(l) + channelHex(l);

    function hueChannel(p, q, t) {
        if (t < 0) t += 1;
        if (t > 1) t -= 1;
        if (t < 1 / 6) return p + (q - p) * 6 * t;
        if (t < 1 / 2) return q;
        if (t < 2 / 3) return p + (q - p) * (2 / 3 - t) * 6;
        return p;
    }

    var q = l < 0.5 ? l * (1 + s) : l + s - l * s;
    var p = 2 * l - q;
    return "#" + [
        hueChannel(p, q, h + 1 / 3),
        hueChannel(p, q, h),
        hueChannel(p, q, h - 1 / 3)
    ].map(channelHex).join("");
}

function resolveBarColor(mode, themeMode, hue, saturation, lightness) {
    var selected = enumIn(mode, BAR_COLOR_IDS, "default");
    if (selected === "custom")
        return hslToHex(hue, saturation, lightness);
    var preset = BAR_COLOR_PRESETS[selected] || BAR_COLOR_PRESETS["default"];
    return themeMode === "light" ? preset.light : preset.dark;
}

function rgbIn(value, fallback) {
    var valid = hexIn(value, fallback || "#000000").toLowerCase();
    return [1, 3, 5].map(function(offset) {
        return parseInt(valid.slice(offset, offset + 2), 16) / 255;
    });
}

function relativeLuminance(value) {
    var linear = rgbIn(value).map(function(channel) {
        return channel <= 0.04045 ? channel / 12.92
            : Math.pow((channel + 0.055) / 1.055, 2.4);
    });
    return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2];
}

function contrastRatio(a, b) {
    var first = relativeLuminance(a);
    var second = relativeLuminance(b);
    return (Math.max(first, second) + 0.05) / (Math.min(first, second) + 0.05);
}

function mixHex(from, to, amount) {
    var start = rgbIn(from);
    var end = rgbIn(to);
    var t = Math.min(1, Math.max(0, amount));
    return "#" + start.map(function(channel, index) {
        return channelHex(channel + (end[index] - channel) * t);
    }).join("");
}

function foregroundFor(background) {
    return contrastRatio("#ffffff", background) >= contrastRatio("#000000", background)
        ? "#ffffff" : "#000000";
}

// The least foreground mixed over a background that reaches the requested
// contrast. On a mid-luminance colour the hierarchy may collapse to the full
// black/white foreground; readability wins over artificial tonal separation.
function contrastTone(background, foreground, target) {
    if (contrastRatio(foreground, background) < target)
        return foreground;
    var low = 0;
    var high = 1;
    for (var i = 0; i < 16; i++) {
        var mid = (low + high) / 2;
        if (contrastRatio(mixHex(background, foreground, mid), background) >= target)
            high = mid;
        else
            low = mid;
    }
    return mixHex(background, foreground, high);
}

// Preserve a semantic colour when it already reads; otherwise pull it toward
// the bar's automatically selected foreground until it does.
function ensureContrast(value, background, target) {
    var source = hexIn(value, foregroundFor(background)).toLowerCase();
    if (contrastRatio(source, background) >= target)
        return source;
    var foreground = foregroundFor(background);
    var low = 0;
    var high = 1;
    for (var i = 0; i < 16; i++) {
        var mid = (low + high) / 2;
        if (contrastRatio(mixHex(source, foreground, mid), background) >= target)
            high = mid;
        else
            low = mid;
    }
    return mixHex(source, foreground, high);
}

function barPalette(background) {
    var bg = hexIn(background, "#161424").toLowerCase();
    var foreground = foregroundFor(bg);
    // Small status glyphs need stronger ink than the adjacent secondary copy.
    // The dark anchor matches the bright silver that already reads correctly
    // on the GitHub mark; light bars use its established deep-ink counterpart.
    // Pull either toward the selected foreground only when a custom bar colour
    // needs more contrast.
    var iconBase = foreground === "#ffffff" ? "#c2c6d1" : "#3a3850";
    return {
        background: bg,
        foreground: foreground,
        textHi: foreground,
        textMid: contrastTone(bg, foreground, 7.0),
        textLow: contrastTone(bg, foreground, 5.5),
        textDim: contrastTone(bg, foreground, 4.8),
        textFaint: contrastTone(bg, foreground, 4.5),
        icon: ensureContrast(iconBase, bg, 10.5)
    };
}

// One step of a semantic ladder, in whichever direction the source needs.
// `ensureContrast` only ever *raises* a colour toward the foreground, so a
// palette whose variant already clears the highest target returns that same
// variant for every step and the ladder collapses to one tone — which is
// exactly what Material's own on-surface roles do on a deep container. Fold
// the tone back toward the background in that case, the way the menubar
// builds its own ladder, so each step lands on its floor rather than above it.
function paletteTone(background, source, target) {
    return contrastRatio(source, background) < target
        ? ensureContrast(source, background, target)
        : contrastTone(background, source, target);
}

// Material palettes provide their own on-surface tones. Build the established
// semantic ladder from those roles while retaining the shell-wide AA floor.
function semanticPalette(background, onSurface, onSurfaceVariant) {
    var bg = hexIn(background, "#161424").toLowerCase();
    var hi = ensureContrast(onSurface, bg, 7.0);
    var variant = ensureContrast(onSurfaceVariant, bg, 4.5);
    return {
        background: bg,
        foreground: hi,
        textHi: hi,
        textMid: paletteTone(bg, variant, 7.0),
        textLow: paletteTone(bg, variant, 5.5),
        textDim: paletteTone(bg, variant, 4.8),
        textFaint: paletteTone(bg, variant, 4.5),
        icon: paletteTone(bg, variant, 6.0)
    };
}

function nameIn(value, fallback) {
    return typeof value === "string" && value !== "" && value.indexOf("/") === -1
        ? value : fallback;
}

function pathIn(value, fallback) {
    if (typeof value !== "string" || value === "" || value.indexOf("\0") !== -1
            || value.indexOf("\n") !== -1 || value.indexOf("\r") !== -1)
        return fallback;
    if (value[0] === "/")
        return value.replace(/\/{2,}/g, "/").replace(/\/$/, "") || "/";
    if (value === "~" || value.indexOf("~/") === 0) {
        var tail = value === "~" ? "" : value.slice(2);
        if (tail.split("/").some(function(part) { return part === ".."; }))
            return fallback;
        return tail === "" ? "~" : "~/" + tail.replace(/\/{2,}/g, "/").replace(/\/$/, "");
    }
    return fallback;
}

function detailIn(value) {
    return enumIn(value, DETAIL_POLICIES, "auto");
}

// The GitHub module's watch list, as *storage*: canonical "owner/repo" only,
// deduped case-insensitively (GitHub resolves names that way, and both
// spellings in the list would poll the same repository twice), capped so a
// hand-edited file cannot turn one poll into hundreds of API calls.
//
// Deliberately stricter and simpler than GitHubHelpers.repoSlug, which also
// accepts a pasted browser URL or an SSH remote. Canonicalising a paste is the
// settings row's job, at the point of entry; by the time a value reaches this
// store it is already a slug, and anything else came from a hand edit.
var MAX_WATCHED_REPOS = 20;
var REPO_SLUG = /^[A-Za-z0-9][A-Za-z0-9-]*\/[A-Za-z0-9._-]+$/;

function repoListIn(value, fallback) {
    if (!Array.isArray(value))
        return fallback;
    var out = [];
    var seen = {};
    for (var i = 0; i < value.length && out.length < MAX_WATCHED_REPOS; i++) {
        if (typeof value[i] !== "string")
            continue;
        var slug = value[i].trim();
        if (slug.length > 120 || !REPO_SLUG.test(slug)
                || slug.split("/")[1] === "." || slug.split("/")[1] === "..")
            continue;
        var key = slug.toLowerCase();
        if (seen[key])
            continue;
        seen[key] = true;
        out.push(slug);
    }
    return out;
}

// Sanitize a persisted module layout: known ids only, first occurrence wins,
// ids a newer schema knows about but the file does not are appended at their
// default column's end so shipping a new module never requires migration.
function normalizeMods(raw) {
    var base = defaultMods();
    if (!raw || typeof raw !== "object")
        return base;
    var defaultOn = {};
    var defaultCol = {};
    ["left", "center", "right"].forEach(function(col) {
        base[col].forEach(function(entry) {
            defaultOn[entry.id] = entry.on;
            defaultCol[entry.id] = col;
        });
    });
    var seen = {};
    var next = { left: [], center: [], right: [] };
    ["left", "center", "right"].forEach(function(col) {
        var list = Array.isArray(raw[col]) ? raw[col] : [];
        list.forEach(function(entry) {
            var id = entry ? entry.id : undefined;
            if (MODULE_IDS.indexOf(id) === -1 || seen[id])
                return;
            seen[id] = true;
            next[col].push({
                id: id,
                on: typeof entry.on === "boolean" ? entry.on : defaultOn[id],
                detail: detailIn(entry.detail)
            });
        });
    });
    MODULE_IDS.forEach(function(id) {
        if (!seen[id])
            next[defaultCol[id]].push({ id: id, on: defaultOn[id], detail: "auto" });
    });
    return next;
}

// Per-key validators for module options. Shared by normalizeModOpts and any
// UI that needs a key's bounds; fallback comes from defaultModOpts.
var MOD_OPT_CHECKS = {
    ws: {
        minSlots: function(v, d) { return intIn(v, 1, 10, 1, d); },
        hideEmpty: boolIn,
        style: function(v, d) { return enumIn(v, ["numbers", "dots"], d); }
    },
    media: {
        titleFormat: function(v, d) {
            return enumIn(v, ["title-artist", "title", "artist-title"], d);
        },
        maxWidth: function(v, d) { return intIn(v, 120, 360, 20, d); }
    },
    indicators: {
        mode: function(v, d) { return enumIn(v, ["hover", "always", "active"], d); },
        order: function(v, d) {
            return orderedIdsIn(v, INDICATOR_ACTION_IDS, d, true);
        },
        enabled: function(v, d) {
            return orderedIdsIn(v, INDICATOR_ACTION_IDS, d, false);
        },
        dictationPrimaryLanguage: function(v, d) {
            return dictationLanguageIn(v, d, false);
        },
        dictationSecondaryLanguage: function(v, d) {
            return dictationLanguageIn(v, d, true);
        },
        dictationModel: function(v, d) { return enumIn(v, DICTATION_MODELS, d); },
        recordingMode: function(v, d) {
            return enumIn(v, ["region", "window", "screen"], d);
        },
        recordingShowElapsed: boolIn,
        reminderDisplay: function(v, d) { return enumIn(v, ["icon", "count"], d); },
        reminderClick: function(v, d) { return enumIn(v, ["list", "quick-add"], d); },
        reminderMinutes: function(v, d) { return enumIn(v, [5, 15, 30, 60], d); },
        nightLightStartup: function(v, d) {
            return enumIn(v, ["remember", "off", "on"], d);
        },
        dndStartup: function(v, d) {
            return enumIn(v, ["remember", "off", "on"], d);
        },
        dndDefaultMode: function(v, d) {
            return enumIn(v, ["always", "1h", "quiet-boundary"], d);
        },
        idleStartup: function(v, d) {
            return enumIn(v, ["remember", "off", "on"], d);
        },
        idleDefaultMode: function(v, d) {
            return enumIn(v, ["30m", "1h", "unplugged", "always"], d);
        },
        idleShowRemaining: boolIn
    },
    clock: {
        seconds: boolIn,
        showDate: boolIn,
        showEvents: boolIn,
        daysAhead: function(v, d) { return intIn(v, 1, 31, 1, d); },
        pollMins: function(v, d) { return intIn(v, 5, 60, 5, d); },
        dateFormat: function(v, d) {
            return enumIn(v, ["ddd dd", "ddd d MMM", "dd MMM", "dd-MM"], d);
        }
    },
    weather: {
        place: function(v, d) { return textIn(v, 40, d); },
        lat: function(v, d) { return realIn(v, -90, 90, 0.0001, d); },
        lon: function(v, d) { return realIn(v, -180, 180, 0.0001, d); },
        pollMins: function(v, d) { return intIn(v, 5, 60, 5, d); }
    },
    notes: {
        titleProvider: function(v, d) {
            return enumIn(v, ["off", "codex", "claude"], d);
        },
        codexModel: function(v, d) { return enumIn(v, NOTE_CODEX_MODELS, d); },
        codexEffort: function(v, d) { return enumIn(v, NOTE_CODEX_EFFORTS, d); },
        claudeModel: function(v, d) { return enumIn(v, NOTE_CLAUDE_MODELS, d); },
        claudeEffort: function(v, d) { return enumIn(v, NOTE_CLAUDE_EFFORTS, d); }
    },
    t3: { showLabel: boolIn },
    hermes: {
        showLabel: boolIn,
        activityDetail: function(v, d) {
            return enumIn(v, ["full", "verb", "generic"], d);
        }
    },
    usage: {
        source: function(v, d) { return enumIn(v, ["direct", "cliproxy", "sub2api"], d); },
        cliproxyUrl: function(v, d) { return textIn(v, 400, d); },
        cliproxyTlsVerify: boolIn,
        sub2apiUrl: function(v, d) { return textIn(v, 400, d); },
        sub2apiTlsVerify: boolIn,
        gemini: boolIn,
        claude: boolIn,
        claudeAutoRefresh: boolIn,
        codex: boolIn,
        kimi: boolIn,
        xai: boolIn,
        warnAt: function(v, d) { return intIn(v, 10, 50, 5, d); },
        critAt: function(v, d) { return intIn(v, 5, 25, 5, d); }
    },
    gh: {
        badge: function(v, d) { return enumIn(v, ["dot", "count", "off"], d); },
        repos: function(v, d) { return intIn(v, 3, 15, 1, d); },
        pollMins: function(v, d) { return intIn(v, 1, 30, 1, d); },
        ciActivity: boolIn,
        toasts: boolIn,
        watch: repoListIn
    },
    updates: {
        pollMins: function(v, d) { return intIn(v, 10, 240, 10, d); },
        flatpak: boolIn,
        notify: boolIn
    },
    tray: { expanded: boolIn },
    notifications: {
        group: function(v, d) { return enumIn(v, NOTIFICATION_GROUPS, d); }
    },
    vol: {
        step: function(v, d) { return intIn(v, 1, 10, 1, d); },
        showPct: boolIn,
        middleClick: function(v, d) { return enumIn(v, ["mute", "none"], d); }
    },
    batt: {
        showPct: boolIn,
        warnAt: function(v, d) { return intIn(v, 10, 40, 5, d); },
        critAt: function(v, d) { return intIn(v, 5, 20, 5, d); }
    }
};

// Sanitize persisted module options: known modules and keys only, each value
// through its validator; anything unknown or invalid falls back to defaults.
function normalizeModOpts(raw) {
    var next = defaultModOpts();
    if (!raw || typeof raw !== "object")
        return next;
    Object.keys(MOD_OPT_CHECKS).forEach(function(id) {
        var entry = raw[id];
        if (!entry || typeof entry !== "object")
            return;
        Object.keys(MOD_OPT_CHECKS[id]).forEach(function(key) {
            if (key in entry)
                next[id][key] = MOD_OPT_CHECKS[id][key](entry[key], next[id][key]);
        });
    });
    return next;
}

// Provider selection did not exist before schema 21. Even if an older file
// happens to contain a future-shaped key, do not interpret it as consent to
// transmit note text. Model names may migrate harmlessly; enabling a provider
// requires a schema-21-or-newer settings write made through the current UI.
function migrateModOpts(raw, sourceVersion, rawSettings) {
    var next = normalizeModOpts(raw);
    if (typeof sourceVersion !== "number" || sourceVersion < 21)
        next.notes.titleProvider = "off";
    // The old persistent boolean meant the user explicitly chose Always.
    // Preserve that opt-in on the first schema-22 session even though a fresh
    // install's safer startup default is Off.
    if ((typeof sourceVersion !== "number" || sourceVersion < 22)
            && rawSettings && rawSettings.idleInhibited === true)
        next.indicators.idleStartup = "remember";

    // An action order written before OCR existed cannot place the new action:
    // normalization appends unknown-to-that-file ids at the end. Put OCR next
    // to Screen recording instead. If the old visibility list still enabled
    // every action, it was effectively the default, so adopt OCR too; a
    // customized list keeps the new action opt-in. Once OCR appears in the
    // stored order this block no longer runs, so explicitly hiding it sticks.
    var rawIndicators = raw && typeof raw === "object" ? raw.indicators : null;
    if (rawIndicators && Array.isArray(rawIndicators.order)
            && rawIndicators.order.indexOf("ocr") === -1) {
        next.indicators.order = next.indicators.order.filter(function(id) {
            return id !== "ocr";
        });
        var recordingIndex = next.indicators.order.indexOf("recording");
        next.indicators.order.splice(recordingIndex === -1
            ? next.indicators.order.length : recordingIndex + 1, 0, "ocr");

        var priorIds = INDICATOR_ACTION_IDS.filter(function(id) {
            return id !== "ocr";
        });
        var priorEnabled = Array.isArray(rawIndicators.enabled)
            && priorIds.every(function(id) {
                return rawIndicators.enabled.indexOf(id) !== -1;
            });
        if (priorEnabled) {
            var enabledRecordingIndex = next.indicators.enabled.indexOf("recording");
            next.indicators.enabled.splice(enabledRecordingIndex === -1
                ? next.indicators.enabled.length : enabledRecordingIndex + 1, 0, "ocr");
        }
    }
    return next;
}

// Schema 1 exposed T3 Code and model usage as one `t3` module. Preserve that
// composite module's placement and visibility when loading an older layout by
// inserting the new `usage` entry directly after it. Current-schema layouts
// continue through normal normalization, where missing ids use their defaults.
function migrateMods(raw, sourceVersion) {
    if (!raw || typeof raw !== "object")
        return normalizeMods(raw);

    var migrated = { left: [], center: [], right: [] };
    ["left", "center", "right"].forEach(function(col) {
        var list = Array.isArray(raw[col]) ? raw[col] : [];
        migrated[col] = list.map(function(entry) {
            return entry && typeof entry === "object"
                ? { id: entry.id, on: entry.on, detail: entry.detail }
                : entry;
        });
    });

    // Schema 1 split model usage out of T3 Code. Keep that historical
    // placement migration before applying newer additions.
    var usagePresent = ["left", "center", "right"].some(function(col) {
        return migrated[col].some(function(entry) { return entry && entry.id === "usage"; });
    });
    if ((sourceVersion === undefined || sourceVersion === 1) && !usagePresent) {
        for (var i = 0; i < 3; i++) {
            var col = ["left", "center", "right"][i];
            var t3Index = migrated[col].findIndex(function(entry) {
                return entry && entry.id === "t3";
            });
            if (t3Index === -1)
                continue;
            var t3 = migrated[col][t3Index];
            migrated[col].splice(t3Index + 1, 0, {
                id: "usage",
                on: typeof t3.on === "boolean" ? t3.on : true,
                detail: "auto"
            });
            break;
        }
    }

    // Schema 8 adds quick actions beside the clock. Older layouts retain
    // every user-chosen column, order, visibility, and detail policy; the one
    // new entry is inserted immediately before wherever their clock lives.
    var indicatorsPresent = ["left", "center", "right"].some(function(col) {
        return migrated[col].some(function(entry) {
            return entry && entry.id === "indicators";
        });
    });
    if ((typeof sourceVersion !== "number" || sourceVersion < 8)
            && !indicatorsPresent) {
        for (var j = 0; j < 3; j++) {
            var clockCol = ["left", "center", "right"][j];
            var clockIndex = migrated[clockCol].findIndex(function(entry) {
                return entry && entry.id === "clock";
            });
            if (clockIndex === -1)
                continue;
            migrated[clockCol].splice(clockIndex, 0, {
                id: "indicators", on: true, detail: "auto"
            });
            break;
        }
    }

    // Schema 11 gives notification history its own right-side widget. Older
    // layouts retain every existing entry exactly where the user put it; add
    // only the new widget, immediately before the first status item that still
    // lives on the right. If the user moved all status items elsewhere, the
    // right column's end is the least surprising stable fallback.
    var notificationsPresent = ["left", "center", "right"].some(function(col) {
        return migrated[col].some(function(entry) {
            return entry && entry.id === "notifications";
        });
    });
    if ((typeof sourceVersion !== "number" || sourceVersion < 11)
            && !notificationsPresent) {
        var statusIds = ["vol", "wifi", "bt", "batt"];
        var notificationIndex = migrated.right.findIndex(function(entry) {
            return entry && statusIds.indexOf(entry.id) !== -1;
        });
        if (notificationIndex === -1)
            notificationIndex = migrated.right.length;
        migrated.right.splice(notificationIndex, 0, {
            id: "notifications", on: true, detail: "auto"
        });
    }

    // Schema 14 adds the Hermes Agent client as its own chip and popover.
    // Put it beside T3 in an older customized layout instead of silently
    // appending it after whichever status widgets the user kept on the right.
    // Every existing entry retains its column, ordering and saved flags.
    var hermesPresent = ["left", "center", "right"].some(function(col) {
        return migrated[col].some(function(entry) {
            return entry && entry.id === "hermes";
        });
    });
    if ((typeof sourceVersion !== "number" || sourceVersion < 14)
            && !hermesPresent) {
        for (var k = 0; k < 3; k++) {
            var t3Col = ["left", "center", "right"][k];
            var hermesIndex = migrated[t3Col].findIndex(function(entry) {
                return entry && entry.id === "t3";
            });
            if (hermesIndex === -1)
                continue;
            migrated[t3Col].splice(hermesIndex + 1, 0, {
                id: "hermes", on: true, detail: "auto"
            });
            break;
        }
    }

    // Schema 20 adds local Notes immediately after Weather. Follow Weather to
    // whichever column and position the user chose, preserving every existing
    // module's order, visibility and detail policy byte-for-byte.
    var notesPresent = ["left", "center", "right"].some(function(col) {
        return migrated[col].some(function(entry) {
            return entry && entry.id === "notes";
        });
    });
    if ((typeof sourceVersion !== "number" || sourceVersion < 20)
            && !notesPresent) {
        for (var l = 0; l < 3; l++) {
            var weatherCol = ["left", "center", "right"][l];
            var weatherIndex = migrated[weatherCol].findIndex(function(entry) {
                return entry && entry.id === "weather";
            });
            if (weatherIndex === -1)
                continue;
            migrated[weatherCol].splice(weatherIndex + 1, 0, {
                id: "notes", on: true, detail: "auto"
            });
            break;
        }
    }
    return normalizeMods(migrated);
}

// Schema 4 is the glass menubar: a taller bar, full-radius corners, a wider
// floating gap and the design's accent. A settings file written by schema 3
// carries the old geometry for every one of those keys, so loading it as-is
// would silently keep the previous design's proportions.
//
// Only values the user never moved are adopted — a key still holding its
// schema-3 default takes the schema-4 one, anything else is theirs and stays.
var V3_DEFAULTS = {
    barHeight: 30, barRadius: 9, gap: 8, accent: "#9ecbeb", font: "oppo",
    osd: "top"
};

var V3_MOD_OPT_DEFAULTS = {
    ws: { style: "numbers" },
    media: { maxWidth: 220 },
    clock: { dateFormat: "ddd dd" }
};

function adoptRedesign(parsed) {
    if (!parsed || typeof parsed !== "object"
            || (typeof parsed.v === "number" && parsed.v >= 4))
        return parsed;
    var next = clone(parsed);
    Object.keys(V3_DEFAULTS).forEach(function(key) {
        if (next[key] === V3_DEFAULTS[key])
            delete next[key];
    });
    if (next.modOpts && typeof next.modOpts === "object") {
        Object.keys(V3_MOD_OPT_DEFAULTS).forEach(function(id) {
            var entry = next.modOpts[id];
            if (!entry || typeof entry !== "object")
                return;
            Object.keys(V3_MOD_OPT_DEFAULTS[id]).forEach(function(key) {
                if (entry[key] === V3_MOD_OPT_DEFAULTS[id][key])
                    delete entry[key];
            });
        });
    }
    return next;
}

// Schema 7 makes the softer variable face the shell default. As with the
// schema-4 redesign, a stored value equal to the previous default is treated
// as untouched; every other valid font remains an explicit user choice.
function adoptSofterTypography(parsed) {
    if (!parsed || typeof parsed !== "object"
            || (typeof parsed.v === "number" && parsed.v >= 7))
        return parsed;
    var next = clone(parsed);
    if (next.font === undefined || next.font === "urbanist")
        next.font = "google";
    return next;
}

// Schema 10 restores the compact August menubar shown in the repository's
// desktop screenshot, without reviving its fixed layout. As with the earlier
// redesign migration, only values still equal to schema 9's defaults move to
// the new visual baseline; customized geometry, glass, colors and workspace
// presentation remain the user's choices.
var V9_CLASSIC_DEFAULTS = {
    glassEnabled: true,
    barHeight: 46,
    barRadius: 23,
    gap: 10,
    accent: "#5e9bff"
};

var V9_CLASSIC_MOD_OPT_DEFAULTS = {
    ws: { style: "dots" },
    clock: { dateFormat: "ddd d MMM" }
};

function adoptClassicMenubar(parsed) {
    if (!parsed || typeof parsed !== "object"
            || (typeof parsed.v === "number" && parsed.v >= 10))
        return parsed;
    // Schema 3 and unversioned files first pass through adoptRedesign(),
    // which already removes their untouched defaults. Do not then mistake a
    // deliberate old-style value for schema 9's default on the second hop.
    if (typeof parsed.v !== "number" || parsed.v < 4)
        return parsed;
    var next = clone(parsed);
    var untouchedCustomColor = (next.barColorMode === undefined
            || next.barColorMode === "default")
        && next.barCustomHue === 247
        && next.barCustomSaturation === 29
        && next.barCustomLightness === 11;
    if (untouchedCustomColor) {
        delete next.barCustomHue;
        delete next.barCustomSaturation;
        delete next.barCustomLightness;
    }
    Object.keys(V9_CLASSIC_DEFAULTS).forEach(function(key) {
        if (next[key] === V9_CLASSIC_DEFAULTS[key])
            delete next[key];
    });
    if (next.modOpts && typeof next.modOpts === "object") {
        Object.keys(V9_CLASSIC_MOD_OPT_DEFAULTS).forEach(function(id) {
            var entry = next.modOpts[id];
            if (!entry || typeof entry !== "object")
                return;
            Object.keys(V9_CLASSIC_MOD_OPT_DEFAULTS[id]).forEach(function(key) {
                if (entry[key] === V9_CLASSIC_MOD_OPT_DEFAULTS[id][key])
                    delete entry[key];
            });
        });
    }
    return next;
}

// Schema 6 replaces two booleans with explicit visual modes. A v5 floating
// bar whose geometry was never changed becomes the new edge-hugging default;
// customized floating geometry remains floating, and the old edge-to-edge
// option remains attached. The fixed color values are intentionally never
// discarded: paletteMode only chooses which palette is active.
var V5_DEFAULTS = {
    barHeight: 46,
    barRadius: 23,
    gap: 10,
    accent: "#5e9bff",
    barColorMode: "default",
    barCustomHue: 247,
    barCustomSaturation: 29,
    barCustomLightness: 11
};

function migrateBarStyle(parsed, defaultsValue) {
    if (typeof parsed.v === "number" && parsed.v >= 6)
        return enumIn(parsed.barStyle, BAR_STYLES, defaultsValue);
    if (parsed.floating === false)
        return "attached";
    var pristine = intIn(parsed.barHeight, 28, 60, 1, V5_DEFAULTS.barHeight)
            === V5_DEFAULTS.barHeight
        && intIn(parsed.barRadius, 0, 30, 1, V5_DEFAULTS.barRadius)
            === V5_DEFAULTS.barRadius
        && intIn(parsed.gap, 4, 24, 1, V5_DEFAULTS.gap) === V5_DEFAULTS.gap;
    return pristine ? "hug" : "floating";
}

function migratePaletteMode(parsed, defaultsValue) {
    if (typeof parsed.v === "number" && parsed.v >= 6)
        return enumIn(parsed.paletteMode, PALETTE_MODES, defaultsValue);
    if (parsed.accentWall === true)
        return "wallpaper";
    var accent = hexIn(parsed.accent, V5_DEFAULTS.accent).toLowerCase();
    var barMode = enumIn(parsed.barColorMode, BAR_COLOR_IDS,
        V5_DEFAULTS.barColorMode);
    var customHue = intIn(parsed.barCustomHue, 0, 359, 1,
        V5_DEFAULTS.barCustomHue);
    var customSaturation = intIn(parsed.barCustomSaturation, 0, 100, 1,
        V5_DEFAULTS.barCustomSaturation);
    var customLightness = intIn(parsed.barCustomLightness, 0, 100, 1,
        V5_DEFAULTS.barCustomLightness);
    return accent === V5_DEFAULTS.accent && barMode === V5_DEFAULTS.barColorMode
        && customHue === V5_DEFAULTS.barCustomHue
        && customSaturation === V5_DEFAULTS.barCustomSaturation
        && customLightness === V5_DEFAULTS.barCustomLightness
        ? "wallpaper" : "fixed";
}

function merge(raw) {
    var d = defaults();
    if (!raw || typeof raw !== "object")
        return d;
    var parsed = adoptClassicMenubar(
        adoptSofterTypography(adoptRedesign(raw)));
    var idleMode = enumIn(parsed.idleInhibitMode,
        ["off", "30m", "1h", "unplugged", "always"],
        parsed.idleInhibited === true ? "always" : d.idleInhibitMode);
    var idleUntil = timestampIn(parsed.idleInhibitUntilMs,
        d.idleInhibitUntilMs);
    if (idleMode !== "30m" && idleMode !== "1h")
        idleUntil = 0;
    var dnd = boolIn(parsed.notifDnd, d.notifDnd);
    var dndUntil = dnd
        ? timestampIn(parsed.notifDndUntilMs, d.notifDndUntilMs) : 0;
    return {
        wall: nameIn(parsed.wall, d.wall),
        wallDir: pathIn(parsed.wallDir, d.wallDir),
        shuffle: enumIn(parsed.shuffle, ["Off", "15m", "1h", "1d"], d.shuffle),
        themeMode: enumIn(parsed.themeMode, ["dark", "light"], d.themeMode),
        glassEnabled: boolIn(parsed.glassEnabled, d.glassEnabled),
        highContrast: boolIn(parsed.highContrast, d.highContrast),
        reducedMotion: boolIn(parsed.reducedMotion, d.reducedMotion),
        shellFontSize: intIn(parsed.shellFontSize, 10, 24, 1, d.shellFontSize),
        shellScale: intIn(parsed.shellScale, 75, 200, 5, d.shellScale),
        surfaceBorderMode: enumIn(parsed.surfaceBorderMode, ["accent", "subtle", "custom"], d.surfaceBorderMode),
        surfaceBorderColor: hexIn(parsed.surfaceBorderColor, d.surfaceBorderColor),
        surfaceBorderWidth: intIn(parsed.surfaceBorderWidth, 0, 8, 1, d.surfaceBorderWidth),
        surfaceBorderOpacity: intIn(parsed.surfaceBorderOpacity, 0, 100, 5, d.surfaceBorderOpacity),
        surfaceCornerRadius: intIn(parsed.surfaceCornerRadius, 0, 30, 1, d.surfaceCornerRadius),
        pluginScale: intIn(parsed.pluginScale, 75, 200, 5, d.pluginScale),
        pluginBorderMode: enumIn(parsed.pluginBorderMode, ["inherit", "accent", "subtle", "custom"], d.pluginBorderMode),
        pluginBorderColor: hexIn(parsed.pluginBorderColor, d.pluginBorderColor),
        pluginBorderWidth: intIn(parsed.pluginBorderWidth, 0, 8, 1, d.pluginBorderWidth),
        pluginBorderOpacity: intIn(parsed.pluginBorderOpacity, 0, 100, 5, d.pluginBorderOpacity),
        pluginRadius: intIn(parsed.pluginRadius, -1, 30, 1, d.pluginRadius),
        pluginThemeOverrides: pluginThemeOverridesIn(parsed.pluginThemeOverrides),
        textScale: enumIn(parsed.textScale, ["default", "large", "larger"], d.textScale),
        interfaceDensity: enumIn(parsed.interfaceDensity,
            ["compact", "default", "comfortable"], d.interfaceDensity),
        barColorMode: enumIn(parsed.barColorMode, BAR_COLOR_IDS, d.barColorMode),
        barCustomHue: intIn(parsed.barCustomHue, 0, 359, 1, d.barCustomHue),
        barCustomSaturation: intIn(parsed.barCustomSaturation, 0, 100, 1,
            d.barCustomSaturation),
        barCustomLightness: intIn(parsed.barCustomLightness, 0, 100, 1,
            d.barCustomLightness),
        barHeight: intIn(parsed.barHeight, 28, 60, 1, d.barHeight),
        barRadius: intIn(parsed.barRadius, 0, 30, 1, d.barRadius),
        font: enumIn(parsed.font, FONT_IDS, d.font),
        accent: hexIn(parsed.accent, d.accent),
        paletteMode: migratePaletteMode(parsed, d.paletteMode),
        position: enumIn(parsed.position, ["top", "bottom"], d.position),
        barStyle: migrateBarStyle(parsed, d.barStyle),
        gap: intIn(parsed.gap, 4, 24, 1, d.gap),
        autoHide: boolIn(parsed.autoHide, d.autoHide),
        exclusive: boolIn(parsed.exclusive, d.exclusive),
        clock24: boolIn(parsed.clock24, d.clock24),
        unit: enumIn(parsed.unit, ["c", "f"], d.unit),
        warmth: intIn(parsed.warmth, 1900, 4500, 50, d.warmth),
        osd: enumIn(parsed.osd, ["top", "bottom"], d.osd),
        pollMax: enumIn(parsed.pollMax, [60, 300, 600], d.pollMax),
        scrollFactor: realIn(parsed.scrollFactor, 0.2, 2.0, 0.1, d.scrollFactor),
        nightLight: boolIn(parsed.nightLight, d.nightLight),
        idleInhibitMode: idleMode,
        idleInhibitUntilMs: idleUntil,
        notifDnd: dnd,
        notifDndUntilMs: dndUntil,
        notifQuiet: enumIn(parsed.notifQuiet, ["off", "nights", "custom"], d.notifQuiet),
        notifQuietStart: intIn(parsed.notifQuietStart, 0, 1425, 15, d.notifQuietStart),
        notifQuietEnd: intIn(parsed.notifQuietEnd, 0, 1425, 15, d.notifQuietEnd),
        notifDuration: intIn(parsed.notifDuration, 4, 20, 1, d.notifDuration),
        notifPosition: enumIn(parsed.notifPosition,
            ["top-left", "top-right", "bottom-left", "bottom-right"], d.notifPosition),
        notifDensity: enumIn(parsed.notifDensity,
            ["compact", "default", "roomy"], d.notifDensity),
        notifIcons: boolIn(parsed.notifIcons, d.notifIcons),
        notifProgress: boolIn(parsed.notifProgress, d.notifProgress),
        notifBodyLines: intIn(parsed.notifBodyLines, 0, 3, 1, d.notifBodyLines),
        drawerTabs: normalizeDrawerTabs(parsed.drawerTabs),
        drawerOverview: normalizeDrawerOverview(parsed.drawerOverview),
        drawerHover: enumIn(parsed.drawerHover, DRAWER_HOVER_MODES, d.drawerHover),
        drawerWidth: intIn(parsed.drawerWidth, 320, 480, 10, d.drawerWidth),
        mods: migrateMods(parsed.mods, parsed.v),
        modOpts: migrateModOpts(parsed.modOpts, parsed.v, parsed)
    };
}

// Quiet hours. "nights" is a fixed preset; "custom" uses the stored
// minutes-since-midnight bounds. A range crossing midnight wraps.
var QUIET_NIGHTS = { start: 1320, end: 420 };

function quietRange(quiet, start, end) {
    if (quiet === "nights")
        return { start: QUIET_NIGHTS.start, end: QUIET_NIGHTS.end };
    if (quiet === "custom")
        return { start: start, end: end };
    return null;
}

function quietActive(quiet, start, end, minutesNow) {
    var range = quietRange(quiet, start, end);
    if (!range || range.start === range.end)
        return false;
    if (range.start < range.end)
        return minutesNow >= range.start && minutesNow < range.end;
    return minutesNow >= range.start || minutesNow < range.end;
}

function formatMinutes(total) {
    var h = Math.floor(total / 60) % 24;
    var m = total % 60;
    return String(h).padStart(2, "0") + ":" + String(m).padStart(2, "0");
}

function hueToHex(degrees) {
    return hslToHex(degrees, 50, 75);
}

function hexHue(value, fallback) {
    if (typeof value !== "string" || !/^#[0-9a-fA-F]{6}$/.test(value))
        return fallback === undefined ? 0 : fallback;
    var r = parseInt(value.slice(1, 3), 16) / 255;
    var g = parseInt(value.slice(3, 5), 16) / 255;
    var b = parseInt(value.slice(5, 7), 16) / 255;
    var max = Math.max(r, g, b);
    var min = Math.min(r, g, b);
    if (max === min)
        return fallback === undefined ? 0 : fallback;
    var d = max - min;
    var h = max === r ? ((g - b) / d + (g < b ? 6 : 0))
        : max === g ? (b - r) / d + 2 : (r - g) / d + 4;
    return Math.round(h * 60) % 360;
}

function clone(value) {
    return JSON.parse(JSON.stringify(value));
}

function restoreSnapshot(current, snapshot) {
    var restored = clone(current);
    Object.keys(snapshot || {}).forEach(function(key) {
        restored[key] = clone(snapshot[key]);
    });
    return restored;
}

// Deterministic serialization: fixed key order so snapshot equality can be
// compared as strings (self-write echo detection) and diffs stay readable.
function serialize(settings) {
    var ordered = { v: VERSION };
    Object.keys(defaults()).forEach(function(key) {
        ordered[key] = settings[key];
    });
    return JSON.stringify(ordered, null, 2) + "\n";
}

// Distinguishing "no settings yet" from "settings we could not read" is what
// keeps a corrupt file recoverable: both merge to defaults, but only the empty
// case may be overwritten. Returns { status, value } where status is one of:
//   "empty"   — nothing on disk yet (or a whitespace-only file); first run.
//   "ok"      — a settings object; value is it.
//   "corrupt" — bytes exist but are not a settings object. Value is null and
//               the caller must preserve the file before saving over it.
function parse(text) {
    if (typeof text !== "string" || text.trim() === "")
        return { status: "empty", value: null };
    var parsed;
    try {
        parsed = JSON.parse(text);
    } catch (e) {
        return { status: "corrupt", value: null };
    }
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed))
        return { status: "corrupt", value: null };
    return { status: "ok", value: parsed };
}

var exported = {
    VERSION: VERSION,
    BAR_STYLES: BAR_STYLES,
    PALETTE_MODES: PALETTE_MODES,
    MODULE_IDS: MODULE_IDS,
    RETIRED_MODULE_IDS: RETIRED_MODULE_IDS,
    MODULE_GROUPS: MODULE_GROUPS,
    NOTIFICATION_GROUPS: NOTIFICATION_GROUPS,
    INDICATOR_ACTION_CHOICES: INDICATOR_ACTION_CHOICES,
    INDICATOR_ACTION_IDS: INDICATOR_ACTION_IDS,
    DICTATION_MODEL_CHOICES: DICTATION_MODEL_CHOICES,
    NOTE_CODEX_MODEL_CHOICES: NOTE_CODEX_MODEL_CHOICES,
    NOTE_CLAUDE_MODEL_CHOICES: NOTE_CLAUDE_MODEL_CHOICES,
    NOTE_CODEX_EFFORT_CHOICES: NOTE_CODEX_EFFORT_CHOICES,
    NOTE_CLAUDE_EFFORT_CHOICES: NOTE_CLAUDE_EFFORT_CHOICES,
    moduleGroup: moduleGroup,
    FILLED_GROUP_KINDS: FILLED_GROUP_KINDS,
    groupFilled: groupFilled,
    DETAIL_IDS: DETAIL_IDS,
    DETAIL_POLICIES: DETAIL_POLICIES,
    FONT_CHOICES: FONT_CHOICES,
    FONT_IDS: FONT_IDS,
    BAR_COLOR_CHOICES: BAR_COLOR_CHOICES,
    BAR_COLOR_IDS: BAR_COLOR_IDS,
    BAR_COLOR_PRESETS: BAR_COLOR_PRESETS,
    DRAWER_TAB_IDS: DRAWER_TAB_IDS,
    DRAWER_HOVER_MODES: DRAWER_HOVER_MODES,
    DRAWER_OVERVIEW_KEYS: DRAWER_OVERVIEW_KEYS,
    appearancePreset: appearancePreset,
    defaults: defaults,
    defaultMods: defaultMods,
    defaultModOpts: defaultModOpts,
    defaultDrawerTabs: defaultDrawerTabs,
    defaultDrawerOverview: defaultDrawerOverview,
    normalizeDrawerTabs: normalizeDrawerTabs,
    normalizeDrawerOverview: normalizeDrawerOverview,
    normalizeMods: normalizeMods,
    normalizeModOpts: normalizeModOpts,
    migrateModOpts: migrateModOpts,
    migrateMods: migrateMods,
    migrateBarStyle: migrateBarStyle,
    migratePaletteMode: migratePaletteMode,
    pathIn: pathIn,
    detailIn: detailIn,
    repoListIn: repoListIn,
    MAX_WATCHED_REPOS: MAX_WATCHED_REPOS,
    quietRange: quietRange,
    quietActive: quietActive,
    formatMinutes: formatMinutes,
    hueToHex: hueToHex,
    hexHue: hexHue,
    hslToHex: hslToHex,
    resolveBarColor: resolveBarColor,
    relativeLuminance: relativeLuminance,
    contrastRatio: contrastRatio,
    foregroundFor: foregroundFor,
    ensureContrast: ensureContrast,
    barPalette: barPalette,
    semanticPalette: semanticPalette,
    clone: clone,
    restoreSnapshot: restoreSnapshot,
    merge: merge,
    serialize: serialize,
    parse: parse
};

if (typeof module !== "undefined" && module.exports)
    module.exports = exported;
