// Connection lifetime for the two long-lived integration sockets, T3 and
// Hermes: when they may exist at all, when a failed link is retried, and how
// fast. The singletons need a live Qt engine, so the bindings that decide it
// are lifted out of the source and run against stand-ins, and the wiring
// around them is checked textually.
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { shellDir, load } = require("./shell.cjs");

const SettingsHelpers = load("SettingsHelpers.js");

function read(relative) {
    return fs.readFileSync(path.join(shellDir, relative), "utf8");
}

// The body of the first `{ … }` block following `marker`.
function blockAfter(source, marker) {
    const at = source.indexOf(marker);
    assert.notEqual(at, -1, `missing ${marker}`);
    const open = source.indexOf("{", at + marker.length - 1);
    let depth = 0;
    for (let i = open; i < source.length; i++) {
        if (source[i] === "{")
            depth++;
        else if (source[i] === "}" && --depth === 0)
            return source.slice(open + 1, i);
    }
    throw new Error(`unbalanced block after ${marker}`);
}

// Evaluate a QML binding body against stand-in singletons.
function binding(body, scope) {
    const names = Object.keys(scope);
    return new Function(...names, body)(...names.map(name => scope[name]));
}

function modsWith(id, on) {
    const mods = SettingsHelpers.defaults().mods;
    for (const col of ["left", "center", "right"]) {
        for (const entry of mods[col]) {
            if (entry.id === id)
                entry.on = on;
        }
    }
    return mods;
}

const closed = { open: false, currentName: "" };

for (const [file, moduleId, panel] of [
    ["Common/T3Connection.qml", "t3", "t3code"],
    ["Common/HermesConnection.qml", "hermes", "hermes"],
]) {
    test(`${file} wants a link only while its module is on or its panel is open`, () => {
        const body = blockAfter(read(file), "readonly property bool enabled:");
        const enabled = (mods, popouts) =>
            binding(body, { Settings: { mods }, Popouts: popouts });
        assert.equal(enabled(modsWith(moduleId, true), closed), true);
        assert.equal(enabled(modsWith(moduleId, false), closed), false,
            "an off module must not hold a socket for the process lifetime");
        assert.equal(enabled(modsWith(moduleId, false),
            { open: true, currentName: panel }), true);
        assert.equal(enabled(modsWith(moduleId, false),
            { open: true, currentName: "control" }), false);
        assert.equal(enabled(modsWith(moduleId, false),
            { open: false, currentName: panel }), false);
    });
}

test("T3 gates every connection path on the module and tears down when it goes", () => {
    const connection = read("Common/T3Connection.qml");
    assert.match(blockAfter(connection, "function connect()"),
        /if \(!paired\) \{[\s\S]*?\}\s*[\s\S]*?if \(!enabled\)\s*return;/,
        "connect() is the one funnel; it must refuse while nothing wants the link");
    const changed = blockAfter(connection, "onEnabledChanged:");
    assert.match(changed,
        /if \(enabled\) \{[\s\S]*socketLoader\.active = true;[\s\S]*connect\(\);[\s\S]*return;\s*\}/,
        "re-enabling must restore the wrapper resetTransport destroyed, then connect");
    assert.match(changed, /resetTransport\(\);\s*connectionError = "";/,
        "disabling must close the link and drop its stale failure");
});

test("Hermes derives its address from the environment only", () => {
    const connection = read("Common/HermesConnection.qml");
    assert.doesNotMatch(connection, /opts\.(socketUrl|enabled)|modOpts\.hermes/,
        "normalizeModOpts drops those keys, so reading them is dead code");
    assert.deepEqual(Object.keys(SettingsHelpers.normalizeModOpts({
        hermes: { enabled: false, socketUrl: "ws://example.test/ws" },
    }).hermes).sort(), ["activityDetail", "showLabel"]);
    assert.match(connection, /onEnabledChanged: enabled \? reconnect\(\) : disconnect\(\)/);
    assert.doesNotMatch(connection, /onEndpointChanged/);
});

test("Settings → About reports an off integration without constructing it", () => {
    const health = read("Common/ShellHealth.qml");
    const issues = blockAfter(health, "readonly property var integrationIssues:");
    const statements = issues.split(/(?=\bif \()/);
    for (const [singleton, guard] of [["T3Connection", "root.t3On"],
        ["HermesConnection", "root.hermesOn"]]) {
        const naming = statements.filter(text => text.includes(singleton + "."));
        assert.ok(naming.length > 0, `${singleton} is no longer reported`);
        for (const statement of naming)
            assert.ok(statement.startsWith("if (" + guard + " && "),
                `${singleton} must only be named behind ${guard}: ${statement.trim()}`);
    }
    assert.doesNotMatch(health.replace(issues, ""), /\b(T3Connection|HermesConnection)\./,
        "no other binding may construct the connection singletons");
    const moduleOn = blockAfter(health, "function moduleOn(id)");
    const on = (mods, id) => binding(moduleOn, { Settings: { mods }, id });
    assert.equal(on(modsWith("t3", false), "t3"), false);
    assert.equal(on(modsWith("t3", true), "t3"), true);
    assert.equal(on(modsWith("hermes", true), "hermes"), true);
});
