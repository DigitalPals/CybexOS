const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { shellDir } = require("./shell.cjs");

const repo = path.resolve(__dirname, "../..");
const rules = fs.readFileSync(path.join(repo, "desktop/hypr/looknfeel.lua"), "utf8");

test("window sizes are expressions, never percentage strings Hyprland ignores", () => {
    // Hyprland 0.56 applies `size = "monitor_w*0.6 monitor_h*0.7"` but
    // silently drops `size = { "60%", "70%" }`: the window keeps whatever
    // size its client asked for.
    assert.doesNotMatch(rules, /size\s*=\s*\{\s*"[^"]*%"/);
});
