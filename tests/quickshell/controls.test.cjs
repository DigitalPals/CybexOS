const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { shellDir } = require("./shell.cjs");

// Common/Toggle.qml and Common/HSlider.qml are the shell's only switch and
// slider. They used to be four types — a popover pair with no keyboard or
// Accessible support at all, and a settings pair that had both — and a popout
// does take keyboard focus while open, so the popover pair was genuinely
// unreachable rather than merely unlabelled.
//
// These assertions guard the outcome rather than the refactor: a second
// implementation reintroduces the split, and a call site that forgets
// `accessibleName` ships a control that a screen reader announces as
// "Toggle".

const CONTROLS = ["Toggle", "HSlider"];

function qmlFiles(dir = ".") {
    const out = [];
    for (const e of fs.readdirSync(path.join(shellDir, dir), { withFileTypes: true })) {
        const rel = dir === "." ? e.name : path.join(dir, e.name);
        if (e.isDirectory() && !["tests", "assets", "scripts"].includes(e.name))
            out.push(...qmlFiles(rel));
        else if (e.isFile() && e.name.endsWith(".qml"))
            out.push(rel);
    }
    return out;
}

function read(rel) {
    return fs.readFileSync(path.join(shellDir, rel), "utf8");
}

// The body of every `<Type> {` object declaration in a file, found by tracking
// brace depth from the opening line. Good enough for this tree's formatting,
// and it fails loudly rather than silently if a block never closes.
function blocksOf(type, source, rel) {
    const lines = source.split("\n");
    const out = [];
    for (let i = 0; i < lines.length; i++) {
        if (!new RegExp(`(^|[\\s(])${type}\\s*\\{\\s*$`).test(lines[i]))
            continue;
        let depth = 0;
        const body = [];
        for (let j = i; j < lines.length; j++) {
            depth += (lines[j].match(/\{/g) || []).length;
            depth -= (lines[j].match(/\}/g) || []).length;
            body.push(lines[j]);
            if (depth === 0) {
                out.push({ line: i + 1, body: body.join("\n") });
                break;
            }
        }
        assert.notEqual(out.at(-1)?.line, undefined,
            `${rel}:${i + 1}: unterminated ${type} block`);
    }
    return out;
}

test("the switch and the slider exist once, in Common/", () => {
    for (const control of CONTROLS) {
        // qs.Ui has a separately versioned, upstream-compatible Toggle API.
        const homes = qmlFiles().filter(f => !f.startsWith("Ui/")).filter(f => path.basename(f) === `${control}.qml`);
        assert.deepEqual(homes, [path.join("Common", `${control}.qml`)],
            `${control} must be defined exactly once, in Common/`);
    }
});

test("both controls carry the accessibility the popover copies lacked", () => {
    for (const control of CONTROLS) {
        const source = read(path.join("Common", `${control}.qml`));
        assert.match(source, /activeFocusOnTab:/,
            `${control} must be reachable by Tab`);
        assert.match(source, /Accessible\.role:/, `${control} needs an Accessible.role`);
        assert.match(source, /Accessible\.name: accessibleName/,
            `${control} must announce its call site's accessibleName`);
        assert.match(source, /Keys\.onPressed:/,
            `${control} must handle keys, not just clicks`);
    }
});

test("every switch and slider is given a name to announce", () => {
    const missing = [];
    for (const rel of qmlFiles()) {
        // The controls' own definitions declare the property, not a value.
        if (CONTROLS.includes(path.basename(rel, ".qml")))
            continue;
        const source = read(rel);
        for (const control of CONTROLS)
            for (const block of blocksOf(control, source, rel))
                if (!/\baccessibleName:/.test(block.body))
                    missing.push(`${rel}:${block.line}`);
    }
    assert.deepEqual(missing, [],
        "these controls would announce themselves by the generic default");
});

test("the name check would notice a call site that dropped the property", () => {
    // Without this the test above passes trivially if blocksOf stops matching.
    const found = qmlFiles()
        .flatMap(rel => CONTROLS.flatMap(c => blocksOf(c, read(rel), rel)))
        .filter(b => /\baccessibleName:/.test(b.body));
    assert.ok(found.length >= 6,
        `only found ${found.length} named controls — blocksOf has stopped matching`);
});

