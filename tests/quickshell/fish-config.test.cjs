const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const repoDir = path.resolve(__dirname, "../..");
const config = path.join(repoDir, "roles/dotfiles/files/fish-config.fish");
const hasFish = spawnSync("fish", ["--version"]).status === 0;

// conf.d/50-cybexos.fish is sourced by every fish, including `fish -c` from
// scripts and tools. Only the environment belongs there; the prompt, hooks
// and aliases cost six processes per shell and serve only a terminal.
test("the fish config keeps prompt setup out of non-interactive shells", () => {
    const source = fs.readFileSync(config, "utf8");
    const gate = source.indexOf("if status is-interactive");
    assert.ok(gate > 0, "interactive setup must sit behind `status is-interactive`");
    for (const needle of ["fish_add_path", "set -gx EDITOR", "set -gx SCCACHE_DIR"])
        assert.ok(source.indexOf(needle) < gate, `${needle} must stay available to fish -c`);
    for (const needle of ["oh-my-posh init", "zoxide init", "fzf --fish", "direnv hook",
        "POSH_OS_ICON", "alias update="])
        assert.ok(source.indexOf(needle) > gate, `${needle} is interactive-only`);
    assert.doesNotMatch(source, /\bsh -c/, "os-release is read with builtins, once");
});

test("sourcing the fish config spawns nothing unless the shell is interactive",
    { skip: !hasFish && "fish is not installed" }, () => {
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "fish-config-"));
    try {
        const bin = path.join(tmp, "bin");
        const calls = path.join(tmp, "calls.log");
        fs.mkdirSync(bin);
        fs.writeFileSync(calls, "");
        for (const name of ["sh", "oh-my-posh", "zoxide", "fzf", "direnv"])
            fs.writeFileSync(path.join(bin, name),
                `#!/bin/bash\nprintf '%s\\n' "${name}" >>"$FISH_CONFIG_CALLS"\n`,
                { mode: 0o755 });
        const run = interactive => spawnSync("fish",
            ["--no-config", ...(interactive ? ["-i"] : []), "-c", `source ${config}`], {
                encoding: "utf8",
                input: "",
                env: {
                    ...process.env,
                    // fish_add_path writes universal variables under these.
                    HOME: tmp,
                    XDG_CONFIG_HOME: path.join(tmp, "config"),
                    XDG_DATA_HOME: path.join(tmp, "data"),
                    XDG_CACHE_HOME: path.join(tmp, "cache"),
                    PATH: `${bin}:/usr/bin:/bin`,
                    FISH_CONFIG_CALLS: calls,
                },
            });

        const quiet = run(false);
        assert.equal(quiet.status, 0, quiet.stderr);
        assert.equal(fs.readFileSync(calls, "utf8"), "", "fish -c ran prompt setup");

        const terminal = run(true);
        assert.equal(terminal.status, 0, terminal.stderr);
        assert.deepEqual(fs.readFileSync(calls, "utf8").trim().split("\n").sort(),
            ["direnv", "fzf", "oh-my-posh", "zoxide"]);
    } finally {
        fs.rmSync(tmp, { recursive: true, force: true });
    }
});
