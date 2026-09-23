const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { shellDir } = require("./shell.cjs");

// Two rules the shell now follows, both easy to forget on the next widget:
//
//   - a click target says so with the cursor, and
//   - anything Tab can land on has a role and a name, because a focus ring
//     with nothing to announce is worse than no focus ring at all.
//
// Neither is something QML or qmllint can notice.

function qmlFiles(dir = ".") {
    const out = [];
    for (const e of fs.readdirSync(path.join(shellDir, dir), { withFileTypes: true })) {
        const rel = dir === "." ? e.name : path.join(dir, e.name);
        if (e.isDirectory() && !["tests", "assets", "scripts"].includes(e.name))
            out.push(...qmlFiles(rel));
        else if (e.name.endsWith(".qml"))
            out.push(rel);
    }
    return out;
}

function read(rel) {
    return fs.readFileSync(path.join(shellDir, rel), "utf8");
}

// The block opened by the line at `start`, by brace depth.
function blockAt(lines, start) {
    let depth = 0;
    for (let j = start; j < lines.length; j++) {
        depth += (lines[j].match(/\{/g) || []).length;
        depth -= (lines[j].match(/\}/g) || []).length;
        if (depth === 0) return lines.slice(start, j + 1);
    }
    return lines.slice(start);
}

// The object a property line belongs to: the nearest enclosing line that
// opens a block at a shallower indent.
function ownerBlock(lines, at) {
    const indent = lines[at].length - lines[at].trimStart().length;
    for (let j = at; j >= 0; j--) {
        const line = lines[j];
        if (line.trimEnd().endsWith("{")
                && line.length - line.trimStart().length < indent)
            return { head: line.trim(), body: blockAt(lines, j).join("\n") };
    }
    return null;
}

// A MouseArea that is not a click target: the cursor must not claim it is.
const CURSOR_EXEMPT = {
    "Bar/Bar.qml": "a right-button-only context area covering the whole bar",
    "LauncherWindow.qml": "the click-to-dismiss strip the launcher surface keeps around its card",
    "OsdWindow.qml": "a wheel handler; nothing in the OSD is clickable",
    "ShortcutsOverlay.qml": "the click-outside-to-dismiss scrim behind the sheet"
};

// Focus that exists so the keyboard can scroll, on a surface that draws no
// ring and has no label of its own to give.
const FOCUS_EXEMPT_HEADS = ["Flickable {"];

test("every clickable MouseArea says so with the cursor", () => {
    const missing = [];
    let checked = 0;
    for (const rel of qmlFiles()) {
        const lines = read(rel).split("\n");
        for (let i = 0; i < lines.length; i++) {
            if (!/^\s*MouseArea\s*\{\s*$/.test(lines[i])) continue;
            const body = blockAt(lines, i).join("\n");
            if (!/onClicked|onDoubleClicked|onPressed/.test(body)) continue;
            checked++;
            if (/cursorShape/.test(body)) continue;
            if (rel in CURSOR_EXEMPT) continue;
            missing.push(`${rel}:${i + 1}`);
        }
    }
    assert.ok(checked > 40, `only found ${checked} clickable MouseAreas`);
    assert.deepEqual(missing, [], "these click targets still show an arrow");
});

test("every cursor exemption still exists and still says why", () => {
    for (const [rel, reason] of Object.entries(CURSOR_EXEMPT)) {
        assert.ok(fs.existsSync(path.join(shellDir, rel)), `${rel} is gone`);
        assert.ok(reason.length > 20, `${rel} needs a real reason`);
        const lines = read(rel).split("\n");
        const bare = lines.some((l, i) => /^\s*MouseArea\s*\{\s*$/.test(l)
            && !/cursorShape/.test(blockAt(lines, i).join("\n")));
        assert.ok(bare, `${rel} no longer has an uncursored MouseArea — drop the exemption`);
    }
});

test("everything Tab can reach has a role and a name", () => {
    const missing = [];
    let checked = 0;
    for (const rel of qmlFiles()) {
        const lines = read(rel).split("\n");
        for (let i = 0; i < lines.length; i++) {
            if (!/^\s*(Accessible\.)?activeFocusOnTab:/.test(lines[i])) continue;
            const owner = ownerBlock(lines, i);
            if (!owner) continue;
            if (FOCUS_EXEMPT_HEADS.some(head => owner.head.endsWith(head))) continue;
            checked++;
            const named = /Accessible\.role:/.test(owner.body)
                && /Accessible\.name:/.test(owner.body);
            if (!named) missing.push(`${rel}:${i + 1} (${owner.head.slice(0, 40)})`);
        }
    }
    assert.ok(checked > 15, `only found ${checked} focusable objects`);
    assert.deepEqual(missing, [],
        "these draw a focus ring that announces nothing");
});
