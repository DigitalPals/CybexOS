// Shell translations (docs/shell-translations.md): the language rule, the
// catalog's completeness, and the guard that keeps new text translatable.
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { shellDir, load } = require("./shell.cjs");
const { qmlFiles, allKeys, catalogBlocks } = require("./i18n-keys.cjs");

const I18n = load("I18nHelpers.js");
const catalog = require(path.join(shellDir, "Common/i18n/nl.js")).MESSAGES;

test("the session's locale picks the language, C and POSIX name none", () => {
    assert.equal(I18n.languageFor(["", "", "", "nl_NL.UTF-8"]), "nl");
    assert.equal(I18n.languageFor(["", "nl_BE.UTF-8@euro", "", "en_US.UTF-8"]), "nl");
    assert.equal(I18n.languageFor(["", "C.UTF-8", "", "nl_NL.UTF-8"]), "nl");
    assert.equal(I18n.languageFor(["", "POSIX", "C", "nl"]), "nl");
    assert.equal(I18n.languageFor(["de_DE.UTF-8", "", "", "nl_NL.UTF-8"]), "en",
        "an unsupported language falls back to English, as gettext does");
    assert.equal(I18n.languageFor([]), "en");
    // CYBEXOS_LANG is read first by I18n.qml, ahead of LC_ALL, LC_MESSAGES, LANG.
    const qml = fs.readFileSync(path.join(shellDir, "Common/I18n.qml"), "utf8");
    assert.match(qml, /Quickshell\.env\("CYBEXOS_LANG"\), Quickshell\.env\("LC_ALL"\),\s*Quickshell\.env\("LC_MESSAGES"\), Quickshell\.env\("LANG"\)/);
    assert.match(fs.readFileSync(path.join(shellDir, "Common/qmldir"), "utf8"), /^singleton I18n I18n\.qml$/m);
});

test("untranslated text stays English and arguments follow translation", () => {
    assert.equal(I18n.translate({ Close: "Sluiten" }, "Close"), "Sluiten");
    assert.equal(I18n.translate({ Close: "Sluiten" }, "Open"), "Open");
    assert.equal(I18n.translate({ Close: "" }, "Close"), "Close", "an empty entry is no translation");
    assert.equal(I18n.translate({}, undefined), "");
    assert.equal(I18n.format({ "%1 of %2": "%2: %1" }, "%1 of %2", [3, 5]), "5: 3");
    assert.equal(I18n.format({}, "Step %1, then %2", ["a"]), "Step a, then %2",
        "a missing argument leaves its placeholder visible rather than inventing one");
});

test("every string the shell translates has a Dutch entry, and none is unused", () => {
    const keys = allKeys();
    const missing = [...keys].filter(key => !(key in catalog));
    const unused = Object.keys(catalog).filter(key => !keys.has(key));
    assert.deepEqual(missing, [], "run scripts/i18n-catalog missing nl");
    assert.deepEqual(unused, [], "run scripts/i18n-catalog merge nl to drop unused entries");
});

test("translations keep placeholders, outer whitespace and line breaks", () => {
    const shape = text => [
        (String(text).match(/%[1-9]/g) || []).sort().join(","),
        /^\s/.test(text), /\s$/.test(text), (String(text).match(/\n/g) || []).length
    ];
    for (const [key, value] of Object.entries(catalog)) {
        assert.equal(typeof value, "string");
        assert.notEqual(value.trim(), "", key);
        assert.deepEqual(shape(value), shape(key), key);
    }
});

test("the catalog is generated: sorted, one entry per line, Node and QML loadable", () => {
    const source = fs.readFileSync(path.join(shellDir, "Common/i18n/nl.js"), "utf8");
    const blocks = catalogBlocks(source);
    const grouped = new Set(blocks.flatMap(block => block.keys));
    for (const keys of [Object.keys(catalog).filter(key => !grouped.has(key)), ...blocks.map(block => block.keys)])
        assert.deepEqual(keys, [...keys].sort((a, b) => (a < b ? -1 : a > b ? 1 : 0)));
    const literals = [...source.matchAll(/^    ("(?:[^"\\]|\\.)*"): /gm)];
    assert.equal(literals.length, Object.keys(catalog).length, "one definition per translation key");
    assert.match(source, /^var MESSAGES = \{$/m, "QML imports the file as a plain JS resource");
    assert.match(source, /module\.exports = \{ MESSAGES: MESSAGES \};/);
});

// The literal-property patterns the migration wrapped. New user-visible text
// in these properties must go through I18n.tr, or carry an explicit
// `// i18n: untranslated` marker (identifiers, technical names).
const PROPS = "text|label|title|placeholderText|subtitle|hint|description|tooltip|toolTip|"
    + "heading|message|emptyText|summary|confirmText|cancelText|confirmLabel|cancelLabel|"
    + "actionLabel|buttonLabel|body|note|statusText|placeholder|Accessible\\.name|Accessible\\.description";
const LITERAL = new RegExp(`^\\s*(?:${PROPS})\\s*:\\s*"((?:[^"\\\\]|\\\\.)*)"\\s*[,;]?\\s*(?://.*)?$`);

function visible(value) {
    if (!/[A-Za-z]{2}/.test(value))
        return false;
    if (/^[a-z0-9_.\-/]+$/.test(value) || /^[a-z]+[A-Z][A-Za-z0-9]*$/.test(value))
        return false;
    return !/^(qrc:|file:|https?:|\/|#|image:|~)/.test(value);
}

test("user-visible QML literals are translatable", () => {
    const offenders = [];
    for (const file of qmlFiles()) {
        if (path.relative(shellDir, file).startsWith("safe-mode"))
            continue;
        fs.readFileSync(file, "utf8").split("\n").forEach((line, index) => {
            const match = line.match(LITERAL);
            if (match && visible(match[1]) && !line.includes("i18n: untranslated"))
                offenders.push(`${path.relative(shellDir, file)}:${index + 1}: ${line.trim()}`);
        });
    }
    assert.deepEqual(offenders, [], "wrap these in I18n.tr(…)");
});
