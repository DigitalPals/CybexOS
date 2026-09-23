const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { shellDir, load } = require("./shell.cjs");

function read(relative) {
    return fs.readFileSync(path.join(shellDir, relative), "utf8");
}

test("the fixed Fedora button owns the ownerless Control Panel anchor", () => {
    const bar = read("Bar/Bar.qml");
    const registry = load("PanelRegistryData.js");
    const button = bar.slice(bar.indexOf("id: controlButton"),
        bar.indexOf("// ---- rearrange overlay"));

    assert.match(button, /BarChip|host:\s*barWindow/);
    assert.match(button, /panelName:\s*"control"/);
    assert.match(button, /tooltip:\s*"Control Panel"/);
    assert.match(button, /BarBrandIcon\s*\{/);
    assert.match(button, /name:\s*"fedora"/);
    assert.match(button, /width:\s*Theme\.barIconSize/);
    assert.match(button, /height:\s*Theme\.barIconSize/);
    assert.match(button,
        /highlighted:\s*controlButton\.held \|\| controlButton\.hovered/,
        "the Fedora mark must switch to its exact white SVG on hover");
    assert.equal(registry.byName("control").moduleId, "",
        "fixed bar furniture must not become a configurable module owner");
});

test("the Control Panel exposes five equal session actions with guarded destructive controls", () => {
    const control = read("Popovers/ControlCenterPopover.qml");
    const actions = control.match(/sessionActions:\s*\[([\s\S]*?)\n\s*\]/)?.[1] ?? "";
    const keys = [...actions.matchAll(/key:\s*"([^"]+)"/g)].map(match => match[1]);
    const labels = [...actions.matchAll(/label:\s*"([^"]+)"/g)].map(match => match[1]);

    assert.deepEqual(keys, ["lock", "suspend", "logout", "restart", "shutdown"]);
    assert.deepEqual(labels, ["Lock", "Suspend", "Log out", "Restart", "Shut down"]);
    assert.match(control, /text:\s*"SESSION"/);
    assert.match(control,
        /sessionActionWidth:\s*\n\s*Math\.max\(0, \(contentWidth - 4 \* sessionSpacing\) \/ 5\)/,
        "all five controls must divide one row equally");
    assert.match(control, /width:\s*root\.sessionActionWidth/);

    const trigger = control.match(/function triggerSession\(key\) \{([\s\S]*?)\n\s*\}/)?.[1] ?? "";
    assert.ok(trigger.indexOf("Popouts.close()") >= 0,
        "session actions must close the popout first");
    assert.ok(trigger.indexOf("Popouts.close()") < trigger.indexOf("switch (key)"));
    for (const method of ["lock", "suspend", "logout", "reboot", "shutdown"])
        assert.match(trigger, new RegExp(`Session\\.${method}\\(\\)`));

    const request = control.slice(control.indexOf("function requestSession(key)"),
        control.indexOf("function triggerSession(key)"));
    for (const key of ["logout", "reboot", "shutdown"])
        assert.match(request, new RegExp(`"${key}"`));
    assert.doesNotMatch(request, /"lock"|"suspend"/,
        "lock and suspend must not require destructive-action confirmation");
    assert.match(request, /pendingSessionKey !== key/);
    assert.match(request, /sessionConfirmTimer\.restart\(\)/);
    assert.match(request, /triggerSession\(key\)/);
    assert.match(control, /interval:\s*5000/);
    assert.match(control, /Accessible\.role:\s*Accessible\.AlertMessage/);

    const sessionAction = control.slice(
        control.indexOf("component SessionAction:"),
        control.indexOf("component StatCard:"));
    assert.match(sessionAction,
        /color:\s*armed \? Theme\.amberBg[\s\S]*actionMouse\.containsMouse \? Theme\.chipHover : Theme\.chip/);
    assert.match(sessionAction, /visibleLabel:\s*armed \? "Confirm" : label/);
    assert.match(sessionAction, /Accessible\.description:\s*armed/);
    assert.doesNotMatch(sessionAction, /Theme\.(?:red|redBg|redText|textOnAccent)/,
        "armed session actions use warning, not error, semantics");
});

test("session actions use the installed helper and report observed failures", () => {
    const session = read("Common/Session.qml");
    assert.match(session,
        /sessionAction\.command = \["\/usr\/local\/libexec\/cybexos-session-action", action\]/);
    assert.match(session, /readonly property bool actionBusy:\s*sessionAction\.running/);
    assert.match(session, /Process \{[\s\S]*id:\s*sessionAction/);
    assert.match(session, /ProcHelpers\.NOT_STARTED/);
    assert.match(session, /summary:\s*"Session action failed"/);
    assert.doesNotMatch(session, /sleep 0\.3|hyprlock.*&/,
        "suspend must not depend on an unobserved fixed delay");
});

test("launcher and session power compatibility routes toggle control", () => {
    const shell = read("shell.qml");
    const providers = read("Common/LauncherProviders.qml");
    const providerData = load("LauncherProviders.js");
    const session = read("Common/Session.qml");

    const ipcPower = shell.match(/function power\(\): void \{([\s\S]*?)\n\s*\}/)?.[1] ?? "";
    assert.match(ipcPower,
        /Popouts\.toggle\("control", undefined, undefined,[\s\S]*Screens\.focused/);

    const launcherPower = providers.slice(providers.indexOf('case "power":'),
        providers.indexOf("break;", providers.indexOf('case "power":')));
    assert.match(launcherPower,
        /Popouts\.toggle\("control", undefined, undefined,[\s\S]*Screens\.focused/);
    assert.equal(providerData.BUILTIN_ACTIONS.find(action => action.id === "power").name,
        "Open Control Panel");

    assert.doesNotMatch(session,
        /powerOpen|openMenu|closeMenu|toggleMenu/,
        "the retired overlay lifecycle must not survive in Session");
    assert.match(shell, /function lock\(\): void \{\s*Session\.lock\(\);/,
        "direct session actions keep their established IPC route");
    assert.match(shell,
        /function close\(\): void \{[\s\S]*Session\.closeAll\(\);[\s\S]*Popouts\.currentName === "control"[\s\S]*Popouts\.close\(\);/,
        "session close must dismiss the panel opened by session power");
});

test("the full-screen power overlay is retired from source and deployment", () => {
    assert.equal(fs.existsSync(path.join(shellDir, "PowerMenu.qml")), false);
    assert.doesNotMatch(read("qmldir"), /\bPowerMenu\b/);
    assert.doesNotMatch(read("shell.qml"), /\bPowerMenu\s*\{/);

    const tasks = fs.readFileSync(path.resolve(shellDir,
        "../../../desktop/tasks/main.yml"), "utf8");
    assert.match(tasks, /Remove files and links that are stale or unsafe copy destinations/,
        "deploys must remove every stale destination-only file");
    assert.match(tasks, /--exclude-standard/,
        "the manifest must include intended new source files but exclude ignored caches");
});
