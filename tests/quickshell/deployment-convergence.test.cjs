const test = require("node:test");
const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");
const { shellDir } = require("./shell.cjs");

const repo = path.resolve(shellDir, "../../../..");
const read = relative => fs.readFileSync(path.join(repo, relative), "utf8");

test("Cybex deployment prunes files outside its source-plus-override manifest", () => {
    const tasks = read("roles/boot/tasks/main.yml");
    const defaults = read("roles/boot/defaults/main.yml");
    const pruneAt = tasks.indexOf("Remove files outside the current Cybex source and override manifest");
    const upstreamCopyAt = tasks.indexOf("Install non-overridden Cybex Plymouth theme files");
    const overrideCopyAt = tasks.indexOf("Install custom Cybex theme files");

    assert.ok(pruneAt > 0 && pruneAt < upstreamCopyAt && upstreamCopyAt < overrideCopyAt,
        "stale paths must be removed before the source and deliberate overrides are installed");
    assert.match(tasks,
        /boot_cybex_installed_files\.stdout_lines \| default\(\[\]\)[\s\S]{0,220}?difference\(\(boot_cybex_source_files\.stdout_lines \| default\(\[\]\)\) \+ boot_cybex_override_files\)/);
    assert.match(tasks,
        /boot_cybex_installed_directories\.stdout_lines \| default\(\[\]\)[\s\S]{0,220}?reject\('in', \(boot_cybex_source_directories\.stdout_lines \| default\(\[\]\)\) \+ boot_cybex_override_directories\)/,
        "directories removed upstream must not linger in the installed tree");
    assert.match(tasks,
        /Inspect the installed Cybex directory tree[\s\S]{0,300}?- -depth/,
        "stale directories must be enumerated child-first before removal");
    assert.match(tasks,
        /dest:\s*\/var\/lib\/cybexos-upstream\/omarchy-cybex\/installed-theme\.manifest/,
        "the manifest must live outside the tree it reconciles");
    assert.match(tasks,
        /boot_cybex_source_files\.stdout_lines[\s\S]{0,180}?difference\(boot_cybex_override_files\)/,
        "the upstream copy must not overwrite files managed by the local override layer");
    assert.doesNotMatch(tasks,
        /src:\s*\/var\/cache\/cybexos-upstream\/omarchy-cybex\/config\/plymouth\/themes\/cybex\/$/m,
        "a recursive source-tree copy would make every customized file change twice on each run");
    for (const manifestTask of ["Inspect the pinned Cybex source manifest",
        "Inspect the pinned Cybex source directory manifest", "Inspect the installed Cybex theme tree",
        "Inspect the installed Cybex directory tree"]) {
        const start = tasks.indexOf(`- name: ${manifestTask}`);
        const end = tasks.indexOf("\n- name:", start + 1);
        assert.match(tasks.slice(start, end), /check_mode:\s*false/,
            `${manifestTask} must remain a read-only fact source during check mode`);
    }
    const upstreamTask = tasks.slice(upstreamCopyAt, tasks.indexOf("\n- name:", upstreamCopyAt + 1));
    assert.doesNotMatch(upstreamTask, /not ansible_check_mode/,
        "check mode must detect drift in cached non-override source files");
    for (const override of ["logo.png", "entry.png", "bullet.png", "progress_bar.png",
        "progress_box.png", "cybex.script", "cybex.plymouth"])
        assert.match(defaults, new RegExp(`- ${override.replace(".", "\\.")}`));
    assert.match(tasks,
        /Remove files outside[\s\S]{0,900}?notify:\s*Rebuild Fedora initramfs/,
        "removing an upstream file must rebuild the initramfs too");
});

