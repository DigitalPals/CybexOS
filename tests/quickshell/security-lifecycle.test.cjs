const test = require("node:test");
const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { shellDir } = require("./shell.cjs");

const repoDir = path.resolve(__dirname, "../..");

function readRepo(relative) {
    return fs.readFileSync(path.join(repoDir, relative), "utf8");
}

function readShell(relative) {
    return fs.readFileSync(path.join(shellDir, relative), "utf8");
}

test("desktop-open boundaries accept only HTTP(S) URLs", () => {
    const urls = require(path.join(shellDir, "Common/ExternalUrl.js"));
    assert.equal(urls.safeHttpUrl("https://github.com/o/r/pull/1"),
        "https://github.com/o/r/pull/1");
    assert.equal(urls.safeHttpUrl(" HTTP://example.test/thread "),
        "HTTP://example.test/thread");
    for (const unsafe of [
        "javascript:alert(1)",
        "file:///etc/passwd",
        "data:text/html,pwned",
        "t3code://app/",
        "https://example.test/\nfile:///etc/passwd",
        null,
    ])
        assert.equal(urls.safeHttpUrl(unsafe), "", String(unsafe));

    const facade = readShell("Common/T3Code.qml");
    const thread = readShell("Popovers/T3ThreadPage.qml");
    const cloud = readShell("scripts/t3-cloud.mjs");
    assert.match(facade,
        /function openExternalUrl\(value\)[\s\S]*ExternalUrl\.safeHttpUrl\(value\)[\s\S]*execDetached\(\["xdg-open", url\]\)/);
    assert.doesNotMatch(thread, /execDetached\(\["xdg-open"/,
        "thread and PR payloads must go through the shared URL allow-list");
    assert.ok((thread.match(/T3Code\.openExternalUrl\(/g) || []).length >= 5,
        "every T3 thread, PR, diff, and markdown opener must use the boundary");
    assert.match(cloud,
        /const \{ safeHttpUrl \} = require\("\.\.\/Common\/ExternalUrl\.js"\)/);
    assert.match(cloud,
        /function openBrowser\(url\)[\s\S]*safeHttpUrl\(url\)[\s\S]*spawn\(CLOUD_CONFIG\.browserCommand, \[safeUrl\]/);
});







test("control-center process toggles expose desired, pending, effective, and error state", () => {
    const control = readShell("Popovers/ControlCenterPopover.qml");
    assert.match(control, /property bool effective: on/);
    assert.match(control, /property bool pending: false/);
    assert.match(control, /property string error: ""/);
    assert.match(control, /Accessible\.checked: tile\.effective/);
    assert.match(control, /Accessible\.description: tile\.statusDescription/);
    for (const binding of [
        "effective: SysInfo.nightLightEffective",
        "pending: SysInfo.nightLightPending",
        "error: SysInfo.nightLightError",
        "effective: SysInfo.idleInhibitEffective",
        "pending: SysInfo.idleInhibitPending",
        "error: SysInfo.idleInhibitError",
    ])
        assert.ok(control.includes(binding), binding);
    assert.match(control,
        /visible: SysInfo\.nightLightError !== ""[\s\S]*SysInfo\.idleInhibitError !== ""[\s\S]*Accessible\.role: Accessible\.StaticText/);
});

test("settings rail reports and retries both load and save failures", () => {
    const view = readShell("Settings/SettingsView.qml");
    const settings = readShell("Common/Settings.qml");
    assert.match(view,
        /persistenceStatus:[\s\S]*Settings\.loadError[\s\S]*Settings\.loadErrorText[\s\S]*Settings\.saveError/);
    assert.match(view,
        /visible: Settings\.persistenceError && !Settings\.undoAvailable/);
    assert.match(view,
        /Accessible\.name: Settings\.loadError[\s\S]*"Retry loading settings"[\s\S]*"Retry saving settings"/);
    assert.match(view,
        /Settings\.loadError \? "Could not read settings"[\s\S]*Settings\.saveError \? "Could not save settings"/);
    assert.match(view,
        /Accessible\.role: Settings\.persistenceError[\s\S]*Accessible\.AlertMessage/);
    assert.match(settings,
        /function retrySave\(\) \{[\s\S]*if \(loadError\)[\s\S]*store\.reload\(\)[\s\S]*saveNow\(\)/);
});
