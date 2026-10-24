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

// The Actions provider is a curated command palette. Every entry belongs to
// one verb group; the groups keep the full list scannable and give the
// blended Apps results a short, honest label. Order here is display order.
var VERBS = [
    { id: "install", label: "Install" },
    { id: "remove", label: "Remove" },
    { id: "setup", label: "Set up" },
    { id: "toggle", label: "Toggle" },
    { id: "update", label: "Update" },
    { id: "capture", label: "Capture" },
    { id: "system", label: "System" }
];

// Commands resolve packaged helpers through the managed desktop's PATH.
// "{argument}" is replaced by
// the whole typed argument as one argv element, never spliced into a word.
//
// An entry is one of:
//   command:      argv run detached once the launcher has closed
//   settingsPage: a NerdOS Settings page id (settingsKey scrolls to a row)
//   neither:      a built-in handled by id in LauncherProviders.qml
// `argument` asks for one text value first; `choices` picks one item from a
// list the shell loads (installed web apps); `requires` hides an entry while
// that installation feature is off; `settle` waits for the launcher to leave
// the screen so a capture never includes it.
//
// Factory reset is deliberately absent: it stays behind Settings' own
// confirmation and is never one mistyped Enter away.
var BUILTIN_ACTIONS = [
    { id: "software", verb: "install", name: "Open Software…", subtitle: "Search and review native package changes", keywords: ["install", "remove", "packages", "applications"], glyph: "apps", command: ["nerdos-software"] },
    {
        id: "webapp-install",
        verb: "install",
        name: "Install web app…",
        subtitle: "Add a website as an app with its own launcher entry",
        keywords: ["webapp", "pwa", "site", "url", "add", "web"],
        glyph: "world",
        argument: {
            kind: "url",
            label: "WEB APP",
            placeholder: "Web address, for example app.slack.com",
            hint: "Type a web address, then press Enter",
            submit: "Install web app from"
        },
        command: ["nerdos-webapp", "install", "--notify",
            "--url", "{argument}"]
    },
    {
        id: "theme-install",
        verb: "install",
        name: "Install theme from Git…",
        subtitle: "Add a desktop theme from a Git repository",
        keywords: ["theme", "appearance", "colors", "omarchy", "repository", "git"],
        glyph: "palette",
        argument: {
            kind: "git",
            label: "THEME",
            placeholder: "Repository, for example https://github.com/owner/theme",
            hint: "Type an https or SSH Git address, then press Enter",
            submit: "Install theme from"
        },
        command: ["nerd", "theme", "install", "{argument}"]
    },
    {
        id: "webapp-remove",
        verb: "remove",
        name: "Remove web app…",
        subtitle: "Remove a web app and its launcher entry",
        keywords: ["webapp", "uninstall", "delete", "pwa", "web"],
        glyph: "trash",
        choices: "webapps",
        command: ["nerdos-webapp", "remove", "--notify", "{argument}"]
    },
    { id: "default-applications", verb: "setup", name: "Default applications", subtitle: "Choose your browser, terminal, editor and viewers", keywords: ["browser", "terminal", "editor", "defaults"], glyph: "apps", settingsPage: "applications" },
    { id: "storage-cleanup", verb: "setup", name: "Storage & cleanup", subtitle: "Review disk space and retained recovery points", keywords: ["disk", "space", "cleanup", "garbage", "retention"], glyph: "archive", settingsPage: "storage" },
    {
        id: "security-fingerprint",
        verb: "setup",
        name: "Set up fingerprint",
        subtitle: "Enroll a fingerprint for unlocking and sign-in",
        keywords: ["fingerprint", "biometric", "login", "security", "unlock"],
        glyph: "shield-lock",
        settingsPage: "security"
    },
    {
        id: "security-key",
        verb: "setup",
        name: "Set up security key",
        subtitle: "Register a FIDO2 security key",
        keywords: ["yubikey", "fido", "u2f", "passkey", "security", "key"],
        glyph: "key",
        settingsPage: "security"
    },
    {
        id: "backup-setup",
        verb: "setup",
        name: "Set up backups",
        subtitle: "Choose what to back up and where",
        keywords: ["backup", "restore", "copy"],
        glyph: "archive",
        settingsPage: "backup"
    },
    {
        id: "ai-agent-choose",
        verb: "setup",
        name: "Choose default AI agent",
        subtitle: "Select and launch OpenCode, Claude Code, or Codex",
        keywords: ["ai", "default", "provider", "model", "agent", "code"],
        glyph: "robot",
        requires: "developerTools",
        command: ["nerd", "agent", "--window", "--pick"]
    },
    {
        id: "game-mode",
        verb: "toggle",
        name: "Toggle game mode",
        subtitle: "Turn off effects and notifications while playing",
        keywords: ["gaming", "games", "steam", "performance", "fullscreen"],
        glyph: "device-gamepad-2",
        command: ["game-mode", "toggle"]
    },
    {
        id: "dnd-toggle",
        verb: "toggle",
        name: "Toggle Do Not Disturb",
        subtitle: "Enable or disable notification toasts",
        keywords: ["notifications", "quiet", "dnd"],
        glyph: "notifications_off"
    },
    {
        id: "updates-check",
        verb: "update",
        name: "Check for updates",
        subtitle: "Look for NerdOS and NixOS package updates",
        keywords: ["upgrade", "nix", "update"],
        glyph: "refresh",
        command: ["nerdos-runtime", "ipc", "updates", "check"]
    },
    {
        id: "firmware-update",
        verb: "update",
        name: "Review device firmware…",
        subtitle: "Check signed device firmware and confirm installation separately",
        keywords: ["firmware", "bios", "uefi", "device", "update"],
        glyph: "refresh",
        command: ["nerdos-apps", "terminal", "--hold", "--", "nerdos-firmware-update", "interactive"]
    },
    {
        id: "updates-open",
        verb: "update",
        name: "Open updates",
        subtitle: "Show pending updates and their progress",
        keywords: ["upgrade", "install", "update", "pending"],
        glyph: "circle-arrow-up",
        command: ["nerdos-runtime", "ipc", "updates", "open"]
    },
    {
        id: "screenshot-region",
        verb: "capture",
        name: "Screenshot a region or window",
        subtitle: "Drag a region or click a window",
        keywords: ["screenshot", "capture", "screen", "print"],
        glyph: "camera",
        settle: true,
        command: ["screenshot", "region"]
    },
    {
        id: "screenshot-fullscreen",
        verb: "capture",
        name: "Screenshot the whole screen",
        subtitle: "Capture the focused monitor",
        keywords: ["screenshot", "capture", "screen", "print", "monitor"],
        glyph: "device-desktop",
        settle: true,
        command: ["screenshot", "fullscreen"]
    },
    {
        id: "screenshot-scroll",
        verb: "capture",
        name: "Take a scrolling screenshot",
        subtitle: "Capture a long page while it scrolls",
        keywords: ["screenshot", "capture", "scroll", "long", "page"],
        glyph: "arrow-down",
        settle: true,
        command: ["screenshot", "scroll"]
    },
    {
        id: "screen-record",
        verb: "capture",
        name: "Start or stop screen recording",
        subtitle: "Record a region of the screen",
        keywords: ["record", "recording", "video", "screencast", "capture"],
        glyph: "video",
        settle: true,
        command: ["screen-record"]
    },
    {
        id: "screen-record-webcam",
        verb: "capture",
        name: "Record with webcam",
        subtitle: "Record the screen with a webcam overlay",
        keywords: ["record", "recording", "video", "camera", "webcam", "capture"],
        glyph: "video",
        settle: true,
        command: ["screen-record", "--webcam"]
    },
    {
        id: "color-picker",
        verb: "capture",
        name: "Pick a colour",
        subtitle: "Copy the hex value of any pixel",
        keywords: ["color", "colour", "picker", "eyedropper", "hex"],
        glyph: "droplet-half-2",
        settle: true,
        command: ["color-picker"]
    },
    {
        id: "screen-ocr",
        verb: "capture",
        name: "Copy text or QR code from a region",
        subtitle: "Recognize text or decode a QR code on screen",
        keywords: ["ocr", "text", "qr", "scan", "capture"],
        glyph: "qrcode",
        settle: true,
        command: ["screen-ocr"]
    },
    {
        id: "settings",
        verb: "system",
        name: "Open NerdOS Settings",
        subtitle: "Appearance, bar, widgets and system",
        keywords: ["preferences", "configuration", "shell"],
        glyph: "settings"
    },
    {
        id: "security-open",
        verb: "system",
        name: "Open Security settings",
        subtitle: "Fingerprint, security keys and sign-in",
        keywords: ["security", "fingerprint", "yubikey", "passkey", "login"],
        glyph: "shield-lock",
        settingsPage: "security"
    },
    {
        id: "backup-now",
        verb: "system",
        name: "Back up now",
        subtitle: "Start a backup with the saved settings",
        keywords: ["backup", "copy", "save"],
        glyph: "archive",
        command: ["nerd", "backup", "now"]
    },
    {
        id: "overview",
        verb: "system",
        name: "Show overview",
        subtitle: "See every window and workspace",
        keywords: ["windows", "workspaces", "expose", "mission"],
        glyph: "layout-grid",
        command: ["nerdos-runtime", "ipc", "overview", "open"]
    },
    {
        id: "ai-agent-launch",
        verb: "system",
        name: "Launch default AI agent",
        subtitle: "Open the selected coding agent in ~/Code",
        keywords: ["ai", "code", "assistant", "terminal", "agent"],
        glyph: "robot",
        requires: "developerTools",
        command: ["nerd", "agent", "--window"]
    },
    {
        id: "wallpaper-shuffle",
        verb: "system",
        name: "Shuffle wallpaper",
        subtitle: "Choose another wallpaper from the configured folder",
        keywords: ["background", "random"],
        glyph: "wallpaper"
    },
    {
        id: "lock",
        verb: "system",
        name: "Lock screen",
        subtitle: "Start Hyprlock",
        keywords: ["session", "security"],
        glyph: "lock"
    },
    {
        id: "power",
        verb: "system",
        name: "Open Control Panel",
        subtitle: "Lock, suspend, log out, restart or shut down",
        keywords: ["session", "shutdown", "restart", "suspend"],
        glyph: "power_settings_new"
    },
    {
        id: "report",
        verb: "system",
        name: "Report a problem",
        subtitle: "Collect diagnostics to share with NerdOS",
        keywords: ["bug", "issue", "feedback", "diagnostics", "support"],
        glyph: "message-circle-exclamation",
        command: ["nerd", "report"]
    },
    {
        id: "recovery",
        verb: "system",
        name: "Open recovery points",
        subtitle: "Restore the system from a recovery point",
        keywords: ["restore", "snapshot", "rollback", "recovery"],
        glyph: "history",
        settingsPage: "about",
        settingsKey: "recoveryPoints"
    }
];

