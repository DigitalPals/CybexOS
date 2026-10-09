const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { shellDir } = require("./shell.cjs");
const H = require("../../roles/desktop/files/quickshell/Common/FuseboxHelpers.js");
const S = require("../../roles/desktop/files/quickshell/Common/SettingsHelpers.js");
const Registry = require("../../roles/desktop/files/quickshell/Common/PanelRegistryData.js");
const Catalog = require("../../roles/desktop/files/quickshell/Common/WidgetCatalog.js");

const NOW = Date.UTC(2026, 9, 9, 10, 0, 0);
const MIN = 60000;

function read(relative) {
    return fs.readFileSync(path.join(shellDir, relative), "utf8");
}

function account(id, extra = {}) {
    return { id, provider: "claude", kind: "oauth", group: null, label: id + "@example.com", disabled: false,
        cooldowns: [], lastError: null, windows: [], ...extra };
}

test("Fusebox is a connected-service widget beside Model Usage, off on a plain install", () => {
    const d = S.defaults();
    const right = d.mods.right.map(m => m.id);
    assert.equal(right[right.indexOf("modelusage") + 1], "fusebox");
    assert.equal(d.mods.right.find(m => m.id === "fusebox").on, false);
    assert.ok(S.CONNECTED_WIDGET_IDS.includes("fusebox"));
    assert.deepEqual(d.modOpts.fusebox,
        { url: "", metric: "sessions", quotaDisplay: "used", hideEmails: true, notify: false });
    const connected = S.merge(null, { connectedWidgets: true });
    assert.equal(connected.mods.right.find(m => m.id === "fusebox").on, true);
    assert.doesNotMatch(read("Common/SettingsHelpers.js"), /fusebox:\s*\{[^}]*key/i,
        "the management key is never a setting");
});

test("schema 28 follows Model Usage wherever the user put it and keeps every other entry", () => {
    const raw = S.defaults();
    raw.v = 27;
    for (const column of ["left", "center", "right"])
        raw.mods[column] = raw.mods[column].filter(m => m.id !== "fusebox");
    const usage = raw.mods.right.shift();
    raw.mods.center.push(usage);
    const before = JSON.parse(JSON.stringify(raw.mods));
    const migrated = S.merge(raw, { connectedWidgets: false }).mods;
    assert.deepEqual(migrated.center.slice(-2).map(m => m.id), ["modelusage", "fusebox"]);
    assert.equal(migrated.center.at(-1).on, false);
    for (const column of ["left", "center", "right"])
        assert.deepEqual(migrated[column].filter(m => m.id !== "fusebox"), before[column],
            `${column} changed while adding Fusebox`);
    assert.equal(S.merge(raw, { connectedWidgets: true }).mods.center.at(-1).on, true);

    // Without Model Usage it leads the right column, as schema 26 placed Model Usage.
    const placed = S.migrateMods({ left: [], center: [], right: [{ id: "vol", on: true }] }, 27, {});
    assert.equal(placed.right[0].id, "fusebox");

    // A current file keeps the user's choice, including off with a server set.
    const saved = S.defaults();
    saved.v = S.VERSION;
    saved.mods.right.find(m => m.id === "fusebox").on = true;
    saved.modOpts.fusebox = { url: "https://fuse.example.ts.net", metric: "faults", quotaDisplay: "remaining",
        hideEmails: false, notify: true };
    const restored = S.merge(saved, { connectedWidgets: false });
    assert.equal(restored.mods.right.find(m => m.id === "fusebox").on, true);
    assert.deepEqual(restored.modOpts.fusebox, saved.modOpts.fusebox);
    assert.equal(S.normalizeModOpts({ fusebox: { url: "  https://x.test  ", metric: "bogus", hideEmails: "yes" } })
        .fusebox.url, "https://x.test");
    assert.equal(S.normalizeModOpts({ fusebox: { metric: "bogus" } }).fusebox.metric, "sessions");
    assert.equal(S.normalizeModOpts({ fusebox: { metric: "serving" } }).fusebox.metric, "serving",
        "a saved choice of requests in progress is kept");
    assert.equal(S.normalizeModOpts({ fusebox: { hideEmails: "no" } }).fusebox.hideEmails, true);
    assert.equal(S.normalizeModOpts({ fusebox: { quotaDisplay: "remaining" } }).fusebox.quotaDisplay, "remaining");
    assert.equal(S.normalizeModOpts({ fusebox: { quotaDisplay: "left" } }).fusebox.quotaDisplay, "used");
});

