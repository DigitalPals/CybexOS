const test = require("node:test");
const { untranslated } = require("./shell.cjs");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { shellDir, load } = require("./shell.cjs");

// Settings > Security (docs/security.md): fingerprints and security keys as
// alternatives to the password. The Python side is covered by
// tests/nixos/test_security_settings.py; this holds the copy, the page's structure and
// its place in Settings.

const Security = load("SecurityHelpers.js");

function read(relative) {
    return untranslated(fs.readFileSync(path.join(shellDir, relative), "utf8"));
}

test("fingers read as words and new ones are offered in a fixed order", () => {
    assert.equal(Security.fingerLabel("right-index-finger"), "Right index finger");
    assert.equal(Security.fingerLabel("left-thumb"), "Left thumb");
    assert.equal(Security.fingerLabel(""), "Fingerprint");
    assert.deepEqual(Security.fingerOptions(["left-thumb", "right-index-finger", "nose"]), [
        { value: "right-index-finger", label: "Right index finger" },
        { value: "left-thumb", label: "Left thumb" },
    ]);
    assert.deepEqual(Security.fingerOptions(null), []);
    // The same names, in the same order, as the Python helper.
    const python = untranslated(fs.readFileSync(path.join(shellDir, "scripts/system_settings_security.py"), "utf8"));
    const names = python.match(/FINGERS = \(([^)]*)\)/)[1].match(/'([a-z-]+)'/g).map(name => name.slice(1, -1));
    assert.deepEqual(names, Security.FINGER_ORDER);
});

test("enrolment events are parsed defensively", () => {
    assert.deepEqual(Security.parseEnrolEvent('{"event":"started","stages":8,"scanType":"swipe"}'),
        { event: "started", result: "", message: "", stage: 0, stages: 8, scanType: "swipe" });
    assert.deepEqual(Security.parseEnrolEvent('{"event":"progress","result":"enroll-stage-passed","stage":3,"stages":8}'),
        { event: "progress", result: "enroll-stage-passed", message: "", stage: 3, stages: 8, scanType: "press" });
    for (const junk of ["", "not json", "[]", "null", '{"event":"exec"}', '{"stage":2}'])
        assert.equal(Security.parseEnrolEvent(junk), null, junk);
    const odd = Security.parseEnrolEvent('{"event":"progress","stage":-1,"stages":"8","result":5}');
    assert.equal(odd.stage, 0);
    assert.equal(odd.stages, 0);
    assert.equal(odd.result, "");
});

test("every fprintd enrolment result has plain words", () => {
    for (const result of ["enroll-stage-passed", "enroll-retry-scan", "enroll-swipe-too-short",
        "enroll-finger-not-centered", "enroll-remove-and-retry", "enroll-too-fast"]) {
        const text = Security.enrolStatus(result, "press");
        assert.match(text, /^[A-Z][^!]*\.$/, result);
        assert.notEqual(text, Security.enrolInstruction("press"), result);
    }
    assert.match(Security.enrolStatus("enroll-stage-passed", "swipe"), /Swipe again/);
    assert.equal(Security.enrolStatus("something-new", "swipe"), Security.enrolInstruction("swipe"));
    for (const result of ["enroll-duplicate", "enroll-data-full", "enroll-disconnected",
        "enroll-timeout", "enroll-failed", "enroll-unknown-error"])
        assert.match(Security.enrolFailure(result, ""), /^[A-Z][^!]*\.$/, result);
    assert.equal(Security.enrolFailure("unavailable", "No fingerprint reader is available."),
        "No fingerprint reader is available.");
    assert.equal(Security.stageLabel(3, 8), "3 of 8");
    assert.equal(Security.stageLabel(9, 8), "8 of 8");
    assert.equal(Security.stageLabel(3, 0), "");
});