// Features an entry can require, keyed by the flags Settings.qml derives
// from the installer's choices (quickshell.service sets them).
var FEATURE_FLAGS = ["developerTools", "connectedWidgets"];

var GLYPHS = PROVIDERS.map(function(provider) { return provider.glyph; })
    .concat(BUILTIN_ACTIONS.map(function(action) { return action.glyph; }))
    .concat(["image", "photo", "pin"])
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

// The cliphist line is "<id>\t<preview>"; the preview of an image entry reads
// "[[ binary data 1.2 MiB png 1920x1080 ]]".
function clipboardDisplay(raw) {
    var value = String(raw || "");
    var tab = value.indexOf("\t");
    return oneLine(tab === -1 ? value : value.slice(tab + 1));
}

function isClipboardImage(display) {
    return /binary data/i.test(String(display || ""));
}

// A file URL Qt's Image accepts for an absolute path. The characters a URL
// would read as a query or fragment are escaped as well.
function fileUrl(path) {
    var value = String(path || "");
    if (value.charAt(0) !== "/")
        return "";
    return "file://" + encodeURI(value).replace(/\?/g, "%3F").replace(/#/g, "%23");
}

// Pins are kept by clipboard-tool.py in a user-owned index; anything this
// cannot vouch for is dropped instead of being drawn from a crafted file.
var PIN_LIMIT = 50;

function parsePins(text) {
    var value;
    try {
        value = JSON.parse(String(text || ""));
    } catch (error) {
        return [];
    }
    var list = value && Array.isArray(value.pins) ? value.pins : [];
    var seen = {};
    return list.slice(0, PIN_LIMIT).map(function(pin) {
        if (!pin || typeof pin !== "object")
            return null;
        var id = cleanString(pin.id, 32);
        if (!/^[0-9a-f]{16}$/.test(id) || seen[id])
            return null;
        if (pin.kind !== "text" && pin.kind !== "image")
            return null;
        var file = cleanString(pin.file, 64);
        var thumb = cleanString(pin.thumb, 64);
        var safeName = /^[0-9a-f]{16}(?:-thumb)?\.(?:txt|png|jpg|gif|webp|bmp)$/;
        if (!safeName.test(file) || (thumb !== "" && !safeName.test(thumb)))
            return null;
        seen[id] = true;
        return {
            id: id,
            kind: pin.kind,
            file: file,
            thumb: thumb,
            preview: oneLine(cleanString(pin.preview, 400)).slice(0, 200),
            source: typeof pin.source === "string" ? pin.source.slice(0, 400) : ""
        };
    }).filter(Boolean);
}

// The image entries worth a preview: the newest first, bounded, because each
// costs a decode and a thumbnail on the helper's side.
function clipboardPreviewTargets(lines, limit) {
    var max = Math.max(0, Number(limit) || 0);
    return (Array.isArray(lines) ? lines : []).filter(function(raw) {
        return isClipboardImage(clipboardDisplay(raw));
    }).slice(0, max).map(String);
}

// Pinned entries come first and survive cliphist pruning; history follows,
// minus the entries a pin already shows. `options.previews` maps a cliphist
// line to its decoded thumbnail; `options.pinDir` is the pins' directory.
function clipboardRows(lines, query, limit, options) {
    var max = Math.max(0, Number(limit) || 0);
    var opts = options || {};
    var pins = Array.isArray(opts.pins) ? opts.pins : [];
    var previews = opts.previews && typeof opts.previews === "object" ? opts.previews : {};
    var pinDir = String(opts.pinDir || "");
    var pinnedText = {};
    var pinnedImage = {};
    var pinned = pins.map(function(pin, index) {
        var image = pin.kind === "image";
        if (image)
            pinnedImage[pin.source] = true;
        else
            pinnedText[clipboardDisplay(pin.source)] = true;
        var title = image ? "Pinned image" : pin.preview;
        var score = textScore(image ? title : pin.preview, query);
        if (score < 0)
            return null;
        var picture = image && pinDir !== ""
            ? fileUrl(pinDir + "/" + (pin.thumb || pin.file)) : "";
        return {
            providerId: "clipboard",
            kind: "clipboard",
            title: title,
            subtitle: "Pinned",
            glyph: image ? "photo" : providerById("clipboard").glyph,
            raw: "",
            pinId: pin.id,
            pinned: true,
            image: image,
            thumbnail: picture,
            score: score,
            sourceIndex: index
        };
    }).filter(Boolean).sort(function(a, b) {
        return b.score - a.score || a.sourceIndex - b.sourceIndex;
    });
    var history = (Array.isArray(lines) ? lines : []).map(function(raw, index) {
        var value = String(raw);
        var tab = value.indexOf("\t");
        var identifier = tab === -1 ? "" : value.slice(0, tab).trim();
        var display = clipboardDisplay(value);
        var image = isClipboardImage(display);
        if (image ? pinnedImage[value] : pinnedText[display])
            return null;
        var score = textScore(display, query);
        if (score < 0)
            return null;
        return {
            providerId: "clipboard",
            kind: "clipboard",
            title: image ? "Clipboard image" : display,
            subtitle: image ? display : "Clipboard" + (identifier ? " · #" + identifier : ""),
            glyph: image ? "image" : providerById("clipboard").glyph,
            raw: value,
            pinned: false,
            image: image,
            thumbnail: image && typeof previews[value] === "string" ? previews[value] : "",
            score: score,
            sourceIndex: index
        };
    }).filter(Boolean).sort(function(a, b) {
        return b.score - a.score || a.sourceIndex - b.sourceIndex;
    }).slice(0, max);
    return pinned.concat(history);
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

function verbLabel(verb) {
    for (var i = 0; i < VERBS.length; i++) {
        if (VERBS[i].id === verb)
            return VERBS[i].label;
    }
    return "";
}

function verbRank(verb) {
    for (var i = 0; i < VERBS.length; i++) {
        if (VERBS[i].id === verb)
            return i;
    }
    return VERBS.length;
}

// Every word of a multi-word query starts a word of the text, in any order:
// "web install" finds "Install web app…".
function tokenScore(value, query) {
    var score = textScore(value, query);
    if (score >= 6000)
        return score;
    var tokens = words(query);
    if (tokens.length < 2)
        return score;
    var targets = words(value);
    var all = tokens.every(function(token) {
        return targets.some(function(word) { return word.indexOf(token) === 0; });
    });
    return all ? 6000 : score;
}

// Name matches outrank keyword, verb and subtitle matches, so "lock" puts
// "Lock screen" above an entry that merely mentions locking.
function actionScore(action, query) {
    if (String(query || "").trim() === "")
        return 1;
    var keywords = Array.isArray(action.keywords) ? action.keywords.join(" ") : "";
    var scores = [
        tokenScore(action.name, query),
        tokenScore(keywords + " " + verbLabel(action.verb), query) - 1000,
        tokenScore(action.subtitle, query) - 2000
    ];
    var best = Math.max.apply(null, scores);
    return best < 0 ? -1 : best;
}

// Entries whose installation feature is off stay out of every list.
function availableActions(actions, flags) {
    var features = flags || {};
    return (Array.isArray(actions) ? actions : []).filter(function(action) {
        return !action.requires || features[action.requires] === true;
    });
}

function actionRow(action, score, index, blended) {
    var tag = blended ? "Action" : (action.user ? "Custom" : verbLabel(action.verb));
    return {
        providerId: "actions",
        kind: "action",
        title: String(action.name || ""),
        subtitle: String(action.subtitle || ""),
        glyph: String(action.glyph || "bolt"),
        tag: tag,
        blended: !!blended,
        action: action,
        score: score,
        sourceIndex: index
    };
}

// The Actions list: an empty query shows every entry grouped by verb in
// catalogue order; a query ranks by match quality, then by group.
function actionRows(actions, query, limit) {
    var max = Math.max(0, Number(limit) || 0);
    return (Array.isArray(actions) ? actions : []).map(function(action, index) {
        var score = actionScore(action, query);
        return score < 0 ? null : actionRow(action, score, index, false);
    }).filter(Boolean).sort(function(a, b) {
        return b.score - a.score
            || verbRank(a.action.verb) - verbRank(b.action.verb)
            || a.sourceIndex - b.sourceIndex;
    }).slice(0, max);
}

// Super+Space is the one palette: a typed Apps query also offers the few
// actions that clearly match, after every app. A match must start a word of
// the name or keywords; substrings and subtitles alone are too loose to put
// beside the apps. An empty query stays the plain application directory.
var BLEND_LIMIT = 3;
var BLEND_MIN_SCORE = 5000;

function blendedActionRows(actions, query, limit) {
    var term = String(query || "").trim();
    if (term.length < 2)
        return [];
    var max = Math.min(BLEND_LIMIT, Math.max(0, Number(limit === undefined ? BLEND_LIMIT : limit) || 0));
    return (Array.isArray(actions) ? actions : []).map(function(action, index) {
        var score = actionScore(action, term);
        return score < BLEND_MIN_SCORE ? null : actionRow(action, score, index, true);
    }).filter(Boolean).sort(function(a, b) {
        return b.score - a.score || a.sourceIndex - b.sourceIndex;
    }).slice(0, max);
}

function blendRows(appRows, actions, query) {
    var apps = Array.isArray(appRows) ? appRows : [];
    return apps.concat(blendedActionRows(actions, query, BLEND_LIMIT));
}

// ---- Argument mode -----------------------------------------------------
// A web address for a web app: http or https, a host, no credentials and no
// whitespace or control characters. A bare host gets https://. The helper
// validates again; this keeps Enter from offering what it would refuse.
function webUrlArgument(value) {
    var text = String(value || "").trim();
    if (text === "")
        return { ok: false, value: "", error: "" };
    if (!/^[a-z][a-z0-9+.-]*:\/\//i.test(text))
        text = "https://" + text;
    var invalid = { ok: false, value: "", error: "Enter an http or https address" };
    if (text.length > 2048 || /[\s\u0000-\u001f\u007f]/.test(text))
        return invalid;
    var match = text.match(/^(https?):\/\/([^\/?#]*)([\/?#].*)?$/i);
    if (!match)
        return invalid;
    var authority = match[2];
    if (authority.indexOf("@") !== -1)
        return { ok: false, value: "", error: "Addresses with a user name or password are not allowed" };
    var host = authority;
    var port = "";
    var ipv6 = authority.match(/^\[([0-9a-f:.]+)\](?::(\d+))?$/i);
    if (ipv6) {
        host = ipv6[1];
        port = ipv6[2] || "";
    } else {
        var colon = authority.lastIndexOf(":");
        if (colon !== -1) {
            host = authority.slice(0, colon);
            port = authority.slice(colon + 1);
            if (!/^\d+$/.test(port))
                return invalid;
        }
        if (!/^[^\s\/?#@:\[\]\\]+$/.test(host) || /^\.|\.\.|^-/.test(host))
            return invalid;
    }
    if (port !== "" && (Number(port) < 1 || Number(port) > 65535))
        return invalid;
    return {
        ok: true,
        value: match[1].toLowerCase() + "://" + authority + (match[3] || "/"),
        error: ""
    };
}

// A theme repository: https without credentials, or SSH (ssh://, or the
// scp-like git@host:owner/repo). Nothing that could read as an option, a
// local path or a transport helper (ext::, file://).
function gitUrlArgument(value) {
    var text = String(value || "").trim();
    if (text === "")
        return { ok: false, value: "", error: "" };
    var invalid = { ok: false, value: "", error: "Enter an https or SSH Git address" };
    if (text.length > 2048 || /[\s\u0000-\u001f\u007f]/.test(text) || text.charAt(0) === "-")
        return invalid;
    if (/^https:\/\//i.test(text)) {
        var web = webUrlArgument(text);
        if (!web.ok)
            return /password/.test(web.error) ? web : invalid;
        // A repository needs a path: https://host/owner/theme.
        return /^https:\/\/[^\/?#]+\/[^\/?#]+/i.test(web.value)
            ? { ok: true, value: text, error: "" } : invalid;
    }
    if (/^ssh:\/\/([a-z0-9._-]+@)?[a-z0-9.-]+(:\d+)?\/[^\s]+$/i.test(text))
        return { ok: true, value: text, error: "" };
    if (/^[a-z0-9._-]+@[a-z0-9.-]+:[^\s\/-][^\s]*$/i.test(text))
        return { ok: true, value: text, error: "" };
    return invalid;
}

function validateArgument(kind, value) {
    if (kind === "url")
        return webUrlArgument(value);
    if (kind === "git")
        return gitUrlArgument(value);
    var text = String(value || "").trim();
    return text === "" ? { ok: false, value: "", error: "" }
        : { ok: true, value: text, error: "" };
}

function displayAddress(value) {
    return String(value || "").replace(/^[a-z][a-z0-9+.-]*:\/\//i, "").replace(/\/$/, "");
}

// The single row argument mode offers once the typed value is valid.
function argumentRows(action, value) {
    var spec = action && action.argument;
    if (!spec)
        return [];
    var checked = validateArgument(spec.kind, value);
    if (!checked.ok)
        return [];
    return [{
        providerId: "actions",
        kind: "argument",
        title: String(spec.submit || action.name) + " " + displayAddress(checked.value),
        glyph: String(action.glyph || "bolt"),
        highlight: false,
        action: action,
        value: checked.value
    }];
}

function argumentEmptyText(action, value) {
    var spec = action && action.argument;
    if (!spec)
        return "";
    var checked = validateArgument(spec.kind, value);
    return checked.error !== "" ? checked.error : String(spec.hint || "");
}

// `nerdos-webapp list --json`, read defensively: it is the shell's view of
// files the user (or anything running as the user) can edit.
function parseWebApps(text) {
    var value;
    try {
        value = JSON.parse(String(text || ""));
    } catch (error) {
        return [];
    }
    if (!Array.isArray(value))
        return [];
    var seen = {};
    return value.map(function(app) {
        if (!app || typeof app !== "object")
            return null;
        var id = cleanString(app.id, 40);
        if (!/^[a-z0-9][a-z0-9-]*$/.test(id) || seen[id])
            return null;
        seen[id] = true;
        var icon = cleanString(app.icon, 1000);
        return {
            id: id,
            name: oneLine(cleanString(app.name, 100)) || id,
            url: cleanString(app.url, 2048),
            icon: icon.charAt(0) === "/" ? icon : ""
        };
    }).filter(Boolean);
}

// Removing takes a second press, as restoring a recovery point does in
// Settings: the chosen row turns into its own confirmation.
function webAppChoiceRows(apps, query, limit, confirmId) {
    var max = Math.max(0, Number(limit) || 0);
    return (Array.isArray(apps) ? apps : []).map(function(app, index) {
        var score = Math.max(textScore(app.name, query), textScore(app.url, query) - 2000);
        if (String(query || "").trim() !== "" && score < 0)
            return null;
        var confirming = confirmId !== undefined && confirmId !== "" && confirmId === app.id;
        return {
            providerId: "actions",
            kind: "choice",
            title: confirming ? "Press Enter again to remove " + app.name : "Remove " + app.name,
            highlight: !confirming,
            confirm: confirming,
            glyph: "trash",
            icon: app.icon,
            value: app.id,
            score: score,
            sourceIndex: index
        };
    }).filter(Boolean).sort(function(a, b) {
        return b.score - a.score || a.title.localeCompare(b.title);
    }).slice(0, max);
}

// argv for an action: "~/" at the start of the program becomes the home
// directory, and an element that is exactly "{argument}" becomes the
// argument, whole. The argument is never expanded or split itself.
function expandCommand(command, home, argument) {
    if (!Array.isArray(command) || command.length === 0)
        return [];
    var base = String(home || "");
    var hasArgument = command.indexOf("{argument}") !== -1;
    if (hasArgument && (argument === undefined || String(argument) === ""))
        return [];
    return command.map(function(part, index) {
        var value = String(part);
        if (value === "{argument}")
            return String(argument);
        if (index === 0 && value.indexOf("~/") === 0)
            return base.replace(/\/$/, "") + value.slice(1);
        return value;
    });
}

// What `nerdos-runtime ipc launcher open <id>` shows: a tab opens as that
// tab; a prefix provider opens Apps with its prefix typed, the way a user
// would reach it. Anything else opens the plain launcher.
function openTarget(providerId) {
    var id = String(providerId || "");
    if (TAB_IDS.indexOf(id) !== -1)
        return { tab: id, query: "" };
    for (var i = 0; i < PROVIDERS.length; i++) {
        if (PROVIDERS[i].id === id && PROVIDERS[i].prefix !== "")
            return { tab: "apps", query: PROVIDERS[i].prefix };
    }
    return { tab: "apps", query: "" };
}

// An icon a desktop entry names by absolute path (web apps do) loads as a
// file; a theme icon name returns "" so the caller asks the icon theme.
function directIconUrl(icon) {
    var value = String(icon || "");
    if (/^(?:file|image):/i.test(value))
        return value;
    return fileUrl(value);
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
    VERBS: VERBS,
    BUILTIN_ACTIONS: BUILTIN_ACTIONS,
    FEATURE_FLAGS: FEATURE_FLAGS,
    GLYPHS: GLYPHS,
    PIN_LIMIT: PIN_LIMIT,
    BLEND_LIMIT: BLEND_LIMIT,
    providerFor: providerFor,
    prefixedProviderFor: prefixedProviderFor,
    providerById: providerById,
    termFor: termFor,
    words: words,
    textScore: textScore,
    appScore: appScore,
    windowScore: windowScore,
    clipboardDisplay: clipboardDisplay,
    isClipboardImage: isClipboardImage,
    fileUrl: fileUrl,
    parsePins: parsePins,
    clipboardPreviewTargets: clipboardPreviewTargets,
    clipboardRows: clipboardRows,
    parseEmojiData: parseEmojiData,
    emojiRows: emojiRows,
    sanitizeActions: sanitizeActions,
    parseActions: parseActions,
    verbLabel: verbLabel,
    actionScore: actionScore,
    availableActions: availableActions,
    actionRows: actionRows,
    blendedActionRows: blendedActionRows,
    blendRows: blendRows,
    webUrlArgument: webUrlArgument,
    gitUrlArgument: gitUrlArgument,
    validateArgument: validateArgument,
    argumentRows: argumentRows,
    argumentEmptyText: argumentEmptyText,
    parseWebApps: parseWebApps,
    webAppChoiceRows: webAppChoiceRows,
    expandCommand: expandCommand,
    openTarget: openTarget,
    directIconUrl: directIconUrl,
    watcherRestartDelayMs: watcherRestartDelayMs
};

if (typeof module !== "undefined" && module.exports)
    module.exports = exported;
