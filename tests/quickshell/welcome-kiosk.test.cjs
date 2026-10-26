// The welcome guide is drawn in the installer's design: the same tokens,
// the same zoom rule for the 1280×800 canvas, the same faces, full screen.
// docs/welcome.md; installer/kiosk/README.md.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const {shellDir} = require('./shell.cjs');
const root = path.resolve(shellDir, '../..');
const read = name => fs.readFileSync(path.join(shellDir, name), 'utf8');

// theme.slint writes #RRGGBBAA; QML writes #AARRGGBB.
function slintTokens() {
    const source = fs.readFileSync(path.join(root, 'installer/kiosk/ui/theme.slint'), 'utf8');
    const tokens = {};
    for (const match of source.matchAll(/out property <color> ([a-z0-9-]+): #([0-9a-f]{6})([0-9a-f]{2})?;/g)) {
        const name = match[1].replace(/-(\w)/g, (_, letter) => letter.toUpperCase()).replace(/-/g, '');
        tokens[name] = '#' + (match[3] || '') + match[2];
    }
    return tokens;
}

test('the guide uses the installer colours verbatim', () => {
    const qml = read('Welcome/Kiosk.qml');
    const tokens = slintTokens();
    assert.ok(Object.keys(tokens).length >= 18, JSON.stringify(tokens));
    for (const [name, value] of Object.entries(tokens)) {
        const own = qml.match(new RegExp(`readonly property color ${name}: "(#[0-9a-f]+)"`));
        assert.ok(own, `Kiosk.qml lacks ${name}`);
        assert.equal(own[1], value, name);
    }
    assert.match(qml, /readonly property string sans: "Space Grotesk"/);
    assert.match(qml, /readonly property string mono: "JetBrains Mono"/);
    // No Theme token reaches the guide's palette.
    assert.doesNotMatch(qml, /Theme\./);
});

test('the canvas zoom follows installer/kiosk/src/zoom.rs', () => {
    const qml = read('Welcome/Kiosk.qml');
    const body = qml.match(/function zoomFor\(width: real, height: real, ratio: real\): real \{([^]*?)\n    \}/);
    assert.ok(body, 'zoomFor');
    const zoomFor = vm.runInNewContext(`(function (width, height, ratio) {${body[1]}\n})`);
    // The installer's own vectors, in physical pixels.
    for (const [width, height, zoom] of [[1280, 800, 1], [1920, 1200, 1.5], [1920, 1080, 1.35],
        [2880, 1800, 2.25], [3840, 2160, 2.7]])
        assert.equal(zoomFor(width, height, 1), zoom, `${width}×${height}`);
    // Logical sizes under a compositor scale give the same physical zoom.
    assert.equal(zoomFor(1280, 800, 1.5) * 1.5, 1.5);
    assert.equal(zoomFor(2560, 1440, 1.5) * 1.5, 2.7);
    // The guide rounds down so the canvas always fits: 1.125 is 1.12, not 1.13.
    assert.equal(zoomFor(1440, 900, 1), 1.12);
    assert.ok(zoomFor(1366, 768, 1) * 800 <= 768 && zoomFor(1366, 768, 1) * 1280 <= 1366);
    // The guide fits small screens down to 0.6 rather than the installer's 0.8.
    assert.equal(zoomFor(1024, 600, 1), 0.75);
    assert.equal(zoomFor(640, 400, 1), 0.6);
    assert.equal(zoomFor(0, 0, 1), 1);
    const rust = fs.readFileSync(path.join(root, 'installer/kiosk/src/zoom.rs'), 'utf8');
    assert.match(rust, /pub const CANVAS: \(f32, f32\) = \(1280\.0, 800\.0\);/);
    assert.match(rust, /fit\.clamp\(0\.8, 3\.0\) \* 100\.0\)\.round\(\) \/ 100\.0/);
});

