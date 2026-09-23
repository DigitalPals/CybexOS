const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { shellDir } = require("./shell.cjs");

const helper = path.join(shellDir, "scripts", "note-title.py");

function fixture() {
    const directory = fs.mkdtempSync(path.join(os.tmpdir(), "qs-note-title-test-"));
    const bin = path.join(directory, "bin");
    fs.mkdirSync(bin);
    return {
        directory,
        bin,
        env: { ...process.env, PATH: `${bin}:/usr/bin:/bin` },
        cleanup() { fs.rmSync(directory, { recursive: true, force: true }); }
    };
}

function executable(base, name, source) {
    const target = path.join(base.bin, name);
    fs.writeFileSync(target, source, { mode: 0o755 });
    return target;
}

function invoke(request, environment) {
    return spawnSync("/usr/bin/python3", [helper], {
        input: `${JSON.stringify(request)}\n`,
        encoding: "utf8",
        env: environment,
        timeout: 5_000,
        maxBuffer: 1024 * 1024
    });
}

function response(result) {
    assert.doesNotThrow(() => JSON.parse(result.stdout), result.stdout + result.stderr);
    return JSON.parse(result.stdout);
}

test("Codex receives a private ephemeral request with the selected model and effort", () => {
    const base = fixture();
    try {
        const log = path.join(base.directory, "codex.json");
        base.env.STUB_LOG = log;
        executable(base, "codex", `#!/usr/bin/python3
import json, os, sys
with open(os.environ["STUB_LOG"], "w", encoding="utf-8") as stream:
    json.dump({"argv": sys.argv[1:], "stdin": sys.stdin.read(),
               "cwd": os.getcwd(), "files": os.listdir(".")}, stream)
print("\\x1b[32m**Résumé du projet**\\x1b[0m")
`);
        const secret = "private body text";
        const result = invoke({
            provider: "codex", model: "gpt-5.6-terra", effort: "high", body: secret
        }, base.env);
        assert.equal(result.status, 0, result.stdout + result.stderr);
        assert.deepEqual(response(result), { ok: true, title: "Résumé du projet" });

        const call = JSON.parse(fs.readFileSync(log, "utf8"));
        assert.deepEqual(call.argv.slice(0, 2), ["exec", "--ephemeral"]);
        for (const flag of ["--ignore-user-config", "--ignore-rules",
            "--skip-git-repo-check", "--sandbox", "--model", "--config"])
            assert.ok(call.argv.includes(flag), flag);
        assert.equal(call.argv[call.argv.indexOf("--sandbox") + 1], "read-only");
        assert.equal(call.argv[call.argv.indexOf("--model") + 1], "gpt-5.6-terra");
        assert.equal(call.argv[call.argv.indexOf("--config") + 1],
            'model_reasoning_effort="high"');
        assert.equal(call.argv.at(-1), "-");
        assert.doesNotMatch(call.argv.join(" "), new RegExp(secret));
        assert.match(call.stdin, new RegExp(secret));
        assert.deepEqual(call.files, [], "the CLI working directory must start empty");
        assert.match(path.basename(call.cwd), /^quickshell-note-title-/);
    } finally {
        base.cleanup();
    }
});

