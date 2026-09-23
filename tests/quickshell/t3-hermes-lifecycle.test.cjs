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

// What a transport's stableTimer does when a link has stayed up.
function stableTrigger(source) {
    return blockAfter(source.slice(source.indexOf("id: stableTimer")), "onTriggered:");
}

// The socket-open branch of a transport's status handler.
function openBranch(source) {
    const handler = blockAfter(source, "function onSocketStatusChanged(");
    return blockAfter(handler, "=== 1)");
}

test("T3 resets its backoff only once the link has proven healthy", () => {
    const connection = read("Common/T3Connection.qml");
    const facade = read("Common/T3Code.qml");
    const opened = openBranch(connection);
    assert.doesNotMatch(opened, /retrySecs/,
        "an accept-then-drop server must not be retried at a fixed five seconds");
    assert.match(opened, /stableTimer\.epoch = epoch;\s*stableTimer\.restart\(\);/);
    assert.match(blockAfter(connection, "function markHealthy()"),
        /stableTimer\.stop\(\);\s*retrySecs = 5;/);
    assert.match(connection, /id: stableTimer\s*interval: 60000/);
    assert.match(stableTrigger(connection),
        /epoch === root\.sessionEpoch && root\.state === "connected"\)\s*root\.markHealthy\(\);/);
    assert.match(blockAfter(connection, "function scheduleRetry(epoch)"),
        /stableTimer\.stop\(\);[\s\S]*retrySecs = Math\.min\(retrySecs \* 2, 120\);/,
        "a drop must cancel a pending proof and keep doubling");

    // The shell stream proves the link, and ending it with a Failure says why.
    const handle = blockAfter(facade, "function handleMessage(text)");
    assert.match(handle,
        /const wasReady = T3Threads\.shellReady;\s*dirty = T3Threads\.applyItems\(msg\.values\) \|\| dirty;[\s\S]*?if \(!wasReady && T3Threads\.shellReady\)\s*T3Connection\.markHealthy\(\);/);
    const exit = blockAfter(handle, 'msg._tag === "Exit")');
    assert.match(exit,
        /if \(msg\.exit && msg\.exit\._tag === "Failure"\)\s*T3Connection\.connectionError = T3Rpc\.failureMessage\(msg,[\s\S]*?\);\s*T3Connection\.scheduleRetry\(\);/);
    assert.doesNotMatch(exit, /markHealthy|retrySecs/);
});

test("Hermes resets its backoff only after the bridge has stayed up", () => {
    const connection = read("Common/HermesConnection.qml");
    const opened = openBranch(connection);
    assert.doesNotMatch(opened, /retrySecs/,
        "a bridge that accepts and drops must not be retried every two seconds");
    assert.match(opened, /stableTimer\.generation = generation;\s*stableTimer\.restart\(\);/);
    assert.match(connection, /id: stableTimer\s*interval: 60000/);
    assert.match(stableTrigger(connection),
        /generation === root\.generation && root\.state === "connected"\)\s*root\.retrySecs = 2;/);
    for (const fn of ["function disconnect()", "function scheduleRetry(emitDrop)"])
        assert.match(blockAfter(connection, fn), /stableTimer\.stop\(\);/, fn);
    assert.match(blockAfter(connection, "function reconnect()"), /retrySecs = 2;/,
        "an explicit reconnect still starts over");
});

test("reconnect holds: known-offline waits unless the server is local, idle waits", () => {
    const Helpers = load("T3CodeHelpers.js");
    assert.equal(Helpers.isLoopbackOrigin("http://127.0.0.1:3773"), true);
    assert.equal(Helpers.isLoopbackOrigin("https://localhost"), true);
    assert.equal(Helpers.isLoopbackOrigin("ws://[::1]:9120/ws"), true);
    assert.equal(Helpers.isLoopbackOrigin("https://t3.example.test"), false);
    assert.equal(Helpers.isLoopbackOrigin("http://127.0.0.1.example.test"), false);
    assert.equal(Helpers.isLoopbackOrigin(""), false);
    assert.equal(Helpers.isLoopbackOrigin(null), false);

    assert.equal(Helpers.reconnectHold(true, false, false, false), "network");
    assert.equal(Helpers.reconnectHold(true, false, true, false), "",
        "a loopback server needs no network");
    assert.equal(Helpers.reconnectHold(false, false, false, false), "",
        "an unknown network state must not strand the link");
    assert.equal(Helpers.reconnectHold(true, true, false, true), "idle");
    assert.equal(Helpers.reconnectHold(true, false, false, true), "network");
    assert.equal(Helpers.reconnectHold(true, true, false, false), "");
});

// Runs T3Connection's own retry functions and edge handlers against
// stand-ins for the QML objects they touch.
function t3Harness(overrides = {}) {
    const source = read("Common/T3Connection.qml");
    const timer = () => ({
        running: false, interval: 0, epoch: -1,
        restart() { this.running = true; },
        stop() { this.running = false; },
    });
    const scope = {
        Helpers: load("T3CodeHelpers.js"),
        NetworkStatus: { known: true, online: true },
        Activity: { idle: false },
        sessionEpoch: 4,
        state: "connected",
        enabled: true,
        paired: true,
        websocketsMissing: false,
        host: "https://t3.example.test",
        retrySecs: 5,
        connects: 0,
        drops: 0,
        socketLoader: { item: null },
        retryTimer: timer(),
        stableTimer: timer(),
        socketConnectTimeout: timer(),
        dropped() { scope.drops++; },
        connect() { scope.connects++; scope.state = "connecting"; },
        ...overrides,
    };
    scope.root = scope;
    const compile = (params, body) =>
        new Function("scope", `with (scope) { return function (${params}) {${body}}; }`)(scope);
    for (const [name, params] of [["scheduleRetry", "epoch"], ["retryHold", "resumed"],
        ["resumeReconnect", "resetBackoff, resumed"]])
        scope[name] = compile(params, blockAfter(source, `function ${name}(${params})`));
    const onOnline = compile("", blockAfter(source, "function onOnlineChanged()"));
    const onKnown = compile("", blockAfter(source, "function onKnownChanged()"));
    const onResumed = compile("", blockAfter(source, "function onResumed()"));
    const fire = compile("", `with (retryTimer) {${blockAfter(
        source.slice(source.indexOf("id: retryTimer")), "onTriggered:")}}`);
    return { scope, onOnline, onKnown, onResumed, fire };
}

