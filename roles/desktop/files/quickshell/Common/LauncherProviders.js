// Pure command-palette routing and result helpers shared by QML and Node tests.
// Keep this file free of Qt APIs: LauncherProviders.qml owns processes and
// desktop objects, while this module keeps provider contracts deterministic.

var PROVIDERS = [
    { id: "files", prefix: "/", label: "FILES", glyph: "folder", enter: "open" },
    { id: "command", prefix: ">", label: "RUN", glyph: "terminal", enter: "run" },
    { id: "calculator", prefix: "=", label: "CALC", glyph: "calculate", enter: "copy" },
    { id: "web", prefix: "@", label: "WEB", glyph: "public", enter: "search" },
    { id: "windows", prefix: "$", label: "WINDOWS", glyph: "web_asset", enter: "focus" },
    { id: "clipboard", prefix: ";", label: "CLIPBOARD", glyph: "content_paste", enter: "copy" },
    { id: "emoji", prefix: ":", label: "EMOJI", glyph: "mood", enter: "paste" },
    { id: "actions", prefix: "!", label: "ACTIONS", glyph: "bolt", enter: "run" },
    { id: "apps", prefix: "", label: "APPS", glyph: "apps", enter: "launch" }
];

// These are the persistent, discoverable launcher tabs. The remaining
// providers stay available as explicit keyboard prefixes, keeping the tab
// strip compact without taking power-user routes away.
var TAB_IDS = ["apps", "emoji", "clipboard", "actions"];

var BUILTIN_ACTIONS = [
    {
        id: "settings",
        name: "Open CybexOS Settings",
        subtitle: "Appearance, bar, widgets and system",
        keywords: ["preferences", "configuration", "shell"],
        glyph: "settings"
    },
    {
        id: "wallpaper-shuffle",
        name: "Shuffle wallpaper",
        subtitle: "Choose another wallpaper from the configured folder",
        keywords: ["background", "random"],
        glyph: "wallpaper"
    },
    {
        id: "dnd-toggle",
        name: "Toggle Do Not Disturb",
        subtitle: "Enable or disable notification toasts",
        keywords: ["notifications", "quiet"],
        glyph: "notifications_off"
    },
    {
        id: "lock",
        name: "Lock screen",
        subtitle: "Start Hyprlock",
        keywords: ["session", "security"],
        glyph: "lock"
    },
    {
        id: "power",
        name: "Open Control Panel",
        subtitle: "Lock, suspend, log out, restart or shut down",
        keywords: ["session", "shutdown", "restart", "suspend"],
        glyph: "power_settings_new"
    }
];

var GLYPHS = PROVIDERS.map(function(provider) { return provider.glyph; })
    .concat(BUILTIN_ACTIONS.map(function(action) { return action.glyph; }))
    .concat(["image"])
    .filter(function(glyph, index, values) { return values.indexOf(glyph) === index; });

function prefixedProviderFor(query) {
    var value = String(query || "");
    for (var i = 0; i < PROVIDERS.length; i++) {
        if (PROVIDERS[i].prefix !== "" && value.indexOf(PROVIDERS[i].prefix) === 0)
            return PROVIDERS[i];
    }
    return null;
}

function providerFor(query) {
    var prefixed = prefixedProviderFor(query);
    if (prefixed)
        return prefixed;
    return PROVIDERS[PROVIDERS.length - 1];
}

function providerById(id) {
    for (var i = 0; i < PROVIDERS.length; i++) {
        if (PROVIDERS[i].id === id)
            return PROVIDERS[i];
    }
    return PROVIDERS[PROVIDERS.length - 1];
}

function termFor(query, provider) {
    var value = String(query || "");
    var selected = provider || providerFor(value);
    return (selected.prefix === "" ? value : value.slice(selected.prefix.length)).trim();
}

function words(value) {
    return String(value || "").toLowerCase().split(/[^a-z0-9]+/).filter(Boolean);
}