test("account state follows the dashboard: off, then the latest pause, then errors, then serving", () => {
    assert.equal(H.accountState(account("a", { disabled: true, lastError: "boom" }), {}, NOW).cls, "disabled");
    const cooling = H.accountState(account("a", {
        lastError: "429",
        cooldowns: [{ model: "opus", until: NOW + 5 * MIN, kind: "rate_limit" },
            { model: "*", until: NOW + 90 * MIN, kind: "quota" }, { model: "old", until: NOW - MIN, kind: "quota" }]
    }), {}, NOW);
    assert.deepEqual([cooling.cls, cooling.word, cooling.kind], ["cooling", "Cooling 1h 30m", "quota"]);
    const signin = H.accountState(account("a", { lastError: "token refresh failed: invalid_grant" }), {}, NOW);
    assert.deepEqual([signin.cls, signin.word, signin.signin], ["error", "Sign-in expired", true]);
    const key = H.accountState(account("k", { kind: "api-key", lastError: "401 Unauthorized" }), {}, NOW);
    assert.deepEqual([key.word, key.signin], ["Error", false], "an API key never needs signing in");
    assert.equal(H.accountState(account("a"), { a: { inFlight: 2, sessions: 3 } }, NOW).word, "Serving 2");
    assert.equal(H.accountState(account("a"), { a: { inFlight: 0, sessions: 3 } }, NOW).word, "Ready");
});

test("a healthy account's label shows only its sessions; trouble shows only the trouble", () => {
    const serving = H.accountState(account("a"), { a: { inFlight: 1, sessions: 2 } }, NOW);
    assert.equal(H.statusText(serving, 2, 1), "2 sessions");
    assert.equal(H.statusText(H.accountState(account("a"), {}, NOW), 1, 0), "1 session");
    assert.equal(H.statusText(H.accountState(account("a"), {}, NOW), 0, 0), "Ready");
    assert.equal(H.statusText(serving, 0, 1), "Serving 1", "requests without a session still show");
    const cooling = H.accountState(account("a", { cooldowns: [{ model: "*", until: NOW + 29 * MIN, kind: "rate_limit" }] }),
        {}, NOW);
    assert.equal(H.statusText(cooling, 3, 0), "Cooling 29m");
    assert.equal(H.statusText(H.accountState(account("a", { disabled: true }), {}, NOW), 2, 0), "Off");
    assert.equal(H.statusText(H.accountState(account("a", { lastError: "boom" }), {}, NOW), 2, 0), "Error");
});

test("quota meters show the busiest current window and the dashboard's thresholds", () => {
    const a = account("a", { windows: [
        { name: "5h", used: 40, resetsAt: NOW + MIN, model: null },
        { name: "5h", used: 99, resetsAt: NOW - MIN, model: null },
        { name: "5h", used: 90, resetsAt: NOW + MIN, model: "opus" },
        { name: "week", used: 76, resetsAt: null, model: null },
        { name: "day", used: 96, resetsAt: NOW + MIN, model: null }
    ] });
    assert.equal(H.windowOf(a, true, NOW).used, 40, "expired and model-scoped windows are skipped");
    assert.equal(H.windowOf(a, false, NOW).name, "day");
    assert.equal(H.quota(H.windowOf(a, false, NOW), NOW).level, "critical");
    assert.equal(H.quota({ name: "week", used: 75, resetsAt: null }, NOW).level, "warn");
    assert.equal(H.quota({ name: "week", used: 74.9, resetsAt: null }, NOW).level, "ok");
    assert.equal(H.quota({ name: "week", used: NaN }, NOW), null);
    assert.deepEqual([H.windowLabel(null, true), H.windowLabel({ name: "day" }, false), H.windowTitle({ name: "5h" })],
        ["5H", "DAY", "5-hour"]);
    assert.deepEqual([H.percent(0.4), H.percent(99.6), H.percent(100), H.percent(0)], ["<1%", ">99%", "100%", "0%"]);
});

