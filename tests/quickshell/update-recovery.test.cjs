const test = require("node:test");
const assert = require("node:assert/strict");
const { load } = require("./shell.cjs");
const H = load("UpdatesHelpers.js");
const available = { upstream: { state: "available", available: "new revision" }, cybexos: { state: "unavailable" } };

test("progress distinguishes compilation from measured downloads and handles old workers", () => {
    const deployment = {state: "building", progress: {schema: 1, active: true, step: "downloading",
        downloads: {doneBytes: 25e6, expectedBytes: 100e6, active: 2, totalKnown: true},
        builds: {done: 3, expected: 9, active: 0}, components: []}};
    let result = H.preparation(deployment);
    assert.equal(result.label, "Downloading packages");
    assert.equal(result.fraction, 0.25);
    deployment.progress.builds.active = 1;
    deployment.progress.components = ["window-manager"];
    result = H.preparation(deployment);
    assert.equal(result.label, "Compiling window manager");
    assert.equal(result.fraction, -1, "download bytes are not compilation completion");
    deployment.state = "validating";
    assert.equal(H.preparation(deployment).label, "Checking compatibility");
    assert.equal(H.preparation(deployment).fraction, -1);
    assert.equal(H.preparation({state:"discovering"}).label, "Preparing update sources");
    assert.equal(H.preparation({state:"building"}).fraction, -1);
});

test("unknown totals and malformed telemetry never produce a fake percentage or private label", () => {
    for (const progress of [null, {}, {schema:1, active:true, step:"secret module", components:["private url"],
        downloads:{active:1, doneBytes:10, expectedBytes:100}}, {schema:1, active:true, downloads:{active:1,
        doneBytes:200, expectedBytes:100, totalKnown:true}}, {schema:1, active:true,
        downloads:{active:1, doneBytes:-1, expectedBytes:NaN, totalKnown:true}, builds:{active:Infinity}}]) {
        const result = H.preparation({state:"building", progress});
        assert.equal(result.fraction, -1);
        assert.doesNotMatch(result.label, /private|secret/);
    }
    assert.equal(H.elapsed(294), "4:54");
    assert.equal(H.elapsed(3661), "1:01:01");
    assert.equal(H.elapsed(-1), "0:00");
    assert.equal(H.downloadSize(25e6), "25.0 MB");
});

test("source scope includes only confirmed and explicitly selected updates", () => {
    assert.equal(H.scope(available, ["upstream", "cybexos"]), "upstream");
    assert.equal(H.scope(available, ["cybexos"]), "");
    const both = { ...available, cybexos: { state: "available", available: "1.1.0" } };
    assert.equal(H.scope(both, ["upstream", "cybexos"]), "both");
    assert.equal(H.scope(both, ["cybexos"]), "cybexos");
});

