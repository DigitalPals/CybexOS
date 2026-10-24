// Firmware is explicitly reviewed outside the Nix generation transaction.
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { load, shellDir } = require("./shell.cjs");

test("desktop firmware action opens the confirmation flow without applying a Nix update", () => {
    const source = fs.readFileSync(path.join(shellDir, "Common/Updates.qml"), "utf8");
    const method = source.match(/function openFirmware\(\) \{[^\n]+\}/)[0];
    const calls = [];
    vm.runInNewContext(method + "; openFirmware();", {
        Quickshell: { execDetached: command => calls.push(Array.from(command)) }
    });
    assert.deepEqual(calls, [["cybexos-apps", "terminal", "--hold", "--", "cybexos-firmware-update", "interactive"]]);
    const panel = fs.readFileSync(path.join(shellDir, "Popovers/UpdatesPopover.qml"), "utf8");
    assert.match(panel, /onTriggered:\s*Updates\.openFirmware\(\)/);
    assert.match(panel, /Firmware changes are not reverted by a system rollback/);
});

test("launcher routes firmware to explicit review and describes Nix source checking accurately", () => {
    const actions = load("LauncherProviders.js").BUILTIN_ACTIONS;
    const firmware = actions.find(action => action.id === "firmware-update");
    assert.deepEqual(firmware.command, ["cybexos-apps", "terminal", "--hold", "--", "cybexos-firmware-update", "interactive"]);
    assert.match(firmware.subtitle, /confirm installation separately/);
    assert.doesNotMatch(actions.find(action => action.id === "updates-check").subtitle, /firmware/i);
});
