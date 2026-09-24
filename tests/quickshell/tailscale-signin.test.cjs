const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { shellDir, load } = require("./shell.cjs");
const H = load("TailscaleHelpers.js");
const P = load("ProcHelpers.js");
const source = fs.readFileSync(path.join(shellDir, "Common/Tailscale.qml"), "utf8");
const url = "https://login.tailscale.com/a/example";

function service() {
    const calls = { setup: 0, closed: 0, browser: [], notifications: [], polls: 0 };
    const later = [];
    const state = {
        backendState: "NeedsLogin", statusKnown: true, running: false,
        authPending: false, authUrl: "", actionError: "", statusError: "",
        browserRequested: false, permissionRetry: false, ip: "", lastLogged: "",
        actionProc: { running: false, buffer: "", errorText: "", privileged: false, up: true },
        authExpiry: { restart() {}, stop() {} }, settle: { restart() {} },
        TailscaleHelpers: H, ProcHelpers: P,
        NetworkOverlayState: { openTailscale() { calls.setup++; }, close() { calls.closed++; } },
        Popouts: { close() {} },
        Quickshell: { execDetached(args) { calls.notifications.push(Array.from(args)); } },
        Qt: { callLater(fn) { later.push(fn); }, openUrlExternally(link) { calls.browser.push(link); return true; } },
        console: { warn() {} }
    };
    Object.defineProperties(state, {
        busy: { get: () => state.actionProc.running || state.permissionRetry },
        needsLogin: { get: () => state.backendState === "NeedsLogin" },
        needsApproval: { get: () => state.backendState === "NeedsMachineAuth" },
        connected: { get: () => state.running && state.ip !== "" && state.statusError === "" }
    });
    state.root = state;
    vm.createContext(state);
    for (const name of ["showSetup", "setRunning", "startAction", "runAction", "signIn", "openBrowser",
        "copySignInLink", "actionLine", "actionErrorLine", "finishAction", "apply"]) {
        const match = source.match(new RegExp("^    function " + name + "\\([^]*?^    }", "m"));
        assert.ok(match, name);
        vm.runInContext(match[0], state);
    }
    state.refresh = () => calls.polls++;
    return { state, calls, flush() { while (later.length) later.shift()(); } };
}

test("streaming login output is decoded before the command exits, including consecutive objects", () => {
    let buffer = "";
    const events = [];
    for (const line of (`Warning: example\n${JSON.stringify({ AuthURL: url, BackendState: "NeedsLogin", QR: "ignored" }, null, 2)}\n`
        + JSON.stringify({ BackendState: "Running" }, null, 2)).split("\n")) {
        const next = H.outputLine(buffer, line);
        buffer = next.buffer;
        if (next.event) events.push(next.event);
    }
    assert.equal(events.length, 2);
    assert.equal(events[0].AuthURL, url);
    assert.equal(events[1].BackendState, "Running");
    assert.equal(buffer, "");
    assert.ok(H.outputLine("{" + "x".repeat(65536), "x").event.Error);
});

test("only HTTPS authentication links without credentials or control characters are opened", () => {
    assert.equal(H.authUrl(url), url);
    assert.equal(H.authUrl("https://headscale.example:8443/register/key"), "https://headscale.example:8443/register/key");
    for (const bad of ["file:///tmp/x", "javascript:alert(1)", "https://user:pass@example.com/a/x",
        "https://login.tailscale.com\\@evil.example/x", "https://example.com/a\nx", url + "\n", {}, null])
        assert.equal(H.authUrl(bad), "");
    assert.doesNotMatch(H.errorMessage(1, "Error " + url, false), /example/);
});

test("first enable presents setup and duplicate clicks cannot spawn more login processes", () => {
    const { state: s, calls } = service();
    s.setRunning(true);
    assert.equal(calls.setup, 1);
    assert.equal(s.actionProc.running, false);
    s.signIn();
    assert.equal(s.authPending, true);
    assert.equal(s.browserRequested, true);
    assert.deepEqual(s.actionProc.command, H.command(true, false));
    const command = s.actionProc.command;
    s.setRunning(true);
    s.signIn();
    assert.equal(s.actionProc.command, command);
});

test("browser handoff releases the dialog and waits for an actual connected snapshot", () => {
    const { state: s, calls, flush } = service();
    s.signIn();
    s.actionLine(JSON.stringify({ AuthURL: url, BackendState: "NeedsLogin" }));
    assert.ok(calls.closed > 0);
    flush();
    assert.deepEqual(calls.browser, [url]);
    assert.equal(s.connected, false);
    s.actionLine('{"BackendState":"Running"}');
    assert.equal(s.connected, false);
    assert.equal(calls.notifications.length, 0);
    s.apply(0, JSON.stringify({ BackendState: "Running", Self: { HostName: "laptop", TailscaleIPs: ["100.1.2.3"] } }), "");
    assert.equal(s.connected, true);
    assert.equal(s.authPending, false);
    assert.equal(s.authUrl, "");
    assert.equal(calls.notifications.length, 1);
    s.apply(0, JSON.stringify({ BackendState: "Running", Self: { TailscaleIPs: ["100.1.2.3"] } }), "");
    assert.equal(calls.notifications.length, 1);
});

