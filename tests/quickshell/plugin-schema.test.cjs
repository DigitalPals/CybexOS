const test = require("node:test");
const assert = require("node:assert/strict");
const { load } = require("./shell.cjs");
const S = load("PluginSchema.js");

// Shaped after a real package (digitalpals.model-usage): the schema lives in
// barWidget, and the defaults object repeats its values.
const manifest = {
    barWidget: {
        defaults: { usageSource: "direct", refreshIntervalSec: 900, hideAccountEmails: true },
        schema: [
            { key: "usageSource", type: "enum", label: "Quota source",
                options: ["direct", "cliproxy"], defaultValue: "direct",
                description: "Read local CLI sign-ins directly or query CLIProxyAPI." },
            { key: "cliproxyUrl", type: "string", label: "CLIProxyAPI server URL",
                defaultValue: "http://127.0.0.1:8317" },
            { key: "hideAccountEmails", type: "boolean", label: "Hide account emails", defaultValue: true },
            { key: "refreshIntervalSec", type: "integer", label: "Refresh interval (seconds)",
                min: 60, max: 3600, step: 60, defaultValue: 900 },
            { key: "enabledProviders", type: "multiselect", label: "Providers",
                noSelectionText: "No providers", defaultValue: ["claude", "codex", "kimi"],
                options: [{ value: "claude", label: "Claude Code" },
                    { value: "codex", label: "OpenAI Codex" }, { value: "kimi", label: "Kimi Code" }] },
            { key: "criticalThreshold", type: "integer", label: "Critical at (% remaining)",
                min: 0, max: 100, step: 1, defaultValue: 10 },
        ],
    },
};

const byKey = result => Object.fromEntries(result.fields.map(field => [field.key, field]));

test("schema entries become typed rows in declaration order", () => {
    const result = S.fields(manifest, { usageSource: "direct" }, manifest.barWidget.defaults);
    assert.deepEqual(result.fields.map(field => field.key), ["usageSource", "cliproxyUrl",
        "hideAccountEmails", "refreshIntervalSec", "enabledProviders", "criticalThreshold"]);
    const fields = byKey(result);
    assert.equal(fields.usageSource.label, "Quota source");
    assert.deepEqual(fields.usageSource.options, [{ value: "direct", label: "Direct" },
        { value: "cliproxy", label: "Cliproxy" }]);
    assert.equal(fields.refreshIntervalSec.slider, true);
    assert.equal(fields.refreshIntervalSec.step, 60);
    assert.equal(fields.enabledProviders.options[1].label, "OpenAI Codex");
    assert.equal(fields.enabledProviders.emptyText, "No providers");
});

test("values come from settings, then the entry default, then barWidget.defaults", () => {
    const withDefaults = { ...manifest, barWidget: { ...manifest.barWidget,
        schema: [{ key: "refreshIntervalSec", type: "integer", min: 60, max: 3600 }] } };
    assert.equal(byKey(S.fields(withDefaults, {}, { refreshIntervalSec: 120 })).refreshIntervalSec.value, 120);
    const fields = byKey(S.fields(manifest, { refreshIntervalSec: 300 }, manifest.barWidget.defaults));
    assert.equal(fields.refreshIntervalSec.value, 300);
    assert.equal(fields.refreshIntervalSec.dirty, true);
    assert.equal(fields.cliproxyUrl.value, "http://127.0.0.1:8317");
    assert.equal(fields.cliproxyUrl.dirty, false);
});

test("a changed multiselect is dirty and compares by content", () => {
    const same = byKey(S.fields(manifest, { enabledProviders: ["claude", "codex", "kimi"] }, {}));
    assert.equal(same.enabledProviders.dirty, false);
    const fewer = byKey(S.fields(manifest, { enabledProviders: ["codex"] }, {}));
    assert.equal(fewer.enabledProviders.dirty, true);
});

test("saved keys the schema cannot draw stay in the raw editor", () => {
    const result = S.fields(manifest, {
        usageSource: "sub2api",          // not one of the declared options
        refreshIntervalSec: 5,           // below the slider's minimum
        hideAccountEmails: "yes",        // wrong type
        costPriceOverrides: "{}",        // not in the schema at all
    }, {});
    const keys = result.fields.map(field => field.key);
    assert.ok(!keys.includes("usageSource"));
    assert.ok(!keys.includes("refreshIntervalSec"));
    assert.ok(!keys.includes("hideAccountEmails"));
    assert.deepEqual(result.other, ["costPriceOverrides", "hideAccountEmails",
        "refreshIntervalSec", "usageSource"]);
});

test("malformed entries are skipped without hiding the rest", () => {
    const broken = { barWidget: { schema: [
        null, "text", { type: "boolean" }, { key: "x", type: "colour" },
        { key: "mode", type: "enum", options: [] },
        { key: "ok", type: "boolean" }, { key: "ok", type: "string" },
    ] } };
    const result = S.fields(broken, {}, {});
    assert.deepEqual(result.fields.map(field => [field.key, field.type]), [["ok", "boolean"]]);
    assert.equal(result.fields[0].value, false);
    assert.equal(result.fields[0].hasDefault, false);
    assert.equal(result.fields[0].dirty, false);
    assert.deepEqual(S.fields({}, { a: 1 }, {}), { fields: [], other: ["a"] });
    assert.deepEqual(S.fields(null, null, null), { fields: [], other: [] });
});

test("a declared default the control cannot show is not treated as one", () => {
    const result = byKey(S.fields({ barWidget: { schema: [
        { key: "mode", type: "enum", options: ["a", "b"], defaultValue: "c" },
    ] } }, {}, {}));
    assert.equal(result.mode.hasDefault, false);
    assert.equal(result.mode.value, "a");
});

test("unbounded numbers use a text field; bounded ones a slider", () => {
    const fields = byKey(S.fields({ barWidget: { schema: [
        { key: "a", type: "integer", min: 1 },
        { key: "b", type: "number", min: 0, max: 1, step: 0.1 },
        { key: "c", type: "integer", min: 5, max: 5 },
    ] } }, {}, {}));
    assert.equal(fields.a.slider, false);
    assert.equal(fields.a.value, 1);
    assert.equal(fields.b.slider, true);
    assert.equal(fields.c.slider, false);
});

test("toggling a multiselect option keeps the schema's option order", () => {
    const field = byKey(S.fields(manifest, {}, {})).enabledProviders;
    assert.deepEqual(S.toggled(field, ["kimi", "claude"], "codex"), ["claude", "codex", "kimi"]);
    assert.deepEqual(S.toggled(field, ["claude", "codex"], "claude"), ["codex"]);
    assert.deepEqual(S.toggled(field, undefined, "kimi"), ["kimi"]);
});

test("typed numbers are checked against type and range", () => {
    const fields = byKey(S.fields({ barWidget: { schema: [
        { key: "n", type: "integer", min: 1, max: 10 },
        { key: "f", type: "number" },
    ] } }, {}, {}));
    assert.equal(S.parseNumber(fields.n, " 7 "), 7);
    assert.equal(S.parseNumber(fields.n, "7.5"), null);
    assert.equal(S.parseNumber(fields.n, "11"), null);
    assert.equal(S.parseNumber(fields.n, ""), null);
    assert.equal(S.parseNumber(fields.n, "1e3"), null);
    assert.equal(S.parseNumber(fields.f, "-.5"), -0.5);
    assert.equal(S.numberHint(fields.n), "Enter a whole number from 1 to 10");
    assert.equal(S.numberHint(fields.f), "Enter a number");
});
