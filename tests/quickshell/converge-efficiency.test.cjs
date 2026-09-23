const test = require("node:test");
const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const crypto = require("node:crypto");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const repo = path.resolve(__dirname, "../..");
const read = relative => fs.readFileSync(path.join(repo, relative), "utf8");

// The text of one top-level task, from its name to the next task.
function task(source, name) {
    const start = source.indexOf(`- name: ${name}`);
    assert.ok(start >= 0, `missing task: ${name}`);
    const end = source.indexOf("\n- name:", start + 1);
    return source.slice(start, end < 0 ? undefined : end);
}

test("Ansible pipelines modules and keeps notified handlers after a failure", () => {
    const config = read("ansible.cfg");
    const section = name => {
        const start = config.indexOf(`[${name}]`);
        const end = config.indexOf("\n[", start + 1);
        return config.slice(start, end < 0 ? undefined : end);
    };
    assert.match(section("defaults"), /^force_handlers = True$/m,
        "a retry after a failure must not lose an initramfs rebuild or restart");
    assert.match(section("connection"), /^pipelining = True$/m);
    assert.match(read("roles/base/tasks/main.yml"),
        /Reconcile firewalld's runtime view with permanent configuration/,
        "an interrupted run still loses handlers, so the firewalld repair stays");
});

test("hypridle restarts when its configuration, unit, or renderer changes", () => {
    const handlers = read("roles/desktop/handlers/main.yml");
    const desktop = read("roles/desktop/tasks/main.yml");
    const handler = task(handlers, "Restart hypridle");
    assert.match(handler, /argv: \[systemctl, --user, try-restart, hypridle\.service\]/,
        "try-restart must leave a stopped or headless idle daemon alone");
    assert.match(handler, /become_user: "\{\{ primary_user \}\}"/);
    assert.match(handler, /XDG_RUNTIME_DIR:/);
    assert.ok(handlers.indexOf("- name: Reload user systemd")
        < handlers.indexOf("- name: Restart hypridle"),
    "a changed unit is reloaded before hypridle restarts");
    for (const name of ["Install rendered Hyprland service configuration",
        "Install the guarded desktop runtime resolver",
        "Install restartable desktop user units",
        "Queue a hypridle restart after its configuration renderer changes"])
        assert.match(task(desktop, name), /Restart hypridle/, name);
    assert.match(task(desktop, "Queue a hypridle restart after its configuration renderer changes"),
        /selectattr\('item', 'equalto', 'scripts\/hypridle-config\.py'\)/);
    assert.ok(desktop.indexOf("Install tracked Quickshell menubar files")
        < desktop.indexOf("Queue a hypridle restart after its configuration renderer changes"));
});
