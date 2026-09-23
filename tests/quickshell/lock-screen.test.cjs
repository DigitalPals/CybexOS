const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { shellDir } = require("./shell.cjs");

const template = path.resolve(shellDir, "../../templates/hyprlock.conf.j2");

test("the lock screen clock does not spawn a process every second", () => {
    const config = fs.readFileSync(template, "utf8");
    // hyprlock renders $TIME (24-hour HH:MM) itself; cmd[update:1000] forked
    // sh and date every second for as long as the session stayed locked.
    assert.match(config, /^ {2}text = \$TIME$/m);
    for (const [, interval] of config.matchAll(/cmd\[update:(\d+)\]/g))
        assert.ok(Number(interval) >= 60000, `cmd label refreshes every ${interval} ms`);
});
