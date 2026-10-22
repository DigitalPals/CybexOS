const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { shellDir, load } = require("./shell.cjs");

function harness() {
    const source = fs.readFileSync(path.join(shellDir, "Common/UserPlugins.qml"), "utf8");
    const later = [], signals = [];
    const context = vm.createContext({
        plugins: [], widgets: [], barConfig: {}, lastResult: "",
        mutationError: "", discoveryError: "", operationResult: "", pendingWrites: [],
        writer: { running: false, command: [] }, refreshes: 0,
        ProcHelpers: load("ProcHelpers.js"), Qt: { callLater(fn) { later.push(fn); } },
        refresh() { context.refreshes++; },
        widgetMembershipFinished(...args) { signals.push(args); }
    });
    context.root = context;
    for (const name of ["settleDiscovery", "settleWrite", "enqueue", "nextWrite"])
        vm.runInContext(source.match(new RegExp("^    function " + name + "\\([^]*?^    }", "m"))[0], context);
    return { context, later, signals };
}

const good = JSON.stringify({ plugins: [{ id: "example.good", enabled: true }],
    widgets: [{ key: "example.good" }], bar: { position: "top" } });

test("valid A -> invalid -> restored A clears discovery health without recreating plugins", () => {
    const { context: h } = harness();
    h.settleDiscovery(0, good, false);
    const plugins = h.plugins, widgets = h.widgets, bar = h.barConfig;
    for (const bad of ["invalid json", "null", "{}", '{"error":"invalid registry","plugins":[]}']) {
        h.settleDiscovery(0, bad, false);
        assert.ok(h.discoveryError);
        assert.equal(h.lastResult, good);
        assert.equal(h.plugins, plugins);
        assert.equal(h.widgets, widgets);
        assert.equal(h.barConfig, bar);
        h.settleDiscovery(0, good, false);
        assert.equal(h.discoveryError, "");
        assert.equal(h.plugins, plugins, "unchanged successful bytes preserve runtime objects");
    }
});

test("timeout or process failure cannot adopt output; identical successful retry recovers", () => {
    const { context: h } = harness();
    h.settleDiscovery(0, good, false);
    const plugins = h.plugins;
    for (const [code, timedOut] of [[-1, false], [2, false], [0, true]]) {
        h.settleDiscovery(code, '{"plugins":[]}', timedOut);
        assert.ok(h.discoveryError);
        assert.equal(h.plugins, plugins);
        h.settleDiscovery(0, good, false);
        assert.equal(h.discoveryError, "");
        assert.equal(h.plugins, plugins);
    }
});

test("successful scans preserve write failures, and queued edits advance after lock timeout", () => {
    const { context: h, later, signals } = harness();
    h.settleDiscovery(0, good, false);
    const first = ["python3", "user-plugins.py", "configure-widget", "example.good", '{"enabled":false}'];
    const second = ["python3", "user-plugins.py", "set", "example.good", "answer", "42"];
    h.enqueue(first);
    h.enqueue(second);
    assert.equal(h.pendingWrites.length, 1);
    h.writer.running = false;
    h.settleWrite(2, first, "Plugin preferences are busy; retry.");
    assert.equal(h.mutationError, "Plugin preferences are busy; retry.");
    assert.deepEqual(signals[0], ["example.good", false, false, h.mutationError]);
    h.settleDiscovery(0, good, false);
    assert.equal(h.discoveryError, "");
    assert.equal(h.mutationError, "Plugin preferences are busy; retry.");
    later.shift()();
    assert.equal(h.writer.running, true);
    assert.equal(h.pendingWrites.length, 0);
    assert.equal(h.writer.command, second);
    h.writer.running = false;
    h.settleWrite(0, second, "");
    assert.equal(h.mutationError, "");
    later.shift()();
    assert.equal(h.writer.running, false);
    assert.equal(h.refreshes, 2);
});

test("silent nonzero and launch failures produce actionable mutation errors without erasing discovery errors", () => {
    const { context: h } = harness();
    h.settleDiscovery(0, "broken", false);
    const discoveryError = h.discoveryError;
    for (const code of [-1, 2]) {
        h.settleWrite(code, ["python3", "user-plugins.py", "set"], "");
        assert.ok(h.mutationError);
        assert.equal(h.discoveryError, discoveryError);
    }
    h.settleWrite(0, ["python3", "user-plugins.py", "set"], "");
    assert.equal(h.mutationError, "");
    assert.equal(h.discoveryError, discoveryError);
});
