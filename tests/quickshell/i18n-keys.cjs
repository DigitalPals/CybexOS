// The English source strings the shell shows through I18n.tr(): every
// literal I18n.tr("…") / I18n.format("…") in the shell's QML, plus the
// labels JS data modules supply to views that translate at display time.
// i18n.test.cjs requires a catalog entry for each of them.
const fs = require("node:fs");
const path = require("node:path");
const { shellDir, load, isVendored } = require("./shell.cjs");

function qmlFiles(dir = shellDir) {
    const out = [];
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
        const full = path.join(dir, entry.name);
        if (entry.isDirectory()) {
            if (!isVendored(full) && !["tests", "scripts", "assets", "compat", "themes"].includes(entry.name))
                out.push(...qmlFiles(full));
        } else if (entry.name.endsWith(".qml")) {
            out.push(full);
        }
    }
    return out;
}

// A QML double-quoted literal as written, decoded the way the engine reads it.
function decode(literal) {
    return JSON.parse('"' + literal + '"');
}

function literalKeys() {
    const keys = new Map();
    const pattern = /I18n\.(?:tr|format)\("((?:[^"\\]|\\.)*)"/g;
    for (const file of qmlFiles()) {
        const source = fs.readFileSync(file, "utf8");
        for (const match of source.matchAll(pattern)) {
            const key = decode(match[1]);
            if (!keys.has(key))
                keys.set(key, path.relative(shellDir, file));
        }
    }
    return keys;
}

// Labels composed in JS data and translated where they are displayed.
function dataKeys() {
    const keys = new Set();
    const add = value => {
        if (typeof value === "string" && /[A-Za-z]{2}/.test(value))
            keys.add(value);
    };
    const wallhaven = load("WallhavenHelpers.js");
    for (const value of Object.values(wallhaven.DOWNLOAD_ERRORS))
        add(value);
    add(wallhaven.downloadError("unknown"));
    for (const status of [0, 429, 503])
        add(wallhaven.statusError(status));
    const search = load("SettingsSearchData.js");
    for (const row of search.ROWS) {
        add(row.label);
        add(row.pageLabel);
    }
    const launcher = load("LauncherProviders.js");
    for (const provider of launcher.PROVIDERS)
        add(provider.label);
    for (const verb of launcher.VERBS || [])
        add(verb.label);
    for (const action of launcher.BUILTIN_ACTIONS) {
        add(action.name);
        add(action.subtitle);
    }
    add("Action");
    add("Custom");
    // I18n.localeName() translates locale names and joins them itself.
    const locales = load("LocaleNames.js");
    for (const value of Object.values(locales.LANGUAGES).concat(Object.values(locales.TERRITORIES)))
        add(value);
    keys.add("%1 (%2)");
    const settings = fs.readFileSync(path.join(shellDir, "Common/Settings.qml"), "utf8");
    for (const match of settings.matchAll(/\{ id: "[a-z]+", group: "([^"]+)"/g))
        add(match[1]);
    const drawer = fs.readFileSync(path.join(shellDir, "Popovers/Drawer/DrawerTabs.qml"), "utf8");
    for (const match of drawer.matchAll(/label: "([^"]+)"/g))
        add(match[1]);
    add("move");
    // Shortcut sheet rows come from bindings.lua descriptions, "Group: Label".
    const bindings = fs.readFileSync(path.join(shellDir, "../hypr/bindings.lua"), "utf8");
    for (const match of bindings.matchAll(/description = "([^":]+): ([^"]+)"/g)) {
        add(match[1]);
        // Numbered labels ("Switch to workspace " .. i) are composed, not shown as is.
        if (!/ \.\. /.test(match[2]) && !/[\d ]$/.test(match[2]))
            add(match[2]);
    }
    // These errors are translated dynamically by Keybindings.reject() and
    // the service's error property, rather than literal QML tr() calls.
    for (const [file, pattern] of [
        ["Common/KeybindingsModel.js", /new Error\("([^"\n]+)"\)/g],
        ["Common/Keybindings.qml", /reject\("([^"\n]+)"\)/g],
        ["scripts/system_settings_keybindings.py", /raise ValueError\('([^'\n]+)'\)/g]
    ]) {
        const source = fs.readFileSync(path.join(shellDir, file), "utf8");
        for (const match of source.matchAll(pattern)) {
            // Lowercase reasons are internal assertions, replaced at the
            // backend boundary by a complete user-facing error.
            if (/^[A-Z]/.test(match[1])) add(match[1]);
        }
    }
    return keys;
}


function allKeys() {
    const keys = new Set(literalKeys().keys());
    for (const key of dataKeys())
        keys.add(key);
    return keys;
}

module.exports = { qmlFiles, literalKeys, dataKeys, allKeys };

if (require.main === module)
    process.stdout.write(JSON.stringify([...allKeys()].sort(), null, 1) + "\n");