test("administrator approval and bounded CLI timeout retain a resumable session", () => {
    const { state: s, calls } = service();
    s.signIn();
    s.actionLine(JSON.stringify({ AuthURL: url }));
    s.actionLine('{"BackendState":"NeedsMachineAuth"}');
    assert.equal(s.needsApproval, true);
    assert.equal(s.authUrl, "");
    s.actionProc.errorText = "timeout waiting for Tailscale service to enter a Running state";
    s.finishAction(1);
    assert.equal(s.authPending, true);
    assert.equal(s.actionError, "");
    assert.equal(calls.notifications.length, 0);
});

test("permissions retry once through graphical authorization using a bounded fixed command", () => {
    const { state: s, calls, flush } = service();
    s.signIn();
    s.actionProc.running = false;
    s.actionProc.errorText = "Access denied: prefs write access denied";
    s.finishAction(1);
    assert.equal(s.busy, true);
    flush();
    assert.equal(s.actionProc.privileged, true);
    assert.deepEqual(s.actionProc.command, H.command(true, true));
    assert.deepEqual(s.actionProc.command.slice(0, 5), ["/usr/bin/pkexec", "/usr/bin/timeout", "--kill-after=2s", "20s", "/usr/bin/tailscale"]);
    s.actionProc.running = false;
    s.actionProc.errorText = "Authorization cancelled";
    s.finishAction(126);
    flush();
    assert.equal(s.authPending, false);
    assert.match(s.actionError, /cancelled or denied/);
    assert.equal(s.actionProc.running, false);
    assert.ok(calls.setup > 0);
});

test("reconnect preserves preferences and stopping a pending sign-in disconnects without logout", () => {
    const { state: s } = service();
    s.backendState = "Stopped";
    s.setRunning(true);
    assert.equal(s.actionProc.running, true);
    assert.deepEqual(s.actionProc.command, H.command(true, false, false));
    assert.deepEqual(s.actionProc.command.slice(4), ["up"], "only a bare up preserves all existing preferences");
    s.actionProc.running = false;
    s.authUrl = url;
    s.startAction(false);
    assert.equal(s.authPending, false);
    assert.equal(s.authUrl, "");
    assert.deepEqual(s.actionProc.command, H.command(false, false));
});

test("daemon failures and unsafe links never open a browser or report success", () => {
    const { state: s, calls, flush } = service();
    s.signIn();
    s.actionLine('{"AuthURL":"file:///tmp/login"}');
    assert.equal(s.authUrl, "");
    assert.match(s.actionProc.errorText, /invalid sign-in link/);
    s.actionProc.errorText = "failed to connect to local tailscaled";
    s.finishAction(1);
    flush();
    assert.match(s.actionError, /service is unavailable/);
    assert.equal(s.authPending, false);
    assert.equal(calls.browser.length, 0);
    assert.equal(calls.notifications.length, 0);
});

test("a failed disconnect remains visible even if a status poll still reports connected", () => {
    const { state: s } = service();
    s.startAction(false);
    s.actionProc.errorText = "Access denied";
    s.actionProc.privileged = true;
    s.finishAction(1);
    s.apply(0, JSON.stringify({ BackendState: "Running", Self: { TailscaleIPs: ["100.1.2.3"] } }), "");
    assert.match(s.actionError, /Access denied/);
});

test("a reconnect that discovers expired credentials exposes its stderr link without changing preferences", () => {
    const { state: s, calls } = service();
    s.backendState = "Stopped";
    s.setRunning(true);
    s.actionErrorLine("To authenticate, visit:");
    s.actionErrorLine("\t" + url);
    assert.equal(s.authUrl, url);
    assert.equal(s.authPending, true);
    assert.equal(calls.setup, 1);
    assert.doesNotMatch(s.actionProc.errorText, /https/);
    s.finishAction(124);
    assert.equal(s.actionError, "");
    assert.equal(s.authPending, true);
});

test("bare up's administrator URL is never mistaken for a user sign-in link", () => {
    const { state: s, calls, flush } = service();
    s.backendState = "Stopped";
    s.signIn();
    s.actionErrorLine("To approve your machine, visit (as admin):");
    s.actionErrorLine("\thttps://login.tailscale.com/admin/machines");
    flush();
    assert.equal(s.needsApproval, true);
    assert.equal(s.authUrl, "");
    assert.equal(calls.browser.length, 0);
    s.finishAction(124);
    assert.equal(s.authPending, true);
    assert.equal(s.actionError, "");
});

test("reopening setup and retrying browser handoff reuse the pending login session", () => {
    const { state: s, calls, flush } = service();
    s.signIn();
    s.actionLine(JSON.stringify({ AuthURL: url }));
    flush();
    const command = s.actionProc.command;
    s.showSetup();
    s.signIn();
    flush();
    assert.equal(s.actionProc.command, command);
    assert.deepEqual(calls.browser, [url, url]);
    assert.equal(s.authPending, true);
});

test("browser launch failure keeps the copyable link and presents recovery", () => {
    const { state: s, calls, flush } = service();
    s.Qt.openUrlExternally = () => false;
    s.signIn();
    s.actionLine(JSON.stringify({ AuthURL: url }));
    flush();
    assert.match(s.actionError, /Copy the sign-in link/);
    assert.equal(s.authUrl, url);
    assert.ok(calls.setup > 0);
});
