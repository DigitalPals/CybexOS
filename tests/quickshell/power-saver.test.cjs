// Power saver is the user's explicit request to trade polish for battery.
// The shell follows it with its reduced-motion path; the compositor follows
// it with fewer blur passes and no animations.
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { shellDir } = require("./shell.cjs");

function read(relative) {
    return fs.readFileSync(path.join(shellDir, relative), "utf8");
}

test("power saver takes the reduced-motion path without changing the setting", () => {
    const theme = read("Common/Theme.qml");
    assert.match(theme,
        /readonly property bool reducedMotion:\s*Settings\.reducedMotion \|\| Activity\.powerSaver\s*\|\|/);
    // The Appearance switch keeps showing what the user chose.
    for (const file of ["Common/Theme.qml", "Common/Activity.qml"])
        assert.doesNotMatch(read(file), /Settings\.(?:set\("reducedMotion"|reducedMotion\s*=[^=])/, file);
});

test("the clock's text transition snaps instead of animating at zero duration", () => {
    const text = read("Common/AnimatedText.qml");
    assert.match(text,
        /Behavior on text \{\s*enabled: root\.animateChange && !Theme\.reducedMotion/,
        "a zero-duration transition still runs through the animation driver every minute");
});