test("a missing reader or key support is one short line, not empty controls", () => {
    assert.equal(Security.readerLine("ready"), "");
    assert.match(Security.readerLine("none"), /^No fingerprint reader was found\.$/);
    assert.ok(Security.readerLine("unavailable"));
    assert.equal(Security.keyLine("ready"), "");
    for (const state of ["missing", "inactive"])
        assert.match(Security.keyLine(state), /^[A-Z].*\.$/, state);

    const page = read("Settings/SecurityPage.qml");
    // Reader and key rows only exist for a usable reader / supported keys.
    assert.match(page, /visible: page\.readerReady\s*\n\s*label: "Reader"/);
    assert.match(page, /model: ScriptModel \{ values: page\.readerReady \? page\.fingers : \[\] \}/);
    assert.match(page, /model: ScriptModel \{ values: page\.keysReady \?/);
    assert.match(page, /SecurityHelpers\.readerLine\(page\.reader\.state\)/);
    assert.match(page, /SecurityHelpers\.keyLine\(page\.keys\.state\)/);
});

test("the page has Password, Fingerprint and Security keys groups", () => {
    const page = read("Settings/SecurityPage.qml");
    const groups = [...page.matchAll(/SettingsGroup \{\s*width: parent\.width\s*title: "([^"]+)"/g)].map(m => m[1]);
    assert.deepEqual(groups, ["Password", "Fingerprint", "Security keys"]);
    // The NixOS authentication policy is read-only here. Enrolment remains an
    // action; policy changes use a personal module and the staged lifecycle.
    const switches = [...page.matchAll(/SwitchRow \{[\s\S]*?label: "([^"]+)"/g)].map(m => m[1]);
    assert.deepEqual(switches, []);
    assert.match(page, /visible: page\.readerReady && page\.fingers\.length > 0\s*\n\s*label: "Use fingerprint/);
    assert.match(page, /value: page\.snapshot\.fingerprintAuth === true \? "Enabled" : "Disabled"/);
    assert.match(page, /hint: "Managed in \/etc\/nixos\/local"/);
    assert.match(page, /nerdos\.authentication\.fingerprint[\s\S]*nerd update stage local[\s\S]*apply the reviewed change/);
    assert.doesNotMatch(page, /action:\s*"fingerprint-auth"/,
        "a read-only policy indicator cannot attempt direct authentication changes");
    for (const action of ["Add fingerprint", "Remove fingerprint", "Remove key"])
        assert.match(page, new RegExp(`text: "${action}"`), action);
    assert.match(page, /text: page\.addingKey \? "Waiting…" : "Add security key"/);
    assert.doesNotMatch(page, /!"|!$/m, "no exclamation marks in the copy");
});

test("removals are confirmed inline before the backend is asked", () => {
    const page = read("Settings/SecurityPage.qml");
    assert.match(page, /text: "Remove…"[\s\S]{0,400}?onTriggered: page\.removingFinger = finger\.modelData/);
    assert.match(page, /label: "Remove this fingerprint\?"[\s\S]{0,700}?action: "delete-finger", finger: finger\.modelData,\s*confirmed: true/);
    assert.match(page, /text: "Remove…"[\s\S]{0,400}?onTriggered: page\.removingKey = key\.info\.id/);
    assert.match(page, /label: "Remove this key\?"[\s\S]{0,700}?action: "remove-key", id: key\.info\.id, confirmed: true/);
    // The Python side refuses an unconfirmed removal as well.
    const python = read("scripts/system_settings_security.py");
    assert.equal((python.match(/request\.get\('confirmed'\) is not True/g) || []).length, 2);
});

test("nothing on the page blocks the UI thread", () => {
    const page = read("Settings/SecurityPage.qml");
    // Reads and changes go through the shared backend's processes; the
    // enrolment streams through its own process and SplitParser.
    assert.match(page, /readonly property SystemSettingsBackend service: SystemSettings\.security/);
    assert.match(page, /Claim \{\s*active: page\.visible && Settings\.panelOpen/);
    assert.match(page, /Process \{\s*id: enroller\s*stdout: SplitParser \{ onRead: data => page\.handleEnrolEvent\(data\) \}/);
    assert.match(page, /"\/scripts\/system_settings_security\.py",\s*"enroll", enrolFinger\]/);
    assert.match(page, /enroller\.signal\(15\)/, "cancel asks the helper to release the reader");
    assert.doesNotMatch(page, /execSync|callSync|XMLHttpRequest/);
    const systemSettings = read("Common/SystemSettings.qml");
    assert.match(systemSettings, /security: SystemSettingsBackend \{ domain: "security" \}/);
    const backend = read("Common/SystemSettingsBackend.qml");
    assert.match(backend, /&& domain !== "security"/, "security is polled, never monitored");
    const dispatcher = read("scripts/system-settings.py");
    assert.match(dispatcher, /'security': SecuritySettings/);
});

test("Security is a System page that IPC, the rail and search reach", () => {
    const settings = read("Common/Settings.qml");
    assert.match(settings, /\{ id: "security", group: "System", label: "Security", glyph: "security",\s*description: "Fingerprints and security keys", system: true \}/);
    const view = read("Settings/SettingsView.qml");
    assert.match(view, /case "security": return securityPage;/);
    assert.match(view, /Component \{ id: securityPage; SecurityPage \{\} \}/);
    assert.match(read("Settings/qmldir"), /^SecurityPage SecurityPage\.qml$/m);
    const { ROWS, search } = load("SettingsSearchData.js");
    const rows = ROWS.filter(row => row.page === "security");
    assert.deepEqual(rows.map(row => row.label), ["Add fingerprint",
        "Use fingerprint to unlock and authorise", "Add security key"]);
    for (const row of rows) {
        assert.equal(row.key, "", "system state, not a shell.json key");
        assert.equal(row.pageLabel, "Security");
    }
    for (const query of ["fingerprint", "yubikey", "fido2", "sudo", "security key"])
        assert.ok(search(query).some(row => row.page === "security"), query);
});
