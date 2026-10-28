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

test("a palette result opens its page and tab and forwards its anchor without writing a preference", () => {
    const fs = require("node:fs");
    const path = require("node:path");
    const vm = require("node:vm");
    const { shellDir } = require("./shell.cjs");
    const palette = fs.readFileSync(path.join(shellDir, "Settings/SettingsPalette.qml"), "utf8");
    const fn = name => palette.match(new RegExp("^    function " + name + "\\([^]*?^    }", "m"))[0];
    const settings = {
        page: "home", highlightKey: "", announcement: "", revision: 0, tabs: {},
        setTab(page, tab) { this.tabs[page] = tab; },
        set(key, value) { this[key] = value; },
        openWidgetSettings(id) { this.widget = id; this.page = "bar"; }
    };
    const context = { Settings: settings, hidden: 0, ran: [] };
    context.hide = () => { context.hidden++; };
    context.run = entry => { context.ran.push(entry.action); };
    vm.createContext(context);
    for (const name of ["valueOf", "go", "highlight", "activate"])
        vm.runInContext(fn(name), context);

    const row = search.ROWS.find(entry => entry.label === "Recovery points");
    context.activate({ kind: "row", title: row.label, crumb: "Backup & storage › Recovery points",
        page: row.page, tab: row.tab, key: row.key, anchor: row.anchor, widget: "" }, false);
    assert.equal(settings.page, "backup");
    assert.equal(settings.tabs.backup, "recovery", "the row's tab opens with its page");
    assert.equal(settings.highlightKey, "recoveryPoints");
    assert.equal(context.hidden, 1, "Enter closes the palette");
    assert.equal(Object.hasOwn(settings, "recoveryPoints"), false);

    // Ctrl+Enter flips a switch where it stands and leaves the palette open.
    settings.notifDnd = false;
    context.activate({ kind: "row", key: "notifDnd", page: "notifications", anchor: "notifDnd" }, true);
    assert.equal(settings.notifDnd, true);
    assert.equal(context.hidden, 1);
    assert.equal(settings.page, "backup", "a toggle does not navigate");
    // Only booleans flip; any other row ignores Ctrl+Enter.
    settings.notifPosition = "top-right";
    context.activate({ kind: "row", key: "notifPosition", page: "notifications", anchor: "notifPosition" }, true);
    assert.equal(settings.notifPosition, "top-right");

    // An action runs; a page entry goes to the page.
    context.activate({ kind: "action", action: "software-update", page: "" }, false);
    assert.deepEqual(context.ran, ["software-update"]);
    context.activate({ kind: "page", title: "Region & language", page: "region", tab: "" }, false);
    assert.equal(settings.page, "region");
});

test("palette actions are searchable and each names a page or runs on its own", () => {
    const ids = search.ACTIONS.map(entry => entry.action);
    assert.equal(new Set(ids).size, ids.length, "action ids are unique");
    const palette = require("node:fs").readFileSync(require("node:path").join(require("./shell.cjs").shellDir,
        "Settings/SettingsPalette.qml"), "utf8");
    for (const entry of search.ACTIONS) {
        assert.ok(entry.page || palette.includes(`case "${entry.action}":`),
            `${entry.action} must either go somewhere or be run by the palette`);
        assert.ok(search.searchActions(entry.label).includes(entry));
    }
    assert.ok(search.searchActions("doctor").some(entry => entry.action === "system-check"), "hidden terms match");
    assert.ok(search.searchActions("passwd").some(entry => entry.action === "change-password"));
    assert.deepEqual(search.searchActions(""), []);
});