function textScore(value, query) {
    var target = String(value || "").toLowerCase();
    var needle = String(query || "").trim().toLowerCase();
    if (needle === "")
        return 1;
    if (target === needle)
        return 10000;
    if (target.indexOf(needle) === 0)
        return 8000;
    if (words(target).some(function(word) { return word.indexOf(needle) === 0; }))
        return 6000;
    if (target.indexOf(needle) !== -1)
        return 4000;
    return -1;
}

function appScore(app, query, usageBoost) {
    var q = String(query || "").toLowerCase();
    // Preserve the existing empty-directory contract: alphabetical first,
    // with history affecting relevance only once the user has typed.
    if (q === "")
        return 1;
    var name = String(app && app.name || "").toLowerCase();
    var generic = String(app && app.genericName || "").toLowerCase();
    var id = String(app && app.id || "").replace(/\.desktop$/i, "").toLowerCase();
    var keywords = app && app.keywords && typeof app.keywords.join === "function"
        ? app.keywords.join(" ").toLowerCase() : "";
    var values = [name, generic, id, keywords];
    var match = -1;
    if (name === q || generic === q || id === q)
        match = 10000;
    else if (name.indexOf(q) === 0 || generic.indexOf(q) === 0 || id.indexOf(q) === 0)
        match = 8000;
    else if (values.some(function(value) {
        return words(value).some(function(word) { return word.indexOf(q) === 0; });
    }))
        match = 6000;
    else if (values.some(function(value) { return value.indexOf(q) !== -1; }))
        match = 4000;
    return match < 0 ? match : match + (Number(usageBoost) || 0);
}

function windowScore(title, windowClass, query, active) {
    var q = String(query || "").toLowerCase();
    var titleValue = String(title || "").toLowerCase();
    var classValue = String(windowClass || "").toLowerCase();
    if (q === "")
        return active ? 100 : 1;
    if (titleValue === q || classValue === q)
        return 10000;
    if (titleValue.indexOf(q) === 0 || classValue.indexOf(q) === 0)
        return 8000;
    if (words(titleValue + " " + classValue).some(function(word) {
        return word.indexOf(q) === 0;
    }))
        return 6000;
    if (titleValue.indexOf(q) !== -1 || classValue.indexOf(q) !== -1)
        return 4000;
    return -1;
}

function oneLine(value) {
    return String(value || "").replace(/\s+/g, " ").trim();
}

function clipboardRows(lines, query, limit) {
    var max = Math.max(0, Number(limit) || 0);
    return (Array.isArray(lines) ? lines : []).map(function(raw, index) {
        var tab = String(raw).indexOf("\t");
        var identifier = tab === -1 ? "" : String(raw).slice(0, tab).trim();
        var display = oneLine(tab === -1 ? raw : String(raw).slice(tab + 1));
        var image = /binary data/i.test(display);
        var score = textScore(display, query);
        if (score < 0)
            return null;
        return {
            providerId: "clipboard",
            kind: "clipboard",
            title: image ? "Clipboard image" : display,
            subtitle: image ? display : "Clipboard" + (identifier ? " · #" + identifier : ""),
            glyph: image ? "image" : providerById("clipboard").glyph,
            raw: String(raw),
            image: image,
            score: score,
            sourceIndex: index
        };
    }).filter(Boolean).sort(function(a, b) {
        return b.score - a.score || a.sourceIndex - b.sourceIndex;
    }).slice(0, max);
}