test("an unpublished vendor channel is neutral and leaves NixOS updates selectable", () => {
    const sources = { ...available, cybexos: {state: "unpublished", installed: "1.0.0-beta.7"} };
    assert.equal(H.validSources(sources), true);
    assert.equal(H.scope(sources, ["upstream", "cybexos"]), "upstream");
    assert.equal(H.capabilities({state: "idle"}, false, true, H.scope(sources, ["upstream"])).prepare, true);
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

test("finished failures can be dismissed; a pending generation cannot", () => {
    for (const state of ["failed", "interrupted", "rolled-back"])
        assert.equal(H.capabilities({ state, transaction: "id" }, false, true, "").discard, true, state);
    for (const state of ["awaiting-boot", "awaiting-login", "recovery-failed", "done", "idle"])
        assert.equal(H.capabilities({ state, transaction: "id" }, false, true, "").discard, false, state);
});

const base = { statusLoaded: true, sourcesLoaded: true, hasUpdates: false, error: "", state: "idle",
    request: {}, automatic: { prepare: true, confirm: true } };
const page = values => H.page({ ...base, ...values });

test("Software Update shows one page per worker state, ahead of discovery", () => {
    assert.equal(page({ statusLoaded: false }), "checking");
    assert.equal(page({ statusLoaded: false, statusError: "no helper" }), "problem");
    assert.equal(page({ sourcesLoaded: false }), "checking");
    assert.equal(page({}), "current");
    assert.equal(page({ state: "done" }), "current");
    assert.equal(page({ hasUpdates: true }), "available");
    assert.equal(page({ hasUpdates: true, state: "done" }), "available", "a later update follows completed history");
    for (const state of ["discovering", "building", "validating"])
        assert.equal(page({ state, hasUpdates: true }), "preparing");
    assert.equal(page({ state: "ready", sourcesLoaded: false }), "ready", "a prepared update survives unknown discovery");
    assert.equal(page({ state: "activating" }), "installing");
    assert.equal(page({ state: "awaiting-boot", hasUpdates: true }), "restart");
    assert.equal(page({ state: "recovering" }), "recovering");
    assert.equal(page({ state: "unavailable" }), "unavailable");
    for (const state of ["failed", "interrupted", "stale", "rolled-back", "recovery-failed"])
        assert.equal(page({ state, hasUpdates: true }), "problem", state);
    assert.equal(page({ error: "offline" }), "problem");
    assert.equal(page({ error: "offline", hasUpdates: true }), "available", "a reachable update outranks another source's error");
});

test("queued requests show their action before the worker reports a phase", () => {
    assert.equal(page({ request: { state: "queued", action: "stage" } }), "preparing");
    assert.equal(page({ state: "ready", request: { state: "queued", action: "apply" } }), "installing");
    assert.equal(page({ state: "awaiting-login", request: { state: "running", action: "confirm" } }), "finishing");
    assert.equal(page({ state: "recovery-failed", request: { state: "queued", action: "rollback" } }), "recovering");
    assert.equal(page({ state: "ready", request: { state: "queued" }, requestAction: "apply" }), "installing");
    assert.equal(page({ state: "ready", request: { state: "queued", action: "discard" } }), "ready");
    assert.equal(page({ state: "ready", request: { state: "failed", action: "apply" } }), "ready");
});

test("a trial boot is confirmed automatically unless that failed or is switched off", () => {
    assert.equal(page({ state: "awaiting-login" }), "finishing");
    assert.equal(page({ state: "awaiting-login", automatic: { prepare: true, confirm: false } }), "confirm");
    assert.equal(page({ state: "awaiting-login", automatic: undefined }), "confirm", "an older status asks");
    const failed = { state: "failed", action: "confirm", error: "Hyprland health failed" };
    assert.equal(page({ state: "awaiting-login", request: failed }), "confirm");
    assert.equal(H.confirmFailed("awaiting-login", failed), true);
    assert.equal(H.confirmFailed("awaiting-login", { ...failed, action: "stage" }), false);
    assert.equal(H.problem({ statusLoaded: true, state: "rolled-back" }), "rolled-back");
    assert.equal(H.problem({ statusLoaded: true, state: "idle" }), "check");
    assert.equal(H.problem({ statusLoaded: false }), "status");
});

test("background preparation is requested for each new target, never over a person's work", () => {
    const sources = { upstream: { state: "available", available: "a" }, cybexos: { state: "current", available: "1.0.0" } };
    assert.equal(H.targetKey(sources, "lock"), JSON.stringify(["lock", "a", ""]));
    assert.notEqual(H.targetKey(sources, "lock"), H.targetKey(sources, "other lock"));
    assert.equal(H.autoPrepare(true, { prepare: true }, "idle", false), true);
    assert.equal(H.autoPrepare(true, { prepare: true }, "done", false), true);
    assert.equal(H.autoPrepare(true, { prepare: false }, "idle", false), false);
    assert.equal(H.autoPrepare(false, { prepare: true }, "idle", false), false);
    assert.equal(H.autoPrepare(true, { prepare: true }, "idle", true), false);
    for (const state of ["ready", "stale", "failed", "rolled-back", "awaiting-boot", "building"])
        assert.equal(H.autoPrepare(true, { prepare: true }, state, false), false, state);
});

test("versions read as people expect: NixOS builds and firmware as dates", () => {
    assert.deepEqual(H.versionParts("nixos", "26.05.20261024.abcdef1"), { text: "26.05", date: "2026-10-24" });
    assert.deepEqual(H.versionParts("nixos", "26.11pre.20261024.abcdef1"), { text: "26.11", date: "2026-10-24" });
    assert.deepEqual(H.versionParts("firmware", "20261014"), { text: "", date: "2026-10-14" });
    assert.deepEqual(H.versionParts("tool", "0-unstable-2026-10-01"), { text: "", date: "2026-10-01" });
    assert.deepEqual(H.versionParts("kernel", "6.12.58"), { text: "6.12.58", date: "" });
    assert.deepEqual(H.versionParts("tool", "20261399"), { text: "20261399", date: "" }, "not a date");
    assert.deepEqual(H.versionParts("kernel", null), { text: "", date: "" });
});

test("the review groups components, apps and tools, falling back to package changes", () => {
    const highlights = { schema: 1, components: [{ id: "kernel", before: "6.12.55", after: "6.12.58" }],
        apps: [{ name: "firefox", title: "Firefox", icon: "firefox", kind: "updated", before: "1", after: "2" }],
        tools: [], background: 213, sizeChange: 40e6 };
    const review = H.summary({ highlights });
    assert.equal(review.components[0].id, "kernel");
    assert.equal(review.apps[0].title, "Firefox");
    assert.equal(review.background, 213);
    const older = H.summary({ packageChanges: [{ name: "hello", kind: "updated", before: "1", after: "2", oldPath: "/nix/store/x" },
        { name: "same", kind: "rebuilt", before: "1", after: "1" }] });
    assert.deepEqual(older.tools, [{ name: "hello", kind: "updated", before: "1", after: "2" }]);
    assert.deepEqual(H.summary({}).components, []);
    for (const id of Object.keys(H.COMPONENTS))
        assert.ok(H.component(id).label && H.component(id).detail && H.component(id).glyph, id);
    assert.equal(H.component("unknown").label, "unknown");
});

test("release notes, sizes and labels stay short and honest", () => {
    assert.deepEqual(H.noteItems("## Highlights\n- One\n* Two\n\n1. Three\n• Four", 3), { items: ["One", "Two", "Three"], more: true });
    assert.deepEqual(H.noteItems(""), { items: [], more: false });
    assert.equal(H.sizeChange(40e6), "+40 MB");
    assert.equal(H.sizeChange(-2.04e9), "\u22122.0 GB");
    assert.equal(H.sizeChange(1000), "", "a rounding error is not a size change");
});
