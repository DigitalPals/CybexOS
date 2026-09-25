// The GTK system theme target (scripts/theme_gtk.py) and the Ansible that
// hands it the GTK appearance: environment.d no longer pins GTK_THEME, and
// the converge only seeds a dark default the shell has not yet chosen over.
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const {
    python, scriptsDir, darkTokens, lightTokens, scratch, runDriver, renderTarget, stubBin,
} = require("./system-theme.cjs");

const repo = path.resolve(__dirname, "../..");
// Resolved once, like python: the scrubbed PATH holds only stubs.
const which = name => spawnSync("sh", ["-c", "command -v " + name], { encoding: "utf8" })
    .stdout.trim() || "/usr/bin/" + name;
const bash = which("bash");
const grep = which("grep");
const SCHEMA = "org.gnome.desktop.interface";

// A gsettings that knows accent-color (GNOME 47+) unless `accent` is false,
// and fails every `set` when `failSet` is given.
function gsettingsStub(t, { accent = true, failSet = "" } = {}) {
    const keys = ["color-scheme", "gtk-theme", "icon-theme"].concat(accent ? ["accent-color"] : []);
    return stubBin(t, {
        gsettings: "case \"$1\" in\n"
            + "  list-keys) printf '%s\\n' " + keys.join(" ") + " ;;\n"
            + (failSet ? "  set) printf '%s\\n' '" + failSet + "' >&2; exit 1 ;;\n" : "")
            + "esac",
    });
}

function apply(state, tokens, bin, args = []) {
    return runDriver(state, ["apply", ...args], JSON.stringify(tokens) + "\n", { bin });
}

function gsettingsCalls(stub) {
    return stub.calls().filter(line => line.startsWith("gsettings "));
}

test("render records the dark and light settings deterministically", () => {
    const dark = renderTarget("gtk", darkTokens());
    assert.deepEqual(Object.keys(dark), ["gtk.json"]);
    assert.deepEqual(JSON.parse(dark["gtk.json"]), {
        "accent-color": "yellow", "color-scheme": "prefer-dark", "gtk-theme": "adw-gtk3-dark",
    });
    assert.ok(dark["gtk.json"].endsWith("}\n"));
    assert.deepEqual(renderTarget("gtk", darkTokens()), dark);

    const light = JSON.parse(renderTarget("gtk", lightTokens())["gtk.json"]);
    assert.deepEqual(light, {
        "accent-color": "yellow", "color-scheme": "prefer-light", "gtk-theme": "adw-gtk3",
    });
});

test("the adw-gtk3 themes it names are the ones the package installs", () => {
    const code = "import json, theme_gtk as g\nprint(json.dumps(g.GTK_THEMES))";
    const result = spawnSync(python, ["-c", code], {
        cwd: scriptsDir, encoding: "utf8", env: { ...process.env, PYTHONDONTWRITEBYTECODE: "1" },
    });
    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(JSON.parse(result.stdout), { dark: "adw-gtk3-dark", light: "adw-gtk3" });
    const packages = fs.readFileSync(path.join(repo, "roles/apps/defaults/main.yml"), "utf8");
    assert.match(packages, /^ {2}- adw-gtk3-theme$/m);
});

test("accents map to the nearest libadwaita accent by hue, greys to slate", () => {
    const table = {
        // The shell's accent presets.
        "#d3d283": "yellow", "#9ecbeb": "blue", "#a992e0": "purple",
        "#79b88b": "green", "#d3b47e": "yellow", "#e8837a": "red",
        // libadwaita's own accents map to themselves.
        "#3584e4": "blue", "#2190a4": "teal", "#3a944a": "green", "#c88800": "yellow",
        "#ed5b00": "orange", "#e62d42": "red", "#d56199": "pink", "#9141ac": "purple",
        "#6f8396": "slate",
        // Too little colour for a hue.
        "#888888": "slate", "#000000": "slate", "#ffffff": "slate", "#f5f0e8": "slate",
    };
    const code = "import json, sys, theme_gtk as g\n"
        + "print(json.dumps({h: g.accent_name(h) for h in json.load(sys.stdin)}))";
    const result = spawnSync(python, ["-c", code], {
        cwd: scriptsDir, input: JSON.stringify(Object.keys(table)), encoding: "utf8",
        env: { ...process.env, PYTHONDONTWRITEBYTECODE: "1" },
    });
    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(JSON.parse(result.stdout), table);

    const tokens = darkTokens();
    tokens.colors.accent = "#9ecbeb";
    assert.equal(JSON.parse(renderTarget("gtk", tokens)["gtk.json"])["accent-color"], "blue");
});