test("T3 holds its retries while offline or idle and resumes on the edge", () => {
    // Offline: the drop arms nothing; regaining the network connects at once
    // and starts the backoff over.
    let { scope, onOnline, onResumed, fire } = t3Harness({ retrySecs: 40 });
    scope.NetworkStatus.online = false;
    scope.scheduleRetry(4);
    assert.equal(scope.state, "offline");
    assert.equal(scope.drops, 1);
    assert.equal(scope.retryTimer.running, false, "no retry may be armed while offline");
    scope.NetworkStatus.online = true;
    onOnline();
    assert.equal(scope.connects, 1);
    assert.equal(scope.retrySecs, 5);

    // A status probe that breaks while offline must not strand the link.
    let onKnown;
    ({ scope, onKnown } = t3Harness());
    scope.NetworkStatus.online = false;
    scope.scheduleRetry(4);
    onKnown();
    assert.equal(scope.connects, 0, "a still-known offline state keeps holding");
    scope.NetworkStatus.known = false;
    onKnown();
    assert.equal(scope.connects, 1);

    // Idle: the same, and the resume edge connects even while `idle` itself
    // has not settled yet.
    ({ scope, onOnline, onResumed, fire } = t3Harness({ retrySecs: 40 }));
    scope.Activity.idle = true;
    scope.scheduleRetry(4);
    assert.equal(scope.retryTimer.running, false, "no retry may start while idle");
    onOnline();
    assert.equal(scope.connects, 0, "coming online does not end an idle hold");
    onResumed();
    assert.equal(scope.connects, 1);
    assert.equal(scope.retrySecs, 40, "resuming alone keeps the backoff");

    // A pending retry that fires into a hold does nothing.
    ({ scope, onOnline, onResumed, fire } = t3Harness());
    scope.scheduleRetry(4);
    assert.equal(scope.retryTimer.running, true);
    assert.equal(scope.retryTimer.interval, 5000);
    assert.equal(scope.retrySecs, 10);
    scope.Activity.idle = true;
    fire();
    assert.equal(scope.connects, 0);
    scope.Activity.idle = false;
    fire();
    assert.equal(scope.connects, 1);

    // A loopback server and an unknown network state are never held.
    ({ scope } = t3Harness({ host: "http://127.0.0.1:3773" }));
    scope.NetworkStatus.online = false;
    scope.scheduleRetry(4);
    assert.equal(scope.retryTimer.running, true);
    ({ scope } = t3Harness({ NetworkStatus: { known: false, online: false } }));
    scope.scheduleRetry(4);
    assert.equal(scope.retryTimer.running, true);

    // Only a transiently offline link is resumed.
    for (const blocked of [{ state: "signed-out" }, { state: "connected" },
        { enabled: false, state: "offline" }, { paired: false, state: "offline" },
        { websocketsMissing: true, state: "offline" }]) {
        ({ scope, onOnline, onResumed } = t3Harness(blocked));
        onOnline();
        onResumed();
        assert.equal(scope.connects, 0, JSON.stringify(blocked));
    }
    ({ scope } = t3Harness({ enabled: false }));
    scope.scheduleRetry(4);
    assert.equal(scope.retryTimer.running, false, "a disabled link arms nothing");
});

test("T3 fetches its environment descriptor once per session", () => {
    const connection = read("Common/T3Connection.qml");
    const fetch = blockAfter(connection, "function fetchDescriptor(epoch)");
    assert.match(fetch, /^\s*if \(descriptorEpoch === epoch\)\s*return;/);
    assert.match(fetch, /root\.environmentCapabilities = [^\n]*\n\s*root\.descriptorEpoch = epoch;/,
        "only a descriptor that was actually read counts as loaded");
    assert.match(blockAfter(connection, "function resetTransport()"), /sessionEpoch\+\+/,
        "a new session must fetch its own descriptor");
});

test("Hermes holds its retries while idle and resumes when the user returns", () => {
    const connection = read("Common/HermesConnection.qml");
    assert.match(blockAfter(connection, "function scheduleRetry(emitDrop)"),
        /if \(!enabled \|\| Activity\.idle\)\s*return;\s*retryTimer\.interval/);
    assert.match(blockAfter(connection.slice(connection.indexOf("id: retryTimer")), "onTriggered:"),
        /if \(!Activity\.idle\)\s*root\.connect\(\);/);
    const resumed = blockAfter(connection, "function onResumed()");
    assert.match(resumed,
        /if \(!root\.enabled \|\| root\.state !== "offline" \|\| root\.websocketsMissing\)\s*return;\s*retryTimer\.stop\(\);\s*root\.connect\(\);/);
    assert.doesNotMatch(resumed, /Activity\.idle/, "idle may not have settled on this edge");
    assert.doesNotMatch(connection, /NetworkStatus/,
        "the bridge is on loopback; the network state is no reason to wait");
});