test("Remaining flips what a meter fills and prints, never what counts as nearly used up", () => {
    const nearlySpent = H.quota({ name: "5h", used: 96, resetsAt: NOW + MIN }, NOW);
    assert.equal(H.quotaShare(nearlySpent, "used"), 96);
    assert.equal(H.quotaShare(nearlySpent, "remaining"), 4);
    assert.equal(nearlySpent.level, "critical", "the level measures used in either display");
    assert.equal(H.percent(H.quotaShare(H.quota({ name: "week", used: 99.7 }, NOW), "remaining")), "<1%");
    assert.equal(H.quotaShare(null, "remaining"), null, "an unreported window stays unknown");
    assert.deepEqual([H.quotaWord("used"), H.quotaWord("remaining")], ["used", "left"]);
    assert.deepEqual(H.QUOTA_DISPLAYS.map(d => d.value), ["used", "remaining"]);
    const meter = read("Popovers/FuseboxPopover.qml");
    assert.match(meter, /value: meter\.reading \? meter\.share \/ 100 : 0/);
    assert.match(meter, /fillColor: root\.meterTone\(meter\.reading \? meter\.reading\.level : "ok"\)/);
    assert.match(read("Settings/ModuleDetailView.qml"), /current: view\.opts\.quotaDisplay/);
});

test("hidden account names stay distinct and stable, and errors lose their emails", () => {
    const accounts = [account("file:b"), account("file:a"), account("file:c"),
        account("key", { provider: "codex", kind: "api-key" })];
    assert.deepEqual(accounts.map(a => H.accountName(a, accounts, true)),
        ["Claude 2", "Claude 1", "Claude 3", "OpenAI key"]);
    assert.equal(H.accountName(accounts[0], accounts, false), "file:b@example.com");
    assert.equal(H.accountName(accounts[0], [accounts[0]], true), "Claude");
    assert.equal(H.maskEmails("401 for jane.doe+ai@mail.example.org, retry"), "401 for ••••••@••••••, retry");
    assert.deepEqual(H.groupAccounts(accounts).map(a => a.id), ["file:a", "file:b", "file:c", "key"]);
});

test("finished requests count into their minute and the figures read them", () => {
    let series = [{ minute: Math.floor(NOW / MIN) - 70, requests: 9, failed: 0, cancelled: 0 }];
    const req = (at, status, ttft) => ({ id: at, at, status, ttft, input: 10, output: 5, cached: 1 });
    const before = JSON.stringify(series);
    series = H.applyRequest(series, req(NOW - 30000, 200, 800), NOW);
    assert.equal(before, JSON.stringify([{ minute: Math.floor(NOW / MIN) - 70, requests: 9, failed: 0, cancelled: 0 }]),
        "the previous series is not mutated");
    series = H.applyRequest(series, req(NOW - 40000, 503, null), NOW);
    series = H.applyRequest(series, req(NOW - 45000, 499, null), NOW);
    series = H.applyRequest(series, req(NOW - 2 * 3600000, 200, 1), NOW);
    assert.deepEqual(series.map(b => [b.minute - Math.floor(NOW / MIN), b.requests, b.failed, b.cancelled]),
        [[-1, 3, 1, 1]], "an hour-old bucket and request fall away");
    const bars = H.bars(series, NOW);
    assert.equal(bars.length, 60);
    assert.deepEqual([bars[58].requests, bars[59].current, bars[0].requests], [3, true, 0]);
    const requests = [req(NOW, 200, 300), req(NOW, 500, 10), req(NOW, 200, 900), req(NOW, 200, null)];
    assert.deepEqual(H.figures(series, requests, 2, NOW),
        { sessions: 0, serving: 2, rpm: 3, failed: 1, ttft: 600 });
    assert.equal(H.barValue("serving", H.figures(series, requests, 2, NOW), []), "2");
    // Between requests a session has nothing in progress, but it still counts.
    const idle = H.figures(series, requests, 0, NOW,
        { a: { inFlight: 0, sessions: 2 }, b: { inFlight: 0, sessions: 1 } });
    assert.deepEqual([idle.sessions, idle.serving], [3, 0]);
    assert.equal(H.barValue("sessions", idle, []), "3");
    assert.equal(H.barValue("serving", idle, []), "0");
    assert.equal(H.METRICS[0].value, "sessions", "sessions lead the menubar choices");
    assert.equal(H.barValue("rpm", H.figures(series, requests, 2, NOW), []), "3");
    assert.equal(H.barValue("faults", null, [{}, {}]), "2");
});

