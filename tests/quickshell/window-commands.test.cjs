const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { load, shellDir } = require("./shell.cjs");

const W = load("WindowCommands.js");

test("addresses are bare hex in, 0x-prefixed selectors out", () => {
    assert.equal(W.bareAddress("55d0c0ffee10"), "55d0c0ffee10");
    assert.equal(W.bareAddress("0x55D0C0FFEE10"), "55d0c0ffee10");
    assert.equal(W.windowSelector("abc"), "\"address:0xabc\"");
    for (const bad of ["", null, undefined, "xyz", "0x", "12345678901234567", "ab\" })", "1 2"])
        assert.equal(W.bareAddress(bad), "", String(bad));
});

test("dispatches are the Lua forms Hyprland 0.56 accepts", () => {
    assert.equal(W.focusWindow("abc"), "hl.dsp.focus({ window = \"address:0xabc\" })");
    assert.equal(W.closeWindow("abc"), "hl.dsp.window.close({ window = \"address:0xabc\" })");
    assert.equal(W.moveWindow("abc", { id: 4, name: "4" }),
        "hl.dsp.window.move({ workspace = 4, follow = false, window = \"address:0xabc\" })");
    assert.equal(W.focusWorkspace(3), "hl.dsp.focus({ workspace = 3 })");
    assert.equal(W.focusWorkspace({ id: -1337, name: "music" }),
        "hl.dsp.focus({ workspace = \"name:music\" })");
});

test("nothing unvalidated reaches the Lua expression", () => {
    // Hyprland acts on the active window when a selector does not resolve,
    // so a bad address must produce no dispatch at all.
    assert.equal(W.focusWindow("\"; os.execute(\"x\") --"), "");
    assert.equal(W.closeWindow(""), "");
    assert.equal(W.moveWindow("abc", { id: -98, name: "special:scratchpad" }), "",
        "special workspaces are never a destination");
    assert.equal(W.moveWindow("abc", { id: -1337, name: "a\"b" }),
        'hl.dsp.window.move({ workspace = "name:a\\"b", follow = false, window = "address:0xabc" })');
    assert.equal(W.moveWindow("abc", { id: -1337, name: "x\n" }), "");
    assert.equal(W.moveWindow("zz", { id: 2 }), "");
    assert.equal(W.focusWorkspace(0), "");
    assert.equal(W.focusWorkspace(1.5), "");
    assert.equal(W.focusWorkspace(null), "");
});

test("positive-ID renamed workspaces use quoted native selectors, never numbered APIs", () => {
    const target = { id: 1, name: "research" };
    assert.equal(W.workspaceKind(target), "named");
    assert.equal(W.focusWorkspace(target), 'hl.dsp.focus({ workspace = "name:research" })');
    assert.equal(W.moveWindow("abc", target),
        'hl.dsp.window.move({ workspace = "name:research", follow = false, window = "address:0xabc" })');
    for (const builder of [W.desktopFocus, W.desktopCycleLayout])
        assert.equal(builder(target), "");
    assert.equal(W.desktopMove("abc", target), "");
    assert.equal(W.desktopLayout(target, "floating"), "");
    const labeled = { id: 41, name: "1", kind: "numbered", workspaceName: "41" };
    assert.equal(W.desktopFocus(labeled), 'require("workspaces").focus_id(41)');
    const hostile = { id: 1, kind: "named", workspaceName: 'research\\";error("x")' };
    assert.equal(W.workspaceArgument(hostile), W.luaString('name:' + hostile.workspaceName));
    for (const name of ["special:scratchpad", "special", "bad\nname", "a".repeat(252)])
        assert.equal(W.focusWorkspace({ id: 1, kind: "named", workspaceName: name }), "");
});

test("the launcher uses the live checked restore-before-focus owner", () => {
    const providers = fs.readFileSync(path.join(shellDir, "Common/LauncherProviders.qml"), "utf8");
    assert.match(providers, /row\.win && DesktopWorkspaces\.activate\(row\.win\.address\)/);
    assert.equal(W.focusWindow("abc"), 'hl.dsp.focus({ window = "address:0x' + "abc" + '" })');
});