test("apply sets exactly the interface keys, once per change", t => {
    const state = scratch(t);
    const stub = gsettingsStub(t);
    const dark = apply(state, darkTokens(), stub.bin);
    assert.equal(dark.report.targets.gtk.error, null);
    assert.equal(dark.report.targets.gtk.changed, true);
    assert.deepEqual(gsettingsCalls(stub), [
        `gsettings list-keys ${SCHEMA}`,
        `gsettings set ${SCHEMA} color-scheme prefer-dark`,
        `gsettings set ${SCHEMA} gtk-theme adw-gtk3-dark`,
        `gsettings set ${SCHEMA} accent-color yellow`,
    ]);

    // Unchanged tokens leave gsettings alone; only --force reapplies them.
    const again = apply(state, darkTokens(), stub.bin);
    assert.equal(again.report.targets.gtk.changed, false);
    assert.equal(gsettingsCalls(stub).length, 4);
    apply(state, darkTokens(), stub.bin, ["--force"]);
    assert.equal(gsettingsCalls(stub).length, 8);

    const light = lightTokens();
    light.colors.accent = "#a992e0";
    assert.equal(apply(state, light, stub.bin).report.targets.gtk.error, null);
    assert.deepEqual(gsettingsCalls(stub).slice(8), [
        `gsettings list-keys ${SCHEMA}`,
        `gsettings set ${SCHEMA} color-scheme prefer-light`,
        `gsettings set ${SCHEMA} gtk-theme adw-gtk3`,
        `gsettings set ${SCHEMA} accent-color purple`,
    ]);
    assert.deepEqual(JSON.parse(fs.readFileSync(path.join(state, "gtk.json"), "utf8")), {
        "accent-color": "purple", "color-scheme": "prefer-light", "gtk-theme": "adw-gtk3",
    });
});

test("a schema without accent-color is left without one", t => {
    const stub = gsettingsStub(t, { accent: false });
    const result = apply(scratch(t), lightTokens(), stub.bin);
    assert.equal(result.report.targets.gtk.error, null);
    assert.deepEqual(gsettingsCalls(stub), [
        `gsettings list-keys ${SCHEMA}`,
        `gsettings set ${SCHEMA} color-scheme prefer-light`,
        `gsettings set ${SCHEMA} gtk-theme adw-gtk3`,
    ]);
});

test("a failing gsettings is reported in a short message", t => {
    const stub = gsettingsStub(t, { failSet: "failed to commit changes to dconf" });
    const result = apply(scratch(t), darkTokens(), stub.bin);
    assert.equal(result.status, 1);
    assert.equal(result.report.success, false);
    assert.equal(result.report.targets.gtk.error,
        "gsettings set color-scheme failed: failed to commit changes to dconf");
    assert.equal(gsettingsCalls(stub).length, 2);

    const silent = stubBin(t, { gsettings: "exit 4" });
    const bare = apply(scratch(t), darkTokens(), silent.bin);
    assert.equal(bare.report.targets.gtk.error, "gsettings list-keys failed: exit status 4");
});

test("without gsettings on PATH there is nothing to reconfigure", t => {
    const result = apply(scratch(t), darkTokens());
    assert.equal(result.report.targets.gtk.error, null);
    assert.equal(result.report.targets.gtk.changed, true);
});

// ---- Ansible ----------------------------------------------------------------

function yamlTask(file, name) {
    const code = "import json, sys, yaml\n"
        + "tasks = yaml.safe_load(open(sys.argv[1]))\n"
        + "print(json.dumps(next(t for t in tasks if t.get('name') == sys.argv[2])))";
    const result = spawnSync(python, ["-c", code, path.join(repo, file), name],
        { encoding: "utf8" });
    assert.equal(result.status, 0, result.stderr);
    return JSON.parse(result.stdout);
}

