// Behavioural fixtures for the OCR and clipboard-history scripts: each run
// gets a private PATH of stubs, so nothing touches the real screen, clipboard
// or other applications' processes.
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawn, spawnSync } = require("node:child_process");

const scripts = path.resolve(__dirname, "../../assets/scripts");

function fixture(t) {
    const base = fs.mkdtempSync(path.join(os.tmpdir(), "qs-capture-test-"));
    const bin = path.join(base, "bin");
    const log = path.join(base, "log");
    const runtime = path.join(base, "run");
    for (const directory of [bin, log, runtime])
        fs.mkdirSync(directory);
    const children = [];
    t.after(() => {
        // Children are spawned detached, so the whole stub group (including
        // a stub's own `sleep`) goes with them.
        for (const child of children) {
            try {
                process.kill(-child.pid, "SIGKILL");
            } catch (error) {
                if (error.code !== "ESRCH")
                    throw error;
            }
        }
        fs.rmSync(base, { recursive: true, force: true });
    });
    return {
        base, bin, log, children,
        env: {
            ...process.env,
            PATH: `${bin}:/usr/bin:/bin`,
            XDG_RUNTIME_DIR: runtime,
            TEST_LOG: log
        },
        stub(name, body) {
            // /bin/bash, not env: the process name must stay the stub's own
            // so the OCR script can recognise its slurp by /proc comm.
            fs.writeFileSync(path.join(bin, name), `#!/bin/bash\n${body}\n`, { mode: 0o755 });
        },
        events() {
            const file = path.join(log, "events");
            return fs.existsSync(file) ? fs.readFileSync(file, "utf8").trim().split("\n") : [];
        }
    };
}

function ocrStubs(f, { grimFails = false, tesseract = 'printf "%s" "recognised text"' } = {}) {
    f.stub("wayfreeze", `touch "$TEST_LOG/frozen"
echo wayfreeze >> "$TEST_LOG/events"
trap 'rm -f "$TEST_LOG/frozen"; exit 0' TERM
while :; do sleep 0.02; done`);
    f.stub("slurp", `echo slurp >> "$TEST_LOG/events"
printf '%s\\n' "10,20 300x200"`);
    f.stub("grim", `echo "grim $([ -e "$TEST_LOG/frozen" ] && echo frozen || echo thawed)" >> "$TEST_LOG/events"
${grimFails ? "exit 1" : 'printf png > "${@: -1}"'}`);
    f.stub("tesseract", `echo "tesseract $([ -e "$TEST_LOG/frozen" ] && echo frozen || echo thawed)" >> "$TEST_LOG/events"
${tesseract}`);
    f.stub("wl-copy", `cat > "$TEST_LOG/clipboard"`);
    f.stub("notify-send", `printf '%s\\n' "\${@: -1}" >> "$TEST_LOG/notify"`);
    f.stub("pkill", `echo "pkill $*" >> "$TEST_LOG/events"; exit 1`);
}

function runOcr(f) {
    return spawnSync("bash", [path.join(scripts, "screen-ocr")], {
        env: f.env, cwd: f.base, encoding: "utf8", timeout: 10_000
    });
}

function notices(f) {
    const file = path.join(f.log, "notify");
    return fs.existsSync(file) ? fs.readFileSync(file, "utf8") : "";
}

test("OCR captures while frozen, thaws before recognition, and copies the text", t => {
    const f = fixture(t);
    ocrStubs(f);
    const result = runOcr(f);
    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(f.events(),
        ["wayfreeze", "slurp", "grim frozen", "tesseract thawed"]);
    assert.equal(fs.readFileSync(path.join(f.log, "clipboard"), "utf8"), "recognised text");
    assert.match(notices(f), /Copied text/);
    assert.ok(!fs.existsSync(path.join(f.log, "frozen")), "wayfreeze must not outlive the script");
    assert.deepEqual(fs.readdirSync(path.join(f.env.XDG_RUNTIME_DIR, `screen-ocr-${process.getuid()}`))
        .filter(name => name !== "action.lock"), [], "scratch captures must be removed");
});

