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

test("app, desktop, and boot packages share dnf transactions and skip no-op removals", () => {
    const apps = read("roles/apps/tasks/packages.yml");
    const desktop = read("roles/desktop/tasks/main.yml");
    const boot = read("roles/boot/tasks/main.yml");

    const required = task(apps, "Install the required Fedora and RPM Fusion application packages");
    assert.match(required,
        /name: "\{\{ apps_desired_required_fedora_packages \+ apps_available_fedora_packages \}\}"/);
    assert.ok(apps.indexOf("Resolve optional packages available for Fedora 44")
        < apps.indexOf("Install the required Fedora and RPM Fusion application packages"));
    assert.match(task(apps, "Resolve optional packages available for Fedora 44"),
        /when: apps_missing_optional_fedora_packages \| length > 0/,
        "installed optional packages need no repository query");
    assert.doesNotMatch(apps, /Install available optional Fedora packages/);
    assert.match(task(apps, "Replace standard Brave with Brave Origin"),
        /'brave-browser' in \(ansible_facts\.packages/);

    assert.doesNotMatch(desktop, /- name: Install Quickshell runtime helpers/);
    const hyprland = task(desktop, "Install stable Hyprland and desktop integration packages");
    for (const helper of ["NetworkManager", "python3-websockets", "evolution-data-server", "dnf5-plugins"])
        assert.match(hyprland, new RegExp(`- ${helper}\\n`));
    assert.match(hyprland, /tags: \[quickshell\]/,
        "a targeted Quickshell deployment still installs its runtime helpers");

    assert.match(task(boot, "Install Fedora BGRT and selected Plymouth theme support"),
        /plymouth-theme-spinner[\s\S]*plymouth_theme == 'cybex'[\s\S]*plymouth-plugin-script/);
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

test("pinned single-file fonts are verified in one pass", () => {
    const upstream = read("roles/apps/tasks/upstream.yml");
    for (const install of ["Create pinned single-file font directories",
        "Install pinned single-file fonts", "Install pinned single-file font licenses"])
        assert.match(task(upstream, install), /loop: "\{\{ apps_pending_font_files \}\}"/);

    const inspection = task(upstream, "Inspect installed pinned single-file fonts");
    const script = inspection.split("      - |\n")[1].split("\n      - /usr/local/share/fonts")[0]
        .split("\n").map(line => line.slice(8)).join("\n");
    const root = fs.mkdtempSync(path.join(os.tmpdir(), "cybexos-font-check-"));
    try {
        const font = Buffer.from("font bytes\n");
        const license = Buffer.from("license\n");
        const sha = bytes => "sha256:" + crypto.createHash("sha256").update(bytes).digest("hex");
        const fonts = ["good", "drifted", "linked", "missing"].map(name => ({
            name, version: "1", filename: "Font.ttf", checksum: sha(font),
            license_filename: "OFL.txt", license_checksum: sha(license).toUpperCase(),
        }));
        for (const name of ["good", "drifted", "linked"]) {
            const directory = path.join(root, name, "1");
            fs.mkdirSync(directory, { recursive: true, mode: 0o755 });
            fs.chmodSync(directory, 0o755);
            fs.writeFileSync(path.join(directory, "OFL.txt"), license, { mode: 0o644 });
            fs.chmodSync(path.join(directory, "OFL.txt"), 0o644);
        }
        fs.writeFileSync(path.join(root, "good/1/Font.ttf"), font);
        fs.chmodSync(path.join(root, "good/1/Font.ttf"), 0o644);
        fs.writeFileSync(path.join(root, "drifted/1/Font.ttf"), "changed\n");
        fs.chmodSync(path.join(root, "drifted/1/Font.ttf"), 0o644);
        fs.symlinkSync(path.join(root, "good/1/Font.ttf"), path.join(root, "linked/1/Font.ttf"));
        const run = (uid, gid) => spawnSync("python3",
            ["-c", script, root, String(uid), String(gid)],
            { input: JSON.stringify(fonts), encoding: "utf8" });
        const current = run(process.getuid(), process.getgid());
        assert.equal(current.status, 0, current.stderr);
        assert.deepEqual(JSON.parse(current.stdout), ["drifted", "linked", "missing"]);
        const foreign = run(process.getuid() + 1, process.getgid());
        assert.deepEqual(JSON.parse(foreign.stdout), ["good", "drifted", "linked", "missing"],
            "ownership drift must reinstall the font");
    } finally {
        fs.rmSync(root, { recursive: true, force: true });
    }
});

test("Docker starts through its socket instead of at boot", () => {
    const base = read("roles/base/tasks/main.yml");
    assert.match(task(base, "Enable Docker socket activation when requested"),
        /name: docker\.socket\s+enabled: true\s+state: started/);
    const service = task(base, "Start Docker on demand rather than at boot");
    assert.match(service, /name: docker\.service\s+enabled: false/);
    assert.doesNotMatch(service, /state:/, "a running daemon must not be stopped mid-converge");
    assert.doesNotMatch(base, /name: docker\.service\s+enabled: true/);
});

test("the weekly Btrfs scrub waits for AC power and stays in the background", () => {
    const scrub = task(read("roles/base/tasks/main.yml"), "Install weekly Btrfs scrub unit");
    assert.match(scrub, /\[Unit\][\s\S]*ConditionACPower=true[\s\S]*\[Service\]/);
    assert.match(scrub, /ExecStart=\/usr\/bin\/btrfs scrub start -B -d --limit \d+M \//);
});

test("dictation runs only with developer tooling and loads its model on demand", () => {
    const desktop = read("roles/desktop/tasks/main.yml");
    const voxtype = read("roles/dotfiles/files/voxtype.toml");
    assert.match(voxtype, /\[whisper\][^[]*\non_demand_loading = true\n/);
    assert.match(task(desktop, "Install the restartable Voxtype user unit"),
        /when: features\.developer_tools \| bool/,
        "dictation follows the feature that downloads its model and binds its keys");
    assert.match(task(desktop, "Enable desktop units for the Hyprland target"),
        /features\.developer_tools \| bool \| ternary\(\['voxtype'\], \[\]\)/);
    assert.match(task(desktop, "Remove the Voxtype user unit when developer tooling is disabled"),
        /hyprland-session\.target\.wants\/voxtype\.service[\s\S]*when: not features\.developer_tools \| bool/);
    assert.ok(desktop.indexOf("Stop the Voxtype daemon when developer tooling is disabled")
        < desktop.indexOf("Remove the Voxtype user unit when developer tooling is disabled"));
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
