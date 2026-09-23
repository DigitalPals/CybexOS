const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { shellDir, load } = require("./shell.cjs");

const H = load("SettingsHelpers.js");
const repoRoot = path.resolve(shellDir, "../../../..");
const generator = path.join(shellDir, "scripts/hypridle-config.py");
const resolver = path.join(repoRoot, "assets/scripts/cybexos-runtime");
const template = path.join(repoRoot, "roles/desktop/templates/hypridle.conf.j2");
const action = "/usr/local/libexec/cybexos-session-action";

function read(relative) {
    return fs.readFileSync(path.join(shellDir, relative), "utf8");
}

function scratch(t) {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), "cybexos-idle."));
    t.after(() => fs.rmSync(root, { recursive: true, force: true }));
    return root;
}

function render(t, settings) {
    const file = path.join(scratch(t), "shell.json");
    if (settings !== undefined)
        fs.writeFileSync(file, typeof settings === "string" ? settings : JSON.stringify(settings));
    const result = spawnSync("python3", [generator, file, action], { encoding: "utf8" });
    assert.equal(result.status, 0, result.stderr);
    return result.stdout;
}

test("idle timeouts default to the vendor hypridle values and validate choices", () => {
    const d = H.defaults();
    assert.equal(d.idleLockMins, 5);
    assert.equal(d.idleScreenOffMins, 10);
    // A laptop left idle on battery suspends; mains power keeps it awake.
    assert.equal(d.idleSuspendMins, 30);
    assert.equal(d.idleSuspendBatteryOnly, true);
    assert.equal(H.merge({ idleLockMins: 7 }).idleLockMins, 5);
    assert.equal(H.merge({ idleLockMins: 0 }).idleLockMins, 0);
    assert.equal(H.merge({ idleScreenOffMins: "15" }).idleScreenOffMins, 10);
    assert.equal(H.merge({ idleSuspendMins: 120 }).idleSuspendMins, 120);
    assert.equal(H.merge({ idleSuspendBatteryOnly: 1 }).idleSuspendBatteryOnly, true);
    // A stored Never stays Never: saved files hold every key, so an untouched
    // 0 cannot be told from a chosen one.
    assert.equal(H.merge({ v: H.VERSION, idleSuspendMins: 0 }).idleSuspendMins, 0);
    assert.equal(H.merge({ v: H.VERSION, idleSuspendBatteryOnly: false })
        .idleSuspendBatteryOnly, false);
});

test("the generator accepts exactly the shell's idle choices", () => {
    const source = fs.readFileSync(generator, "utf8");
    const tuple = values => "(" + values.join(", ") + ")";
    assert.ok(source.includes(`"idleLockMins": ${tuple(H.IDLE_LOCK_MINS)}`));
    assert.ok(source.includes(`"idleScreenOffMins": ${tuple(H.IDLE_SCREEN_OFF_MINS)}`));
    assert.ok(source.includes(`"idleSuspendMins": ${tuple(H.IDLE_SUSPEND_MINS)}`));
    const d = H.defaults();
    for (const key of ["idleLockMins", "idleScreenOffMins", "idleSuspendMins"])
        assert.ok(source.includes(`"${key}": ${d[key]},`), key);
    assert.ok(source.includes(`"idleSuspendBatteryOnly": ${d.idleSuspendBatteryOnly ? "True" : "False"},`));
});

// The rendered listener blocks as rows, in file order.
function listeners(output) {
    return output.split("\n\n").filter(block => block.startsWith("listener {")).map(block => {
        const field = name => block.match(new RegExp(`^  ${name} = (.*)$`, "m"))?.[1] ?? "";
        return { timeout: Number(field("timeout")), condition: field("condition_cmd"),
            retry: field("condition_retry"), onTimeout: field("on-timeout"),
            onResume: field("on-resume") };
    });
}

test("default settings render the vendor hypridle.conf byte for byte", t => {
    const vendor = fs.readFileSync(template, "utf8");
    assert.equal(render(t, undefined), vendor);
    assert.equal(render(t, {}), vendor);
    assert.equal(render(t, "[1, 2]"), vendor);
    assert.equal(render(t, { idleLockMins: true, idleScreenOffMins: 7 }), vendor);
});

test("chosen timeouts render in seconds and Never drops the listener", t => {
    const output = render(t, { idleLockMins: 0, idleScreenOffMins: 2,
        idleSuspendMins: 30, idleSuspendBatteryOnly: true });
    assert.doesNotMatch(output, /on-timeout = systemctl --user start/);
    assert.match(output, /timeout = 120\n  on-timeout = hyprctl eval .*"off"/);
    assert.deepEqual(listeners(output).find(row => row.timeout === 1800), {
        timeout: 1800, condition: `${action} on-battery`, retry: "60",
        onTimeout: `${action} idle-suspend on-battery`, onResume: "" });
    assert.match(output, /lock_cmd = systemctl --user start cybexos-session-lock\.service/);
    // Suspend waits for the lock screen whatever the timeouts are.
    const general = output.slice(0, output.indexOf("\n}\n") + 3);
    assert.match(general, /^general \{\n[\s\S]*\n  inhibit_sleep = 3\n\}\n$/);

    const always = render(t, { idleSuspendMins: 60, idleSuspendBatteryOnly: false });
    assert.match(always, new RegExp(`timeout = 3600\\n  on-timeout = ${action} idle-suspend\\n`));
    assert.match(always, /timeout = 300\n/);
});