test("Podman inventory controls packages, helpers, keybindings, and desktop entries", () => {
    const inventory = read("inventory/group_vars/all.yml");
    const featureTemplate = read("roles/desktop/templates/features.lua.j2");
    const desktopTasks = read("roles/desktop/tasks/main.yml");
    const dotfileTasks = read("roles/dotfiles/tasks/main.yml");
    const hyprland = read("roles/desktop/files/hyprland.lua");
    const bindings = read("roles/desktop/files/bindings.lua");
    const packages = read("roles/apps/tasks/packages.yml");

    assert.match(inventory, /^\s{2}podman:\s*(?:true|false)$/m);
    assert.match(featureTemplate, /features\.podman \| bool/);
    const featureInstallAt = desktopTasks.indexOf(
        "Install rendered Hyprland Lua dependencies before their consumers");
    const luaConsumersAt = desktopTasks.indexOf("Install Hyprland Lua configuration");
    assert.ok(featureInstallAt > 0 && featureInstallAt < luaConsumersAt,
        "the rendered feature module must exist before a live reload can evaluate bindings");
    assert.match(desktopTasks.slice(featureInstallAt, luaConsumersAt),
        /src:\s*"\{\{ item \}\}\.j2"[\s\S]{0,220}?dest:\s*"\{\{ cybexos_runtime_root \}\}\/hypr\/\{\{ item \}\}"[\s\S]{0,220}?- features\.lua[\s\S]{0,260}?tags:\s*\[browser\]/,
        "partial browser/config deploys must install the feature dependency first");
    const luaInstallBlock = desktopTasks.slice(luaConsumersAt,
        desktopTasks.indexOf("Install ordered Hyprland session starter", luaConsumersAt));
    assert.ok(luaInstallBlock.indexOf("- bindings.lua")
        < luaInstallBlock.indexOf("- hyprland.lua"),
    "the activating entrypoint must land after the modules it requires");
    assert.match(desktopTasks.slice(featureInstallAt, luaConsumersAt),
        /- features\.lua\s+- monitors\.lua\s+- input\.lua\s+- looknfeel\.lua/,
        "all imported leaf modules must precede the activating entrypoint");
    assert.match(hyprland, /\{ "features", "monitors", "input", "bindings"/,
        "a config reload must evict the rendered feature module before reloading bindings");
    assert.match(bindings, /local features = require\("features"\)/);
    const optionalBinds = bindings.slice(bindings.indexOf("if features.podman then"),
        bindings.indexOf("end", bindings.indexOf("if features.podman then")) + 3);
    for (const distro of ["fedora", "arch", "debian"])
        assert.match(optionalBinds, new RegExp(`dev-${distro}-shell`));

    const commonLaunchers = dotfileTasks.slice(
        dotfileTasks.indexOf("Install MIME defaults and desktop launchers"),
        dotfileTasks.indexOf("Install Distrobox desktop launchers when Podman is enabled"));
    assert.doesNotMatch(commonLaunchers, /dev-(?:fedora|arch|debian)\.desktop/);
    assert.match(dotfileTasks,
        /Install Distrobox desktop launchers when Podman is enabled[\s\S]{0,700}?when: features\.podman \| bool/);
    assert.ok(dotfileTasks.includes(
        "Remove managed Distrobox desktop launchers when Podman is disabled"));
    for (const unit of ["podman.socket", "podman.service", "podman-auto-update.timer"])
        assert.ok(packages.includes(`- ${unit}`), `disabled Podman must retire ${unit}`);
    assert.match(packages,
        /Disable user Podman activation when Podman is disabled[\s\S]{0,600}?scope: user/);
    assert.match(packages,
        /Remove disabled Podman and Steam package families[\s\S]{0,600}?Reload systemd after application package removal/);
});

test("ChatGPT launcher follows portable desktop scaling", () => {
    const appDefaults = read("roles/apps/defaults/main.yml");
    const appPackages = read("roles/apps/tasks/packages.yml");
    const appRepos = read("roles/apps/tasks/repos.yml");
    const repository = read("roles/apps/files/chatgpt.repo");
    const repositoryKey = fs.readFileSync(path.join(
        repo, "roles/apps/files/chatgpt-repository-key.asc"));
    const dotfileTasks = read("roles/dotfiles/tasks/main.yml");
    const launcher = read("roles/dotfiles/files/chatgpt.desktop");
    const lookAndFeel = read("roles/desktop/templates/looknfeel.lua.j2");

    assert.equal(crypto.createHash("sha256").update(repositoryKey).digest("hex"),
        "6c8933f828af390b2457f9e2d234082d783d6e4bb1911615b4861c6c61f4ea5a",
        "the in-tree key must remain byte-identical to OpenAI's reviewed installer key");
    assert.match(appDefaults,
        /apps_chatgpt_repository_key_fingerprint:\s*3BFA0E4AE8B8CC16A2D9BA684A3B4A566C4660E4/);
    assert.match(appRepos,
        /Install the reviewed ChatGPT repository key[\s\S]{0,900}?fingerprint:[\s\S]{0,200}?apps_chatgpt_repository_key_fingerprint/);
    assert.match(appRepos,
        /Install enabled signed vendor repository definitions[\s\S]{0,500}?- chatgpt/);
    assert.match(appPackages,
        /Install signed vendor applications[\s\S]{0,300}?- chatgpt/);
    assert.match(repository, /^gpgcheck=1$/m);
    assert.match(repository, /^repo_gpgcheck=1$/m);
    assert.match(repository,
        /^gpgkey=file:\/\/\/etc\/pki\/rpm-gpg\/RPM-GPG-KEY-chatgpt$/m);
    assert.match(lookAndFeel,
        /force_zero_scaling = \{\{ .*cybexos_dynamic_hardware.*cybexos_xps_2026.* \}\}/,
        "XWayland scaling keeps the XPS behavior behind the hardware gate");
    assert.match(dotfileTasks,
        /Install MIME defaults and desktop launchers[\s\S]{0,1200}?name: chatgpt\.desktop[\s\S]{0,120}?features\.proprietary_apps/,
        "the launcher must be deployed as a per-user package override");
    assert.match(launcher, /^Exec=chatgpt %U$/m,
        "ChatGPT follows the display scale selected by the desktop");
});

test("disabled Docker and Tailscale retire activation and imported trust", () => {
    const base = read("roles/base/tasks/main.yml");
    const repos = read("roles/apps/tasks/repos.yml");

    assert.match(base,
        /Stop and disable Docker socket activation[\s\S]{0,400}?- docker\.socket[\s\S]{0,100}?- docker\.service/);
    assert.match(repos,
        /Remove the imported Tailscale package key when disabled[\s\S]{0,500}?ansible\.builtin\.rpm_key:[\s\S]{0,300}?state: absent/);
    assert.match(repos,
        /Remove the imported Tailscale package key when disabled[\s\S]{0,700}?not features\.tailscale \| bool/);
});

test("Voxtype probes as the desktop user but activates its system backend as root", () => {
    const tasks = read("roles/apps/tasks/devtools.yml");
    const handlers = read("roles/apps/handlers/main.yml");
    const config = read("roles/dotfiles/files/voxtype.toml");
    const statusBlock = tasks.slice(tasks.indexOf("Read Voxtype backend status"),
        tasks.indexOf("Select Voxtype GPU backend"));
    const activationBlock = tasks.slice(tasks.indexOf("Select Voxtype GPU backend"),
        tasks.indexOf("Verify the selected Voxtype GPU backend"));
    const verificationBlock = tasks.slice(tasks.indexOf("Verify the selected Voxtype GPU backend"),
        tasks.indexOf("Download Voxtype base English model"));

    assert.match(statusBlock, /become_user:\s*"\{\{ primary_user \}\}"/,
        "status should reflect the desktop user's active backend");
    assert.match(activationBlock, /become:\s*true/);
    assert.doesNotMatch(activationBlock, /become_user:/,
        "backend activation replaces the root-owned /usr/bin/voxtype selector");
    assert.match(activationBlock, /setup gpu --enable/);
    assert.match(tasks,
        /Refuse an unreadable Voxtype backend state[\s\S]{0,500}?apps_voxtype_status\.rc/);
    assert.match(verificationBlock, /Active backend: GPU/,
        "successful activation must be checked through the normal user selector");
    assert.match(verificationBlock, /become_user:\s*"\{\{ primary_user \}\}"/);
    assert.match(handlers,
        /Restart Voxtype after updates[\s\S]{0,400}?--machine=\{\{ primary_user \}\}@\.host/);
    const restartBlock = handlers.slice(handlers.indexOf("Restart Voxtype after updates"),
        handlers.indexOf("Reload systemd after application package removal"));
    assert.doesNotMatch(restartBlock, /getent_passwd|XDG_RUNTIME_DIR|become_user/,
        "the restart handler must work even when --start-at-task skipped passwd facts");
    assert.match(config, /\[osd\]\s+enabled\s*=\s*false/,
        "the managed Quickshell indicator replaces Voxtype's optional OSD process");
});

test("the deployed Quickshell manifest excludes tracked paths deleted on disk", () => {
    const tasks = read("roles/desktop/tasks/main.yml");
    const verifier = read("tests/verify-system");
    const deletedPairingHelper = "roles/desktop/files/quickshell/scripts/t3-pair.py";

    assert.equal(fs.existsSync(path.join(repo, deletedPairingHelper)), false,
        "the obsolete credential-pairing helper is intentionally absent");
    assert.match(tasks,
        /git -C "\$repo" ls-files -z --cached --others --exclude-standard[\s\S]{0,500}?\[\[ -f "\$repo\/\$source_path" \|\| -L "\$repo\/\$source_path" \]\]/,
        "deployment must filter the index through actual file/symlink existence");
    assert.match(tasks,
        /rev-parse --is-inside-work-tree[\s\S]{0,1000}?find "\$repo\/roles\/desktop\/files\/quickshell"/,
        "deployment must build the same source allowlist from release archives without .git");
    assert.match(tasks,
        /find "\$repo\/roles\/desktop\/files\/quickshell"[\s\S]{0,300}?-name __pycache__ -prune[\s\S]{0,200}?! -name '\*\.py\[co\]'/,
        "archive deployment must exclude generated Python bytecode caches");
    assert.match(tasks,
        /Refuse an empty or incomplete Quickshell source manifest[\s\S]{0,400}?'shell\.qml' in quickshell_managed_manifest/,
        "an invalid manifest must fail before it can prune the deployed shell");
    assert.match(verifier,
        /git -C "\$repo_root" ls-files -z --cached --others --exclude-standard[\s\S]{0,400}?\[\[ -f "\$repo_root\/\$source_path" \|\| -L "\$repo_root\/\$source_path" \]\]/,
        "installed-state verification must calculate the identical manifest");
    assert.ok(tasks.indexOf("Build the tracked Quickshell source manifest")
        < tasks.indexOf("Install tracked Quickshell menubar files"),
    "the allowlist must exist before any shell source is copied");
    assert.match(tasks,
        /Calculate the content identity of the managed Quickshell tree[\s\S]{0,2600}?stdin: "\{\{ quickshell_managed_manifest \| sort \| to_json \}\}"/,
        "the expected tree must be described from the tracked allowlist alone");
    assert.match(tasks,
        /Inspect the deployed Quickshell tree before writing through any child path[\s\S]{0,4500}?stdin: "\{\{ quickshell_source_digest\.stdout \}\}"/,
        "the deployed tree must be compared with that allowlist description");
    assert.match(tasks,
        /Install tracked Quickshell menubar files[\s\S]{0,500}?src: "quickshell\/\{\{ item \}\}"[\s\S]{0,400}?loop: "\{\{ quickshell_deploy\.install \}\}"/,
        "copy input must be the changed part of the tracked allowlist, not the whole source directory");
    assert.doesNotMatch(tasks,
        /Install (?:tracked )?Quickshell menubar (?:configuration|files)[\s\S]{0,250}?src: quickshell\//,
        "recursive copy would transiently deploy ignored caches and developer files");
    assert.match(tasks,
        /Remove directories not present in the tracked Quickshell manifest[\s\S]{0,600}?loop: >-\s*\{\{ quickshell_deploy\.stale_directories\b/,
        "directories removed upstream must not linger in the deployed tree");
    const preflightAt = tasks.indexOf("Inspect the deployed Quickshell tree before writing through any child path");
    const lintAt = tasks.indexOf("Check the Quickshell configuration before installing it");
    const snapshotAt = tasks.indexOf("Snapshot the last-known-good live Quickshell before deployment");
    const rootStatAt = tasks.indexOf("Inspect the managed Quickshell root without following links");
    const rootRemoveAt = tasks.indexOf("Remove a non-directory or linked Quickshell root safely");
    const removeFilesAt = tasks.indexOf("Remove files and links that are stale or unsafe copy destinations");
    const removeDirectoriesAt = tasks.indexOf("Remove directories not present in the tracked Quickshell manifest");
    const createDirectoriesAt = tasks.indexOf("Create tracked Quickshell directories");
    const copyAt = tasks.indexOf("Install tracked Quickshell menubar files");
    const verifyAt = tasks.indexOf("Verify the live Quickshell deployment or restore its last-known-good tree");
    assert.ok(preflightAt > 0 && preflightAt < lintAt && lintAt < snapshotAt
        && snapshotAt < rootStatAt,
    "the read-only inspection decides the lint and snapshot before any write");
    assert.ok(rootStatAt < rootRemoveAt && rootRemoveAt < removeFilesAt
        && removeFilesAt < removeDirectoriesAt && removeDirectoriesAt < createDirectoriesAt
        && createDirectoriesAt < copyAt && copyAt < verifyAt,
    "root and child path types must be normalized before any managed child is written");
    assert.match(tasks,
        /Inspect the managed Quickshell root without following links[\s\S]{0,220}?follow: false/);
    const preflight = tasks.slice(preflightAt, tasks.indexOf("\n- name:", preflightAt + 1));
    assert.match(preflight, /os\.lstat\(root\)/,
        "a linked or non-directory root must be detected without following it");
    assert.match(preflight, /entry\.stat\(follow_symlinks=False\)/,
        "deployed children must be classified without following links");
    assert.match(preflight,
        /elif relative not in files or not stat\.S_ISREG\(info\.st_mode\):\s*delta\["stale_files"\]\.append/,
        "even a symlink at an otherwise managed file path must be removed before copy");
    assert.match(preflight, /os\.O_NOFOLLOW/,
        "a managed file is hashed only as the regular file that was inspected");
    assert.match(preflight, /changed_when: false[\s\S]*check_mode: false/,
        "the inspection is a read-only fact source, also during check mode");
    for (const gated of ["Check the Quickshell configuration before installing it",
        "Snapshot the last-known-good live Quickshell before deployment",
        "Prune stale compiled QML cache entries after a shell change"]) {
        const block = tasks.slice(tasks.indexOf(gated), tasks.indexOf("\n- name:", tasks.indexOf(gated) + 1));
        assert.match(block, /quickshell_deploy_required/,
            `${gated} must be skipped when the deployed tree already matches`);
    }
    const verify = tasks.slice(verifyAt, tasks.indexOf("\n- name:", verifyAt + 1));
    assert.match(verify, /quickshell_live_snapshot is not skipped/,
        "verification may only roll back to a snapshot taken by the same run");
    assert.match(tasks,
        /Record deferred path normalization during check mode[\s\S]{0,500}?quickshell_removed_files\.changed \| default\(false\)[\s\S]{0,180}?quickshell_removed_directories\.changed \| default\(false\)/,
        "check mode must defer writes whose prerequisite removals are only simulated");
    for (const taskName of ["Create tracked Quickshell directories",
        "Install tracked Quickshell menubar files"]) {
        const block = tasks.slice(tasks.indexOf(taskName),
            tasks.indexOf("\n- name:", tasks.indexOf(taskName) + 1));
        assert.match(block, /follow: false/,
            `${taskName} must fail closed if a destination link races the preflight`);
        assert.match(block, /when: not quickshell_path_normalization_pending \| bool/,
            `${taskName} must be deferred behind check-mode path normalization`);
    }
});

test("the retired Paseo shell widget leaves no bridge runtime behind", () => {
    const tasks = read("roles/desktop/tasks/main.yml");
    const cleanupAt = tasks.indexOf("Remove retired Paseo shell widget runtime");
    const nextTaskAt = tasks.indexOf("\n- name:", cleanupAt + 1);

    assert.ok(cleanupAt > 0, "Paseo retirement must be part of desktop convergence");
    const cleanup = tasks.slice(cleanupAt, nextTaskAt);
    assert.match(cleanup,
        /path:\s*"\{\{ primary_home \}\}\/\.local\/share\/cybexos\/paseo-bridge"/);
    assert.match(cleanup, /state:\s*absent/);
    assert.match(cleanup, /tags:\s*\[quickshell\]/,
        "a targeted Quickshell deployment must remove the retired bridge too");
});
