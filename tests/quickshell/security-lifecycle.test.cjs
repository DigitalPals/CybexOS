const test = require("node:test");
const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { shellDir } = require("./shell.cjs");

const repoDir = path.resolve(__dirname, "../..");

function readRepo(relative) {
    return fs.readFileSync(path.join(repoDir, relative), "utf8");
}

function readShell(relative) {
    return fs.readFileSync(path.join(shellDir, relative), "utf8");
}

test("desktop-open boundaries accept only HTTP(S) URLs", () => {
    const urls = require(path.join(shellDir, "Common/ExternalUrl.js"));
    assert.equal(urls.safeHttpUrl("https://github.com/o/r/pull/1"),
        "https://github.com/o/r/pull/1");
    assert.equal(urls.safeHttpUrl(" HTTP://example.test/thread "),
        "HTTP://example.test/thread");
    for (const unsafe of [
        "javascript:alert(1)",
        "file:///etc/passwd",
        "data:text/html,pwned",
        "t3code://app/",
        "https://example.test/\nfile:///etc/passwd",
        null,
    ])
        assert.equal(urls.safeHttpUrl(unsafe), "", String(unsafe));

    const facade = readShell("Common/T3Code.qml");
    const thread = readShell("Popovers/T3ThreadPage.qml");
    const cloud = readShell("scripts/t3-cloud.mjs");
    assert.match(facade,
        /function openExternalUrl\(value\)[\s\S]*ExternalUrl\.safeHttpUrl\(value\)[\s\S]*execDetached\(\["xdg-open", url\]\)/);
    assert.doesNotMatch(thread, /execDetached\(\["xdg-open"/,
        "thread and PR payloads must go through the shared URL allow-list");
    assert.ok((thread.match(/T3Code\.openExternalUrl\(/g) || []).length >= 5,
        "every T3 thread, PR, diff, and markdown opener must use the boundary");
    assert.match(cloud,
        /const \{ safeHttpUrl \} = require\("\.\.\/Common\/ExternalUrl\.js"\)/);
    assert.match(cloud,
        /function openBrowser\(url\)[\s\S]*safeHttpUrl\(url\)[\s\S]*spawn\(CLOUD_CONFIG\.browserCommand, \[safeUrl\]/);
});

test("Hyprland session publication is serialized before target activation", () => {
    const autostart = readRepo("roles/desktop/files/autostart.lua");
    const starter = path.join(repoDir, "roles/desktop/files/hyprland-session-start");
    assert.equal((autostart.match(/hl\.exec_cmd/g) || []).length, 1);
    assert.match(autostart, /cybexos-hyprland-session-start/);

    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "hypr-session-test-"));
    try {
        const bin = path.join(tmp, "bin");
        const log = path.join(tmp, "calls.log");
        const runtime = path.join(tmp, "runtime");
        fs.mkdirSync(bin);
        for (const [name, body] of Object.entries({
            systemctl: 'printf "systemctl %s\\n" "$*" >>"$SESSION_TEST_LOG"\n',
            "dbus-update-activation-environment":
                'printf "dbus %s\\n" "$*" >>"$SESSION_TEST_LOG"\n'
                    + '[ "${FAIL_DBUS:-}" != 1 ]\n',
            sleep: 'printf "sleep %s\\n" "$*" >>"$SESSION_TEST_LOG"\n',
        })) {
            const target = path.join(bin, name);
            fs.writeFileSync(target, `#!/bin/sh\nset -eu\n${body}`);
            fs.chmodSync(target, 0o755);
        }
        const result = spawnSync("bash", [starter], {
            encoding: "utf8",
            env: {
                ...process.env,
                PATH: `${bin}:/usr/bin:/bin`,
                SESSION_TEST_LOG: log,
                XDG_RUNTIME_DIR: runtime,
                WAYLAND_DISPLAY: "wayland-1",
                XDG_CURRENT_DESKTOP: "Hyprland",
                HYPRLAND_INSTANCE_SIGNATURE: "instance",
            },
        });
        assert.equal(result.status, 0, result.stderr);
        const calls = fs.readFileSync(log, "utf8").trim().split("\n");
        assert.match(calls[0], /^systemctl --user import-environment /);
        assert.match(calls[1], /^dbus --systemd /);
        assert.equal(calls[2], "systemctl --user start hyprland-session.target");
        assert.equal(calls[3], "sleep 1");
        assert.match(calls[4], /^systemctl --user restart /);

        fs.writeFileSync(log, "");
        const failedImport = spawnSync("bash", [starter], {
            encoding: "utf8",
            env: {
                ...process.env,
                PATH: `${bin}:/usr/bin:/bin`,
                SESSION_TEST_LOG: log,
                FAIL_DBUS: "1",
                XDG_RUNTIME_DIR: runtime,
                WAYLAND_DISPLAY: "wayland-1",
                XDG_CURRENT_DESKTOP: "Hyprland",
                HYPRLAND_INSTANCE_SIGNATURE: "instance",
            },
        });
        assert.notEqual(failedImport.status, 0);
        assert.doesNotMatch(fs.readFileSync(log, "utf8"),
            /start hyprland-session\.target/,
            "a partial environment publication must never start target units");
    } finally {
        fs.rmSync(tmp, { recursive: true, force: true });
    }
});

test("external monitor watcher asks systemd to retry incomplete sessions", () => {
    const helper = readRepo("roles/dotfiles/templates/external-monitor-toggle.j2");
    const desktopTasks = readRepo("roles/desktop/tasks/main.yml");
    assert.match(helper, /command -v "\$command"[\s\S]*exit 75/);
    assert.match(helper, /-z \$\{XDG_RUNTIME_DIR:-\}[\s\S]*exit 75/);
    assert.match(helper, /for _attempt in \{1\.\.12\}[\s\S]*\[\[ -S \$socket \]\]/);
    assert.match(helper,
        /watch_hyprland_events\(\)[\s\S]*socat -U - "UNIX-CONNECT:\$socket"/);
    assert.match(helper, /emit_event socket-closed[\s\S]*exit 75/);
    assert.match(helper,
        /while IFS= read -r -t "\$debounce_seconds"[\s\S]*reconcile_state/);
    assert.doesNotMatch(helper, /upower --monitor|hyprctl reload/,
        "power and monitor events must not race independent config reloads");
    assert.match(desktopTasks,
        /Description=Apply XPS lid and external display policy[\s\S]*StartLimitIntervalSec=0[\s\S]*Restart=on-failure[\s\S]*RestartSec=5/);

    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "monitor-watcher-test-"));
    try {
        for (const command of ["hyprctl", "jq", "socat"]) {
            const target = path.join(tmp, command);
            fs.writeFileSync(target, "#!/bin/sh\nexit 0\n");
            fs.chmodSync(target, 0o755);
        }
        const result = spawnSync("bash", [path.join(repoDir,
            "roles/dotfiles/templates/external-monitor-toggle.j2")], {
            encoding: "utf8",
            env: {
                ...process.env,
                PATH: `${tmp}:/usr/bin:/bin`,
                XDG_RUNTIME_DIR: "",
                HYPRLAND_INSTANCE_SIGNATURE: "",
            },
        });
        assert.equal(result.status, 75);
        assert.match(result.stderr, /environment is not available yet/);
    } finally {
        fs.rmSync(tmp, { recursive: true, force: true });
    }
});

