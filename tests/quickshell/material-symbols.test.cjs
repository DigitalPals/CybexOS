const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { shellDir, load } = require("./shell.cjs");

// Material Symbols selects a glyph by *ligature*: `name: "wifi"` is the string
// "wifi", shaped into one mark by the font. A name the font does not carry is
// not a missing icon — it is the word, drawn in the icon font, in the middle of
// the bar. That failure is invisible to qmllint and to every other check here,
// so this reads the installed face and confirms every name the shell draws
// exists in it.
//
// The face is a pinned install (inventory/group_vars/all.yml → pinned_font_files);
// the check skips rather than fails when it is absent, the way tests/qml-lint
// skips without qmllint.

const FONT_DIR = "/usr/local/share/fonts/material-symbols-rounded";

function installedFont() {
    if (!fs.existsSync(FONT_DIR))
        return null;
    for (const version of fs.readdirSync(FONT_DIR).sort().reverse()) {
        const dir = path.join(FONT_DIR, version);
        if (!fs.statSync(dir).isDirectory())
            continue;
        const ttf = fs.readdirSync(dir).find(f => f.endsWith(".ttf"));
        if (ttf)
            return path.join(dir, ttf);
    }
    return null;
}

// Glyph names out of the TrueType `post` table (format 2.0), which for this
// face is exactly the icon-name list.
function glyphNames(file) {
    const data = fs.readFileSync(file);
    const tableCount = data.readUInt16BE(4);
    let post = null;
    for (let i = 0; i < tableCount; i++) {
        const record = 12 + i * 16;
        if (data.toString("latin1", record, record + 4) === "post")
            post = { offset: data.readUInt32BE(record + 8), length: data.readUInt32BE(record + 12) };
    }
    assert.ok(post, "the installed face has no post table");
    assert.equal(data.readUInt32BE(post.offset), 0x00020000,
        "expected a format 2.0 post table with real glyph names");

    const count = data.readUInt16BE(post.offset + 32);
    let cursor = post.offset + 34 + count * 2;
    const names = new Set();
    while (cursor < post.offset + post.length) {
        const length = data[cursor];
        names.add(data.toString("latin1", cursor + 1, cursor + 1 + length));
        cursor += 1 + length;
    }
    return names;
}

function qmlFiles() {
    const out = [];
    const walk = dir => {
        for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
            const full = path.join(dir, entry.name);
            if (entry.isDirectory())
                walk(full);
            else if (entry.name.endsWith(".qml"))
                out.push(full);
        }
    };
    walk(shellDir);
    return out;
}

// Where an icon name can come from, and nowhere else: a `name:` inside a Sym
// block, a `glyph:` on a BarIcon or a Control Panel tile, a `symbol:` on an
// IconButton, and the two helpers that pick one by hand. Deliberately narrow —
// a broad "any lowercase string" sweep collects enum values and format strings
// and stops meaning anything.
const LIGATURE = /"([a-z][a-z0-9_]*)"/g;

function blockAt(source, index) {
    let depth = 0;
    for (let i = source.indexOf("{", index); i < source.length; i++) {
        if (source[i] === "{")
            depth++;
        else if (source[i] === "}" && --depth === 0)
            return source.slice(index, i + 1);
    }
    return source.slice(index);
}

function lineOf(source, index) {
    return source.slice(0, index).split("\n").length;
}

function addNames(found, text, where) {
    for (const [, name] of text.matchAll(LIGATURE)) {
        if (!found.has(name))
            found.set(name, where);
    }
}