test("faults count down to their time and only new, lasting ones notify", () => {
    const quota = { key: "quota:a", kind: "quota", level: "warn", until: NOW + 72 * MIN };
    const rate = { key: "rate:a", kind: "rate_limit", level: "warn", until: NOW + 4 * MIN };
    const signin = { key: "signin:b", kind: "signin", level: "err", until: null };
    assert.match(H.faultTiming(quota, NOW), /^Back at \d\d:\d\d, in 1h 12m$/);
    assert.equal(H.faultTiming(signin, NOW), "");
    assert.equal(H.faultTiming({ ...quota, until: NOW - 1 }, NOW), "");
    assert.match(H.faultTiming({ ...quota, until: NOW + 3 * 24 * 3600000 }, NOW), /^Back at [A-Z][a-z]{2} \d\d:\d\d/);
    assert.deepEqual(H.newFaults(["quota:a"], [quota, rate, signin]).map(f => f.key), ["signin:b"]);
    assert.deepEqual([H.faultLevel([]), H.faultLevel([quota]), H.faultLevel([quota, signin])],
        ["ok", "warn", "critical"]);
    // The same countdowns as Fusebox (push/faults.rs span()).
    assert.deepEqual([H.span(20000), H.span(45 * MIN), H.span(134 * MIN), H.span(79 * 60 * MIN), H.span(-5)],
        ["<1m", "45m", "2h 14m", "3d 7h", "<1m"]);
});

test("request rows name the client, tag transports and retries, and summarise timing and tokens", () => {
    const base = { status: 200, ttft: 3600, usage: "complete", input: 2, cached: 333000, output: 290,
        transport: "http", attempts: 1 };
    assert.equal(H.clientLabel({ ...base, clientApp: "Claude Code", client: "claude" }), "Claude Code");
    assert.equal(H.clientLabel({ ...base, clientApp: null, client: "responses" }), "Responses",
        "an unnamed client reads as its API format, as in the dashboard");
    assert.equal(H.clientLabel({ ...base, clientApp: null, client: "claude" }), "Anthropic");
    assert.deepEqual(H.requestTags(base), []);
    assert.deepEqual(H.requestTags({ ...base, transport: "ws", attempts: 3 }), ["ws", "3 tries"]);
    assert.equal(H.requestMetrics(base), "3.6 s · 333k in · 290 out", "cached context counts as input");
    assert.equal(H.requestMetrics({ ...base, ttft: null, usage: "partial" }), "≥333k in · ≥290 out");
    assert.equal(H.requestMetrics({ ...base, usage: "missing" }), "3.6 s");
});

test("account details read as figures, resets and pauses", () => {
    const a = account("a", { requests: 546, failures: 2, expiresAt: NOW + 388 * MIN, lastUsed: NOW - 11000,
        windows: [{ name: "5h", used: 100, resetsAt: NOW + 50 * MIN, model: null },
            { name: "week", used: 59, resetsAt: NOW + 340 * MIN, model: null }],
        cooldowns: [{ model: "*", until: NOW + 50 * MIN, kind: "quota" },
            { model: "claude-opus", until: NOW + 4 * MIN, kind: "rate_limit" },
            { model: "old", until: NOW - MIN, kind: "quota" }] });
    assert.equal(H.accountSubtitle(a, NOW), "Claude · OAuth · last used 11 s ago");
    assert.deepEqual(H.accountFacts(a, { sessions: new Array(22) }, NOW).map(f => [f.label, f.value, f.level || "ok"]),
        [["Requests", "546", "ok"], ["Failed", "2", "critical"], ["Pinned", "22", "ok"], ["Token", "6h 28m", "ok"]]);
    assert.equal(H.accountFacts(a, null, NOW)[2].value, "–", "sessions load with the details");
    assert.deepEqual(H.accountFacts({ ...a, expiresAt: NOW - 1 }, null, NOW)[3], { label: "Token", value: "Expired",
        level: "critical" });
    assert.equal(H.accountFacts(account("k", { kind: "api-key", requests: 0, failures: 0 }), null, NOW).length, 3);
    const resets = H.resetFacts(a, NOW);
    assert.deepEqual(resets.map(f => [f.label, f.level]), [["5-hour back", "warn"], ["Weekly resets", "ok"]]);
    assert.match(resets[1].value, /^\d\d:\d\d · in 5h 40m$/);
    assert.deepEqual(H.resetFacts(account("k", { windows: [] }), NOW), []);
    assert.equal(H.pauseText(a, NOW), "claude-opus · rate limited · back in 4m\nEvery model · usage limit used up · back in 50m");
    assert.deepEqual([H.authName({ kind: "api-key" }), H.authName({ kind: "oauth", provider: "kimi" }),
        H.authName({ kind: "service-account" })], ["API key", "Device code", "Service account"]);
});