test('the guide is a full-screen overlay that steps aside and leaves a resume pill', () => {
    const window = read('WelcomeWindow.qml');
    assert.match(window, /WlrLayershell\.layer: WlrLayer\.Overlay/);
    assert.match(window, /anchors \{ top: true; left: true; right: true; bottom: true \}/);
    assert.match(window, /exclusionMode: ExclusionMode\.Ignore/);
    assert.match(window, /WlrLayershell\.keyboardFocus: root\.shown \? WlrKeyboardFocus\.Exclusive : WlrKeyboardFocus\.None/);
    assert.match(window, /value: Guide\.Kiosk\.zoomFor\(guide\.width, guide\.height/);
    assert.match(window, /visible: Welcome\.open && Welcome\.aside/);
    assert.match(window, /event\.name === "openwindow"/, 'a new window makes the guide step aside');
    assert.match(window, /Launcher\.open \|\| Overview\.open \|\| Session\.keysOpen/);
    assert.match(window, /readonly property Item contentItem: guide\.contentItem/);
    // The window rule for the old floating window is gone.
    assert.doesNotMatch(fs.readFileSync(path.join(root, 'desktop/hypr/looknfeel.lua'), 'utf8'), /Welcome to Cybex OS/);
});

test('steps open Settings only after stepping aside', () => {
    for (const name of fs.readdirSync(path.join(shellDir, 'Welcome')).filter(file => file.endsWith('.qml'))) {
        const source = read('Welcome/' + name);
        for (const match of source.matchAll(/Settings\.showPanel\(/g)) {
            const before = source.slice(Math.max(0, match.index - 200), match.index);
            assert.match(before, /Welcome\.stepAside\(false\);\s*$/, `${name} opens Settings without stepping aside`);
        }
    }
});

test('shortcut changes are applied or discarded on the way out of the step, not from its footer', () => {
    const step = read('Welcome/ShortcutsStep.qml');
    assert.doesNotMatch(step, /Keybindings\.(apply|discard)\(/, 'the step has no Apply bar');
    assert.match(step, /onNext: Welcome\.move\(1\)/);
    const welcome = read('Common/Welcome.qml');
    assert.match(welcome, /function move\(delta\) \{\s*leave\(/);
    assert.match(welcome, /step === "shortcuts" && target !== step && Keybindings\.dirty\) \{\s*leaving = target;\s*sheet = "shortcuts";/);
    assert.match(read('Welcome/WelcomeView.qml'), /shortcuts: "ShortcutChangesSheet\.qml"/);
    // The guide's own ways out ask too; only Hello's Not now and the resume
    // pill (the step is not on screen) dismiss directly.
    for (const name of fs.readdirSync(path.join(shellDir, 'Welcome')).filter(file => file.endsWith('.qml'))) {
        const source = read('Welcome/' + name);
        assert.doesNotMatch(source, /Welcome\.go\(/, name);
        if (!['HelloStep.qml', 'ResumePill.qml'].includes(name))
            assert.doesNotMatch(source, /Welcome\.dismiss\(/, `${name} closes the guide without asking`);
    }
    const sheet = read('Welcome/ShortcutChangesSheet.qml');
    assert.match(sheet, /Keybindings\.apply\(\)/);
    assert.match(sheet, /if \(Keybindings\.discard\(\)\) Welcome\.proceed\(\);/);
    assert.match(sheet, /function onApplied\(\) \{\s*if \(!root\.applying\) return;\s*root\.applying = false;\s*Welcome\.proceed\(\);/);
    assert.match(sheet, /kind: "primary"\s*focus: true/, 'Enter applies');
});

test('the desktop ships the installer faces and the wordmark', () => {
    const nix = fs.readFileSync(path.join(root, 'nix/modules/applications.nix'), 'utf8');
    assert.match(nix, /\.\.\/packages\/space-grotesk\.nix/);
    assert.match(nix, /\bjetbrains-mono\b/);
    const font = fs.readFileSync(path.join(root, 'nix/packages/space-grotesk.nix'), 'utf8');
    for (const face of ['Regular', 'Medium', 'Bold']) {
        assert.match(font, new RegExp(`SpaceGrotesk-${face}\\.ttf`));
        assert.ok(fs.existsSync(path.join(root, `installer/kiosk/assets/fonts/SpaceGrotesk-${face}.ttf`)));
    }
    assert.deepEqual(fs.readFileSync(path.join(shellDir, 'Welcome/assets/cybexos-logo.svg')),
        fs.readFileSync(path.join(root, 'installer/kiosk/assets/logo.svg')));
});