function parseEmojiData(text) {
    var entries = [];
    String(text || "").split("\n").forEach(function(line) {
        var match = line.match(/^\s*[0-9A-F ]+\s*;\s*fully-qualified\s*#\s*(\S+)\s+E[0-9.]+\s+(.+?)\s*$/);
        if (!match)
            return;
        entries.push({ emoji: match[1], name: match[2] });
    });
    return entries;
}

function emojiRows(entries, query, limit) {
    var max = Math.max(0, Number(limit) || 0);
    return (Array.isArray(entries) ? entries : []).map(function(entry, index) {
        var score = textScore(entry && entry.name, query);
        if (score < 0)
            return null;
        return {
            providerId: "emoji",
            kind: "emoji",
            title: String(entry.name || ""),
            subtitle: "Emoji · press Enter to paste",
            iconText: String(entry.emoji || ""),
            glyph: providerById("emoji").glyph,
            value: String(entry.emoji || ""),
            score: score,
            sourceIndex: index
        };
    }).filter(Boolean).sort(function(a, b) {
        return b.score - a.score || a.sourceIndex - b.sourceIndex;
    }).slice(0, max);
}

function cleanString(value, maxLength) {
    return typeof value === "string" ? value.trim().slice(0, maxLength) : "";
}

function sanitizeActions(value) {
    if (!Array.isArray(value))
        return [];
    var seen = {};
    return value.map(function(action, index) {
        if (!action || typeof action !== "object")
            return null;
        var name = cleanString(action.name, 100);
        var command = Array.isArray(action.command)
            ? action.command.slice(0, 32).map(function(part) {
                return cleanString(part, 1000);
            }).filter(Boolean)
            : [];
        if (name === "" || command.length === 0)
            return null;
        var rawId = cleanString(action.id, 80).toLowerCase().replace(/[^a-z0-9_-]+/g, "-");
        var id = "user-" + (rawId || "action-" + index);
        if (seen[id])
            return null;
        seen[id] = true;
        var keywordValues = Array.isArray(action.keywords) ? action.keywords : [action.keywords];
        return {
            id: id,
            name: name,
            subtitle: cleanString(action.subtitle, 180) || "User command",
            keywords: keywordValues.map(function(keyword) {
                return cleanString(keyword, 80);
            }).filter(Boolean),
            glyph: "bolt",
            command: command,
            user: true
        };
    }).filter(Boolean);
}

function parseActions(text) {
    try {
        var value = JSON.parse(String(text || "[]"));
        if (!Array.isArray(value))
            return { actions: [], error: "launcher-actions.json must contain an array" };
        return { actions: sanitizeActions(value), error: "" };
    } catch (error) {
        return { actions: [], error: "launcher-actions.json is invalid JSON" };
    }
}

function actionRows(actions, query, limit) {
    var max = Math.max(0, Number(limit) || 0);
    return (Array.isArray(actions) ? actions : []).map(function(action, index) {
        var searchable = String(action.name || "") + " "
            + String(action.subtitle || "") + " "
            + (Array.isArray(action.keywords) ? action.keywords.join(" ") : "");
        var score = textScore(searchable, query);
        if (score < 0)
            return null;
        return {
            providerId: "actions",
            kind: "action",
            title: String(action.name || ""),
            subtitle: String(action.subtitle || ""),
            glyph: String(action.glyph || "bolt"),
            action: action,
            score: score,
            sourceIndex: index
        };
    }).filter(Boolean).sort(function(a, b) {
        return b.score - a.score || a.sourceIndex - b.sourceIndex;
    }).slice(0, max);
}

// Delay before restarting a clipboard watcher that has exited, doubling from
// one second per consecutive failure up to a minute, so a watcher that
// cannot start retries slowly instead of spinning.
function watcherRestartDelayMs(failures) {
    var count = Math.max(0, Math.floor(Number(failures) || 0));
    return Math.min(60000, 1000 * Math.pow(2, Math.min(count, 6)));
}

var exported = {
    PROVIDERS: PROVIDERS,
    TAB_IDS: TAB_IDS,
    BUILTIN_ACTIONS: BUILTIN_ACTIONS,
    GLYPHS: GLYPHS,
    providerFor: providerFor,
    prefixedProviderFor: prefixedProviderFor,
    providerById: providerById,
    termFor: termFor,
    words: words,
    textScore: textScore,
    appScore: appScore,
    windowScore: windowScore,
    clipboardRows: clipboardRows,
    parseEmojiData: parseEmojiData,
    emojiRows: emojiRows,
    sanitizeActions: sanitizeActions,
    parseActions: parseActions,
    actionRows: actionRows,
    watcherRestartDelayMs: watcherRestartDelayMs
};

if (typeof module !== "undefined" && module.exports)
    module.exports = exported;
