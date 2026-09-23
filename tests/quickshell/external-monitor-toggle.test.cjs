const test = require("node:test");
const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const net = require("node:net");
const os = require("node:os");
const path = require("node:path");

const repoDir = path.resolve(__dirname, "../..");
const helper = path.join(repoDir,
    "roles/dotfiles/templates/external-monitor-toggle.j2");

function executable(target, body) {
    fs.writeFileSync(target, `#!/usr/bin/env bash\nset -eu\n${body}`);
    fs.chmodSync(target, 0o755);
}

function monitor(name, disabled, description = "") {
    return {
        name,
        description,
        make: description,
        disabled,
        width: name === "eDP-1" ? 2880 : 5120,
        height: name === "eDP-1" ? 1800 : 2880,
    };
}

// A logind PropertiesChanged line as `gdbus monitor` prints it.
const LID_SIGNAL = "/org/freedesktop/login1: org.freedesktop.DBus.Properties."
    + "PropertiesChanged ('org.freedesktop.login1.Manager', {'LidClosed': <false>}, @as [])";

// Scenarios end when the socat stub exits (the helper then exits 75), so a
// gdbus stub must outlive it or the helper stops on the lid stream instead.
async function runScenario({ initialMonitors, socatBody, gdbusBody = "sleep 0.6\n",
    pollSeconds = "30" }) {
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "monitor-toggle-state-"));
    const bin = path.join(tmp, "bin");
    const runtime = path.join(tmp, "runtime");
    const socketDir = path.join(runtime, "hypr", "test-instance");
    const drm = path.join(tmp, "drm");
    const edpDir = path.join(drm, "card0-eDP-1");
    const dpDir = path.join(drm, "card0-DP-1");
    const lid = path.join(tmp, "lid", "LID0");
    const state = path.join(tmp, "monitors.json");
    const calls = path.join(tmp, "calls.log");
    const socket = path.join(socketDir, ".socket2.sock");
    fs.mkdirSync(bin);
    fs.mkdirSync(socketDir, { recursive: true });
    fs.mkdirSync(edpDir, { recursive: true });
    fs.mkdirSync(dpDir, { recursive: true });
    fs.mkdirSync(lid, { recursive: true });
    fs.writeFileSync(path.join(edpDir, "status"), "connected\n");
    fs.writeFileSync(path.join(dpDir, "status"), "disconnected\n");
    fs.writeFileSync(path.join(lid, "state"), "state: closed\n");
    fs.writeFileSync(state, JSON.stringify(initialMonitors));
    fs.writeFileSync(calls, "");

    executable(path.join(bin, "hyprctl"), `
case "\${1:-}" in
  monitors) cat "$MONITOR_TEST_STATE" ;;
  eval|reload) printf '%s\\n' "$*" >>"$MONITOR_TEST_CALLS" ;;
  *) exit 1 ;;
esac
`);
    executable(path.join(bin, "socat"), socatBody);
    executable(path.join(bin, "gdbus"), gdbusBody);

    const server = net.createServer();
    await new Promise((resolve, reject) => {
        server.once("error", reject);
        server.listen(socket, resolve);
    });

    let result;
    try {
        result = spawnSync("bash", [helper], {
            encoding: "utf8",
            timeout: 3000,
            env: {
                ...process.env,
                PATH: `${bin}:/usr/bin:/bin`,
                XDG_RUNTIME_DIR: runtime,
                HYPRLAND_INSTANCE_SIGNATURE: "test-instance",
                EXTERNAL_MONITOR_TOGGLE_DRM_ROOT: drm,
                EXTERNAL_MONITOR_TOGGLE_LID_ROOT: path.join(tmp, "lid"),
                EXTERNAL_MONITOR_TOGGLE_DEBOUNCE_SECONDS: "0.05",
                EXTERNAL_MONITOR_TOGGLE_STABILITY_SECONDS: "0.02",
                EXTERNAL_MONITOR_TOGGLE_POLL_SECONDS: pollSeconds,
                MONITOR_TEST_STATE: state,
                MONITOR_TEST_CALLS: calls,
                MONITOR_TEST_DP_STATUS: path.join(dpDir, "status"),
                MONITOR_TEST_LID_STATE: path.join(lid, "state"),
                MONITOR_TEST_TMP: tmp,
            },
        });
        return {
            result,
            calls: fs.readFileSync(calls, "utf8").trim(),
        };
    } finally {
        await new Promise(resolve => server.close(resolve));
        fs.rmSync(tmp, { recursive: true, force: true });
    }
}

