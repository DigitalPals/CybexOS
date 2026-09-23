// The shell settings reload cycle: our own saves must not come back as
// external edits, an editor's truncate-and-write must not reset or quarantine
// the file, a file from a newer shell must not be rewritten, and discovery of
// user plugins must degrade one plugin at a time rather than all at once.
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { shellDir, load } = require("./shell.cjs");

const H = load("SettingsHelpers.js");

function read(relative) {
    return fs.readFileSync(path.join(shellDir, relative), "utf8");
}

function functionSource(source, name) {
    const match = source.match(new RegExp("^    function " + name + "\\([^]*?^    }", "m"));
    assert.ok(match, `function ${name} not found`);
    return match[0];
}

test("normalizeKey stores what a save and reload would produce", () => {
    const d = H.defaults();
    for (const key of Object.keys(d))
        assert.deepEqual(H.normalizeKey(key, H.clone(d[key])), d[key], key);
    // A stepped slider quantizes by multiplication and lands off the grid.
    assert.equal(H.normalizeKey("scrollFactor", 7 * 0.1), 0.7);
    assert.equal(H.normalizeKey("barHeight", 999), 60);
    assert.equal(H.normalizeKey("themeMode", "sepia"), d.themeMode);
    // Expiries are written before their mode flips on; they must survive that.
    assert.equal(H.normalizeKey("idleInhibitUntilMs", 1234.5), 1234);
    assert.equal(H.normalizeKey("notifDndUntilMs", 99), 99);
    assert.equal(H.normalizeKey("notSetting", "kept"), "kept");
    const settings = Object.assign(H.defaults(), { scrollFactor: H.normalizeKey("scrollFactor", 0.30000000000000004) });
    const text = H.serialize(settings);
    assert.equal(H.serialize(H.merge(JSON.parse(text))), text,
        "a normalized value round-trips byte for byte");
});

test("a newer schema is recognized so it is never rewritten", () => {
    assert.equal(H.isNewerSchema({ v: H.VERSION + 1 }), true);
    assert.equal(H.isNewerSchema({ v: H.VERSION }), false);
    assert.equal(H.isNewerSchema({ v: 3 }), false);
    assert.equal(H.isNewerSchema({}), false);
    assert.equal(H.isNewerSchema(null), false);
});

function settingsHarness() {
    const source = read("Common/Settings.qml");
    const calls = { applied: 0, rechecks: 0, backups: 0, writes: 0 };
    const context = {
        SettingsHelpers: H, filePath: "/home/test/.config/cybexos/shell.json",
        loaded: false, ready: false, firstRun: false, migrationPending: false,
        loadError: false, loadErrorText: "", newerSchema: false, recheckPending: false,
        initialLoadHandled: false, lastPersistedText: "", savePending: false,
        announcement: "", corruptBackupPending: false, writeInFlight: false,
        saveError: false, writeSnapshot: "",
        saveTimer: { stop() {}, restart() {} },
        reloadTimer: { restart() { calls.rechecks++; } },
        store: { setText() { calls.writes++; } },
        FileViewError: { FileNotFound: 1, Unknown: 2, toString: String },
        console: { warn() {} },
        Quickshell: { env: () => "" },
        clearUndo() {},
        backUpCorruptFile() { calls.backups++; },
        // Runs once per full application of a loaded file.
        applyScrollFactor() {}, applyGlassEffect() { calls.applied++; }
    };
    context.root = context;
    context.defaults = H.defaults();
    Object.assign(context, H.defaults());
    vm.createContext(context);
    for (const name of ["snapshot", "seedWeatherFromEnv", "protectNewerFile", "assignChanged",
            "applyLoaded", "handleLoadFailure", "saveNow", "set"])
        vm.runInContext(functionSource(source, name), context);
    return { context, calls };
}

test("our own save echoes back as a no-op, byte for byte", () => {
    const { context, calls } = settingsHarness();
    const initial = H.serialize(Object.assign(H.defaults(), { scrollFactor: 0.7 }));
    context.applyLoaded(initial);
    assert.equal(context.loaded, true);
    assert.equal(calls.applied, 1);
    // Memory holds a value merge() would round differently; the reload of
    // the bytes we last persisted must still not re-apply every key.
    context.scrollFactor = 0.7000000000000001;
    context.applyLoaded(initial);
    assert.equal(calls.applied, 1, "an echo of the persisted bytes re-applied settings");
    // Writers normalize, so a drifted slider value never reaches memory.
    context.set("scrollFactor", 7 * 0.1);
    assert.equal(context.scrollFactor, 0.7);
    const external = H.serialize(Object.assign(H.defaults(), { scrollFactor: 1.2 }));
    context.applyLoaded(external);
    assert.equal(calls.applied, 2);
    assert.equal(context.scrollFactor, 1.2);
});

