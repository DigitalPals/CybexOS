const test = require("node:test");
const assert = require("node:assert/strict");
const { load } = require("./shell.cjs");

const N = load("LauncherNavigation.js");

test("launcher selection stays valid for empty and single-result lists", () => {
    for (const selected of [-1, 0, 7]) {
        assert.equal(N.clampSelection(selected, 0), 0);
        assert.equal(N.wrapSelection(selected, 0, 1), 0);
        assert.equal(N.pageSelection(selected, 0, 6), 0);
        assert.equal(N.clampSelection(selected, 1), 0);
        assert.equal(N.wrapSelection(selected, 1, -1), 0);
        assert.equal(N.pageSelection(selected, 1, -6), 0);
    }
});

test("launcher result movement wraps at both list boundaries", () => {
    assert.equal(N.wrapSelection(0, 8, -1), 7);
    assert.equal(N.wrapSelection(7, 8, 1), 0);
    assert.equal(N.wrapSelection(3, 8, 1), 4);
});

test("launcher page movement jumps six rows and clamps at the ends", () => {
    assert.equal(N.pageSelection(0, 8, 6), 6);
    assert.equal(N.pageSelection(1, 8, 6), 7);
    assert.equal(N.pageSelection(7, 8, -6), 1);
    assert.equal(N.pageSelection(5, 8, -6), 0);
});

// Execute the shipped handler, including its ordering of modifier/prompt
// branches. Helper-only selection tests cannot detect query loss on Ctrl+Left.
function handlerFixture(query = "", argumentMode = false) {
    const fs = require("node:fs");
    const path = require("node:path");
    const vm = require("node:vm");
    const { shellDir } = require("./shell.cjs");
    const source = fs.readFileSync(path.join(shellDir, "LauncherView.qml"), "utf8");
    const handler = source.match(/    function handleCommandKey\(event\): bool \{[^]*?^    }/m)[0].replace(": bool", "");
    const Qt = Object.fromEntries(["Escape", "Tab", "Backtab", "Left", "Right", "Home", "End", "1", "8", "Delete", "P", "Return", "Enter", "Down", "Up", "PageDown", "PageUp"].map((name, index) => ["Key_" + name, index + 100]));
    Object.assign(Qt, {ControlModifier: 1, ShiftModifier: 2, AltModifier: 4, MetaModifier: 8});
    const context = {Qt, query, argumentMode, search: {text: query}, selected: 2, rows: [1, 2, 3, 4], cycles: [], activated: [],
        LauncherProviders: {cancelPending() {}, canRemove() { return false; }, canPin() { return false; }},
        Launcher: {close() {}},
        cycleTab(offset) { context.cycles.push(offset); context.search.text = ""; },
        activate(row, copy) { context.activated.push([row, copy]); },
        wrapSelection(offset) { context.selected += offset; }, pageSelection(offset) { context.selected += offset; }};
    vm.createContext(context);
    vm.runInContext(handler, context);
    context.press = (key, modifiers = 0) => context.handleCommandKey({key: Qt["Key_" + key], modifiers});
    return context;
}

test("nonempty queries and argument prompts retain caret, word and selection navigation", () => {
    for (const query of ["fire fox", "/some/path", ">echo hello", "!action", "=2+2"])
        for (const key of ["Left", "Right", "Home", "End"])
            for (const modifiers of [0, 1, 2, 3, 8]) {
                const view = handlerFixture(query);
                assert.equal(view.press(key, modifiers), false, `${query}: ${key}/${modifiers}`);
                assert.equal(view.search.text, query);
                assert.equal(view.selected, 2);
                assert.deepEqual(view.cycles, []);
            }
    for (const key of ["Left", "Right", "Home", "End"])
        assert.equal(handlerFixture("", true).press(key), false);
});

test("explicit provider cycling, empty-input shortcuts and modifier-tolerant activation remain available", () => {
    const view = handlerFixture("edited query");
    assert.equal(view.press("Tab", view.Qt.ControlModifier), true);
    assert.deepEqual(view.cycles, [1]);
    assert.equal(view.search.text, "");
    const backwards = handlerFixture("", true);
    assert.equal(backwards.press("Backtab", backwards.Qt.ControlModifier | backwards.Qt.ShiftModifier), true);
    assert.deepEqual(backwards.cycles, [-1]);
    for (const [key, direction] of [["Left", -1], ["Right", 1]]) {
        const empty = handlerFixture();
        assert.equal(empty.press(key, empty.Qt.MetaModifier), true);
        assert.deepEqual(empty.cycles, [direction]);
    }
    const empty = handlerFixture();
    assert.equal(empty.press("Home"), true);
    assert.equal(empty.selected, 0);
    assert.equal(empty.press("End"), true);
    assert.equal(empty.selected, 3);
    assert.equal(empty.press("Return", empty.Qt.MetaModifier | empty.Qt.ShiftModifier), true);
    assert.deepEqual(empty.activated, [[4, true]]);
});
