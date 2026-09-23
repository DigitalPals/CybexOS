// Discovery cost and failure isolation of scripts/user-plugins.py: the shell
// runs `list --live` on a timer, so a rescan must not rehash every package,
// block on a FIFO, let one broken plugin take the rest down, or accumulate
// code snapshots; and package installs must not hold the registry lock
// across network operations.
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { shellDir } = require("./shell.cjs");

const helper = path.join(shellDir, "scripts", "user-plugins.py");

function fixture() {
    const base = fs.mkdtempSync(path.join(os.tmpdir(), "qs-user-plugins-test-"));
    const packages = path.join(base, "plugins");
    const config = path.join(base, "config");
    const runtime = path.join(base, "runtime");
    fs.mkdirSync(packages);
    const env = {
        ...process.env, HOME: base, CYBEXOS_PLUGIN_ROOT: packages,
        CYBEXOS_USER_CONFIG_ROOT: config, XDG_DATA_HOME: path.join(base, "data"),
        XDG_RUNTIME_DIR: base, PYTHONDONTWRITEBYTECODE: "1"
    };
    function cli(...args) {
        const result = spawnSync("python3", [helper, ...args], { env, encoding: "utf8", timeout: 30000 });
        assert.equal(result.error, undefined, "helper did not finish");
        assert.equal(result.status, 0, result.stderr);
        return result.stdout;
    }
    function plugin(id) {
        const directory = path.join(packages, id);
        fs.mkdirSync(directory);
        fs.writeFileSync(path.join(directory, "manifest.json"), JSON.stringify({
            id, apiVersion: 1, name: id, version: "1", entrypoint: "Widget.qml" }));
        fs.writeFileSync(path.join(directory, "Widget.qml"), "import QtQuick\nItem {}\n");
        cli("enable", id);
        return directory;
    }
    function list() {
        return JSON.parse(cli("list", "--runtime-root", runtime));
    }
    function revisionOf(info, id) {
        const item = info.plugins.find(entry => entry.id === id);
        assert.equal(item.error, "", `unexpected error for ${id}`);
        return path.basename(path.dirname(new URL(item.source).pathname));
    }
    return { base, packages, config, runtime, env, cli, plugin, list, revisionOf,
        cleanup() {
            spawnSync("chmod", ["-R", "u+rwX", base]);
            fs.rmSync(base, { recursive: true, force: true });
        } };
}

function settle() {
    // The helper refuses to remember a fingerprint for a tree changed within
    // the last two seconds (timestamp granularity), so let it age.
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 2200);
}

test("a rescan reuses the remembered fingerprint while stat metadata is unchanged", () => {
    const f = fixture();
    try {
        f.plugin("example.cached");
        settle();
        const first = f.revisionOf(f.list(), "example.cached");
        const cachePath = path.join(f.runtime, ".revisions.json");
        const cache = JSON.parse(fs.readFileSync(cachePath, "utf8"));
        assert.equal(cache.plugins["example.cached"].revision, first);
        // Point the remembered signature at a different snapshot. If the
        // helper rehashed the package it would still answer `first`.
        const fake = "f".repeat(64);
        fs.cpSync(path.join(f.runtime, "example.cached", first),
            path.join(f.runtime, "example.cached", fake), { recursive: true });
        cache.plugins["example.cached"].revision = fake;
        fs.writeFileSync(cachePath, JSON.stringify(cache));
        assert.equal(f.revisionOf(f.list(), "example.cached"), fake,
            "an unchanged stat signature must not rehash package contents");
        // Any content change alters the signature and is hashed again.
        fs.appendFileSync(path.join(f.packages, "example.cached", "Widget.qml"), "// edit\n");
        const edited = f.revisionOf(f.list(), "example.cached");
        assert.notEqual(edited, fake);
        assert.notEqual(edited, first);
    } finally {
        f.cleanup();
    }
});

test("snapshots keep only the current and previously served revision", () => {
    const f = fixture();
    try {
        const directory = f.plugin("example.pruned");
        const widget = path.join(directory, "Widget.qml");
        const revisions = [f.revisionOf(f.list(), "example.pruned")];
        fs.mkdirSync(path.join(f.runtime, "example.pruned", ".snapshot-interrupted"));
        for (const edit of ["// one\n", "// two\n", "// three\n"]) {
            fs.appendFileSync(widget, edit);
            revisions.push(f.revisionOf(f.list(), "example.pruned"));
        }
        assert.equal(new Set(revisions).size, 4);
        assert.deepEqual(fs.readdirSync(path.join(f.runtime, "example.pruned")).sort(),
            revisions.slice(-2).sort(),
            "older revisions and interrupted snapshots are pruned after a new snapshot");
    } finally {
        f.cleanup();
    }
});