test("plaintext distributed sccache requires an explicit local decision", () => {
    const inventory = readRepo("inventory/group_vars/all.yml");
    const site = readRepo("site.yml");
    const wrapper = readRepo("roles/private-hooks/templates/sccache.j2");
    assert.match(inventory, /^allow_insecure_sccache_transport: (?:true|false)$/m);
    assert.match(inventory, /^allow_insecure_sccache_transport: false$/m);
    assert.match(inventory, /^\s+sccache_scheduler_url: ""$/m);
    assert.match(site, /allow_insecure_sccache_transport is boolean/);
    assert.match(wrapper,
        /http:\/\/\*\)[\s\S]*\$allow_insecure != true[\s\S]*scheduler_url=""/);
    assert.match(wrapper, /https:\/\/\*\) ;;/,
        "TLS scheduler URLs must not require the insecure opt-in");
    assert.match(wrapper, /SCCACHE_DIST_SCHEDULER_URL="\$scheduler_url"/);
    assert.doesNotMatch(wrapper, /bash -c "<\/dev\/tcp\/\$host/,
        "inventory values must not be interpolated into shell source");
});

test("control-center process toggles expose desired, pending, effective, and error state", () => {
    const control = readShell("Popovers/ControlCenterPopover.qml");
    assert.match(control, /property bool effective: on/);
    assert.match(control, /property bool pending: false/);
    assert.match(control, /property string error: ""/);
    assert.match(control, /Accessible\.checked: tile\.effective/);
    assert.match(control, /Accessible\.description: tile\.statusDescription/);
    for (const binding of [
        "effective: SysInfo.nightLightEffective",
        "pending: SysInfo.nightLightPending",
        "error: SysInfo.nightLightError",
        "effective: SysInfo.idleInhibitEffective",
        "pending: SysInfo.idleInhibitPending",
        "error: SysInfo.idleInhibitError",
    ])
        assert.ok(control.includes(binding), binding);
    assert.match(control,
        /visible: SysInfo\.nightLightError !== ""[\s\S]*SysInfo\.idleInhibitError !== ""[\s\S]*Accessible\.role: Accessible\.StaticText/);
});

test("settings rail reports and retries both load and save failures", () => {
    const view = readShell("Settings/SettingsView.qml");
    const settings = readShell("Common/Settings.qml");
    assert.match(view,
        /persistenceStatus:[\s\S]*Settings\.loadError[\s\S]*Settings\.loadErrorText[\s\S]*Settings\.saveError/);
    assert.match(view,
        /visible: Settings\.persistenceError && !Settings\.undoAvailable/);
    assert.match(view,
        /Accessible\.name: Settings\.loadError[\s\S]*"Retry loading settings"[\s\S]*"Retry saving settings"/);
    assert.match(view,
        /Settings\.loadError \? "Could not read settings"[\s\S]*Settings\.saveError \? "Could not save settings"/);
    assert.match(view,
        /Accessible\.role: Settings\.persistenceError[\s\S]*Accessible\.AlertMessage/);
    assert.match(settings,
        /function retrySave\(\) \{[\s\S]*if \(loadError\)[\s\S]*store\.reload\(\)[\s\S]*saveNow\(\)/);
});
