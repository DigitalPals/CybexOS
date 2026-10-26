// Firmware is explicitly reviewed outside the Nix generation transaction.
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { load, shellDir } = require("./shell.cjs");

test("system update review keeps firmware outside its install action", () => {
    const panel = fs.readFileSync(path.join(shellDir, "Popovers/UpdatesPopover.qml"), "utf8");
    assert.doesNotMatch(panel, /firmware-update|openFirmware/);
});

test("launcher routes firmware to explicit review and describes Nix source checking accurately", () => {
    const actions = load("LauncherProviders.js").BUILTIN_ACTIONS;
    const firmware = actions.find(action => action.id === "firmware-update");
    assert.deepEqual(firmware.command, ["cybexos-apps", "terminal", "--hold", "--", "cybexos-firmware-update", "interactive"]);
    assert.match(firmware.subtitle, /confirm installation separately/);
    assert.doesNotMatch(actions.find(action => action.id === "updates-check").subtitle, /firmware/i);
});
