const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { load, shellDir } = require("./shell.cjs");
const H = load("UpdatesHelpers.js");

test("Software Update reviews devices and displays fwupd requests without a terminal action", () => {
    const review = fs.readFileSync(path.join(shellDir, "SoftwareUpdate/ReadyPage.qml"), "utf8");
    assert.match(review, /updateFirmwareDevice/);
    assert.match(review, /Firmware changes cannot be undone/);
    const updates = fs.readFileSync(path.join(shellDir, "Common/Updates.qml"), "utf8");
    assert.doesNotMatch(updates, /openFirmware|firmware-update.*interactive/);
    const view = fs.readFileSync(path.join(shellDir, "SoftwareUpdate/UpdateView.qml"), "utf8");
    assert.match(view, /updateFirmwareRequest/);
    assert.doesNotMatch(view, /Device firmware…|openFirmware/);
});

test("firmware searches lead to the ordinary Software Update application", () => {
    const actions = load("LauncherProviders.js").BUILTIN_ACTIONS;
    assert.equal(actions.some(action => action.id === "firmware-update"), false);
    const update = actions.find(action => action.id === "updates-open");
    assert.deepEqual(update.command, ["cybexos-software-update"]);
    assert.equal(update.keywords.includes("firmware"), true);
});

test("firmware-only discovery uses the normal prepare and install actions", () => {
    const sources = { upstream: { state: "current" }, cybexos: { state: "unpublished" },
        firmware: { state: "available", devices: [{ id: "device", to: "2" }] } };
    assert.equal(H.scope(sources, ["upstream", "cybexos"]), "firmware");
    assert.equal(H.capabilities({state:"idle"}, false, true, "firmware").prepare, true);
    assert.equal(H.capabilities({state:"ready", transaction:"a", reviewToken:"b"}, false, true, "firmware").apply, true);
    sources.upstream = {state:"available", available:"revision"};
    assert.equal(H.scope(sources, ["upstream", "cybexos"]), "upstream");
    assert.notEqual(H.targetKey(sources, "lock"), H.targetKey({...sources, firmware:{devices:[]}}, "lock"));
});

test("firmware progress and restart keep priority over source discovery", () => {
    assert.equal(H.page({statusLoaded:true, state:"firmware", hasUpdates:true}), "installing");
    assert.equal(H.active("firmware"), true);
    for (const state of ["done", "failed", "interrupted"]) {
        const deployment = {state, firmware:{needsReboot:true}};
        assert.equal(H.firmwareRestart(deployment), true);
        assert.equal(H.page({statusLoaded:true, state, hasUpdates:true, firmwareRestart:true}), "restart");
        assert.equal(H.capabilities(deployment, false, true, "firmware").prepare, false);
        assert.equal(H.overviewVisible(false, deployment, ""), true);
    }
});
