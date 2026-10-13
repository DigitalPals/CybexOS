const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { shellDir, load } = require("./shell.cjs");

// Evaluate the production domain methods with a controlled wire boundary.
// The Qt lifecycle harness separately verifies process/event delivery.
function harness() {
    const sent = [];
    const context = { actionStates: {}, actionTimeoutMs: 15000,
        supportsSettlement: true, supportsSnooze: true,
        supportsTitleRegeneration: true, supportsPinning: true,
        Helpers: load("T3CodeHelpers.js"),
        T3Connection: { canOperate: true, state: "connected" },
        T3Threads: { threadMap: {} },
        T3Rpc: { genId: () => "command", requestOnce: (tag, payload, success, failure) => {
            sent.push({ tag, payload, success, failure }); return String(sent.length);
        } },
        console: { warn() {} }, Date,
    };
    context.root = context;
    vm.createContext(context);
    const source = fs.readFileSync(path.join(shellDir, "Common/T3Actions.qml"), "utf8");
    for (const match of source.matchAll(/^    function \w+\([^]*?^    }/gm))
        vm.runInContext(match[0], context);
    return { context, sent };
}

test("a partially accepted batch stops on rejection and is never replayed", () => {
    const { context: c, sent } = harness();
    const commands = [{type:"one"}, {type:"two"}, {type:"three"}];
    c.dispatchBatch(commands, "batch", {});
    assert.equal(sent.length, 1);
    assert.equal(c.actionStates.batch.pending, true);
    sent[0].success();
    assert.equal(sent.length, 2);
    sent[1].failure("Disconnected before confirmation");
    assert.equal(sent.length, 2);
    assert.equal(c.actionStates.batch.pending, false);
    assert.equal(c.actionStates.batch.error, "Disconnected before confirmation");
});

test("duplicate pending actions and read-only connections cannot dispatch", () => {
    const { context: c, sent } = harness();
    c.dispatch({type:"one"}, "same", true);
    assert.equal(c.dispatch({type:"one"}, "same", true), "");
    assert.equal(sent.length, 1);
    sent[0].success();
    assert.equal(c.actionStates.same.pending, true, "RPC acceptance alone cannot resolve an approval");
    c.T3Connection.canOperate = false;
    c.dispatch({type:"two"}, "other", false);
    assert.equal(sent.length, 1);
    assert.match(c.actionStates.other.error, /read-only/);
});

test("action expiry affects pending feedback and retains earlier errors", () => {
    const { context: c } = harness();
    c.beginAction("expired", "1", false, 20);
    c.beginAction("running", "2", false, 50000);
    c.rejectAction("failed", "Rejected", false);
    c.expire(Date.now() + 30);
    assert.equal(c.actionStates.expired.pending, false);
    assert.equal(c.actionStates.running.pending, true);
    assert.equal(c.actionStates.failed.error, "Rejected");
});
