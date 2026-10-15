// Behavioural fixtures for the capture and clipboard-history scripts: each
// run gets a private PATH of stubs, so nothing touches the real screen,
// clipboard, GPU, camera or other applications' processes.
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
        // A Python stub, for processes that must handle SIGINT: bash cannot
        // trap a signal it was started with ignored, as a background job is.
        pyStub(name, body) {
            fs.writeFileSync(path.join(bin, name), `#!/usr/bin/python3\n${body}\n`, { mode: 0o755 });
        },
        events() {
            const file = path.join(log, "events");
            return fs.existsSync(file) ? fs.readFileSync(file, "utf8").trim().split("\n") : [];
        }
    };
}

function ocrStubs(f, { grimFails = false, tesseract = 'printf "%s" "recognised text"',
    zbarimg = "exit 4" } = {}) {
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
    // zbarimg exits 4 when the image holds no code.
    f.stub("zbarimg", `echo "zbarimg $*" | sed "s| /.*| <image>|" >> "$TEST_LOG/events"
${zbarimg}`);
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
        ["wayfreeze", "slurp", "grim frozen", "zbarimg --quiet --raw <image>", "tesseract thawed"]);
    assert.equal(fs.readFileSync(path.join(f.log, "clipboard"), "utf8"), "recognised text");
    assert.match(notices(f), /Copied text/);
    assert.ok(!fs.existsSync(path.join(f.log, "frozen")), "wayfreeze must not outlive the script");
    assert.deepEqual(fs.readdirSync(path.join(f.env.XDG_RUNTIME_DIR, `screen-ocr-${process.getuid()}`))
        .filter(name => name !== "action.lock"), [], "scratch captures must be removed");
});

test("a QR code in the region is decoded and copied instead of OCR'd", t => {
    const cases = [
        ["https://example.com/a?b=1&c=<x>", /^Copied link from code: https:\/\/example\.com\/a\?b=1&amp;c=&lt;x&gt;$/m],
        ["WIFI:T:WPA;S:Home\\;Net;P:hunter2;;", /^Copied Wi-Fi details for Home;Net$/m],
        ["4006381333931", /^Copied text from code: 4006381333931$/m]
    ];
    for (const [content, notice] of cases) {
        const f = fixture(t);
        fs.writeFileSync(path.join(f.base, "code"), content);
        ocrStubs(f, { zbarimg: `cat "${path.join(f.base, "code")}"; echo` });
        const result = runOcr(f);
        assert.equal(result.status, 0, result.stderr);
        assert.equal(fs.readFileSync(path.join(f.log, "clipboard"), "utf8"), content,
            "the decoded content is copied as it is, never opened");
        assert.match(notices(f), notice);
        assert.doesNotMatch(notices(f), /hunter2/, "a Wi-Fi password is never shown");
        assert.ok(!f.events().some(line => line.startsWith("tesseract")));
        assert.ok(!fs.existsSync(path.join(f.log, "frozen")));
    }
});

