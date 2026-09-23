const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { shellDir, load } = require("./shell.cjs");

const Tabler = load("TablerGlyphs.js");

// Read cmap formats 4 and 12 directly, so coverage is checked on every machine
// without an installed icon font or a Python/fonttools test dependency.
function fontCodepoints(file) {
    const data = fs.readFileSync(file);
    let cmap;
    for (let i = 0; i < data.readUInt16BE(4); i++) {
        const r = 12 + i * 16;
        if (data.toString("ascii", r, r + 4) === "cmap")
            cmap = data.readUInt32BE(r + 8);
    }
    assert.notEqual(cmap, undefined);
    const found = new Set();
    for (let i = 0; i < data.readUInt16BE(cmap + 2); i++) {
        const table = cmap + data.readUInt32BE(cmap + 4 + i * 8 + 4);
        const format = data.readUInt16BE(table);
        if (format === 12) {
            for (let j = 0; j < data.readUInt32BE(table + 12); j++) {
                const group = table + 16 + j * 12;
                const start = data.readUInt32BE(group);
                const end = data.readUInt32BE(group + 4);
                const glyph = data.readUInt32BE(group + 8);
                for (let c = start; c <= end; c++)
                    if (glyph + c - start !== 0) found.add(c);
            }
        } else if (format === 4) {
            const n = data.readUInt16BE(table + 6) / 2;
            const ends = table + 14, starts = ends + 2 * n + 2;
            const deltas = starts + 2 * n, offsets = deltas + 2 * n;
            for (let j = 0; j < n; j++) {
                const start = data.readUInt16BE(starts + j * 2);
                const end = data.readUInt16BE(ends + j * 2);
                const delta = data.readInt16BE(deltas + j * 2);
                const offset = data.readUInt16BE(offsets + j * 2);
                for (let c = start; c <= end && c < 0xffff; c++) {
                    let glyph = offset ? data.readUInt16BE(offsets + j * 2 + offset + (c - start) * 2) : c;
                    if (!offset || glyph) glyph = (glyph + delta) & 0xffff;
                    if (glyph) found.add(c);
                }
            }
        }
    }
    return found;
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

// Existing semantic names (underscore spelling) can come from: a `name:` inside a Sym
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
        // the notification sources — return the semantic name itself.
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
    // action glyph rather than accepting an arbitrary icon name from JSON.
    for (const glyph of load("LauncherProviders.js").GLYPHS)
        found.set(glyph, "Common/LauncherProviders.js: GLYPHS");

    for (const [id, widget] of Object.entries(load("WidgetCatalog.js").WIDGETS))
        found.set(widget.glyph, "Common/WidgetCatalog.js: " + id);

    return found;
}

test("every shell icon name resolves to bundled Tabler artwork", () => {
    const used = collectNames();
    assert.ok(used.size > 140);
    const missing = [...used].filter(([name]) => !Tabler.has(name));
    assert.deepEqual(missing, []);
});

test("all registry codepoints exist in the bundled outline font", () => {
    const aliases = JSON.parse(fs.readFileSync(path.join(shellDir, "assets/tabler/aliases.json")));
    assert.deepEqual(Tabler.ALIASES, aliases, "regenerate after changing icon mappings");
    const points = fontCodepoints(path.join(shellDir, "assets/tabler/outline.ttf"));
    assert.ok(Object.keys(Tabler.GLYPHS).length > 150);
    for (const [name, glyph] of Object.entries(Tabler.GLYPHS)) {
        assert.ok(points.has(glyph.outline.codePointAt(0)), `${name}: missing outline`);
        assert.equal(glyph.filled, undefined, `${name}: filled icons are not shipped`);
    }
    for (const target of Object.values(aliases))
        assert.ok(Object.hasOwn(Tabler.GLYPHS, target));
    assert.equal(fs.existsSync(path.join(shellDir, "assets/tabler/filled.ttf")), false);
});

test("empty, unknown, canonical and compatibility names resolve safely", () => {
    assert.equal(Tabler.resolve("").outline, "");
    assert.equal(Tabler.resolve(null).outline, "");
    assert.equal(Tabler.resolve("not-an-icon"), Tabler.GLYPHS["help-circle"]);
    assert.equal(Tabler.resolve("__proto__"), Tabler.GLYPHS["help-circle"]);
    assert.equal(Tabler.resolve("notifications"), Tabler.resolve("bell"));
    assert.ok(Tabler.resolve("notifications").outline);
    assert.ok(Tabler.resolve("wifi").outline);
    assert.equal(Tabler.resolve("wifi").filled, undefined);
});

test("icons are drawn through Sym rather than by hand", () => {
    // Sym owns the bundled font and square alignment.
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
