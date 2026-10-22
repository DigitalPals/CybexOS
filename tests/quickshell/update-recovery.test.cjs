const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { shellDir } = require("./shell.cjs");

test("a failed recovery is a terminal failure with retry controls available", () => {
    const source = fs.readFileSync(path.join(shellDir, "Common/Updates.qml"), "utf8");
    const expression = source.match(/readonly property string runState: ([\s\S]+?)\n    readonly property/)[1];
    assert.equal(vm.runInNewContext(expression, { runActive: false, deployment: { state: "recovery-failed" } }), "failed");
    const active = source.match(/readonly property bool runActive: ([^\n]+)/)[1];
    assert.equal(vm.runInNewContext(active, { deployment: { state: "recovery-failed" } }), false);
});

test("pending failed recovery blocks new previews and keeps explicit rollback usable", () => {
    const panel = fs.readFileSync(path.join(shellDir, "Popovers/UpdatesPopover.qml"), "utf8");
    const preview = panel.match(/enabled: (!Updates\.runActive && [^\n]+)/)[1];
    const Updates = { runActive: false, deployment: { state: "recovery-failed" } };
    assert.equal(vm.runInNewContext(preview, { Updates }), false);
    const recoveryControls = panel.slice(panel.indexOf('label:"Recovery"'));
    assert.match(recoveryControls, /label:"Rollback", action:"rollback"/);
    const enabled = recoveryControls.match(/enabled: ([^\n]+)/)[1];
    assert.equal(vm.runInNewContext(enabled, { Updates }), true);
});