test("OCR failures are reported instead of exiting silently", t => {
    let f = fixture(t);
    ocrStubs(f, { grimFails: true });
    let result = runOcr(f);
    assert.equal(result.status, 1);
    assert.match(notices(f), /Could not capture/);
    assert.ok(!f.events().some(line => line.startsWith("tesseract")));
    assert.ok(!fs.existsSync(path.join(f.log, "frozen")));

    f = fixture(t);
    ocrStubs(f, { tesseract: "exit 1" });
    result = runOcr(f);
    assert.equal(result.status, 1);
    assert.match(notices(f), /Text recognition failed/);
    assert.ok(!fs.existsSync(path.join(f.log, "clipboard")));

    f = fixture(t);
    ocrStubs(f, { tesseract: "true" });
    result = runOcr(f);
    assert.equal(result.status, 1);
    assert.match(notices(f), /No text found/);
});

test("a second OCR press cancels only its own region picker", async t => {
    const f = fixture(t);
    ocrStubs(f);
    f.stub("slurp", `echo slurp >> "$TEST_LOG/events"
touch "$TEST_LOG/selecting"
trap 'kill "$child" 2>/dev/null; exit 1' TERM
sleep 10 & child=$!
wait "$child"`);
    // Somebody else's region picker, running under the same name.
    const other = path.join(f.base, "other");
    fs.mkdirSync(other);
    fs.copyFileSync(path.join(f.bin, "slurp"), path.join(other, "slurp"));
    fs.chmodSync(path.join(other, "slurp"), 0o755);
    const foreign = spawn(path.join(other, "slurp"), [], {
        env: { ...f.env, TEST_LOG: other }, cwd: f.base, stdio: "ignore", detached: true
    });
    f.children.push(foreign);

    const first = spawn("bash", [path.join(scripts, "screen-ocr")], { env: f.env, cwd: f.base, stdio: "ignore", detached: true });
    f.children.push(first);
    const firstExit = new Promise(resolve => first.on("exit", code => resolve(code)));
    const deadline = Date.now() + 5_000;
    while (!fs.existsSync(path.join(f.log, "selecting"))) {
        assert.ok(Date.now() < deadline, "the first run never opened its picker");
        await new Promise(resolve => setTimeout(resolve, 20));
    }

    const second = runOcr(f);
    assert.equal(second.status, 0, second.stderr);
    assert.equal(await firstExit, 0);
    assert.ok(!f.events().some(line => /^(grim|tesseract|pkill)/.test(line)),
        "a cancelled selection must not be captured, and nothing is pkill'd");
    assert.equal(foreign.exitCode, null, "another application's slurp must survive");
    assert.ok(!fs.existsSync(path.join(f.log, "frozen")));
});

test("clipboard history skips concealed payloads even when grep stops reading early", t => {
    const f = fixture(t);
    // A long type list after the hint: grep -q exits at the first line, so a
    // piped wl-paste would die of SIGPIPE and pipefail would hide the match.
    f.stub("wl-paste", `printf '%s\\n' x-kde-passwordManagerHint text/plain
for i in $(seq 1 20000); do printf 'application/x-filler-%d\\n' "$i"; done`);
    f.stub("cliphist", `cat > "$TEST_LOG/stored"`);
    const store = path.join(scripts, "clipboard-history-store");
    let result = spawnSync("bash", [store], { env: f.env, input: "hunter2", encoding: "utf8" });
    assert.equal(result.status, 0, result.stderr);
    assert.ok(!fs.existsSync(path.join(f.log, "stored")), "the secret must not reach cliphist");

    f.stub("wl-paste", `printf '%s\\n' text/plain UTF8_STRING`);
    result = spawnSync("bash", [store], { env: f.env, input: "hello", encoding: "utf8" });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(fs.readFileSync(path.join(f.log, "stored"), "utf8"), "hello");
});
