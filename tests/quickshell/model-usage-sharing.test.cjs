const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");
const { shellDir } = require("./shell.cjs");

test("shared request channels isolate credentials and count awake consumers", () => {
    const context = vm.createContext({});
    vm.runInContext(fs.readFileSync(path.join(shellDir, "ModelUsage/UsageLogic.js"), "utf8")
        .replace(/^\.pragma library\s*/, ""), context);
    const created = [];
    const factory = { createObject(parent, properties) {
        assert.equal(parent, null);
        const object = { ...properties, stopped: 0, destroyed: 0,
            stop() { this.stopped++; }, destroy() { this.destroyed++; } };
        created.push(object);
        return object;
    } };
    const first = context.acquireBackend("Quota", "old-key", { automaticRefreshEnabled: true }, factory);
    const second = context.acquireBackend("Quota", "old-key", { automaticRefreshEnabled: false }, factory);
    assert.equal(first, second);
    assert.equal(created.length, 1);
    assert.equal(first.automaticRefreshEnabled, true);
    context.updateBackendActivity("Quota", "old-key", false, true);
    context.releaseBackend("Quota", "old-key", true);
    assert.equal(second.stopped, 0);
    assert.equal(second.automaticRefreshEnabled, true);
    context.updateBackendActivity("Quota", "old-key", true, false);
    assert.equal(second.automaticRefreshEnabled, false);
    const changed = context.acquireBackend("Quota", "new-key", { automaticRefreshEnabled: false }, factory);
    assert.notEqual(changed, second);
    context.releaseBackend("Quota", "old-key", false);
    assert.equal(second.stopped, 1);
    assert.equal(second.destroyed, 1);
    context.releaseBackend("Quota", "new-key", false);
    assert.equal(changed.stopped, 1);
});

test("plugin discovery polls quickly only on pages that show its results", () => {
    const qml = fs.readFileSync(path.join(shellDir, "Common/UserPlugins.qml"), "utf8");
    const expression = qml.match(/interval: (Settings\.panelOpen[^\n]+\? 2000 : 300000)/)[1];
    const interval = (panelOpen, page) => vm.runInNewContext(expression, { Settings: { panelOpen, page } });
    for (const page of ["sound", "network", "accounts", "appearance", "security"]) {
        assert.equal(interval(true, page), 300000, page);
    }
    assert.equal(interval(true, "bar"), 2000);
    assert.equal(interval(true, "plugins"), 2000);
    assert.equal(interval(false, "plugins"), 300000);
});