test("an external edit leaves unchanged var keys untouched", () => {
    const { context } = settingsHarness();
    context.applyLoaded(H.serialize(H.defaults()));
    const mods = context.mods;
    const modOpts = context.modOpts;
    // Each var-key reassignment notifies and rebuilds every bar module.
    context.applyLoaded(H.serialize(Object.assign(H.defaults(), { scrollFactor: 1.2 })));
    assert.equal(context.scrollFactor, 1.2);
    assert.equal(context.mods, mods, "an unchanged mods was reassigned");
    assert.equal(context.modOpts, modOpts, "an unchanged modOpts was reassigned");
});

test("an empty or partial file mid-session is re-read, not applied", () => {
    const { context, calls } = settingsHarness();
    const initial = H.serialize(Object.assign(H.defaults(), { barHeight: 40 }));
    context.applyLoaded(initial);
    assert.equal(calls.applied, 1);

    context.applyLoaded("");
    assert.equal(calls.rechecks, 1, "an empty reload schedules a second read");
    assert.equal(context.barHeight, 40);
    // The editor finished by the second read: the complete file applies.
    context.applyLoaded(H.serialize(Object.assign(H.defaults(), { barHeight: 44 })));
    assert.equal(context.barHeight, 44);

    context.applyLoaded('{"v": 2');
    assert.equal(calls.rechecks, 2);
    assert.equal(calls.backups, 0, "a half-written file is not moved aside on first sight");
    assert.equal(context.barHeight, 44);
    context.applyLoaded(H.serialize(Object.assign(H.defaults(), { barHeight: 46 })));
    assert.equal(context.barHeight, 46);
    assert.equal(context.firstRun, false);

    // Still empty on the second read: keep running values, not defaults.
    context.applyLoaded("");
    context.applyLoaded("");
    assert.equal(context.barHeight, 46);
    assert.equal(context.firstRun, false);

    // Still corrupt on the second read: now it is damage, and preserved.
    context.applyLoaded("{corrupt");
    assert.equal(calls.backups, 0);
    context.applyLoaded("{corrupt");
    assert.equal(calls.backups, 1);
});

test("only a missing file at startup is a first run", () => {
    const { context } = settingsHarness();
    context.handleLoadFailure(context.FileViewError.FileNotFound);
    assert.equal(context.firstRun, true);
    assert.equal(context.loaded, true);
});

test("a file from a newer shell applies but is never saved over", () => {
    const { context, calls } = settingsHarness();
    const newer = JSON.parse(H.serialize(Object.assign(H.defaults(), { barHeight: 50 })));
    newer.v = H.VERSION + 1;
    newer.futureKey = { keep: true };
    context.applyLoaded(JSON.stringify(newer));
    assert.equal(context.barHeight, 50);
    assert.equal(context.newerSchema, true);
    assert.equal(context.loadError, true);
    context.set("barHeight", 52);
    context.saveNow();
    assert.equal(calls.writes, 0, "a newer file must not be rewritten with this schema");
    // Moving the newer file aside (or a downgrade by hand) lifts the guard.
    context.applyLoaded(H.serialize(H.defaults()));
    assert.equal(context.newerSchema, false);
    assert.equal(context.loadError, false);
});

test("file-change reloads are debounced once settings are live", () => {
    const settings = read("Common/Settings.qml");
    assert.match(settings,
        /onFileChanged: \{\s*if \(root\.loaded\)\s*reloadTimer\.restart\(\);\s*else\s*reload\(\);\s*\}/);
    assert.match(settings, /id: reloadTimer\s*interval: 250\s*onTriggered: store\.reload\(\)/);
    assert.match(functionSource(settings, "set"), /SettingsHelpers\.normalizeKey\(key, value\)/);
});

test("persisted settings are written through Settings writers, not assigned", () => {
    const keys = Object.keys(H.defaults());
    const offenders = [];
    const walk = dir => {
        for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
            const full = path.join(dir, entry.name);
            if (entry.isDirectory())
                walk(full);
            else if (/\.(qml|js)$/.test(entry.name) && full !== path.join(shellDir, "Common/Settings.qml")) {
                const text = fs.readFileSync(full, "utf8");
                for (const match of text.matchAll(/\bSettings\.(\w+)\s*=(?!=)/g))
                    if (keys.includes(match[1]))
                        offenders.push(path.relative(shellDir, full) + ": " + match[0]);
            }
        }
    };
    walk(shellDir);
    // A direct assignment skips set(): migrationPending is not cleared, so a
    // toggle made before the first edit after a migration is never saved.
    assert.deepEqual(offenders, []);
});

