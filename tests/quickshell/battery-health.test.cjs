const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { shellDir } = require("./shell.cjs");

const helper = path.join(shellDir, "scripts/battery-health");
const singleton = fs.readFileSync(
    path.join(shellDir, "Common/BatteryHealth.qml"), "utf8");
const adapter = fs.readFileSync(helper, "utf8");

function executable(file, source) {
    fs.writeFileSync(file, source, { mode: 0o755 });
}

function fixture(t) {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), "battery-health-"));
    const bin = path.join(root, "bin");
    const calls = path.join(root, "calls");
    fs.mkdirSync(bin);
    t.after(() => fs.rmSync(root, { recursive: true, force: true }));

    executable(path.join(bin, "upower"), `#!/usr/bin/env bash
[[ \${1:-} == --enumerate ]] || exit 2
printf '%s\n' \
  /org/freedesktop/UPower/devices/battery_BAT0 \
  /org/freedesktop/UPower/devices/battery_BAT1 \
  /org/freedesktop/UPower/devices/battery_mouse \
  /org/freedesktop/UPower/devices/DisplayDevice
`);
    executable(path.join(bin, "busctl"), `#!/usr/bin/env bash
set -u
if [[ \${3:-} == get-property ]]; then
  object=\$5 property=\$7
  case \$property in
    Type) printf 'u 2\n' ;;
    PowerSupply)
      [[ \$object == */battery_mouse ]] && printf 'b false\n' || printf 'b true\n'
      ;;
    ChargeThresholdSupported) printf 'b true\n' ;;
    ChargeThresholdEnabled)
      [[ \$object == */battery_BAT1 ]] && printf 'b true\n' || printf 'b false\n'
      ;;
    ChargeStartThreshold)
      [[ \$object == */battery_BAT1 ]] && printf 'u 60\n' || printf 'u 75\n'
      ;;
    ChargeEndThreshold)
      [[ \$object == */battery_BAT1 ]] && printf 'u 85\n' || printf 'u 80\n'
      ;;
    ChargeThresholdSettingsSupported) printf 'u 7\n' ;;
    *) exit 3 ;;
  esac
  exit
fi
if [[ \${4:-} == call ]]; then
  printf '%s\t%s\n' "\$6" "\${10}" >> "\$MOCK_BUSCTL_CALLS"
  exit
fi
exit 2
`);

    return {
        calls,
        env: {
            ...process.env,
            PATH: `${bin}:${process.env.PATH}`,
            MOCK_BUSCTL_CALLS: calls
        }
    };
}

test("battery health reads physical UPower batteries without shell persistence", () => {
    assert.match(adapter, /upower --enumerate/);
    assert.match(adapter, /Type/);
    assert.match(adapter, /PowerSupply/);
    assert.match(adapter, /DisplayDevice/);
    assert.match(adapter, /ChargeThresholdSupported/);
    assert.match(adapter, /ChargeThresholdEnabled/);
    assert.match(adapter, /ChargeStartThreshold/);
    assert.match(adapter, /ChargeEndThreshold/);
    assert.doesNotMatch(adapter, /charge_control_(?:start|end)_threshold/);
    assert.doesNotMatch(adapter, /\/sys\/class\/power_supply/);
    assert.doesNotMatch(singleton, /Settings\.|JsonAdapter|FileView/);
});

test("battery health changes every supported pack through UPower", () => {
    assert.match(adapter, /EnableChargeThreshold b "\$wanted"/);
    assert.match(adapter, /allow-interactive-authorization=yes/);
    assert.match(adapter,
        /\[\[ \$supported == true \]\] \|\| continue[\s\S]{0,360}?EnableChargeThreshold/);
    assert.match(singleton, /function setEnabled\(value\)/);
    assert.match(singleton, /"set", desired \? "true" : "false"/);
    assert.match(singleton, /readonly property bool busy:\s*setProc\.running/);
    assert.match(singleton, /refreshDebounce\.restart\(\)/);
});

test("battery health refreshes only while a visible consumer holds a claim", () => {
    assert.match(singleton, /function acquire\(\)/);
    assert.match(singleton, /function release\(\)/);
    assert.match(singleton, /command:\s*\["upower", "--monitor-detail"\]/);
    // The status poll is a safety net for a monitor that is down, as
    // NetworkStatus's is, not a second source while it is healthy.
    assert.match(singleton,
        /interval:\s*30000\s*running:\s*root\.watchers > 0 && !monitorProc\.running/);
    assert.match(singleton,
        /monitorProc\.running = true;[\s\S]{0,120}?root\.refresh\(\);/,
        "a restarted monitor reads the status it missed");
    assert.match(singleton, /BatteryView\.parseChargeThresholdStatus\(body\)/);
});

test("the adapter ignores aggregate and peripheral batteries", t => {
    const f = fixture(t);
    const result = spawnSync("bash", [helper, "status"], {
        env: f.env, encoding: "utf8"
    });

    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout, [
        "battery\t/org/freedesktop/UPower/devices/battery_BAT0\ttrue\tfalse\t75\t80\t7",
        "battery\t/org/freedesktop/UPower/devices/battery_BAT1\ttrue\ttrue\t60\t85\t7",
        ""
    ].join("\n"));
    assert.doesNotMatch(result.stdout, /DisplayDevice|battery_mouse/);
});

test("the adapter applies one requested policy to every supported pack", t => {
    const f = fixture(t);
    const result = spawnSync("bash", [helper, "set", "true"], {
        env: f.env, encoding: "utf8"
    });

    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(fs.readFileSync(f.calls, "utf8").trim().split("\n"), [
        "/org/freedesktop/UPower/devices/battery_BAT0\ttrue",
        "/org/freedesktop/UPower/devices/battery_BAT1\ttrue"
    ]);
});