test("dock bursts settle before one closed-lid layout change", async () => {
    const initial = [monitor("eDP-1", true, "Internal")];
    const external = JSON.stringify([
        monitor("eDP-1", false, "Internal"),
        monitor("DP-1", false, "Studio XDR"),
    ]);
    const { result, calls } = await runScenario({
        initialMonitors: initial,
        socatBody: `
sleep 0.02
printf '%s' '${external}' >"$MONITOR_TEST_STATE"
printf 'connected\\n' >"$MONITOR_TEST_DP_STATUS"
printf 'monitoradded>>DP-1\\n'
sleep 0.30
`,
    });

    assert.equal(result.status, 75, result.stderr);
    assert.equal(calls.split("\n").filter(Boolean).length, 1, calls);
    assert.match(calls, /eval .*output = "eDP-1", disabled = true/);
    assert.doesNotMatch(calls, /reload|disabled = false/);
    assert.match(result.stderr, /disabling eDP-1 after external output stabilized/);
});

test("opening the lid enables eDP once without reloading the config", async () => {
    // The 30 s safety poll cannot fire inside this scenario: only the
    // logind signal can have woken the helper.
    const { result, calls } = await runScenario({
        initialMonitors: [monitor("eDP-1", true, "Internal")],
        socatBody: "sleep 0.45\n",
        gdbusBody: `
printf '%s\\n' 'Monitoring signals on object /org/freedesktop/login1 owned by org.freedesktop.login1'
sleep 0.12
printf 'state: open\\n' >"$MONITOR_TEST_LID_STATE"
printf '%s\\n' "${LID_SIGNAL}"
sleep 0.6
`,
    });

    assert.equal(result.status, 75, result.stderr);
    assert.equal(calls.split("\n").filter(Boolean).length, 1, calls);
    assert.match(calls, /eval .*output = "eDP-1".*disabled = false/);
    assert.doesNotMatch(calls, /reload|disabled = true/);
    assert.match(result.stderr, /enabling eDP-1 after stable lid\/output state/);
    assert.match(result.stderr, /Hyprland event stream disconnected/);
});

test("the safety poll still catches a lid change logind never announced", async () => {
    const { result, calls } = await runScenario({
        initialMonitors: [monitor("eDP-1", true, "Internal")],
        pollSeconds: "0.01",
        socatBody: `
sleep 0.12
printf 'state: open\\n' >"$MONITOR_TEST_LID_STATE"
sleep 0.30
`,
    });

    assert.equal(result.status, 75, result.stderr);
    assert.equal(calls.split("\n").filter(Boolean).length, 1, calls);
    assert.match(calls, /eval .*output = "eDP-1".*disabled = false/);
});

test("a closed lid event stream asks systemd to restart the watcher", async () => {
    const { result, calls } = await runScenario({
        initialMonitors: [monitor("eDP-1", false, "Internal")],
        socatBody: "sleep 0.6\n",
        gdbusBody: "exit 1\n",
    });

    assert.equal(result.status, 75, result.stderr);
    assert.match(result.stderr, /logind lid event stream disconnected/);
    assert.equal(calls, "");
});

test("only monitor events reach the helper's read loop", () => {
    const source = fs.readFileSync(helper, "utf8");
    assert.match(source,
        /socat -U - "UNIX-CONNECT:\$socket" \\\n\s*\| grep --line-buffered -E '\^monitor\(added\|removed\)\(v2\)\?>>'/);
    assert.match(source, /gdbus monitor --system --dest org\.freedesktop\.login1/);
    assert.match(source, /poll_seconds=\$\{EXTERNAL_MONITOR_TOGGLE_POLL_SECONDS:-30\}/);
    assert.doesNotMatch(source, /while sleep/, "the safety poll must not fork a sleep per sample");
});
