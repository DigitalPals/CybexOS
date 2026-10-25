const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { shellDir } = require("./shell.cjs");
const {
    darkTokens, lightTokens, scratch, runDriver, renderTarget, stubBin,
} = require("./system-theme.cjs");

const repoRoot = path.resolve(__dirname, "../..");
const resolver = path.join(repoRoot, "assets/scripts/cybexos-runtime");
const template = path.join(repoRoot, "desktop/hypr/hyprlock.conf");
const HEADER = "# Cybex OS lock screen, rendered by the system theme (theme_hyprlock.py).";
const WALLPAPER = "/home/test/Pictures/Wallpapers/mountains.jpg";

function render(tokens) {
    const files = renderTarget("hyprlock", tokens);
    assert.deepEqual(Object.keys(files), ["hyprlock.conf"]);
    return files["hyprlock.conf"];
}

function withWallpaper(tokens, wallpaper) {
    return { ...tokens, wallpaper };
}

// The config as {section: [{key: value}]}, sections in file order.
function sections(config) {
    const out = [];
    let current = null;
    for (const line of config.split("\n")) {
        if (/^\w[\w-]* \{$/.test(line))
            out.push(current = { name: line.slice(0, -2), values: {} });
        else if (line === "}")
            current = null;
        else if (current) {
            const match = line.match(/^ {2}(\w+) =(?: (.*))?$/);
            assert.ok(match, `unexpected line: ${line}`);
            current.values[match[1]] = match[2] ?? "";
        }
    }
    return out;
}

function section(config, name, index = 0) {
    return sections(config).filter(s => s.name === name)[index].values;
}

// ---- WCAG contrast, over hyprlock's sRGB-space blending ----------------------
function channels(hex) {
    return [1, 3, 5].map(i => parseInt(hex.slice(i, i + 2), 16) / 255);
}

function luminance(hex) {
    const [r, g, b] = channels(hex).map(c => c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4);
    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

function contrast(a, b) {
    const [x, y] = [luminance(a), luminance(b)].sort((p, q) => q - p);
    return (x + 0.05) / (y + 0.05);
}

// `top` at `alpha` over `bottom`, as "#rrggbb".
function over(top, alpha, bottom) {
    const t = channels(top), b = channels(bottom);
    return "#" + t.map((c, i) => Math.round((c * alpha + b[i] * (1 - alpha)) * 255)
        .toString(16).padStart(2, "0")).join("");
}

// "rgba(rrggbbaa)" -> ["#rrggbb", alpha]
function parseRgba(value) {
    const match = value.match(/^rgba\(([0-9a-f]{6})([0-9a-f]{2})\)$/);
    assert.ok(match, `not rgba(rrggbbaa): ${value}`);
    return ["#" + match[1], parseInt(match[2], 16) / 255];
}

function markupColor(value) {
    const match = value.match(/^<span foreground="##([0-9a-f]{6})">[^<>"]+<\/span>$/);
    assert.ok(match, `not escaped Pango markup: ${value}`);
    return "#" + match[1];
}

test("the lock screen renders the shell's font and colours over a solid base", () => {
    const tokens = darkTokens();
    tokens.wallpaper = "";
    const config = render(tokens);
    const lines = config.split("\n");
    assert.equal(lines[0], HEADER);
    assert.equal(lines[2], "$font = JetBrainsMono Nerd Font");
    assert.deepEqual(sections(config).map(s => s.name),
        ["general", "animations", "background", "label", "label", "input-field", "label"]);
    assert.deepEqual(section(config, "background"), { monitor: "", color: "rgba(1a1917ff)" });
    assert.equal(section(config, "label", 0).color, "rgba(f2f0eaff)");
    assert.equal(section(config, "label", 1).color, "rgba(b3afa4ff)");
    const field = section(config, "input-field");
    assert.equal(field.inner_color, "rgba(201e1bd9)");
    assert.equal(field.outer_color, "rgba(3a3936ff)");
    assert.equal(field.check_color, "rgba(60a5faff)");
    assert.equal(field.fail_color, "rgba(ff8f8fff)");
    assert.equal(field.placeholder_text, '<span foreground="##b3afa4">Password</span>');
    // $FAIL is the latest failure from PAM or hyprlock's fingerprint check.
    assert.equal(field.fail_text, '<span foreground="##ff8f8f">$FAIL</span>');
    // The fingerprint prompt under the field is empty, so unseen, unless
    // cybexos-runtime turns on hyprlock's fprintd check (docs/security.md).
    const prompt = section(config, "label", 2);
    assert.equal(prompt.text, "$FPRINTPROMPT");
    assert.equal(prompt.color, "rgba(b3afa4ff)");
    assert.equal(field.font_family, "$font");
    assert.doesNotMatch(config, /^shape \{$/m);
});

test("the lock screen shows the wallpaper blurred under a scrim of the base colour", () => {
    for (const tokens of [darkTokens(), withWallpaper(lightTokens(), WALLPAPER)]) {
        const config = render(tokens);
        const background = section(config, "background");
        assert.equal(background.path, WALLPAPER);
        assert.equal(background.color, `rgba(${tokens.colors.background.slice(1)}ff)`,
            "a wallpaper hyprlock cannot load falls back to the base colour");
        assert.equal(background.blur_passes, "3");
        assert.equal(background.brightness, "1.0");
        assert.equal(background.contrast, "1.0");
        const shape = section(config, "shape");
        assert.equal(shape.size, "100%, 100%");
        // hyprlock's zindex sort is unstable: the order must not rest on ties.
        assert.deepEqual([background.zindex, shape.zindex], ["-2", "-1"]);
        const [scrim, alpha] = parseRgba(shape.color);
        assert.equal(scrim, tokens.colors.background);
        assert.ok(alpha >= 0.5 && alpha <= 0.9, `scrim alpha ${alpha}`);
    }
    assert.equal(section(render(lightTokens()), "background").path, undefined);
});

test("every lock screen text reaches 4.5:1 on the worst backdrop", () => {
    const cases = [
        withWallpaper(darkTokens(), ""), darkTokens(),
        withWallpaper(lightTokens(), ""), withWallpaper(lightTokens(), WALLPAPER),
    ];
    // A pale wallpaper-palette base that the fixed text ladder would fail on.
    const pale = withWallpaper(lightTokens(), WALLPAPER);
    pale.colors = { ...pale.colors, background: "#c9c6d8", surface: "#d4d1e0", textMuted: "#6b6880" };
    cases.push(pale);
    for (const tokens of cases) {
        const config = render(tokens);
        const base = tokens.colors.background;
        const backdrops = tokens.wallpaper
            ? ["#000000", "#ffffff"].map(extreme => over(base, parseRgba(section(config, "shape").color)[1], extreme))
            : [base];
        const field = section(config, "input-field");
        const [inner, innerAlpha] = parseRgba(field.inner_color);
        const fills = backdrops.map(backdrop => over(inner, innerAlpha, backdrop));
        const checks = [
            ["clock", parseRgba(section(config, "label", 0).color)[0], backdrops],
            ["date", parseRgba(section(config, "label", 1).color)[0], backdrops],
            ["dots", parseRgba(field.font_color)[0], fills],
            ["placeholder", markupColor(field.placeholder_text), fills],
            ["failure", markupColor(field.fail_text), fills],
            ["fingerprint prompt", parseRgba(section(config, "label", 2).color)[0], backdrops],
        ];
        for (const [name, color, behind] of checks)
            for (const backdrop of behind)
                assert.ok(contrast(color, backdrop) >= 4.49,
                    `${tokens.mode} ${tokens.wallpaper ? "wallpaper" : "solid"} ${name} `
                    + `${color} on ${backdrop}: ${contrast(color, backdrop).toFixed(2)}`);
    }
});

test("rendering is deterministic and embeds only safe values", () => {
    for (const tokens of [darkTokens(), lightTokens()]) {
        const config = render(tokens);
        assert.equal(render(tokens), config);
        assert.ok(config.endsWith("}\n"));
        const body = config.split("\n").slice(2);
        for (const line of body) {
            // Outside the header, every '#' is hyprlang's '##' escape.
            assert.doesNotMatch(line.replaceAll("##", ""), /#/, line);
            assert.ok(line === "" || line === "}" || /^\w[\w-]* \{$/.test(line)
                || /^\$font = [A-Za-z0-9 ._+-]+$/.test(line) || /^ {2}\w+ =( |$)/.test(line), line);
        }
        // Only the vendor's own hyprlock variables appear.
        assert.deepEqual([...new Set(config.match(/\$\w+/g))].sort(), ["$FAIL", "$FPRINTPROMPT", "$TIME", "$font"]);
    }
});

test("a wallpaper name hyprlang would misread shows the solid background", () => {
    for (const wallpaper of ["/w/a#1.jpg", "/w/$font.jpg", "/w/{a}.png", "/w/trailing.jpg "]) {
        const config = render(withWallpaper(darkTokens(), wallpaper));
        assert.equal(section(config, "background").path, undefined, wallpaper);
        assert.doesNotMatch(config, /^shape \{$/m, wallpaper);
    }
    const spaced = render(withWallpaper(darkTokens(), "/w/Snow Peak (2).webp"));
    assert.equal(section(spaced, "background").path, "/w/Snow Peak (2).webp");
});

test("apply writes the lock screen and reload touches nothing", t => {
    const state = scratch(t);
    // Other targets' reloads may need commands this PATH lacks; only the
    // lock screen's report matters here.
    const stubs = stubBin(t, { hyprlock: "exit 1", pkill: "exit 1", loginctl: "exit 1" });
    const first = runDriver(state, ["apply"], JSON.stringify(darkTokens()) + "\n", { bin: stubs.bin });
    assert.ok(first.report, first.stderr);
    assert.deepEqual(first.report.targets.hyprlock, { changed: true, error: null });
    const file = path.join(state, "hyprlock.conf");
    assert.equal(fs.readFileSync(file, "utf8"), render(darkTokens()));
    assert.equal(fs.statSync(file).mode & 0o777, 0o644);
    const again = runDriver(state, ["apply", "--force"], JSON.stringify(darkTokens()) + "\n",
        { bin: stubs.bin });
    assert.deepEqual(again.report.targets.hyprlock, { changed: false, error: null });
    // pkill is the kitty target's reload; nothing may start or signal a lock.
    assert.deepEqual(stubs.calls().filter(call => !call.startsWith("pkill ")), []);
});

test("the vendor lock screen adds the bundled default to the same dark controls", () => {
    const vendor = fs.readFileSync(template, "utf8");
    // Installed with NixOS modules's template module: it must stay free of Jinja.
    assert.doesNotMatch(vendor, /\{[{%#]/);
    const rendered = render(withWallpaper(darkTokens(), ""));
    const lines = rendered.split("\n");
    assert.equal(lines[0], HEADER);
    assert.match(lines[1], /^# /);
    assert.match(vendor, /path = \$CYBEXOS_DEFAULT_WALLPAPER/);
    assert.match(vendor, /blur_passes = 3/);
    assert.match(vendor, /brightness = 0.4/);
    const withoutBackdrop = vendor.replace(/^  (?:path|blur_passes|blur_size|brightness) = .*\n/gm, "");
    assert.equal(withoutBackdrop, lines.slice(2).join("\n"),
        "the fallback before the shell's first export must match the renderer");
});

function resolverFixture(t) {
    const root = scratch(t);
    const home = path.join(root, "home");
    const config = path.join(root, "config/cybexos");
    const runtime = path.join(root, "data/cybexos/runtime");
    const state = path.join(root, "state");
    fs.mkdirSync(path.join(config, "hypr"), { recursive: true });
    fs.mkdirSync(path.join(runtime, "hypr"), { recursive: true });
    fs.mkdirSync(path.join(state, "cybexos/theme"), { recursive: true });
    fs.mkdirSync(path.join(home, ".local/state/cybexos/theme"), { recursive: true });
    fs.copyFileSync(template, path.join(runtime, "hypr/hyprlock.conf"));
    // Never the real hyprlock: a stub that prints the arguments it was given.
    const hyprlock = path.join(root, "hyprlock");
    fs.writeFileSync(hyprlock, "#!/usr/bin/env bash\nprintf '%s\\n' \"$@\"\n", { mode: 0o755 });
    const script = path.join(root, "cybexos-runtime");
    const source = fs.readFileSync(resolver, "utf8");
    assert.ok(source.includes("exec hyprlock "));
    // The lock screen's PAM service and fingerprintPolicy's state, as fixtures.
    const lockPam = path.join(root, "pam.d/cybexos-lock");
    const fingerprintPolicy = path.join(root, "policy/fingerprint-enabled");
    for (const [system] of [["lock_pam=/etc/pam.d/cybexos-lock"], ["fingerprint_policy=/etc/cybexos/fingerprint-enabled"]])
        assert.ok(source.includes(system), system);
    fs.writeFileSync(script, source.replace("runtime_root=/etc/cybexos/runtime", `runtime_root=${runtime}`).replace("exec hyprlock ", `exec ${hyprlock} `)
        .replace("lock_pam=/etc/pam.d/cybexos-lock", `lock_pam=${lockPam}`)
        .replace("fingerprint_policy=/etc/cybexos/fingerprint-enabled", `fingerprint_policy=${fingerprintPolicy}`));
    return {
        root, home, lockPam, fingerprintPolicy,
        user: path.join(config, "hypr/hyprlock.conf"),
        vendor: path.join(runtime, "hypr/hyprlock.conf"),
        generated: path.join(state, "cybexos/theme/hyprlock.conf"),
        homeGenerated: path.join(home, ".local/state/cybexos/theme/hyprlock.conf"),
        exec(env = {}) {
            const result = spawnSync("bash", [script, "exec", "hyprlock"], {
                encoding: "utf8",
                env: { PATH: process.env.PATH, HOME: home, XDG_CONFIG_HOME: path.join(root, "config"),
                    XDG_DATA_HOME: path.join(root, "data"), XDG_STATE_HOME: state, ...env },
            });
            assert.equal(result.status, 0, result.stderr);
            const args = result.stdout.trim().split("\n");
            assert.deepEqual(args.slice(2), ["--immediate-render", "--no-fade-in", "--quiet"]);
            return args[1];
        },
    };
}

test("the lock starts with the user file, then the themed one, then the vendor one", t => {
    const f = resolverFixture(t);
    assert.equal(f.exec(), f.vendor);

    fs.writeFileSync(f.generated, render(darkTokens()));
    assert.equal(f.exec(), f.generated);

    fs.writeFileSync(f.user, "general {}\n");
    assert.equal(f.exec(), f.user);
    fs.rmSync(f.user);
    // A linked user file is not an override, as before.
    fs.symlinkSync(f.vendor, f.user);
    assert.equal(f.exec(), f.generated);
    fs.rmSync(f.user);

    // Without XDG_STATE_HOME the state lives under ~/.local/state.
    fs.writeFileSync(f.homeGenerated, render(lightTokens()));
    assert.equal(f.exec({ XDG_STATE_HOME: "" }), f.homeGenerated);

    // A missing vendor file does not stop the themed lock screen.
    fs.rmSync(f.vendor);
    assert.equal(f.exec(), f.generated);
});

test("a linked, empty or foreign themed file falls back to the vendor lock screen", t => {
    const f = resolverFixture(t);
    const valid = render(darkTokens());
    const target = path.join(path.dirname(f.generated), "elsewhere.conf");
    fs.writeFileSync(target, valid);
    fs.symlinkSync(target, f.generated);
    assert.equal(f.exec(), f.vendor);
    fs.rmSync(f.generated);

    for (const content of ["", "general {}\n", valid.slice(valid.indexOf("\n") + 1),
        " " + valid]) {
        fs.writeFileSync(f.generated, content);
        assert.equal(f.exec(), f.vendor, JSON.stringify(content.slice(0, 40)));
    }
    fs.rmSync(f.generated);
    fs.mkdirSync(f.generated);
    assert.equal(f.exec(), f.vendor);
});

test("the lock screen's text and field grow with the shell's text size", () => {
    const at = size => render({ ...withWallpaper(darkTokens(), WALLPAPER),
        font: { ...darkTokens().font, size } });
    const base = at(14);
    assert.equal(base, render(withWallpaper(darkTokens(), WALLPAPER)),
        "the default size renders exactly what an older export did");
    const large = at(21);
    const clock = section(large, "label", 0);
    const date = section(large, "label", 1);
    const field = section(large, "input-field");
    assert.equal(clock.font_size, "126");
    assert.equal(clock.position, "0, 225");
    assert.equal(date.font_size, "36");
    assert.equal(date.position, "0, 128");
    assert.equal(field.size, "450, 81");
    assert.equal(field.position, "0, -27");
    // Colours, the wallpaper and the scrim are untouched by size.
    assert.deepEqual(section(large, "background"), section(base, "background"));
    assert.deepEqual(section(large, "shape"), section(base, "shape"));
    // A small size keeps the same proportions.
    const small = at(10);
    assert.equal(section(small, "label", 0).font_size, "60");
    assert.equal(section(small, "input-field").size, "214, 39");
});

// cybexos-runtime adds the sign-in factors at lock time (docs/security.md).
test("the lock screen gains the fingerprint-free PAM service and hyprlock's fingerprint check", t => {
    const f = resolverFixture(t);
    const runtime = path.join(f.root, "run");
    fs.mkdirSync(runtime, { mode: 0o700 });
    const rendered = path.join(runtime, "cybexos/hyprlock.conf");
    // Without the PAM service, the file is used as it is: naming a missing
    // service would refuse every password.
    assert.equal(f.exec({ XDG_RUNTIME_DIR: runtime }), f.vendor);

    fs.mkdirSync(path.dirname(f.lockPam));
    fs.writeFileSync(f.lockPam, "auth include password-auth\n");
    fs.mkdirSync(path.dirname(f.fingerprintPolicy));

    assert.equal(f.exec({ XDG_RUNTIME_DIR: runtime }), rendered);
    let config = fs.readFileSync(rendered, "utf8");
    const vendor = fs.readFileSync(f.vendor, "utf8");
    assert.ok(config.startsWith(vendor), "the layout is kept byte for byte");
    assert.match(config, /auth \{\n  pam \{\n    module = cybexos-lock\n  \}/);
    assert.match(config, /fingerprint \{\n    enabled = false\n/,
        "no fingerprint check while fingerprintPolicy does not offer fingerprints");
    assert.equal((fs.statSync(rendered).mode & 0o077), 0, "the rendered file is private");

    fs.writeFileSync(f.fingerprintPolicy, "enabled\n");
    f.exec({ XDG_RUNTIME_DIR: runtime });
    config = fs.readFileSync(rendered, "utf8");
    assert.match(config, /fingerprint \{\n    enabled = true\n    ready_message = Touch the fingerprint reader or enter your password\n/);
    assert.doesNotMatch(config, /ignore_empty_input = false|security key/,
        "nothing about keys without a registered key");

    // The themed lock screen gets the same additions.
    fs.writeFileSync(f.generated, render(darkTokens()));
    f.exec({ XDG_RUNTIME_DIR: runtime });
    assert.ok(fs.readFileSync(rendered, "utf8").startsWith(render(darkTokens())));

    // A person's own lock file keeps exactly the authentication it sets.
    fs.writeFileSync(f.user, "general {}\n");
    assert.equal(f.exec({ XDG_RUNTIME_DIR: runtime }), f.user);
});

test("a registered security key can be used from an empty password field", t => {
    const f = resolverFixture(t);
    const runtime = path.join(f.root, "run");
    fs.mkdirSync(runtime, { mode: 0o700 });
    fs.mkdirSync(path.dirname(f.lockPam));
    fs.writeFileSync(f.lockPam, "-auth sufficient pam_u2f.so\nauth include password-auth\n");
    const mapping = path.join(f.home, ".config/Yubico/u2f_keys");
    fs.mkdirSync(path.dirname(mapping), { recursive: true });
    const user = require("node:os").userInfo().username;
    fs.writeFileSync(mapping, `someone-else:kh,pk,es256,+presence\n`);
    let config = fs.readFileSync(f.exec({ XDG_RUNTIME_DIR: runtime }), "utf8");
    assert.doesNotMatch(config, /security key/, "another account's key is not this account's");

    fs.writeFileSync(mapping, `${user}:kh,pk,es256,+presence`);
    config = fs.readFileSync(f.exec({ XDG_RUNTIME_DIR: runtime }), "utf8");
    // PAM tries the key when the field is submitted, so Enter on an empty
    // field must reach it, and the wait for a touch is named.
    assert.match(config, /^general:ignore_empty_input = false$/m);
    assert.match(config, />Password or security key<\/span>/);
    assert.match(config, /^ {2}placeholder_text = .*\n {2}check_text = Touch your security key if it flashes$/m);
});
