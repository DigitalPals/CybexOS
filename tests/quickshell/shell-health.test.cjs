const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const shellRoot = path.resolve(__dirname,
    "../../roles/desktop/files/quickshell");
const health = fs.readFileSync(path.join(shellRoot, "Common/ShellHealth.qml"), "utf8");
const page = fs.readFileSync(path.join(shellRoot, "Settings/AboutPage.qml"), "utf8");
const helper = fs.readFileSync(path.join(shellRoot, "scripts/shell-health.py"), "utf8");

test("Shell Health is read-only, bounded, and refreshable", () => {
    assert.match(health, /readonly property var integrationIssues/);
    assert.match(health, /FileView\s*{[\s\S]*?watchChanges:\s*true/);
    assert.match(health, /command:\s*\["\/usr\/bin\/python3", root\.helper\]/);
    assert.match(health, /property bool exitSeen:\s*false/);
    assert.match(health, /Qt\.callLater\(root\.finishProbe\)/);
    assert.doesNotMatch(health, /systemctl[\s\S]{0,40}?(restart|stop|start)/);
    assert.match(helper, /return warnings\[-3:\]/);
    assert.match(helper, /len\(compact\) > 240/);
    assert.match(page, /title:\s*"Shell health"/);
    assert.match(page, /onVisibleChanged:[\s\S]*?ShellHealth\.refresh\(\)/);
    assert.match(page, /text:\s*ShellHealth\.busy \? "Checking" : "Refresh"[\s\S]*?ShellHealth\.refresh\(\)/);
});
