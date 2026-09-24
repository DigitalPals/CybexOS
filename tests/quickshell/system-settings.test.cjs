const test = require("node:test");
const assert = require("node:assert/strict");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const vm = require("node:vm");
const { shellDir } = require("./shell.cjs");

test("system settings preserve profiles, roll back trials and validate changing device identities", () => {
    const result = spawnSync("python3", [path.join(__dirname, "../system-settings.py")], {
        encoding: "utf8", timeout: 30000,
        env: { ...process.env, PYTHONDONTWRITEBYTECODE: "1" },
    });
    assert.equal(result.status, 0, result.stdout + result.stderr);
});

function backend() {
    const source = fs.readFileSync(path.join(shellDir, "Common/SystemSettingsBackend.qml"), "utf8");
    const calls = [];
    const context = vm.createContext({
        watchers: 0, preview: null, busy: false, loading: false, revision: 0,
        refreshQueued: false, error: "", message: "",
        snapshotProc: { running: false, signal: value => calls.push(["stop-snapshot", value]) },
        actionProc: { running: false },
    });
    for (const name of ["acquire", "release", "refresh", "run", "decode"]) {
        const match = source.match(new RegExp(`^    function ${name}\\([^]*?^    }`, "m"));
        assert.ok(match, name);
        vm.runInContext(match[0], context);
    }
    return { context, calls };
}

test("settings service claims share reads and release a pending trial only after the last consumer", () => {
    const { context: c, calls } = backend();
    c.acquire();
    assert.equal(c.snapshotProc.running, true);
    c.acquire();
    c.preview = { checkpoint: "/trial" };
    c.release();
    assert.equal(c.actionProc.running, false);
    c.release();
    assert.equal(c.watchers, 0);
    assert.deepEqual(JSON.parse(JSON.stringify(c.request)), { action: "rollback", checkpoint: "/trial" });
    assert.deepEqual(calls, [["stop-snapshot", 15]]);
});

test("a trial blocks a second network edit and overlapping reads are queued", () => {
    const { context: c } = backend();
    c.preview = { checkpoint: "/trial" };
    assert.equal(c.run({ action: "apply" }), false);
    assert.equal(c.actionProc.running, false);
    assert.equal(c.run({ action: "confirm" }), true);
    c.loading = true;
    c.refresh();
    assert.equal(c.refreshQueued, true);
});

test("broken service output becomes a bounded error rather than a parser exception", () => {
    const { context: c } = backend();
    assert.equal(c.decode("not JSON", 0).success, false);
    for (const body of ["null", "[]", "42", '"text"', "{}"])
        assert.equal(c.decode(body, 0).success, false);
    assert.equal(c.decode('{"success":true}', 2).success, false);
    assert.equal(c.decode('{"success":true}', 0).success, true);
});

const read = file => fs.readFileSync(path.join(shellDir, file), "utf8");

test("system pages speak about their service only when there is something to say", () => {
    const status = read("Settings/SystemServiceStatus.qml");
    assert.match(status, /visible: text !== ""/);
    assert.match(status, /visible: !!root\.service && root\.service\.error !== ""\s+text: "Refresh"/,
        "Refresh is offered after a failure, not as a standing button");
});

test("Network lists saved connections and drafts the selected one behind an Apply bar", () => {
    const page = read("Settings/NetworkPage.qml");
    const ip = read("Settings/IpSettings.qml");
    assert.doesNotMatch(page, /label: "Saved connection"|Changes apply only to the selected connection/);
    assert.match(page,
        /delegate: ChoiceRow \{[\s\S]*?meta: profile\.active \? "Connected" : ""[\s\S]*?onActivated: page\.load\(connection\.modelData\)/);
    // Choosing another connection would drop the edits made to this one.
    assert.match(page, /enabled: !page\.trialActive && !page\.service\.busy && \(!page\.dirty \|\| checked\)/);
    assert.match(page, /title: page\.draft \? page\.draft\.name : ""/);
    assert.match(page, /overlay: ApplyBar \{/);
    assert.match(page, /onApply: page\.applyChanges\(\)[\s\S]*?onKeep: page\.keep\(\)[\s\S]*?onRevert: page\.revert\(\)/);
    // Manual addressing reveals labelled fields; the DNS field says whether it
    // adds to the network's own servers, which is how NetworkManager uses it.
    assert.match(ip, /label: "Address"/);
    assert.match(ip, /label: "Gateway"/);
    assert.match(ip, /label: root\.config\.autoDns \? "Additional DNS" : "DNS servers"/);
    // Each keystroke reaches the draft, so the Apply bar appears while typing.
    assert.match(read("Settings/DraftFieldRow.qml"), /onTextEdited: root\.edited\(text\)/);
});

test("Sound is built from settings rows over the drawer's data, not the drawer itself", () => {
    const page = read("Settings/SoundPage.qml");
    assert.doesNotMatch(page, /DrawerSound|Popovers\/Drawer/);
    assert.match(page, /AudioHelpers\.outputDevices\(/);
    assert.match(page, /onActivated: Audio\.setDefaultSink\(/);
    assert.match(page, /onActivated: Audio\.setDefaultSource\(/);
    assert.match(page, /PwNodePeakMonitor \{/);
    assert.match(page, /SettingsDisclosure \{[\s\S]*?" network outputs"/, "network outputs stay folded");
    // Ports, balance, profiles and routing still go through the pactl helper.
    for (const action of ["port", "balance", "profile", "route"])
        assert.match(page, new RegExp(`action: "${action}"`), action);
    assert.match(page, /SystemSettings\.openExternal\("sound"\)/);
});
