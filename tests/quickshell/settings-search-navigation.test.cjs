const test = require("node:test");
const assert = require("node:assert/strict");
const { load } = require("./shell.cjs");
const search = load("SettingsSearchData.js");
const helpers = load("I18nHelpers.js");
const nl = load("i18n/nl.js").MESSAGES;

test("settings search matches current catalog translations and English aliases at the same destination", () => {
    const translate = text => helpers.translate(nl, text);
    for (const [english, dutch, page] of [["Network", "Netwerk", "network"], ["Keyboard", "Toetsenbord", "keyboard"]]) {
        assert.equal(translate(english), dutch);
        const expected = search.search(english).filter(row => row.page === page);
        assert.ok(expected.length > 0);
        for (const query of [english, dutch])
            assert.deepEqual(search.search(query, translate).filter(row => row.page === page), expected);
    }
});

test("Recovery points has a scroll destination without inventing a shell preference", () => {
    const row = search.search("Recovery points").find(row => row.label === "Recovery points");
    assert.equal(row.page, "backup");
    assert.equal(row.anchor, "recoveryPoints");
    assert.equal(row.key, "");
    assert.ok(!Object.hasOwn(load("SettingsHelpers.js").defaults(), row.anchor));
});

test("opening a non-preference result forwards its anchor without writing a preference", () => {
    const fs = require("node:fs");
    const path = require("node:path");
    const vm = require("node:vm");
    const { shellDir } = require("./shell.cjs");
    const view = fs.readFileSync(path.join(shellDir, "Settings/SettingsView.qml"), "utf8");
    const handler = view.match(/^    function jumpToResult\(row\) \{[^]*?^    }/m)[0];
    const settings = {page: "about", highlightKey: "", announcement: ""};
    const context = {Settings: settings, searchQuery: "recovery", searchSelection: 2};
    vm.createContext(context);
    vm.runInContext(handler, context);
    context.jumpToResult(search.ROWS.find(row => row.label === "Recovery points"));
    assert.equal(settings.page, "backup");
    assert.equal(settings.highlightKey, "recoveryPoints");
    assert.equal(context.searchQuery, "");
    assert.equal(context.searchSelection, 0);
    assert.equal(Object.hasOwn(settings, "recoveryPoints"), false);
});
