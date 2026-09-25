// Shared fixtures for the system theme tests: token exports as
// Common/SystemTheme.qml produces them, and runners for scripts/theme-apply.py
// and single target modules against a scratch state directory.
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { shellDir } = require("./shell.cjs");

const scriptsDir = path.join(shellDir, "scripts");
const driver = path.join(scriptsDir, "theme-apply.py");
// Resolved once, so the scrubbed PATH below never has to include /usr/bin.
const python = spawnSync("sh", ["-c", "command -v python3"], { encoding: "utf8" })
    .stdout.trim() || "/usr/bin/python3";

// The shell's fixed dark and light palettes with the default accent, the
// values SystemTheme exports on a fresh install.
function darkTokens() {
    return {
        v: 1, mode: "dark", source: "fixed",
        colors: {
            background: "#1a1917", surface: "#201e1b", surfaceRaised: "#26241f",
            bar: "#1a1917", text: "#f2f0ea", textMuted: "#b3afa4", textDim: "#97938a",
            accent: "#d3d283", onAccent: "#1c1c12", accentText: "#d3d283",
            accentContainer: "#7a7950", stroke: "#3a3936",
            red: "#ff8f8f", amber: "#ffc26e", green: "#63d68c",
        },
        font: { ui: "JetBrainsMono Nerd Font", mono: "JetBrainsMono Nerd Font" },
        radius: 16, glass: false,
        wallpaper: "/home/test/Pictures/Wallpapers/mountains.jpg",
    };
}

function lightTokens() {
    return {
        v: 1, mode: "light", source: "fixed",
        colors: {
            background: "#eae9ef", surface: "#f1f0f5", surfaceRaised: "#f8f7fa",
            bar: "#eae9ef", text: "#1f1d2b", textMuted: "#43415a", textDim: "#535168",
            accent: "#d3d283", onAccent: "#1c1c12", accentText: "#6b6a1c",
            accentContainer: "#e3e2bf", stroke: "#cfced6",
            red: "#c22f2f", amber: "#9a6414", green: "#1a7f47",
        },
        font: { ui: "Figtree", mono: "JetBrainsMono Nerd Font" },
        radius: 16, glass: true, wallpaper: "",
    };
}

function scratch(t) {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), "cybexos-tests.theme."));
    t.after(() => fs.rmSync(root, { recursive: true, force: true }));
    return root;
}

// Runs the driver. `env` is merged over a scrubbed environment whose PATH is
// only `bin` (a stubBin directory) or, without one, a directory that does
// not exist, so no test can ever signal a real kitty or change a real
// hyprctl or gsettings value. A target's reload must therefore resolve every
// command through PATH.
function runDriver(stateDir, args, input, options = {}) {
    const env = {
        HOME: options.home || stateDir,
        PATH: options.bin || path.join(stateDir, "no-commands"),
        PYTHONDONTWRITEBYTECODE: "1",
        CYBEXOS_THEME_STATE_DIR: stateDir,
        ...(options.env || {}),
    };
    const result = spawnSync(python, [driver, ...args], {
        input: input === undefined ? "" : input, encoding: "utf8", env,
    });
    let report = null;
    try {
        report = JSON.parse(result.stdout);
    } catch (e) {
        report = null;
    }
    return { status: result.status, stderr: result.stderr, report };
}

// Renders one target module in-process: {file name: content}.
function renderTarget(name, tokens) {
    const code = [
        "import json, sys",
        "import theme_tokens, theme_" + name + " as target",
        "tokens = theme_tokens.validate(json.loads(sys.stdin.read()))",
        "print(json.dumps(target.render(tokens)))",
    ].join("\n");
    const result = spawnSync(python, ["-c", code], {
        cwd: scriptsDir, input: JSON.stringify(tokens), encoding: "utf8",
        env: { ...process.env, PYTHONDONTWRITEBYTECODE: "1" },
    });
    if (result.status !== 0)
        throw new Error(result.stderr);
    return JSON.parse(result.stdout);
}

// A directory of stub commands that log their argv to calls.log, for
// asserting what a target's reload ran. `scripts` maps a command name to an
// optional shell body run after logging (default: exit 0).
function stubBin(t, scripts) {
    const bin = path.join(scratch(t), "bin");
    fs.mkdirSync(bin);
    const log = path.join(bin, "calls.log");
    for (const [name, body] of Object.entries(scripts)) {
        const file = path.join(bin, name);
        fs.writeFileSync(file, "#!/bin/sh\nprintf '%s' \"" + name + "\" >>'" + log + "'\n"
            + "for a in \"$@\"; do printf ' %s' \"$a\" >>'" + log + "'; done\n"
            + "printf '\\n' >>'" + log + "'\n" + (body || "exit 0") + "\n");
        fs.chmodSync(file, 0o755);
    }
    return {
        bin,
        calls: () => fs.existsSync(log)
            ? fs.readFileSync(log, "utf8").split("\n").filter(Boolean) : [],
    };
}

module.exports = {
    python, scriptsDir, driver, darkTokens, lightTokens, scratch, runDriver, renderTarget, stubBin,
};
