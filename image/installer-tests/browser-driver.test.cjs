const assert = require("node:assert/strict");
const test = require("node:test");
const vm = require("node:vm");
const {selectKeyboard} = require("../real_browser_qualification.cjs");

const BUSY = "Another installer operation is still running.";

function keyboardPage(results) {
    let error;
    let value;
    const page = {
        attempts: 0,
        delays: [],
        async selectOption(selector, keyboard) {
            assert.equal(selector, "#keyboard");
            value = keyboard;
            error = results[Math.min(page.attempts++, results.length - 1)];
        },
        async waitForFunction(predicate, expected) {
            const elements = {
                "#keyboard": {value}, "#password": {disabled: Boolean(error)},
                "#error": {hidden: !error, textContent: error || ""},
            };
            const ready = vm.runInNewContext(`(${predicate.toString()})(expected)`, {
                expected, document: {querySelector: selector => elements[selector]},
            });
            assert.equal(ready, true, "helper must recognize success or the visible error");
        },
        async inputValue() { return value; },
        locator(selector) {
            return {
                async isDisabled() { assert.equal(selector, "#password"); return Boolean(error); },
                async textContent() { assert.equal(selector, "#error"); return error; },
            };
        },
        async waitForTimeout(delay) { page.delays.push(delay); },
    };
    return page;
}

test("keyboard selection retries the transient installer lock and waits for applied layout", async () => {
    const page = keyboardPage([BUSY, null]);
    await selectKeyboard(page, "nl", 10000, [1]);
    assert.equal(page.attempts, 2);
    assert.deepEqual(page.delays, [1]);
});

test("persistent keyboard lock exhausts a bounded number of retries", async () => {
    const page = keyboardPage([BUSY]);
    await assert.rejects(selectKeyboard(page, "us", 10000, [1, 2]), /bounded retries/);
    assert.equal(page.attempts, 3);
    assert.deepEqual(page.delays, [1, 2]);
});

test("non-busy keyboard errors fail without retrying", async () => {
    const page = keyboardPage(["The live keyboard could not be applied."]);
    await assert.rejects(selectKeyboard(page, "us", 10000, [1]), /could not be applied/);
    assert.equal(page.attempts, 1);
    assert.deepEqual(page.delays, []);
});

test("an expired keyboard deadline does not start an operation", async () => {
    const page = keyboardPage([null]);
    await assert.rejects(selectKeyboard(page, "us", 0), /deadline/);
    assert.equal(page.attempts, 0);
});
