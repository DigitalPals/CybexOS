const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { shellDir, load } = require("./shell.cjs");

// SettingsHelpers.defaults() is the schema. Settings.qml used to restate it
// four times — one property per key, one field in snapshot(), one assignment
// in applyLoaded(), one entry in sectionKeys — and three of those four failed
// silently when they drifted: a setting with no snapshot field is never
// saved, one with no applyLoaded assignment is never restored, and one
// missing from sectionKeys is invisible to its page's dirty dot and Reset
// page button.
//
// snapshot() and applyLoaded() are loops now. The other two cannot be —
// QML properties are declared statically, and sectionKeys is a UI grouping
// the schema does not know about — so they are checked here instead.

const SETTINGS = fs.readFileSync(path.join(shellDir, "Common", "Settings.qml"), "utf8");
const KEYS = Object.keys(load("SettingsHelpers.js").defaults());

// The wallpaper palette has its own cache file, so every persisted shell
// setting is user-facing and belongs to one page.
const NOT_USER_FACING = [];

function functionBody(name) {
    const start = SETTINGS.indexOf(`function ${name}`);
    assert.notEqual(start, -1, `${name}() must exist`);
    const opening = SETTINGS.indexOf("{", start);
    let depth = 0;
    for (let index = opening; index < SETTINGS.length; index++) {
        if (SETTINGS[index] === "{")
            depth++;
        else if (SETTINGS[index] === "}" && --depth === 0)
            return SETTINGS.slice(start, index + 1);
    }
    assert.fail(`${name}() has an unterminated body`);
}

function sectionKeys() {
    const start = SETTINGS.indexOf("readonly property var sectionKeys: ({");
    assert.notEqual(start, -1, "sectionKeys must exist");
    const end = SETTINGS.indexOf("})", start);
    const body = SETTINGS.slice(start, end);
    const out = {};
    for (const line of body.split("\n")) {
        const m = line.match(/^\s*(\w+):\s*\[/);
        if (m) out[m[1]] = [];
        const owner = Object.keys(out).at(-1);
        if (owner)
            out[owner].push(...[...line.matchAll(/"(\w+)"/g)].map(x => x[1]));
    }
    return out;
}

test("the schema is not small enough to be a fluke", () => {
    assert.ok(KEYS.length > 25, `only ${KEYS.length} settings keys loaded`);
});

test("every schema key has a property that defaults to it", () => {
    const declared = [...SETTINGS.matchAll(/^\s*property \w+ (\w+): defaults\.(\w+)$/gm)];
    for (const [, name, from] of declared)
        assert.equal(name, from, `property ${name} defaults to ${from}`);
    const names = declared.map(m => m[1]);
    assert.deepEqual(KEYS.filter(k => !names.includes(k)), [],
        "these schema keys have no property in Settings.qml, so nothing holds them");
    assert.deepEqual(names.filter(n => !KEYS.includes(n)), [],
        "these properties default to a key the schema does not define");
});

test("saving and loading enumerate the schema rather than restating it", () => {
    const snapshot = SETTINGS.slice(SETTINGS.indexOf("function snapshot()"),
        SETTINGS.indexOf("function seedWeatherFromEnv"));
    assert.match(snapshot, /for \(const key of Object\.keys\(root\.defaults\)\)/,
        "snapshot() must loop the schema");
    assert.ok(snapshot.split("\n").length < 15,
        "snapshot() has grown a hand-written list again");

    const body = functionBody("applyLoaded(rawText)");
    assert.match(body, /for \(const key of Object\.keys\(root\.defaults\)\)\s*\n\s*assignChanged\(key, merged\[key\]\);/,
        "applyLoaded() must loop the schema");
    // modOpts is the one key that is not a straight copy, and it has to be
    // assigned after the loop or the env seed is overwritten by it.
    const loopAt = body.indexOf("assignChanged(key, merged[key])");
    const seedAt = body.indexOf("seedWeatherFromEnv");
    assert.ok(loopAt > 0 && seedAt > loopAt,
        "the modOpts env seed must run after the schema loop, not before");
});

test("every user-facing setting belongs to exactly one settings page", () => {
    const sections = sectionKeys();
    assert.ok(Object.keys(sections).length >= 6, "expected one list per page");
    const owners = {};
    for (const [section, keys] of Object.entries(sections))
        for (const key of keys) {
            assert.ok(KEYS.includes(key),
                `sectionKeys.${section} names "${key}", which is not in the schema`);
            assert.equal(owners[key], undefined,
                `"${key}" is claimed by both ${owners[key]} and ${section}`);
            owners[key] = section;
        }
    const unclaimed = KEYS.filter(k => !(k in owners));
    assert.deepEqual(unclaimed.sort(), [...NOT_USER_FACING].sort(),
        "these settings belong to no page, so no page can show or reset them");
});

test("Reset all skips exactly the settings no page owns", () => {
    const resetAll = SETTINGS.slice(SETTINGS.indexOf("function resetAll()"));
    const skipped = [...resetAll.slice(0, resetAll.indexOf("}")).matchAll(/key !== "(\w+)"/g)]
        .map(m => m[1]);
    assert.deepEqual(skipped.sort(), [...NOT_USER_FACING].sort(),
        "Reset all and the page grouping disagree about what is user-facing");
    assert.match(resetAll, /resetKeys\(Object\.keys\(defaults\), "All settings"\)/);
});