test("a FIFO in a package neither blocks discovery nor enters the snapshot", () => {
    const f = fixture();
    try {
        const directory = f.plugin("example.fifo");
        const made = spawnSync("mkfifo", [path.join(directory, "pipe")]);
        assert.equal(made.status, 0);
        const revision = f.revisionOf(f.list(), "example.fifo");
        const snapshot = path.join(f.runtime, "example.fifo", revision);
        assert.ok(fs.existsSync(path.join(snapshot, "Widget.qml")));
        assert.ok(!fs.existsSync(path.join(snapshot, "pipe")));
    } finally {
        f.cleanup();
    }
});

test("one plugin that cannot be snapshotted does not fail the whole listing", {
    skip: process.getuid && process.getuid() === 0 ? "root reads unreadable files" : false
}, () => {
    const f = fixture();
    try {
        f.plugin("example.good");
        const broken = f.plugin("example.unreadable");
        const secret = path.join(broken, "Secret.qml");
        fs.writeFileSync(secret, "import QtQuick\nItem {}\n");
        fs.chmodSync(secret, 0);
        const info = f.list();
        assert.equal(info.error, "");
        assert.ok(f.revisionOf(info, "example.good"));
        const failed = info.plugins.find(entry => entry.id === "example.unreadable");
        assert.match(failed.error, /Could not prepare plugin code/);
        const widget = info.widgets.find(entry => entry.id === "example.unreadable");
        assert.equal(widget.error, failed.error);
    } finally {
        f.cleanup();
    }
});

test("install and update run git clone and fetch without the registry lock", () => {
    const f = fixture();
    try {
        const realGit = spawnSync("sh", ["-c", "command -v git"], { encoding: "utf8" }).stdout.trim();
        const bin = path.join(f.base, "bin");
        const log = path.join(f.base, "git.log");
        fs.mkdirSync(bin);
        fs.writeFileSync(path.join(bin, "git"), `#!/usr/bin/env python3
import fcntl, os, sys
command = next((arg for arg in sys.argv[1:] if arg in ("clone", "fetch")), None)
if command:
    with open(os.environ["TEST_LOCK"], "a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            state = "free"
        except BlockingIOError:
            state = "held"
    with open(os.environ["TEST_LOG"], "a") as out:
        out.write(command + " " + state + "\\n")
os.execv(${JSON.stringify(realGit)}, ["git"] + sys.argv[1:])
`, { mode: 0o755 });
        fs.mkdirSync(f.config, { recursive: true });
        Object.assign(f.env, { PATH: bin + ":" + process.env.PATH,
            TEST_LOCK: path.join(f.config, "plugins.json.lock"), TEST_LOG: log,
            GIT_AUTHOR_NAME: "Test", GIT_AUTHOR_EMAIL: "test@example.invalid",
            GIT_COMMITTER_NAME: "Test", GIT_COMMITTER_EMAIL: "test@example.invalid" });
        const source = path.join(f.base, "source");
        fs.mkdirSync(source);
        const git = (...args) => {
            const result = spawnSync(realGit, ["-C", source, ...args], { env: f.env, encoding: "utf8" });
            assert.equal(result.status, 0, result.stderr);
        };
        git("init", "-q", "-b", "main");
        fs.writeFileSync(path.join(source, "manifest.json"), JSON.stringify({
            id: "example.remote", schemaVersion: 1, name: "Remote", version: "1",
            kinds: ["bar-widget"], entryPoints: { barWidget: "Widget.qml" } }));
        fs.writeFileSync(path.join(source, "Widget.qml"), "import QtQuick\nItem {}\n");
        git("add", ".");
        git("commit", "-q", "-m", "initial");
        assert.equal(f.cli("add", source).trim(), "example.remote");
        const saved = JSON.parse(fs.readFileSync(path.join(f.config, "plugins.json"), "utf8"));
        assert.equal(saved.plugins["example.remote"].enabled, false);
        fs.writeFileSync(path.join(source, "Widget.qml"), "import QtQuick\nItem { width: 2 }\n");
        git("commit", "-q", "-am", "update");
        f.cli("update", "example.remote");
        assert.match(fs.readFileSync(path.join(f.packages, "example.remote", "Widget.qml"), "utf8"), /width: 2/);
        const calls = fs.readFileSync(log, "utf8").trim().split("\n");
        assert.ok(calls.includes("clone free") && calls.includes("fetch free"), calls.join(", "));
        assert.ok(!calls.some(line => line.endsWith(" held")), calls.join(", "));
        assert.ok(!fs.readdirSync(f.packages).some(name => name.startsWith(".")),
            "temporary install/update trees are removed");
    } finally {
        f.cleanup();
    }
});
