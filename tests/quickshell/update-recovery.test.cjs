const test = require("node:test");
const assert = require("node:assert/strict");
const { load } = require("./shell.cjs");
const H = load("UpdatesHelpers.js");
const available = { upstream: { state: "available", available: "new revision" }, cybexos: { state: "unavailable" } };

test("source scope includes only confirmed and explicitly selected updates", () => {
    assert.equal(H.scope(available, ["upstream", "cybexos"]), "upstream");
    assert.equal(H.scope(available, ["cybexos"]), "");
    const both = { ...available, cybexos: { state: "available", available: "1.1.0" } };
    assert.equal(H.scope(both, ["upstream", "cybexos"]), "both");
    assert.equal(H.scope(both, ["cybexos"]), "cybexos");
});

test("failed discovery, zero updates and completed history create no update badge", () => {
    for (const state of ["idle", "done", "failed", "interrupted", "ready", "recovery-failed"]) {
        assert.equal(H.indicator(false, state), false, state);
    }
    assert.equal(H.indicator(true, "idle"), true);
    assert.equal(H.indicator(true, "done"), true, "a later confirmed update survives older completed history");
    assert.equal(H.indicator(true, "awaiting-boot"), false);
});

test("a failed recovery blocks preparation and offers explicit restoration", () => {
    const capabilities = H.capabilities({ state: "recovery-failed", transaction: "failed" }, false, true, "upstream");
    assert.equal(H.active("recovery-failed"), false);
    assert.equal(capabilities.prepare, false);
    assert.equal(capabilities.apply, false);
    assert.equal(capabilities.rollback, true);
});

test("ready review cannot be accidentally restaged; apply is bound to its identity", () => {
    const value = { state: "ready", transaction: "id", reviewToken: "token" };
    assert.equal(H.capabilities(value, false, true, "both").prepare, false);
    assert.equal(H.capabilities(value, false, true, "both").apply, true);
    assert.equal(H.capabilities({ state: "ready" }, false, true, "both").apply, false);
    assert.equal(H.capabilities(value, true, true, "both").apply, false);
    assert.equal(H.capabilities(value, false, false, "both").apply, false);
});

test("boot, login and stale preview have separate next steps", () => {
    assert.equal(H.capabilities({ state: "awaiting-boot" }, false, true, "upstream").prepare, false);
    assert.equal(H.capabilities({ state: "awaiting-login" }, false, true, "upstream").confirm, true);
    const stale = H.capabilities({ state: "stale", transaction: "id" }, false, true, "upstream");
    assert.equal(stale.prepare, true);
    assert.equal(stale.apply, false);
    assert.equal(stale.discard, true);
});

test("queued requests and unknown worker liveness block duplicate operations", () => {
    for (const state of ["queued", "running", "unknown"]) assert.equal(H.pending({ state }), true);
    for (const state of ["done", "failed"]) assert.equal(H.pending({ state }), false);
    for (const state of ["discovering", "building", "validating", "activating", "recovering"]) {
        assert.equal(H.capabilities({ state }, false, true, "upstream").prepare, false);
    }
});

test("unknown and malformed helper responses never become a reviewable plan", () => {
    for (const value of [null, {}, {upstream: {}, cybexos: {}}, {upstream: {state: "available"}, cybexos: {state:"current"}}]) {
        assert.equal(!!H.validSources(value), false);
    }
    assert.equal(H.validSources(available), true);
    assert.equal(H.validDeployment({ state: "idle" }), true);
    assert.equal(!!H.validDeployment({ state: "ready" }), false);
    assert.equal(H.validDeployment({ state: "ready", transaction: "a".repeat(32), reviewToken: "b".repeat(64),
        changes: "app: 1 → 2", packageChanges: [] }), true);
});

test("Control Center keeps pending system changes and errors reachable without a badge", () => {
    assert.equal(H.overviewVisible(false, { state: "idle" }, ""), false);
    assert.equal(H.overviewVisible(false, { state: "idle" }, "Failed to check"), true);
    assert.equal(H.overviewVisible(false, { state: "ready" }, ""), true);
    assert.equal(H.overviewVisible(false, { state: "awaiting-login" }, ""), true);
});

test("readable package details distinguish upgrades, additions, removals and rebuilds", () => {
    assert.equal(H.packageChange({kind:"updated",before:"1",after:"2"}), "1 → 2");
    assert.match(H.packageChange({kind:"added",after:"2"}), /New/);
    assert.match(H.packageChange({kind:"removed",before:"1"}), /Removed/);
    assert.match(H.packageChange({kind:"rebuilt",before:"1",after:"1"}), /Rebuilt/);
});
