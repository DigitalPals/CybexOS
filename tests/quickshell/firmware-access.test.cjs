// Firmware is explicitly reviewed outside the Nix generation transaction.
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { load, shellDir } = require("./shell.cjs");

test("system update review keeps firmware outside its install action", () => {
    const review = fs.readFileSync(path.join(shellDir, "SoftwareUpdate/ReadyPage.qml"), "utf8");
    assert.doesNotMatch(review, /firmware-update|openFirmware/);
    // The up-to-date page links to the separate, explicitly confirmed review.
    const updates = fs.readFileSync(path.join(shellDir, "Common/Updates.qml"), "utf8");
    assert.match(updates, /function openFirmware\(\) \{\s*Quickshell\.execDetached\(\["cybexos-apps", "terminal", "--hold", "--", "cybexos-firmware-update", "interactive"\]\)/);
});

test("launcher routes firmware to explicit review and describes Nix source checking accurately", () => {
    const actions = load("LauncherProviders.js").BUILTIN_ACTIONS;
    const firmware = actions.find(action => action.id === "firmware-update");
    assert.deepEqual(firmware.command, ["cybexos-apps", "terminal", "--hold", "--", "cybexos-firmware-update", "interactive"]);
    assert.match(firmware.subtitle, /confirm installation separately/);
    assert.doesNotMatch(actions.find(action => action.id === "updates-check").subtitle, /firmware/i);
});
