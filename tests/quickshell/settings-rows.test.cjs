const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { shellDir, load } = require("./shell.cjs");

// SwitchRow, PickerRow, SliderRow and SettingsTextRow are one skeleton now —
// Settings/SettingsRow.qml — and a row that names a `settingKey` gets its
// value, its dirty state, its commit and its undo chip from the base.
//
// The risk that buys is a silent one: `Settings[settingKey]` resolves to
// `undefined` for a key that does not exist, which reads as "not dirty" and
// commits to nothing. QML says nothing, qmllint says nothing, and the row
// looks fine until someone tries to change it. So the keys are checked
// against the schema here.

const ROWS = ["SwitchRow", "PickerRow", "SliderRow", "SettingsTextRow"];
const DEFAULTS = load("SettingsHelpers.js").defaults();

function read(rel) {
    return fs.readFileSync(path.join(shellDir, rel), "utf8");
}

function settingsFiles() {
    return fs.readdirSync(path.join(shellDir, "Settings"))
        .filter(name => name.endsWith(".qml"))
        .map(name => path.join("Settings", name));
}

// Every `<RowType> { … }` block in the Settings pages, with its source line.
function rowBlocks() {
    const out = [];
    for (const rel of settingsFiles()) {
        if (ROWS.includes(path.basename(rel, ".qml")))
            continue;
        const lines = read(rel).split("\n");
        for (let i = 0; i < lines.length; i++) {
            const m = lines[i].match(new RegExp(`^\\s*(${ROWS.join("|")})\\s*\\{\\s*$`));
            if (!m) continue;
            let depth = 0;
            for (let j = i; j < lines.length; j++) {
                depth += (lines[j].match(/\{/g) || []).length;
                depth -= (lines[j].match(/\}/g) || []).length;
                if (depth === 0) {
                    out.push({ at: `${rel}:${i + 1}`, type: m[1], body: lines.slice(i, j + 1) });
                    break;
                }
            }
        }
    }
    return out;
}

const BLOCKS = rowBlocks();

test("the row skeleton lives in one file", () => {
    const base = read("Settings/SettingsRow.qml");
    assert.match(base, /readonly property bool narrow:/);
    assert.match(base, /readonly property int labelWidth:/);
    assert.match(base, /UndoChip \{/);
    for (const row of ROWS) {
        const source = read(`Settings/${row}.qml`);
        assert.match(source, /^SettingsRow \{$/m, `${row} must build on SettingsRow`);
        for (const owned of [/property bool narrow/, /property int labelWidth/, /UndoChip \{/,
                             /property string label\b/, /property bool dirty/,
                             /signal resetRequested/])
            assert.doesNotMatch(source, owned,
                `${row} redeclares something SettingsRow already owns`);
    }
});

test("every settingKey and resetKeys entry is a real setting", () => {
    assert.ok(Object.keys(DEFAULTS).length > 20, "the schema failed to load");
    const seen = [];
    for (const block of BLOCKS)
        for (const line of block.body) {
            const single = line.match(/^\s*settingKey:\s*"(\w+)"\s*$/);
            if (single) {
                seen.push(single[1]);
                assert.ok(single[1] in DEFAULTS,
                    `${block.at}: settingKey "${single[1]}" is not in the settings schema`);
            }
            const group = line.match(/^\s*resetKeys:\s*\[([^\]]*)\]\s*$/);
            if (group)
                for (const key of group[1].match(/"(\w+)"/g) || [])
                    assert.ok(key.slice(1, -1) in DEFAULTS,
                        `${block.at}: resetKeys names "${key}", not in the settings schema`);
        }
    assert.ok(seen.length >= 20,
        `only ${seen.length} rows use settingKey — has the block scanner stopped matching?`);
});

test("a row with a settingKey does not also hand-wire the same behaviour", () => {
    for (const block of BLOCKS) {
        if (!block.body.some(l => /^\s*settingKey:/.test(l)))
            continue;
        const text = block.body.join("\n");
        // The base already resets on undo; a second handler would reset twice
        // and announce twice.
        assert.doesNotMatch(text, /onResetRequested:/,
            `${block.at}: settingKey rows reset through the base — use resetKeys/resetLabel`);
        assert.doesNotMatch(text, /Settings\.set\(/,
            `${block.at}: settingKey rows commit through the base`);
    }
});

test("rows that cannot use settingKey still wire themselves completely", () => {
    // ModuleDetailView stores per-module options, not settings, so its rows
    // keep explicit wiring. Each one still needs a dirty state and a reset,
    // or its undo chip is either absent or inert.
    for (const block of BLOCKS) {
        if (block.body.some(l => /^\s*settingKey:/.test(l)))
            continue;
        const text = block.body.join("\n");
        // Layout commands and external plugin settings have no schema default.
        // Their enable/remove controls preserve state, rather than inventing a reset.
        if (block.at.startsWith("Settings/ModulesPage.qml:") || block.at.startsWith("Settings/PluginWidgetSettings.qml:")) {
            assert.match(text, /on(?:Toggled|Picked|Moved|Committed):/, `${block.at}: missing write handler`);
            continue;
        }
        assert.match(text, /^\s*dirty:/m, `${block.at}: no dirty state`);
        assert.ok(/onResetRequested:/.test(text) || /^\s*resetKeys:/m.test(text),
            `${block.at}: nothing happens when its undo chip is clicked`);
    }
});