test("filled sliders keep their leading glyph inside a low-value fill", () => {
    const source = read("Popovers/FillSlider.qml");

    assert.match(source,
        /Math\.min\(width,\s*Math\.max\(height,\s*exact\)\)/,
        "a tiny non-zero value must render as a leading circle, not a vertical sliver");
    assert.match(source, /width:\s*root\.fillExtent/,
        "the painted fill must use the guarded visual extent");
});

test("shared state layers use Material interaction strengths", () => {
    const layer = read("Common/StateLayer.qml");
    const theme = read("Common/Theme.qml");
    assert.match(theme, /stateHoverOpacity:\s*0\.08/);
    assert.match(theme, /statePressedOpacity:\s*0\.12/);
    assert.match(layer,
        /opacity:\s*root\.pressed \|\| root\.focused \? Theme\.statePressedOpacity\s*:\s*root\.hovered \? Theme\.stateHoverOpacity : 0/);
    assert.match(read("Bar/BarHover.qml"), /StateLayer\s*\{/,
        "bar targets must adapt the shared state overlay in one place");
    for (const rel of [
        "Common/Toggle.qml", "Popovers/ActionButton.qml", "Popovers/IconButton.qml",
        "Settings/PillRow.qml", "Settings/SettingsAction.qml"
    ])
        assert.match(read(rel), /StateLayer\s*\{/,
            `${rel} does not use the shared state overlay`);
    for (const rel of [
        "Bar/BarIcon.qml", "Bar/BarChip.qml", "Bar/Workspaces.qml"
    ])
        assert.match(read(rel), /BarHover\s*\{/,
            `${rel} does not use the shared bar state overlay`);
    assert.match(read("Bar/BarIcon.qml"), /scale:\s*mouse\.pressed/,
        "the state layer must not replace bar press-scale feedback");
});

test("state layers ripple from the pointer and keyboard activation stays visible", () => {
    const layer = read("Common/StateLayer.qml");
    assert.match(layer, /function pulseAt\(x, y\)/);
    assert.match(layer, /onPressedChanged:/);
    assert.match(layer, /maskEnabled:\s*true/,
        "the ripple must be clipped to the control shape");
    assert.match(layer, /rippleAnimation\.restart\(\)/);

    for (const rel of [
        "Bar/BarIcon.qml", "Bar/BarChip.qml", "Bar/Workspaces.qml",
        "Common/Toggle.qml", "Popovers/ActionButton.qml", "Popovers/IconButton.qml",
        "Settings/PillRow.qml",
        "Settings/SettingsAction.qml", "Settings/SettingsView.qml"
    ])
        assert.match(read(rel), /pressPoint:\s*Qt\.point\(/,
            `${rel} does not pass the pointer origin to StateLayer`);

    for (const rel of [
        "Bar/Workspaces.qml", "Common/Toggle.qml", "Popovers/ActionButton.qml",
        "Popovers/IconButton.qml",
        "Settings/PillRow.qml", "Settings/SettingsAction.qml", "Settings/SettingsView.qml"
    ])
        assert.match(read(rel), /\.pulseCenter\(\)/,
            `${rel} does not echo non-pointer activation`);
});

test("switch and slider handles morph while pressed", () => {
    const toggle = read("Common/Toggle.qml");
    const slider = read("Common/HSlider.qml");

    assert.match(toggle, /restingSize:/);
    assert.match(toggle, /pressedSize:/);
    assert.match(toggle, /width:\s*toggleMouse\.pressed \? pressedSize : restingSize/);
    assert.match(toggle, /Behavior on width/);

    assert.match(slider, /width:\s*sliderMouse\.pressed \? 4 : 10/);
    assert.match(slider, /height:\s*sliderMouse\.pressed \? 18 : 10/);
    assert.match(slider, /Behavior on height/);
    assert.match(slider, /onPressed:\s*mouse =>/,
        "pointer interaction should focus the shared slider");
});