function collectNames() {
    const found = new Map();
    for (const file of qmlFiles()) {
        const relative = path.relative(shellDir, file);
        if (relative === "Common/Sym.qml")
            continue;
        const source = fs.readFileSync(file, "utf8");

        for (const match of source.matchAll(/\bSym\s*\{/g)) {
            const block = blockAt(source, match.index);
            for (const line of block.split("\n")) {
                // A name picked by a helper is checked at the helper, below;
                // the literals on this line are that helper's arguments.
                if (/^\s*name:/.test(line) && !/\w*(?:glyph|symbol)\w*\(/i.test(line))
                    addNames(found, line, `${relative}:${lineOf(source, match.index)}`);
            }
        }

        // Helpers that pick a name from state — the launcher's result kinds,
        // the notification sources — return the ligature itself.
        for (const fn of source.matchAll(/function \w*(?:glyph|symbol)\w*\s*\(/gi)) {
            addNames(found, blockAt(source, fn.index),
                `${relative}:${lineOf(source, fn.index)}`);
        }

        source.split("\n").forEach((line, index) => {
            const named = /^\s*\/\//.test(line) ? null : line.match(/\b(?:glyph|symbol):/);
            if (!named)
                return;
            addNames(found, line.slice(named.index),
                `${relative}:${index + 1}`);
        });
    }

    // The one name chosen outside a QML file.
    const status = fs.readFileSync(path.join(shellDir, "Common/StatusHelpers.js"), "utf8");
    const players = status.slice(status.indexOf("var PLAYER_GLYPH"));
    addNames(found, blockAt(players, 0), "Common/StatusHelpers.js: PLAYER_GLYPH");

    // Command-palette providers and built-in actions choose their glyphs from
    // a pure-JS registry. User actions deliberately inherit the validated
    // action glyph rather than accepting an arbitrary ligature from JSON.
    for (const glyph of load("LauncherProviders.js").GLYPHS)
        found.set(glyph, "Common/LauncherProviders.js: GLYPHS");

    for (const [id, widget] of Object.entries(load("WidgetCatalog.js").WIDGETS))
        found.set(widget.glyph, "Common/WidgetCatalog.js: " + id);

    return found;
}

test("every Material Symbols name the shell draws exists in the installed face", () => {
    const file = installedFont();
    if (!file) {
        console.log(`SKIP  Material Symbols Rounded not installed under ${FONT_DIR}`);
        return;
    }

    const available = glyphNames(file);
    // Sanity: a name the shell definitely draws, so a broken parse fails loudly
    // rather than passing an empty set.
    for (const known of ["wifi", "power_settings_new", "chevron_left"])
        assert.ok(available.has(known), `the post table parse missed "${known}"`);

    const used = collectNames();
    assert.ok(used.size > 30, `only found ${used.size} icon names — did the scan break?`);

    const missing = [];
    for (const [name, where] of used) {
        if (!available.has(name))
            missing.push(`${where}: "${name}"`);
    }
    assert.deepEqual(missing.sort(), [],
        "these names are not ligatures in the face, so they draw as literal text");
});

test("icons are drawn through Sym rather than by hand", () => {
    // Sym is what sets the family, the fill axis and the optical size; a bare
    // Text in the icon font renders at the font's default instance, which is
    // visibly lighter than everything beside it.
    const offenders = [];
    for (const file of qmlFiles()) {
        const relative = path.relative(shellDir, file);
        if (relative === "Common/Sym.qml")
            continue;
        fs.readFileSync(file, "utf8").split("\n").forEach((line, index) => {
            if (/font\.family:\s*Theme\.fontIcon/.test(line))
                offenders.push(`${relative}:${index + 1}`);
        });
    }
    assert.deepEqual(offenders, []);
});

test("presentation marks do not fall back to unrelated text-font symbols", () => {
    // Arrow strings in Session's shortcut-key data are copy, not icons. This
    // targets only visual `text:` properties, where a check, close mark or
    // direction arrow would otherwise vary with the selected menu typeface.
    const offenders = [];
    const marks = /[✓✔✕×⌃⌄↑↓←→]/;
    for (const file of qmlFiles()) {
        const relative = path.relative(shellDir, file);
        // The pinned Omarchy kit retains its upstream icon/font contract.
        if (relative === "Ui/MultiSelect.qml") continue;
        fs.readFileSync(file, "utf8").split("\n").forEach((line, index) => {
            if (/\btext\s*:/.test(line) && marks.test(line))
                offenders.push(`${relative}:${index + 1}`);
        });
    }
    assert.deepEqual(offenders, [],
        "presentation glyphs belong in Sym so one icon face controls them");
});