test("no dashboard list is rebuilt by the clock", () => {
    // A Repeater whose model is recomputed every second recreates its rows each
    // tick, and rows torn down mid-binding lose their parent.
    const popover = read("Popovers/FuseboxPopover.qml");
    const models = popover.split("\n").filter(line => /^\s*model:/.test(line));
    assert.ok(models.length >= 5);
    for (const line of models)
        assert.doesNotMatch(line, /root\.now|loadBars/, line.trim());
    assert.doesNotMatch(popover, /required property var modelData\n\s*width: parent\.width/,
        "repeated rows guard their parent");
});

test("the dashboard opens only on its own hash routes", () => {
    assert.equal(H.dashboardUrl("https://fuse.example.ts.net/", "#/accounts/file%3Aa"),
        "https://fuse.example.ts.net/#/accounts/file%3Aa");
    assert.equal(H.dashboardUrl("https://fuse.example.ts.net", "javascript:alert(1)"), "https://fuse.example.ts.net/");
    assert.equal(H.dashboardUrl("file:///etc/passwd", "#/accounts"), "");
});

test("the widget is registered everywhere a bar widget must be", () => {
    assert.ok(S.MODULE_IDS.includes("fusebox"));
    assert.equal(Catalog.widgetName("fusebox"), "Fusebox");
    const panel = Registry.PANELS.find(p => p.name === "fusebox");
    assert.deepEqual([panel.moduleId, panel.source], ["fusebox", "Popovers/FuseboxPopover.qml"]);
    assert.match(read("Bar/Bar.qml"), /fusebox: "Modules\/Fusebox\.qml"/);
    assert.match(read("Common/qmldir"), /^singleton Fusebox Fusebox\.qml$/m);
    assert.match(read("Settings/ModuleDetailView.qml"), /case "fusebox": return fuseboxOptions;/);
    assert.match(read("Common/BrandIcons.qml"), /fusebox: "fusebox\.svg"/);
});

test("the singleton keeps the key out of argv, settings and IPC", () => {
    const singleton = read("Common/Fusebox.qml");
    assert.match(singleton, /keyRequest\.stdinEnabled = true;\s*keyRequest\.inputText = key \+ "\\n";/);
    assert.match(singleton, /\["python3", "-B", script, "store-key"\]/);
    assert.doesNotMatch(singleton, /store-key", key|--key/);
    const ipc = singleton.slice(singleton.indexOf("IpcHandler"), singleton.indexOf("Timer {"));
    assert.doesNotMatch(ipc, /accounts:\s*root\.accounts[,\s]/, "IPC reports counts, not account names");
    assert.match(ipc, /accounts: root\.accounts\.length/);
    const settings = read("Settings/ModuleDetailView.qml");
    const keyRow = settings.slice(settings.indexOf('label: "Management key"'), settings.indexOf('label: "Connection"'));
    assert.match(keyRow, /secret: true/);
    assert.match(keyRow, /value: ""/);
    assert.match(keyRow, /onCommitted: text => Fusebox\.storeKey\(text\)/);
    assert.doesNotMatch(keyRow, /setOpt/);
});
