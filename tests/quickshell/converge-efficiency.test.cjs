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

test("RPM Fusion trust and release packages converge without the network", () => {
    const repos = read("roles/apps/tasks/repos.yml");
    const main = read("roles/apps/tasks/main.yml");
    for (const [scope, digest, fingerprint] of [
        ["free", "10fc0a3e1a0307e8088357a31a9c5e4e3d9f9e0b01db2b03b5790d949a47f3b3",
            "E9A491A3DE247814E7E067EAE06F8ECDD651FF2E"],
        ["nonfree", "7ac65a8dfeced70c8c335862b5f0696d57abac378deda34c4af78cd2220e3de6",
            "79BDB88F9BBF73910FD4095B6A2AF96194843C65"],
    ]) {
        const key = fs.readFileSync(path.join(repo,
            `roles/apps/files/rpmfusion-${scope}-fedora-2020.asc`));
        assert.equal(crypto.createHash("sha256").update(key).digest("hex"), digest,
            `the ${scope} key must stay byte-identical to rpmfusion-${scope}-release's copy`);
        assert.match(repos, new RegExp(`scope: ${scope}\\s+fingerprint: ${fingerprint}`));
        const release = task(repos, `Enable RPM Fusion ${scope} repository`);
        assert.match(release,
            new RegExp(`fedora_release not in \\(\\(ansible_facts\\.packages \\| default\\(\\{\\}\\)\\)\\['rpmfusion-${scope}-release'\\]`),
            "an installed release package must not be downloaded again");
        assert.match(release, /until: apps_rpmfusion_\w+ is succeeded/);
    }
    const keys = task(repos, "Import RPM Fusion release-package signing keys");
    assert.match(keys, /key: "\{\{ role_path \}\}\/files\/rpmfusion-\{\{ item\.scope \}\}-fedora-2020\.asc"/);
    assert.doesNotMatch(keys, /https?:/, "an imported key must be recognized offline");
    assert.ok(main.indexOf("Read the installed package inventory")
        < main.indexOf("Configure package repositories"));
    assert.match(task(main, "Read the installed package inventory"), /tags: \[browser\]/,
        "the Brave replacement under --tags browser relies on the inventory");
});

test("cached boot artwork and finished upstream jobs skip network and polling waits", () => {
    const boot = read("roles/boot/tasks/main.yml");
    const defaults = read("roles/boot/defaults/main.yml");
    const upstream = read("roles/apps/tasks/upstream.yml");

    assert.match(defaults, /^boot_cybex_commit: [0-9a-f]{40}$/m);
    assert.equal((boot.match(/boot_cybex_commit/g) || []).length, 3);
    const inspect = task(boot, "Inspect the cached Cybex Plymouth artwork checkout");
    assert.match(inspect, /status --porcelain --untracked-files=no/,
        "a modified cache must still be reset by the forced checkout");
    assert.match(inspect, /check_mode: false/);
    assert.ok(boot.indexOf("Inspect the cached Cybex Plymouth artwork checkout")
        < boot.indexOf("Checkout pinned Cybex Plymouth artwork"));
    assert.match(task(boot, "Checkout pinned Cybex Plymouth artwork"),
        /boot_cybex_checkout\.rc \| default\(1\) != 0/);

    for (const [name, limit] of [["Collect upstream application installs", 900],
        ["Collect source-only application builds", 2400]]) {
        const block = task(upstream, name);
        assert.match(block, /delay: 1\n/);
        const retries = Number(block.match(/retries: (\d+)/)[1]);
        assert.ok(retries >= limit, `${name} must still wait out its ${limit}s async limit`);
    }
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
