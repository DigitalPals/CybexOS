// The GTK system theme target (scripts/theme_gtk.py) and the NixOS modules that
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
        "accent-color": "blue", "color-scheme": "prefer-dark", "gtk-theme": "adw-gtk3-dark",
        "text-scaling-factor": "1.00",
    });
    assert.ok(dark["gtk.json"].endsWith("}\n"));
    assert.deepEqual(renderTarget("gtk", darkTokens()), dark);

    const light = JSON.parse(renderTarget("gtk", lightTokens())["gtk.json"]);
    assert.deepEqual(light, {
        "accent-color": "blue", "color-scheme": "prefer-light", "gtk-theme": "adw-gtk3",
        "text-scaling-factor": "1.00",
    });
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
        `gsettings set ${SCHEMA} accent-color blue`,
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
        "text-scaling-factor": "1.00",
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

function statefulGsettings(t, initial = "1.0") {
    const stub = stubBin(t, {
        // Shell builtins only: the scrubbed PATH holds nothing but stubs.
        gsettings: "store=\"${0%/*}/$3.value\"\n"
            + "case \"$1\" in\n"
            + "  list-keys) printf '%s\\n' color-scheme gtk-theme accent-color text-scaling-factor ;;\n"
            + "  get) if [ -f \"$store\" ]; then read -r value <\"$store\"; printf '%s\\n' \"$value\";"
            + " else printf '%s\\n' '" + initial + "'; fi ;;\n"
            + "  set) printf '%s\\n' \"$4\" >\"$store\" ;;\n"
            + "esac",
    });
    return {
        ...stub,
        value: key => {
            const file = path.join(stub.bin, key + ".value");
            return fs.existsSync(file) ? fs.readFileSync(file, "utf8").trim() : initial;
        },
        userSets: (key, value) => fs.writeFileSync(path.join(stub.bin, key + ".value"), value + "\n"),
    };
}

function sized(tokens, size) {
    return { ...tokens, font: { ...tokens.font, size } };
}

test("the GTK text scale follows the shell's effective text size", () => {
    const factor = size => JSON.parse(renderTarget("gtk", sized(darkTokens(), size))["gtk.json"])[
        "text-scaling-factor"];
    // 14 px is a fresh install's size and GNOME's 1.0; Large text (x1.15 of
    // 14 rounds to 16 px) and a 150% interface scale (21 px) scale with it.
    assert.equal(factor(14), "1.00");
    assert.equal(factor(16), "1.14");
    assert.equal(factor(18), "1.29");
    assert.equal(factor(21), "1.50");
    assert.equal(factor(28), "2.00");
    // GNOME's own range bounds the extremes.
    assert.equal(factor(6), "0.50");
    assert.equal(factor(96), "3.00");
});

test("the text scale is set only while the shell still owns it", t => {
    const state = scratch(t);
    const stub = statefulGsettings(t);
    const KEY = "text-scaling-factor";
    const scaleCalls = () => gsettingsCalls(stub).filter(line => line.includes(KEY));

    // GNOME's default belongs to nobody: the shell takes it.
    assert.equal(apply(state, sized(darkTokens(), 16), stub.bin).report.targets.gtk.error, null);
    assert.equal(stub.value(KEY), "1.14");
    assert.deepEqual(scaleCalls(), [`gsettings get ${SCHEMA} ${KEY}`,
        `gsettings set ${SCHEMA} ${KEY} 1.14`]);
    assert.equal(fs.readFileSync(path.join(state, "gtk-text-scale"), "utf8"), "1.14\n");

    // Still the value it set: the next size replaces it.
    apply(state, sized(darkTokens(), 18), stub.bin);
    assert.equal(stub.value(KEY), "1.29");

    // A value of the user's own (GNOME Tweaks) wins, even over --force,
    // while the colour keys keep following the shell.
    stub.userSets(KEY, "1.25");
    const lightRun = apply(state, sized(lightTokens(), 21), stub.bin);
    assert.equal(lightRun.report.targets.gtk.error, null);
    assert.equal(stub.value(KEY), "1.25");
    assert.equal(stub.value("color-scheme"), "prefer-light");
    apply(state, sized(lightTokens(), 21), stub.bin, ["--force"]);
    assert.equal(stub.value(KEY), "1.25");

    // `gsettings reset` hands it back: the next change applies again.
    stub.userSets(KEY, "1.0");
    apply(state, sized(lightTokens(), 14), stub.bin);
    assert.equal(stub.value(KEY), "1.00");
});

test("a user's own text scale survives the first export after an upgrade", t => {
    const stub = statefulGsettings(t, "1.25");
    const result = apply(scratch(t), darkTokens(), stub.bin);
    assert.equal(result.report.targets.gtk.error, null);
    assert.equal(stub.value("text-scaling-factor"), "1.25");
    assert.ok(!gsettingsCalls(stub).some(line =>
        line.startsWith(`gsettings set ${SCHEMA} text-scaling-factor`)));
});