function runTask(task, bin, env = {}) {
    const script = task["ansible.builtin.shell"];
    assert.equal(task.args.executable, "/bin/bash");
    assert.doesNotMatch(script, /\{\{/, "the stubbed script must not need templating");
    return spawnSync(bash, ["-c", script], {
        encoding: "utf8", env: { PATH: bin, HOME: bin, ...env },
    });
}

test("environment.d no longer pins GTK_THEME", () => {
    const template = fs.readFileSync(
        path.join(repo, "roles/dotfiles/templates/environment.conf.j2"), "utf8");
    assert.doesNotMatch(template, /GTK_THEME/);
    for (const file of ["main.yml", "personal.yml"]) {
        const tasks = fs.readFileSync(path.join(repo, "roles/dotfiles/tasks", file), "utf8");
        assert.doesNotMatch(tasks, /gsettings set org\.gnome\.desktop\.interface color-scheme/);
    }
});

test("the converge seeds dark GTK only on keys still at their schema default", t => {
    // Shared with installed images, which also run it offline.
    const task = yamlTask("roles/dotfiles/tasks/personal.yml",
        "Default GTK to dark until the shell applies its appearance");
    assert.deepEqual(task.when, ["manage_personal_dotfiles | bool", "not ansible_check_mode"]);
    assert.equal(task.become_user, "{{ primary_user }}");
    assert.equal(task.changed_when, "'CHANGED:' in dotfiles_gtk_default.stdout");

    // A gsettings stub backed by one file per key, behind a dbus-run-session
    // stub that just runs its command.
    const cases = [
        [{ "color-scheme": "'default'", "gtk-theme": "'Adwaita'" }, true, true],
        [{ "color-scheme": "'prefer-light'", "gtk-theme": "'adw-gtk3'" }, false, false],
        [{ "color-scheme": "'prefer-dark'", "gtk-theme": "'Adwaita'" }, false, true],
    ];
    for (const [initial, seedsScheme, seedsTheme] of cases) {
        const values = scratch(t);
        for (const [key, value] of Object.entries(initial))
            fs.writeFileSync(path.join(values, key), value + "\n");
        const stub = stubBin(t, {
            "dbus-run-session": "[ \"$1\" = -- ] && shift\nexec \"$@\"",
            gsettings: "case \"$1\" in\n"
                + "  get) read -r v <\"$VALUES/$3\"; printf '%s\\n' \"$v\" ;;\n"
                + "  set) printf \"'%s'\\n\" \"$4\" >\"$VALUES/$3\" ;;\n"
                + "esac",
        });
        const result = runTask(task, stub.bin, { VALUES: values });
        assert.equal(result.status, 0, result.stderr);
        const sets = stub.calls().filter(line => line.startsWith("gsettings set"));
        assert.deepEqual(sets, [
            ...(seedsScheme ? [`gsettings set ${SCHEMA} color-scheme prefer-dark`] : []),
            ...(seedsTheme ? [`gsettings set ${SCHEMA} gtk-theme adw-gtk3-dark`] : []),
        ], JSON.stringify(initial));
        assert.equal(result.stdout.includes("CHANGED:"), seedsScheme || seedsTheme);
        const read = key => fs.readFileSync(path.join(values, key), "utf8").trim();
        assert.equal(read("color-scheme"),
            seedsScheme ? "'prefer-dark'" : initial["color-scheme"]);
        assert.equal(read("gtk-theme"), seedsTheme ? "'adw-gtk3-dark'" : initial["gtk-theme"]);
        // Every gsettings call, reads included, runs on a session bus.
        assert.equal(stub.calls().filter(line => line.startsWith("dbus-run-session")).length,
            stub.calls().filter(line => line.startsWith("gsettings")).length);
    }
});

test("the converge drops only CybexOS's GTK_THEME from the user manager", t => {
    const task = yamlTask("roles/dotfiles/tasks/main.yml",
        "Drop the retired GTK_THEME pin from the running user manager");
    assert.equal(task.when, "not ansible_check_mode");
    assert.match(task.environment.XDG_RUNTIME_DIR, /^\/run\/user\//);
    assert.equal(task.changed_when, "'CHANGED:' in dotfiles_gtk_theme_pin.stdout");

    const cases = [
        ["PATH=/usr/bin\nGTK_THEME=adw-gtk3-dark\nLANG=C", true],
        ["PATH=/usr/bin\nGTK_THEME=Adwaita:dark\n", false],
        ["PATH=/usr/bin\n", false],
        [null, false], // no user manager to talk to, as in the installer
    ];
    for (const [environment, unsets] of cases) {
        const stub = stubBin(t, {
            systemctl: environment === null ? "exit 1"
                : "[ \"$2\" = show-environment ] && printf '%s\\n' '"
                    + environment.replace(/\n/g, "' '") + "'\nexit 0",
        });
        fs.symlinkSync(grep, path.join(stub.bin, "grep"));
        const result = runTask(task, stub.bin);
        assert.equal(result.status, 0, result.stderr);
        // The daemon-reload is what drops a value environment.d supplied.
        const unset = stub.calls().filter(line => !line.includes("show-environment"));
        assert.deepEqual(unset, unsets ? ["systemctl --user unset-environment GTK_THEME",
            "systemctl --user daemon-reload",
            "systemctl --user try-restart xdg-desktop-portal-gtk.service"] : [],
        String(environment));
        assert.equal(result.stdout.includes("CHANGED:"), unsets);
    }
});