test("OCR still works where zbar is missing or fails", t => {
    const f = fixture(t);
    ocrStubs(f, { zbarimg: "exit 1" });
    const result = runOcr(f);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(fs.readFileSync(path.join(f.log, "clipboard"), "utf8"), "recognised text");
    assert.match(notices(f), /Copied text from selection/);
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

// ---- Colour picker -----------------------------------------------------------

function pickerStubs(f, { picked = "[LOG] picking\n#1e1e2e", status = 0, magickFails = false } = {}) {
    fs.writeFileSync(path.join(f.base, "picked"), picked);
    f.stub("hyprpicker", `echo "hyprpicker $*" >> "$TEST_LOG/events"
cat "${path.join(f.base, "picked")}"
exit ${status}`);
    f.stub("wl-copy", `cat > "$TEST_LOG/clipboard"`);
    // ImageMagick is asked for "PNG32:path"; the stub writes that path.
    f.stub("magick", `printf '%s\\n' "$@" > "$TEST_LOG/magick"
${magickFails ? "exit 1" : 'out="${@: -1}"; printf png > "${out#PNG32:}"'}`);
    f.stub("notify-send", `printf '%s\\n' "$@" > "$TEST_LOG/notify"`);
}

function runPicker(f) {
    return spawnSync("bash", [path.join(scripts, "color-picker")], {
        env: f.env, cwd: f.base, encoding: "utf8", timeout: 10_000
    });
}

test("the colour picker copies the hex value and shows it with a swatch", t => {
    const f = fixture(t);
    pickerStubs(f);
    const result = runPicker(f);
    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(f.events(), ["hyprpicker --format=hex --no-fancy"]);
    assert.equal(fs.readFileSync(path.join(f.log, "clipboard"), "utf8"), "#1E1E2E");
    const magick = fs.readFileSync(path.join(f.log, "magick"), "utf8").split("\n");
    assert.ok(magick.includes("#1E1E2E"), "the swatch is filled with the picked colour");
    const notice = fs.readFileSync(path.join(f.log, "notify"), "utf8").split("\n");
    const swatch = path.join(f.env.XDG_RUNTIME_DIR, `color-picker-${process.getuid()}`,
        "swatch-1E1E2E.png");
    assert.ok(notice.includes(`--icon=${swatch}`));
    assert.ok(fs.existsSync(swatch), "the icon must outlive the script for the card");
    assert.ok(notice.includes("Copied #1E1E2E"));
});

test("cancelling the colour picker is quiet", t => {
    for (const [picked, status] of [["", 1], ["", 0], ["not a colour", 0]]) {
        const f = fixture(t);
        pickerStubs(f, { picked, status });
        const result = runPicker(f);
        assert.equal(result.status, 0, result.stderr);
        assert.ok(!fs.existsSync(path.join(f.log, "clipboard")));
        assert.ok(!fs.existsSync(path.join(f.log, "notify")), "Escape needs no notification");
    }
});

test("a colour is still copied and announced when the swatch cannot be drawn", t => {
    const f = fixture(t);
    pickerStubs(f, { magickFails: true });
    const result = runPicker(f);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(fs.readFileSync(path.join(f.log, "clipboard"), "utf8"), "#1E1E2E");
    const notice = fs.readFileSync(path.join(f.log, "notify"), "utf8");
    assert.doesNotMatch(notice, /--icon/);
    assert.match(notice, /Copied #1E1E2E/);
    assert.deepEqual(fs.readdirSync(path.join(f.env.XDG_RUNTIME_DIR,
        `color-picker-${process.getuid()}`)).filter(name => name !== "action.lock"), []);
});

// ---- Screen recording: encoder choice, webcam and lifecycle ------------------

// A /sys/class/drm with one render node per GPU: [vendor, kernel driver].
function drmTree(f, gpus) {
    const root = path.join(f.base, "drm");
    const drivers = path.join(f.base, "drivers");
    fs.mkdirSync(drivers, { recursive: true });
    gpus.forEach(([vendor, driver], index) => {
        const device = path.join(root, `renderD${128 + index}`, "device");
        fs.mkdirSync(device, { recursive: true });
        fs.writeFileSync(path.join(device, "vendor"), vendor + "\n");
        fs.mkdirSync(path.join(drivers, driver), { recursive: true });
        fs.symlinkSync(path.join(drivers, driver), path.join(device, "driver"));
    });
    f.env.SCREEN_RECORD_DRM_ROOT = root;
}

// vainfo lists what each node's driver can do: "encode" adds an H.264
// encoding entrypoint, "decode" only the decoding one.
function vainfoStub(f, abilities) {
    const lines = Object.entries(abilities).map(([node, ability]) =>
        `  ${node}) ${ability === "encode"
            ? "printf '      VAProfileH264Main               :\\tVAEntrypointVLD\\n      VAProfileH264Main               :\\tVAEntrypointEncSliceLP\\n'"
            : "printf '      VAProfileH264Main               :\\tVAEntrypointVLD\\n'"} ;;`);
    f.stub("vainfo", `[[ "$1 $2 $3" == "--display drm --device" ]] || exit 9
case "\${4##*/}" in
${lines.join("\n")}
  *) exit 1 ;;
esac`);
}

// The probe treats a command's presence as information, so this run sees
// only the stubs and the few system tools the probe uses: an installed
// vainfo, ffmpeg or gpu-screen-recorder on the machine must not leak in.
function encoder(f) {
    const tools = path.join(f.base, "tools");
    if (!fs.existsSync(tools)) {
        fs.mkdirSync(tools);
        for (const name of ["bash", "cat", "grep", "readlink", "timeout"]) {
            const found = spawnSync("bash", ["-c", `command -v ${name}`], { encoding: "utf8" });
            fs.symlinkSync(found.stdout.trim(), path.join(tools, name));
        }
    }
    const result = spawnSync("bash", [path.join(scripts, "screen-record"), "--encoder"], {
        env: { ...f.env, PATH: `${f.bin}:${tools}` }, cwd: f.base, encoding: "utf8",
        timeout: 20_000
    });
    assert.equal(result.status, 0, result.stderr);
    return result.stdout.trim();
}

const INTEL = ["0x8086", "i915"];
const AMD = ["0x1002", "amdgpu"];
const NVIDIA = ["0x10de", "nvidia"];
const NOUVEAU = ["0x10de", "nouveau"];

test("recording picks hardware encoding the driver offers, else software", t => {
    let f = fixture(t);
    drmTree(f, [INTEL]);
    vainfoStub(f, { renderD128: "encode" });
    assert.equal(encoder(f), "wf-recorder vaapi /dev/dri/renderD128");

    // Fedora's own Mesa: VA-API is there, H.264 encoding is not.
    f = fixture(t);
    drmTree(f, [AMD]);
    vainfoStub(f, { renderD128: "decode" });
    assert.equal(encoder(f), "wf-recorder software");

    // No libva-utils at all.
    f = fixture(t);
    drmTree(f, [AMD]);
    assert.equal(encoder(f), "wf-recorder software");

    f = fixture(t);
    drmTree(f, []);
    vainfoStub(f, {});
    assert.equal(encoder(f), "wf-recorder software");
});

test("on NVIDIA an installed gpu-screen-recorder is preferred", t => {
    // A hybrid laptop with the proprietary driver: gpu-screen-recorder wins
    // even though the integrated GPU could encode.
    let f = fixture(t);
    drmTree(f, [INTEL, NVIDIA]);
    vainfoStub(f, { renderD128: "encode", renderD129: "decode" });
    f.stub("gpu-screen-recorder", "exit 0");
    assert.equal(encoder(f), "gpu-screen-recorder nvenc");

    // Without it, the integrated GPU's VA-API encoder; NVIDIA nodes come last.
    f = fixture(t);
    drmTree(f, [NVIDIA, INTEL]);
    vainfoStub(f, { renderD128: "decode", renderD129: "encode" });
    assert.equal(encoder(f), "wf-recorder vaapi /dev/dri/renderD129");

    // nvidia-vaapi-driver only decodes; NVENC through FFmpeg does the work.
    f = fixture(t);
    drmTree(f, [NVIDIA]);
    vainfoStub(f, { renderD128: "decode" });
    f.stub("ffmpeg", `printf ' V....D h264_nvenc           NVIDIA NVENC H.264 encoder\\n'`);
    assert.equal(encoder(f), "wf-recorder nvenc");

    // Should a VA-API driver on NVIDIA ever encode, it is used like any other.
    f = fixture(t);
    drmTree(f, [NVIDIA]);
    vainfoStub(f, { renderD128: "encode" });
    assert.equal(encoder(f), "wf-recorder vaapi /dev/dri/renderD128");

    // Nouveau: gpu-screen-recorder's NVIDIA path does not apply.
    f = fixture(t);
    drmTree(f, [NOUVEAU]);
    vainfoStub(f, { renderD128: "decode" });
    f.stub("gpu-screen-recorder", "exit 0");
    f.stub("ffmpeg", `printf ' V....D h264_nvenc           NVIDIA NVENC H.264 encoder\\n'`);
    assert.equal(encoder(f), "wf-recorder software");
});

function recorderStubs(t, f, { slurp = "10,20 301x200", cameras = 1, failing = [] } = {}) {
    f.stub("wayfreeze", "while :; do sleep 0.05; done");
    f.stub("slurp", `printf '%s\\n' "${slurp}"`);
    f.stub("notify-send", `printf '%s\\n' "\${@: -1}" >> "$TEST_LOG/notify"`);
    const recorder = `import json, os, signal, sys, time
log = os.environ["TEST_LOG"]
with open(os.path.join(log, "recorders"), "a") as stream:
    stream.write(json.dumps([os.path.basename(sys.argv[0])] + sys.argv[1:]) + "\\n")
if any(flag in sys.argv for flag in ${JSON.stringify(failing)}):
    sys.exit(1)
with open(os.path.join(log, "running"), "w") as stream:
    stream.write(str(os.getpid()))
def stop(*_):
    os.remove(os.path.join(log, "running"))
    sys.exit(0)
signal.signal(signal.SIGINT, stop)
while True:
    time.sleep(0.05)`;
    f.pyStub("wf-recorder", recorder);
    const v4l = path.join(f.base, "video4linux");
    fs.mkdirSync(v4l);
    for (let index = 0; index < cameras; index++)
        fs.mkdirSync(path.join(v4l, `video${index}`));
    f.env.SCREEN_RECORD_V4L_ROOT = v4l;
    f.env.HOME = path.join(f.base, "home");
    t.after(() => {
        const running = path.join(f.log, "running");
        if (fs.existsSync(running)) {
            try {
                process.kill(Number(fs.readFileSync(running, "utf8")), "SIGKILL");
            } catch (error) {
                if (error.code !== "ESRCH")
                    throw error;
            }
        }
    });
    return recorder;
}

function record(f, ...args) {
    return spawnSync("bash", [path.join(scripts, "screen-record"), ...args], {
        env: f.env, cwd: f.base, encoding: "utf8", timeout: 20_000
    });
}

function recorders(f) {
    const file = path.join(f.log, "recorders");
    return fs.existsSync(file)
        ? fs.readFileSync(file, "utf8").trim().split("\n").map(line => JSON.parse(line)) : [];
}

test("a webcam recording publishes its area, and stopping clears it", t => {
    const f = fixture(t);
    recorderStubs(t, f);
    drmTree(f, [INTEL]);
    vainfoStub(f, { renderD128: "encode" });
    const state = path.join(f.env.XDG_RUNTIME_DIR, "screen-record");

    let result = record(f, "--webcam");
    assert.equal(result.status, 0, result.stderr);
    const [run, ...others] = recorders(f);
    assert.deepEqual(others, []);
    assert.deepEqual(run.slice(0, 8), ["wf-recorder", "-g", "10,20 300x200",
        "-c", "h264_vaapi", "-d", "/dev/dri/renderD128", "-f"]);
    assert.match(run[8], /\/Videos\/Screen Recordings\/screen-recording-.*\.mp4$/);
    // The selection is normalised to even dimensions for the encoder.
    assert.equal(fs.readFileSync(path.join(state, "webcam"), "utf8"), "10,20 300x200\n");
    assert.equal(fs.readFileSync(path.join(state, "wf-recorder.pid"), "utf8").trim(),
        fs.readFileSync(path.join(f.log, "running"), "utf8"));
    assert.match(fs.readFileSync(path.join(f.log, "notify"), "utf8"), /with the webcam/);

    result = record(f, "--webcam");
    assert.equal(result.status, 0, result.stderr);
    assert.ok(!fs.existsSync(path.join(f.log, "running")), "the recorder was stopped");
    for (const name of ["webcam", "wf-recorder.pid", "wf-recorder.start-ticks", "output-file"])
        assert.ok(!fs.existsSync(path.join(state, name)), `${name} must be cleared`);
    assert.match(fs.readFileSync(path.join(f.log, "notify"), "utf8"), /Saved to /);
});

test("without a camera a webcam recording records anyway and says so once", t => {
    const f = fixture(t);
    recorderStubs(t, f, { cameras: 0 });
    drmTree(f, []);
    const result = record(f, "--webcam");
    assert.equal(result.status, 0, result.stderr);
    const state = path.join(f.env.XDG_RUNTIME_DIR, "screen-record");
    assert.ok(!fs.existsSync(path.join(state, "webcam")));
    assert.ok(fs.existsSync(path.join(state, "wf-recorder.pid")));
    const notices = fs.readFileSync(path.join(f.log, "notify"), "utf8").trim().split("\n");
    assert.deepEqual(notices.filter(line => /No camera/.test(line)),
        ["No camera found. Recording without the webcam."]);
    assert.deepEqual(recorders(f)[0].slice(0, 3), ["wf-recorder", "-g", "10,20 300x200"]);
    assert.equal(recorders(f)[0].includes("-c"), false, "software encoding as before");
    record(f);
});

test("a hardware encoder that fails to start falls back to software", t => {
    const f = fixture(t);
    recorderStubs(t, f, { failing: ["h264_vaapi"] });
    drmTree(f, [AMD]);
    vainfoStub(f, { renderD128: "encode" });
    const result = record(f);
    assert.equal(result.status, 0, result.stderr);
    const runs = recorders(f);
    assert.equal(runs.length, 2);
    assert.ok(runs[0].includes("h264_vaapi"));
    assert.deepEqual(runs[1], ["wf-recorder", "-g", "10,20 300x200", "-f", runs[0].at(-1)],
        "the same recording, encoded in software");
    const state = path.join(f.env.XDG_RUNTIME_DIR, "screen-record");
    assert.ok(fs.existsSync(path.join(state, "wf-recorder.log.hardware")),
        "the failed attempt's log is kept for diagnosis");
    assert.equal(fs.readFileSync(path.join(state, "wf-recorder.pid"), "utf8").trim(),
        fs.readFileSync(path.join(f.log, "running"), "utf8"));
    record(f);
});

test("gpu-screen-recorder records the selected region and stops like wf-recorder", t => {
    const f = fixture(t);
    const recorder = recorderStubs(t, f);
    f.pyStub("gpu-screen-recorder", recorder);
    drmTree(f, [NVIDIA]);
    let result = record(f);
    assert.equal(result.status, 0, result.stderr);
    const run = recorders(f)[0];
    assert.deepEqual(run.slice(0, 10), ["gpu-screen-recorder", "-w", "region",
        "-region", "300x200+10+20", "-f", "60", "-c", "mp4", "-o"]);
    const pid = Number(fs.readFileSync(path.join(f.log, "running"), "utf8"));
    assert.equal(fs.readFileSync(`/proc/${pid}/comm`, "utf8").trim(), "gpu-screen-reco",
        "the stop path and the menubar know the recorder by this truncated name");
    result = record(f);
    assert.equal(result.status, 0, result.stderr);
    assert.ok(!fs.existsSync(path.join(f.log, "running")));
});

test("screen-record rejects unknown arguments", t => {
    const f = fixture(t);
    for (const args of [["--bogus"], ["region", "window"], ["--encoder", "region"]]) {
        const result = record(f, ...args);
        assert.equal(result.status, 2, args.join(" "));
        assert.match(result.stderr, /usage: screen-record \[--webcam\]/);
    }
});
