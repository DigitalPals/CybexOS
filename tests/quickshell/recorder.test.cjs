const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { shellDir } = require("./shell.cjs");

test("the recording PID is published last as a verified ready marker", () => {
    const script = fs.readFileSync(path.resolve(__dirname, "../../assets/scripts/screen-record"),
        "utf8");
    const tail = script.slice(script.lastIndexOf("if ! kill -0"));

    const outputAt = tail.indexOf('publish_state "$OUTPUT_FILE_STATE"');
    const stampAt = tail.indexOf('publish_state "$STARTED_AT_STATE"');
    const ticksAt = tail.indexOf('publish_state "$START_TICKS_STATE"');
    const pidAt = tail.indexOf('publish_state "$PID_FILE"');
    assert.ok(outputAt >= 0 && stampAt > outputAt && ticksAt > stampAt
        && pidAt > ticksAt,
        "consumers must not see active before the output path and start time exist");
    assert.match(script, /exec 9>"\$STATE_DIR\/action\.lock"[\s\S]*flock -n 9/,
        "start and stop must share one lock");
    assert.doesNotMatch(script, /pkill slurp/,
        "a recorder action must never kill another program's selector");
    assert.match(script,
        /if kill -0 "\$pid"[\s\S]*recording state was retained[\s\S]*return 2/,
        "a timed-out stop must keep its truthful active marker");
    assert.match(script, /capture_mode=\$\{1:-region\}/,
        "existing keybindings retain region capture as their default");
    assert.match(script, /slurp -o >"\$selection_file"/,
        "screen capture restricts selection to an output");
    assert.match(script, /hyprctl -j clients \| jq -r/);
    assert.match(script, /slurp -r <"\$window_boxes_file"/,
        "window capture restricts selection to compositor-provided boxes");
});

test("the recording indicator validates a marker against the live process", () => {
    const recorder = fs.readFileSync(path.join(shellDir, "Common/Recorder.qml"), "utf8");

    assert.match(recorder, /path: root\.recorderPid > 0 \? "\/proc\/" \+ root\.recorderPid \+ "\/comm"/);
    assert.match(recorder,
        /expectedStartTicks === actualStartTicks/,
        "PID identity must include process start time to reject reuse");
    assert.match(recorder, /path: root\.stateDir \+ "\/wf-recorder\.start-ticks"/);
    assert.match(recorder, /\["region", "window", "screen"\]/);
    assert.match(recorder, /Quickshell\.execDetached\(\[root\.script, selected\]\)/,
        "the configured capture type is passed as one safe argv item");
    assert.match(recorder, /root\.recorderName = "";[\s\S]*root\.recomputeActive\(\)/,
        "a process that dies after startup must clear the indicator on the next poll");
});

test("recording and dictation state is watched, not reloaded on a timer", () => {
    const recorder = fs.readFileSync(path.join(shellDir, "Common/Recorder.qml"), "utf8");
    const dictation = fs.readFileSync(path.join(shellDir, "Common/Dictation.qml"), "utf8");
    const script = fs.readFileSync(path.resolve(__dirname, "../../assets/scripts/screen-record"),
        "utf8");

    // A FileView reload rebuilds its inotify watches; the directory watch
    // already sees files appear, so nothing reloads the watched views
    // on a schedule. The directory must exist for that watch.
    assert.match(recorder,
        /command: \["mkdir", "-p", "-m", "0700", root\.stateDir\]\s*running: true\s*onRunningChanged: \{\s*if \(!running\)\s*root\.refresh\(\);/);
    assert.match(script, /STATE_DIR="\$\{XDG_RUNTIME_DIR:-\/tmp\}\/screen-record"/);
    assert.match(recorder, /\(Quickshell\.env\("XDG_RUNTIME_DIR"\) \|\| "\/tmp"\) \+ "\/screen-record"/,
        "the shell and the script must agree on the state directory");
    // Liveness: only procfs, only while a published PID names a live process.
    assert.match(recorder,
        /id: liveness\s*interval: 4000\s*running: root\.recorderPid > 0 && root\.recorderName !== ""\s*repeat: true\s*onTriggered: procView\.reload\(\)/);
    for (const [label, source] of [["Recorder", recorder], ["Dictation", dictation]])
        assert.doesNotMatch(source, /running: true\s*repeat: true/, `${label} has no unconditional poll`);

    assert.match(dictation, /onLoaded: \{\s*root\.stateMissing = false;/);
    assert.match(dictation, /onLoadFailed: \{\s*root\.stateMissing = true;/);
    assert.match(dictation, /interval: 3000\s*running: root\.available && root\.stateMissing && !Activity\.idle/,
        "without developer tooling there is no daemon to wait for");
});
