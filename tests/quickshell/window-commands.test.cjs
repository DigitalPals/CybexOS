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
    assert.equal(W.moveWindow("abc", { id: -1337, name: "a\"b" }), "");
    assert.equal(W.moveWindow("abc", { id: -1337, name: "x\n" }), "");
    assert.equal(W.moveWindow("zz", { id: 2 }), "");
    assert.equal(W.focusWorkspace(0), "");
    assert.equal(W.focusWorkspace(1.5), "");
    assert.equal(W.focusWorkspace(null), "");
});

test("the launcher's own focus string agrees with the shared builder", () => {
    const providers = fs.readFileSync(path.join(shellDir, "Common/LauncherProviders.qml"), "utf8");
    assert.match(providers, /hl\.dsp\.focus\(\{ window = "address:0x'\s*\+ row\.win\.address \+ '" \}\)/);
    assert.equal(W.focusWindow("abc"), 'hl.dsp.focus({ window = "address:0x' + "abc" + '" })');
});
