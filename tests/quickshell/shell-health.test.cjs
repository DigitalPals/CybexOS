const test = require("node:test");
const { untranslated } = require("./shell.cjs");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const shellRoot = path.resolve(__dirname,
    "../../desktop/quickshell");
const health = untranslated(fs.readFileSync(path.join(shellRoot, "Common/ShellHealth.qml"), "utf8"));
// Home's "About this computer" group took over About's shell health.
const page = untranslated(fs.readFileSync(path.join(shellRoot, "Settings/HomePage.qml"), "utf8"));
const helper = untranslated(fs.readFileSync(path.join(shellRoot, "scripts/shell-health.py"), "utf8"));

test("Shell Health is read-only, bounded, and refreshable", () => {
    assert.match(health, /readonly property var integrationIssues/);
    assert.match(health, /FileView\s*{[\s\S]*?watchChanges:\s*true/);
    assert.match(health, /command:\s*\["python3", root\.helper\]/);
    assert.match(health, /property bool exitSeen:\s*false/);
    assert.match(health, /Qt\.callLater\(root\.finishProbe\)/);
    assert.doesNotMatch(health, /systemctl[\s\S]{0,40}?(restart|stop|start)/);
    assert.match(helper, /return warnings\[-3:\]/);
    assert.match(helper, /len\(compact\) > 240/);
    assert.match(page, /title:\s*"About this computer"[\s\S]*?label:\s*"Desktop shell"/);
    assert.match(page, /onVisibleChanged:[\s\S]*?ShellHealth\.refresh\(\)/);
    assert.match(page, /text:\s*ShellHealth\.busy \? "Checking" : "Refresh"[\s\S]*?ShellHealth\.refresh\(\)/);
});
