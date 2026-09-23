const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

// The T3 Code URI handler. A browser sign-in redirect must reach the panel's
// pending loopback listener through the helper in the active shell runtime;
// ~/.config/quickshell no longer exists, and a redirect that misses the helper
// opens the desktop client instead of finishing the panel's sign-in.
const launcher = path.resolve(__dirname,
    "../../roles/dotfiles/templates/t3code-desktop.j2");

function executable(file, source) {
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, source, { mode: 0o755 });
}

function fixture(t, { callbackStatus = 0 } = {}) {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), "t3code-desktop-"));
    t.after(() => fs.rmSync(root, { recursive: true, force: true }));
    const home = path.join(root, "home");
    const bin = path.join(root, "bin");
    const shell = path.join(root, "runtime/quickshell");
    const log = path.join(root, "calls.log");
    executable(path.join(home, ".local/bin/cybexos-runtime"), `#!/usr/bin/env bash
[[ $* == "path quickshell" ]] || exit 2
printf '%s\\n' "$SHELL_RUNTIME"
`);
    executable(path.join(bin, "node"), `#!/usr/bin/env bash
printf 'node %s\\n' "$*" >> "$CALL_LOG"
exit "$CALLBACK_STATUS"
`);
    executable(path.join(root, "data/t3code-nightly/T3-Code-Nightly-x86_64.AppImage"),
        `#!/usr/bin/env bash
printf 'appimage %s\\n' "$*" >> "$CALL_LOG"
`);
    const env = {
        ...process.env,
        HOME: home,
        XDG_CONFIG_HOME: path.join(root, "config"),
        XDG_DATA_HOME: path.join(root, "data"),
        PATH: `${bin}:${process.env.PATH}`,
        SHELL_RUNTIME: shell,
        CALL_LOG: log,
        CALLBACK_STATUS: String(callbackStatus),
    };
    return {
        shell,
        run: args => spawnSync("bash", [launcher, ...args], { env, encoding: "utf8" }),
        calls: () => fs.existsSync(log)
            ? fs.readFileSync(log, "utf8").split("\n").filter(Boolean) : [],
    };
}

test("a pending sign-in redirect reaches the helper in the active runtime", t => {
    const f = fixture(t);
    const uri = "t3code://app/oauth/callback?code=abc";
    const result = f.run([uri]);
    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(f.calls(),
        [`node ${f.shell}/scripts/t3-cloud.mjs oauth-callback ${uri}`],
        "the redirect must not also open the desktop client");
});

test("a redirect with no pending sign-in, and any other URI, open the client", t => {
    const f = fixture(t, { callbackStatus: 1 });
    const uri = "t3code://app/oauth/callback?code=abc";
    assert.equal(f.run([uri]).status, 0);
    assert.deepEqual(f.calls(), [
        `node ${f.shell}/scripts/t3-cloud.mjs oauth-callback ${uri}`,
        `appimage --appimage-extract-and-run --password-store=gnome-libsecret ${uri}`,
    ]);

    const other = fixture(t);
    assert.equal(other.run(["t3code://thread/42"]).status, 0);
    assert.deepEqual(other.calls(), [
        "appimage --appimage-extract-and-run --password-store=gnome-libsecret t3code://thread/42",
    ]);
});