test("a locked screen goes dark a minute after the last input", t => {
    const lockedOff = settings => listeners(render(t, settings))
        .filter(row => row.condition === "hyprctl locked | grep -qx true");

    // A manual lock at 60 s and the five-minute idle lock at 360 s; the
    // unlocked screen-off listener remains at ten minutes, before suspend.
    const rows = listeners(render(t, {}));
    assert.deepEqual(rows.map(row => row.timeout), [60, 300, 360, 600, 1800]);
    const defaults = lockedOff({});
    assert.deepEqual(defaults.map(row => row.timeout), [60, 360]);
    for (const row of defaults) {
        assert.match(row.onTimeout, /^hyprctl eval .*dpms\(\{ action = "off" \}\)/);
        assert.match(row.onResume, /^hyprctl eval .*dpms\(\{ action = "on" \}\)/);
        assert.equal(row.retry, "", "an unlocked idle stretch is not polled");
    }

    assert.deepEqual(lockedOff({ idleLockMins: 0 }).map(row => row.timeout), [60]);
    // Listeners at or after the screen-off timeout would add nothing.
    assert.deepEqual(lockedOff({ idleLockMins: 10, idleScreenOffMins: 10 })
        .map(row => row.timeout), [60]);
    assert.deepEqual(lockedOff({ idleScreenOffMins: 1 }), []);
    // Never turning the screen off applies to the lock screen too.
    assert.ok(listeners(render(t, { idleScreenOffMins: 0 }))
        .every(row => !/dpms/.test(row.onTimeout)));

    const late = listeners(render(t, { idleLockMins: 1, idleScreenOffMins: 5 }));
    assert.deepEqual(late.map(row => row.timeout), [60, 60, 120, 300, 1800]);
    assert.equal(late[0].onTimeout, "systemctl --user start cybexos-session-lock.service");
});

function resolverFixture(t) {
    const root = scratch(t);
    const config = path.join(root, "config");
    const data = path.join(root, "data");
    const run = path.join(root, "run");
    const runtime = path.join(data, "cybexos/runtime");
    fs.mkdirSync(path.join(config, "cybexos/hypr"), { recursive: true });
    fs.mkdirSync(path.join(runtime, "hypr"), { recursive: true });
    fs.mkdirSync(path.join(runtime, "quickshell/scripts"), { recursive: true });
    fs.mkdirSync(run, { mode: 0o700 });
    fs.copyFileSync(template, path.join(runtime, "hypr/hypridle.conf"));
    fs.copyFileSync(generator, path.join(runtime, "quickshell/scripts/hypridle-config.py"));
    const hypridle = path.join(root, "hypridle");
    fs.writeFileSync(hypridle, "#!/usr/bin/env bash\nprintf '%s\\n' \"$@\"\n", { mode: 0o755 });
    const script = path.join(root, "cybexos-runtime");
    fs.writeFileSync(script, fs.readFileSync(resolver, "utf8")
        .replace("exec /usr/bin/hypridle", `exec ${hypridle}`));
    return {
        config: path.join(config, "cybexos"),
        runtime,
        run,
        exec() {
            const result = spawnSync("bash", [script, "exec", "hypridle"], {
                encoding: "utf8",
                env: { ...process.env, XDG_CONFIG_HOME: config, XDG_DATA_HOME: data,
                    XDG_RUNTIME_DIR: run }
            });
            assert.equal(result.status, 0, result.stderr);
            return { config: result.stdout.trim().split("\n")[1], stderr: result.stderr };
        }
    };
}

test("the runtime resolver starts hypridle with the rendered shell timeouts", t => {
    const f = resolverFixture(t);
    fs.writeFileSync(path.join(f.config, "shell.json"), JSON.stringify({ idleLockMins: 15 }));
    const started = f.exec();
    assert.equal(started.config, path.join(f.run, "cybexos/hypridle.conf"));
    assert.match(fs.readFileSync(started.config, "utf8"), /timeout = 900\n/);
});

test("a user hypridle.conf wins and a failed render falls back to the vendor file", t => {
    const f = resolverFixture(t);
    fs.writeFileSync(path.join(f.config, "shell.json"), JSON.stringify({ idleLockMins: 15 }));
    const user = path.join(f.config, "hypr/hypridle.conf");
    fs.writeFileSync(user, "general {}\n");
    assert.equal(f.exec().config, user);
    fs.rmSync(user);

    fs.writeFileSync(path.join(f.config, "shell.json"), "{ not json");
    const fallback = f.exec();
    assert.equal(fallback.config, path.join(f.runtime, "hypr/hypridle.conf"));
    assert.match(fallback.stderr, /using defaults/);
    assert.deepEqual(fs.readdirSync(path.join(f.run, "cybexos")), []);
});

test("saved idle changes restart hypridle and the power drawer links to them", () => {
    const settings = read("Common/Settings.qml");
    const sysinfo = read("Common/SysInfo.qml");
    const system = read("Settings/SystemPage.qml");
    const power = read("Popovers/Drawer/DrawerPower.qml");

    for (const key of ["idleLockMins", "idleScreenOffMins", "idleSuspendMins",
            "idleSuspendBatteryOnly"]) {
        assert.match(settings, new RegExp(`on${key[0].toUpperCase()}${key.slice(1)}Changed: scheduleSave\\(\\)`));
        assert.match(system, new RegExp(`settingKey: "${key}"`));
    }
    assert.match(sysinfo, /"systemctl", "--user", "try-restart", "hypridle\.service"/);
    assert.match(sysinfo, /onLastPersistedTextChanged/);
    assert.match(sysinfo, /SettingsHelpers\.parse\(Settings\.lastPersistedText\)/);
    assert.match(system, /SysInfo\.idleUserConfig/);
    // hypridle keeps retrying the battery condition until the next input, so
    // an idle laptop unplugged after the timeout still suspends.
    assert.match(system, /description: "Waits while plugged in; suspends once unplugged"/);
    assert.match(power, /Settings\.showSetting\("system", "idleLockMins"/);
    assert.doesNotMatch(power, /gnome-control-center/);
});