test("module option sliders store where the drag rests", () => {
    const detail = read("Settings/ModuleDetailView.qml");
    const sliders = [...detail.matchAll(/^( +)SliderRow \{\n[^]*?^\1\}/gm)].map(match => match[0]);
    assert.ok(sliders.length >= 10);
    for (const slider of sliders) {
        assert.doesNotMatch(slider, /onMoved: value => view\.setOpt\(/, slider);
        assert.match(slider, /onMoved: value => view\.settleOpt\("(\w+)", value\)/);
        assert.match(slider, /value: view\.optValue\("\w+"\)/);
    }
    assert.match(detail, /id: optSettle\s*interval: 300\s*onTriggered: view\.flushSettling\(\)/);
    assert.match(detail, /Component\.onDestruction: flushSettling\(\)/);
    assert.match(detail, /onModuleIdChanged: \{[^}]*flushSettling\(\);/);
});

test("the plugin width slider settles instead of writing every tick", () => {
    const page = read("Settings/PluginWidgetSettings.qml");
    const width = page.slice(page.indexOf("id: widthRow"), page.indexOf("id: labelProbe"));
    assert.doesNotMatch(width, /enabled: !UserPlugins\.busy/,
        "a queued write must not disable the row mid-drag");
    assert.match(width, /onMoved: value => \{\s*pending = Math\.round\(value\);[^}]*widthSettle\.restart\(\);/);
    assert.match(width, /id: widthSettle\s*interval: 300/);
    assert.match(width, /Component\.onDestruction: flushWidth\(\)/);
});

test("closing settings releases the page after a short keep-alive", () => {
    const view = read("Settings/SettingsView.qml");
    const loader = view.slice(view.indexOf("id: pageLoader"), view.indexOf("sourceComponent:", view.indexOf("id: pageLoader")));
    assert.match(loader, /active: Settings\.panelOpen \|\| pageRelease\.running/);
    assert.match(view, /function onPanelOpenChanged\(\) \{\s*if \(Settings\.panelOpen\)\s*pageRelease\.stop\(\);\s*else\s*pageRelease\.restart\(\);/);
});

test("plugin discovery keeps the last good state and cannot wedge", () => {
    const plugins = read("Common/UserPlugins.qml");
    const handler = plugins.slice(plugins.indexOf("id: scanner"), plugins.indexOf("id: writer"));
    const guard = handler.indexOf("if (result.error || !Array.isArray(result.plugins))");
    assert.ok(guard > 0, "a registry error must not be applied");
    assert.ok(guard < handler.indexOf("root.plugins = result.plugins"));
    assert.match(plugins, /id: scanWatchdog[^]*?scanner\.running = false;/);
    assert.match(plugins, /interval: Settings\.panelOpen \? 2000 : 30000/);
    assert.match(plugins, /FileView \{\s*path: root\.registryPath\s*watchChanges: true/);
    // Neither process may wedge its queue when python3 cannot start.
    for (const id of ["scanner", "writer"]) {
        const block = plugins.slice(plugins.indexOf("id: " + id));
        const exited = block.slice(block.indexOf("onExited:"));
        assert.ok(block.indexOf("onRunningChanged:") >= 0, id + " settles on running");
        assert.doesNotMatch(exited.slice(0, exited.indexOf("}")),
            /refresh|nextWrite|widgetMembershipFinished/, id + " must not settle in onExited");
    }
    assert.match(plugins, /exitSeen \? lastExit : ProcHelpers\.NOT_STARTED[\s\S]{0,700}?Qt\.callLater\(root\.nextWrite\)/);
});

test("one plugin's exception cannot abort the registry sync", () => {
    const host = read("Common/OmarchyEntryHost.qml");
    assert.match(functionSource(host, "configure"),
        /for \(const key of Object\.keys\(fields\)\) \{\s*try \{/);
    const plugins = read("Common/OmarchyPlugins.qml");
    const sync = functionSource(plugins, "sync");
    assert.doesNotMatch(sync, /[^y]load\(item, /, "sync() must load through loadSafely()");
    assert.match(sync, /loadSafely\(item, "service"\)/);
    assert.match(functionSource(plugins, "loadSafely"), /try \{\s*return load\(item, kind\);\s*\} catch/);
});