test("Claude runs without tools or persistence and input is capped at 12,000 characters", () => {
    const base = fixture();
    try {
        const log = path.join(base.directory, "claude.json");
        base.env.STUB_LOG = log;
        executable(base, "claude", `#!/usr/bin/python3
import json, os, sys
with open(os.environ["STUB_LOG"], "w", encoding="utf-8") as stream:
    json.dump({"argv": sys.argv[1:], "stdin": sys.stdin.read()}, stream)
print('{"title":"Title: ignored JSON prefix"}')
`);
        const body = "a".repeat(12_000) + "NEVER_SENT";
        const result = invoke({
            provider: "claude", model: "sonnet", effort: "xhigh", body
        }, base.env);
        assert.equal(result.status, 0, result.stdout + result.stderr);
        assert.deepEqual(response(result), { ok: true, title: "ignored JSON prefix" });

        const call = JSON.parse(fs.readFileSync(log, "utf8"));
        for (const flag of ["--print", "--no-session-persistence", "--safe-mode",
            "--restricted", "--tools", "--effort", "--model", "--strict-mcp-config"])
            assert.ok(call.argv.includes(flag), flag);
        assert.equal(call.argv[call.argv.indexOf("--tools") + 1], "");
        assert.equal(call.argv[call.argv.indexOf("--effort") + 1], "xhigh");
        assert.equal(call.argv[call.argv.indexOf("--model") + 1], "sonnet");
        assert.doesNotMatch(call.argv.join(" "), /a{100}/);
        assert.doesNotMatch(call.stdin, /NEVER_SENT/);
        const sentBody = call.stdin.split("<note>\n")[1].split("\n</note>")[0];
        assert.equal(sentBody.length, 12_000);
    } finally {
        base.cleanup();
    }
});

test("missing binaries and CLI failures return bounded actionable envelopes", () => {
    const base = fixture();
    try {
        let result = invoke({
            provider: "codex", model: "gpt-5.6-luna", effort: "none", body: "Body"
        }, base.env);
        assert.notEqual(result.status, 0);
        assert.equal(response(result).code, "unavailable");

        executable(base, "codex", `#!/bin/sh
printf '%s\n' 'authentication required: private body must not be repeated' >&2
exit 7
`);
        result = invoke({
            provider: "codex", model: "gpt-5.6-luna", effort: "none", body: "Body"
        }, base.env);
        assert.equal(response(result).code, "authentication");

        executable(base, "codex", `#!/bin/sh
printf '%s\n' 'unknown model' >&2
exit 8
`);
        result = invoke({
            provider: "codex", model: "gpt-5.6-luna", effort: "none", body: "Body"
        }, base.env);
        assert.equal(response(result).code, "model");

        executable(base, "codex", `#!/bin/sh
printf '%0600d\n' 0 >&2
exit 9
`);
        result = invoke({
            provider: "codex", model: "gpt-5.6-luna", effort: "none", body: "Body"
        }, base.env);
        const generic = response(result);
        assert.equal(generic.code, "cli_error");
        assert.ok(generic.error.length <= 240);
        assert.doesNotMatch(generic.error, /0000000000/,
            "raw CLI output must not be reflected into the UI envelope");
    } finally {
        base.cleanup();
    }
});

test("a timed-out CLI process is killed and reported", () => {
    const base = fixture();
    try {
        executable(base, "claude", `#!/bin/sh
sleep 2
printf '%s\n' 'Too late'
`);
        base.env.CYBEXOS_NOTE_TITLE_TEST_TIMEOUT = "0.1";
        const started = Date.now();
        const result = invoke({
            provider: "claude", model: "fable", effort: "low", body: "Body"
        }, base.env);
        assert.notEqual(result.status, 0);
        assert.equal(response(result).code, "timeout");
        assert.ok(Date.now() - started < 1500, "the process-group timeout must be prompt");
    } finally {
        base.cleanup();
    }
});

test("invalid requests and empty successful output are machine-readable", () => {
    const base = fixture();
    try {
        executable(base, "codex", "#!/bin/sh\nexit 0\n");
        let result = invoke({
            provider: "codex", model: "bad model", effort: "none", body: "Body"
        }, base.env);
        assert.equal(response(result).code, "invalid_model");
        result = invoke({
            provider: "codex", model: "gpt-5.6-luna", effort: "ultra", body: "Body"
        }, base.env);
        assert.equal(response(result).code, "invalid_effort");
        result = invoke({
            provider: "claude", model: "fable", effort: "none", body: "Body"
        }, base.env);
        assert.equal(response(result).code, "invalid_effort");
        result = invoke({
            provider: "codex", model: "gpt-5.6-luna", effort: "none", body: "Body"
        }, base.env);
        assert.equal(response(result).code, "invalid_output");
    } finally {
        base.cleanup();
    }
});
