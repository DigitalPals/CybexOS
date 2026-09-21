const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { shellDir } = require("./shell.cjs");

for (const [refresh, update, expected, calls] of [
    [0, 0, 0, "refresh\nupdate\n"],
    [2, 2, 0, "refresh\nupdate\n"],
    [1, 0, 1, "refresh\n"],
    [0, 1, 1, "refresh\nupdate\n"],
]) {
    test(`firmware installer handles refresh=${refresh}, update=${update}`, t => {
        const root = fs.mkdtempSync(path.join(os.tmpdir(), "firmware-update-"));
        t.after(() => fs.rmSync(root, { recursive: true, force: true }));
        fs.writeFileSync(path.join(root, "fwupdmgr"),
            '#!/bin/bash\nprintf "%s\\n" "$*" >> "$CALLS"\n'
            + 'if [[ $1 == refresh ]]; then exit "$REFRESH_RC"; fi\nexit "$UPDATE_RC"\n',
            { mode: 0o755 });
        const result = spawnSync("bash", [path.join(shellDir, "scripts/firmware-update")], {
            encoding: "utf8",
            env: { ...process.env, PATH: root + ":" + process.env.PATH,
                XDG_RUNTIME_DIR: root, CALLS: path.join(root, "calls"),
                REFRESH_RC: String(refresh), UPDATE_RC: String(update) }
        });
        assert.equal(result.status, expected, result.stderr);
        assert.equal(fs.readFileSync(path.join(root, "calls"), "utf8"), calls);
    });
}
