const test = require("node:test");
const { untranslated } = require("./shell.cjs");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { shellDir, load } = require("./shell.cjs");
const H = require("../../desktop/quickshell/Common/FuseboxHelpers.js");
const S = require("../../desktop/quickshell/Common/SettingsHelpers.js");
const Registry = require("../../desktop/quickshell/Common/PanelRegistryData.js");
const Catalog = require("../../desktop/quickshell/Common/WidgetCatalog.js");

const NOW = Date.UTC(2026, 9, 9, 10, 0, 0);
const MIN = 60000;

function read(relative) {
    return untranslated(fs.readFileSync(path.join(shellDir, relative), "utf8"));
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
    assert.match(meter, /value: bar\.reading \? bar\.share \/ 100 : 0/);
    assert.match(meter, /fillColor: root\.meterTone\(bar\.reading \? bar\.reading\.level : "ok"\)/);
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
        { sessions: 0, serving: 2, rpm: 3, failed: 1, ttft: 600, clients: 0 });
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
    const connected = { connected: [{ ip: "10.0.0.2" }, { ip: "10.0.0.3" }], named: [] };
    assert.equal(H.barValue("clients", H.figures(series, requests, 2, NOW, {}, connected), []), "2");
    assert.equal(H.barValue("clients", H.figures(series, requests, 2, NOW, {}, null), []), "0",
        "a server without the clients API reads 0");
    assert.deepEqual(H.METRICS.map(m => m.value), ["sessions", "serving", "rpm", "faults", "clients"]);
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
    const windows = H.windowDetails(a, NOW, false);
    assert.deepEqual(windows.map(w => [w.title, w.level]), [["5-hour", "warn"], ["Weekly", "ok"]]);
    assert.match(windows[0].timing, /^back \d\d:\d\d · in 50m$/, "a used-up window says when it is back");
    assert.match(windows[1].timing, /^resets \d\d:\d\d · in 5h 40m$/);
    assert.deepEqual(H.windowDetails(account("k", { windows: [] }), NOW, false), []);
    assert.equal(H.pauseText(a, NOW), "claude-opus · rate limited · back in 4m\nEvery model · usage limit used up · back in 50m");
    assert.deepEqual([H.authName({ kind: "api-key" }), H.authName({ kind: "oauth", provider: "kimi" }),
        H.authName({ kind: "service-account" })], ["API key", "Device code", "Service account"]);
});

test("a reset can be used only with fresh, eligible status and a confirmation", () => {
    const a = account("a");
    const grant = { id: "g", label: "Weekly reset", remaining: 2, expiresAt: NOW + 11 * 24 * 60 * MIN, startsAt: null,
        clears: ["5-hour", "weekly"], usable: true, reason: null };
    const view = { checkedAt: NOW - MIN, error: null, quote: "q", retryable: false, operation: null,
        inventory: { available: 2, applicable: 1, eligible: true, reason: null, selectedGrant: "g", grants: [grant] } };
    assert.equal(H.resetBlock(view, a, NOW), "");
    assert.equal(H.resetBlock(null, a, NOW), "Checking reset status…");
    assert.match(H.resetBlock(view, { ...a, disabled: true }, NOW), /Turn this account on/);
    assert.equal(H.resetBlock({ ...view, error: "Provider unavailable" }, a, NOW), "Provider unavailable");
    assert.match(H.resetBlock({ ...view, checkedAt: NOW - 6 * MIN }, a, NOW), /Refresh/, "status older than 5 minutes");
    assert.match(H.resetBlock({ ...view, quote: null }, a, NOW), /Refresh/);
    assert.equal(H.resetBlock({ ...view, inventory: { ...view.inventory, eligible: false, reason: "Account is not eligible" } },
        a, NOW), "Account is not eligible");
    const expired = { ...view, inventory: { ...view.inventory, grants: [{ ...grant, expiresAt: NOW - 1 }] } };
    assert.ok(H.grantTimingChanged(expired, NOW));
    assert.match(H.resetBlock(expired, a, NOW), /Refresh/, "a usable grant that lapsed means stale status");
    const pending = { ...view, operation: { requestId: "r", status: "pending", message: "", retryUntil: NOW + 5 * MIN } };
    assert.ok(H.resetUnresolved(pending));
    assert.match(H.resetBlock(pending, a, NOW), /blocked until it's resolved/);
    assert.ok(!H.resetUnresolved({ ...view, operation: { status: "applied" } }));
    assert.deepEqual(H.usableGrants(view).map(g => g.id), ["g"]);
    assert.ok(H.resetsSupported(a, true) && H.resetsSupported({ ...a, provider: "codex" }, true));
    assert.ok(!H.resetsSupported(a, false) && !H.resetsSupported({ ...a, kind: "api-key" }, true)
        && !H.resetsSupported({ ...a, provider: "kimi" }, true));
});

test("recovery, countdowns and wording follow Fusebox's dialog", () => {
    const op = { requestId: "r", status: "unknown", message: "", retryUntil: NOW + 6 * MIN };
    const view = { checkedAt: NOW, error: null, quote: null, retryable: true, operation: op, inventory: null };
    assert.ok(H.retryAllowed(view, account("a"), NOW));
    assert.ok(!H.retryAllowed(view, account("c", { provider: "codex" }), NOW), "Codex can only record the outcome");
    assert.ok(!H.retryAllowed({ ...view, retryable: false }, account("a"), NOW));
    assert.ok(!H.retryAllowed(view, account("a"), NOW + 7 * MIN), "the ten-minute retry window closes");
    assert.equal(H.countdown(H.quoteLeft(NOW - 8000, NOW)), "1:42");
    assert.ok(H.quoteLeft(NOW - H.QUOTE_MS, NOW) <= 0);
    assert.ok(H.QUOTE_MS < 120000, "the widget withdraws a confirmation before Fusebox refuses it");
    assert.equal(H.countdown(-5), "0:00");
    assert.equal(H.grantDetail({ expiresAt: null, clears: [] }, NOW), "No expiry reported · Clears provider limits");
    assert.match(H.grantDetail({ expiresAt: NOW + 11 * 24 * 60 * MIN, clears: ["weekly"] }, NOW), /^Expires [A-Z][a-z]{2} \d+ · Clears weekly$/);
    assert.deepEqual([H.resetCountText(1), H.resetCountText(2)], ["1 banked reset", "2 banked resets"]);
    assert.deepEqual(["applied", "reconciled_used", "refused", "pending"].map(status => H.operationTone({ status })),
        ["ok", "ok", "info", "warn"]);
});

test("a reset is spent only from its confirmation, never by IPC or a retry", () => {
    const singleton = read("Common/Fusebox.qml");
    const popover = read("Popovers/FuseboxPopover.qml");
    // banked-action is built in one place: the confirmation's handler.
    assert.equal(singleton.split('"banked-action"').length - 1, 1);
    const confirm = singleton.slice(singleton.indexOf("function confirmReset"), singleton.indexOf("function expireReset"));
    assert.match(confirm, /"banked-action"/);
    assert.match(confirm, /if \(!d\)\s*return;/, "nothing is spent without an open confirmation");
    assert.match(confirm, /quoteLeft\(d\.startedAt, Date\.now\(\)\) <= 0/, "a lapsed confirmation is withdrawn");
    const ipc = singleton.slice(singleton.indexOf("IpcHandler"), singleton.indexOf("Timer {"));
    assert.doesNotMatch(ipc, /Reset\(|banked/i, "IPC can't spend resets");
    // After a failed spend the widget only reads status again.
    const done = singleton.slice(singleton.indexOf("function resetDone"), singleton.indexOf("// ---- breaker actions"));
    assert.match(done, /Qt\.callLater\(\(\) => loadReset\(id\)\)/);
    assert.doesNotMatch(done, /confirmReset|banked-action/);
    // Only the confirmation's buttons call confirmReset; Back comes first.
    assert.equal(popover.split("Fusebox.confirmReset(").length - 1, 4);
    const row = popover.slice(popover.indexOf("id: backButton"), popover.indexOf("component FaultRow"));
    assert.ok(row.indexOf("Back") < row.indexOf("Apply reset"));
    assert.match(popover, /onModeChanged: if \(panel\.asking\) Qt\.callLater\(\(\) => backButton\.forceActiveFocus\(\)\)/);
    // Hidden buttons still evaluate bindings, so a missing dialog must never be read.
    assert.match(popover, /readonly property var dialog: resetInfo && resetInfo\.dialog \? resetInfo\.dialog : null/);
    for (const line of popover.split("\n").filter(l => l.includes("panel.dialog.grant")))
        assert.match(line, /panel\.dialog &&|panel\.dialog !== null|^\s*&& \(/, line.trim());
    assert.match(popover, /enabled: !panel\.busy && panel\.dialog !== null/);
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

test("a dismissed fault stays hidden while it lasts and returns when it changes or recurs", () => {
    const quota = { key: "quota:a", kind: "quota", level: "warn", until: NOW + 5 * 24 * 60 * MIN };
    const signin = { key: "signin:b", kind: "signin", level: "err", until: null };
    let dismissed = H.dismissFault({}, quota, NOW);
    assert.deepEqual(H.visibleFaults([quota, signin], dismissed).map(f => f.key), ["signin:b"]);
    assert.equal(H.faultLevel(H.visibleFaults([quota], dismissed)), "ok", "a dismissed fault leaves the badge");
    // A new end time is a new incident.
    assert.equal(H.visibleFaults([{ ...quota, until: quota.until + MIN }], dismissed).length, 1);
    // Still there: kept, and its last sighting moves on.
    dismissed = H.pruneDismissed(dismissed, [quota], NOW + 60 * MIN);
    assert.equal(dismissed["quota:a"].seenAt, NOW + 60 * MIN);
    // Briefly gone (a Fusebox restart): kept. Gone past the grace period: forgotten.
    assert.ok(H.pruneDismissed(dismissed, [], NOW + 70 * MIN)["quota:a"]);
    assert.deepEqual(H.pruneDismissed(dismissed, [], NOW + 60 * MIN + H.DISMISS_GRACE_MS + 1), {});
    // Changed while present: forgotten, so the new incident shows.
    assert.deepEqual(H.pruneDismissed(dismissed, [{ ...quota, until: 1 }], NOW + 61 * MIN), {});
    // From disk: no time limit until the first update, and nothing malformed.
    const loaded = H.loadDismissed({ "quota:a": { signature: H.faultSignature(quota), seenAt: NOW - 3 * 24 * 60 * MIN },
        bad: { signature: 5 }, worse: null });
    assert.deepEqual(Object.keys(loaded), ["quota:a"], "a dismissal survives the shell being off for days");
    assert.ok(H.isDismissed(loaded, quota));
    assert.deepEqual(H.loadDismissed("junk"), {});
    // The widget lists, badges and counts only what is shown.
    const singleton = read("Common/Fusebox.qml");
    assert.match(singleton, /faultLevel\(shownFaults\)/);
    assert.match(singleton, /barValue\(options\.metric, figures, shownFaults\)/);
    assert.match(singleton, /loadDismissed\(stateData\.dismissed\)/);
    assert.match(read("Popovers/FuseboxPopover.qml"), /model: Fusebox\.shownFaults/);
});

test("a request is one line on the grid; tokens and tags are for screen readers", () => {
    const popover = read("Popovers/FuseboxPopover.qml");
    const row = popover.slice(popover.indexOf("component RequestLine"), popover.indexOf("// ---- header"));
    assert.match(row, /height: root\.lineHeight \+ \(requestLine\.showError/);
    assert.match(row, /Helpers\.requestTags\(request\)\.join\(", "\)/);
    assert.match(row, /Helpers\.requestMetrics\(request\)/);
    assert.match(popover, /readonly property var latest: Fusebox\.requests\.slice\(0, 5\)/);
    // Every row starts its text at the same column and ends at the same edge.
    for (const component of ["AccountRow", "GroupHead", "FaultRow", "ClientLine", "BudgetLine", "RequestLine"]) {
        const body = popover.slice(popover.indexOf("component " + component + ":"));
        assert.match(body.slice(0, 9000), /root\.textX/, component + " uses the text column");
    }
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

test("pace marks even use, and a window this pace uses up early says when", () => {
    const week = 7 * 24 * 60 * MIN;
    // Half the week gone, 70% used: 1.4x even pace, out before the reset.
    const hot = { name: "week", used: 70, resetsAt: NOW + week / 2, model: null };
    assert.equal(H.windowElapsed(hot, NOW), 0.5);
    assert.equal(H.paceMark(hot, NOW, "used"), 0.5);
    assert.equal(H.paceMark({ ...hot, resetsAt: NOW + week / 4 }, NOW, "remaining"), 0.25, "Left mirrors the mark");
    assert.ok(Math.abs(H.burnRate(hot, NOW) - 70 / 84) < 1e-9, "percent of the window per hour");
    const out = H.runsOutAt(hot, NOW);
    assert.ok(out > NOW && out < hot.resetsAt);
    assert.equal(Math.round((out - NOW) / MIN), Math.round(30 / (70 / (week / 2)) / MIN));
    assert.equal(H.runsOutAt({ ...hot, used: 40 }, NOW), null, "under even pace it lasts");
    assert.equal(H.runsOutAt({ ...hot, used: 15, resetsAt: NOW + week * 0.9 }, NOW), null, "too early to say");
    assert.equal(H.runsOutAt({ ...hot, resetsAt: null }, NOW), null);
    assert.equal(H.paceMark({ name: "x9", used: 1, resetsAt: NOW + MIN }, NOW, "used"), null, "unknown length");
    assert.equal(H.rateText(0.42), "0.4% an hour");
    assert.equal(H.rateText(0.01), "", "a window barely in use shows no rate");
    const facts = H.windowDetails(account("a", { windows: [hot] }), NOW, false);
    assert.match(facts[0].timing, /^runs out /);
    assert.equal(facts[0].level, "warn");
    assert.equal(facts[0].rate, "0.8% an hour");
    // The meter draws the mark and turns it amber when the window runs out early.
    const popover = read("Popovers/FuseboxPopover.qml");
    assert.match(popover, /pace: meter\.mark === null \? -1 : meter\.mark/);
    assert.match(popover, /color: bar\.early \? Theme\.amber : Theme\.textMid/);
});

test("Codex Pro tiers and Claude plans read as the dashboard names them", () => {
    assert.equal(H.planName({ provider: "codex", plan: "pro", subscriptionPlan: "chatgptpromax" }), "Pro 500");
    assert.equal(H.planName({ provider: "codex", plan: "pro", subscriptionPlan: "chatgptprolite" }), "Pro 100");
    assert.equal(H.planName({ provider: "codex", plan: "pro", subscriptionPlan: "something-new" }), "Pro");
    assert.equal(H.planName({ provider: "claude", plan: "max_20x", subscriptionPlan: "chatgptpro" }), "Max 20x");
    assert.equal(H.planName({ provider: "codex", subscriptionPlan: "toString" }), "", "no prototype lookups");
});

test("pace and storage faults list, but only badge-worthy ones count and notify", () => {
    const pace = { key: "pace:a:week", kind: "pace", level: "warn", until: NOW + 90 * MIN, badge: false };
    const storage = { key: "storage:usage", kind: "storage", level: "err", until: null, badge: true };
    assert.equal(H.faultLevel([pace]), "ok", "a pace warning leaves the badge alone");
    assert.equal(H.faultLevel([pace, storage]), "critical");
    assert.equal(H.barValue("faults", null, [pace, storage]), "1");
    assert.deepEqual(H.newFaults([], [pace, storage]).map(f => f.key), ["storage:usage"]);
    assert.match(H.faultTiming(pace, NOW), /^Renews \d\d:\d\d, in 1h 30m$/);
    const glyphs = [H.faultGlyph(pace), H.faultGlyph(storage), H.faultGlyph({ level: "err" }),
        H.faultGlyph({ level: "warn" })];
    assert.deepEqual(glyphs, ["speed", "server", "error", "warning"]);
    const Tabler = load("TablerGlyphs.js");
    for (const glyph of glyphs)
        assert.ok(Tabler.has(glyph), glyph + " is bundled");
    assert.match(read("Bar/Modules/Fusebox.qml"), /const shown = Fusebox\.badgeFaults;/);
});

test("combined weekly limits weigh plans by price and compare with even pace", () => {
    const week = 7 * 24 * 60 * MIN;
    const sub = (id, plan, used, extra = {}) => account(id, { plan, windows: [
        { name: "week", used, resetsAt: NOW + week / 2, model: null }], ...extra });
    const pools = H.weeklyPools([sub("a", "max_20x", 60), sub("b", "pro", 20), sub("c", "max_20x", 30),
        sub("d", "max_20x", 99, { disabled: true }), account("k", { kind: "api-key" }),
        sub("x", "pro", 50, { provider: "codex" })], NOW);
    assert.equal(pools.length, 1, "a provider needs two subscriptions");
    const p = pools[0];
    assert.equal(p.priced, true);
    assert.equal(Math.round(p.used * 100) / 100, Math.round((10 * 60 + 20 + 10 * 30) / 21 * 100) / 100);
    assert.equal(p.pace, 0.5);
    assert.deepEqual(H.poolGap(p), { text: "6 points under pace", level: "ok" });
    assert.equal(H.poolBasis(pools), "weighted by plan price");
    const unknown = H.weeklyPools([sub("a", null, 80), sub("b", "pro", 80)], NOW)[0];
    assert.equal(unknown.priced, false, "an unknown plan weighs everyone equally");
    assert.deepEqual(H.poolGap(unknown), { text: "30 points over pace", level: "warn" });
    const popover = read("Popovers/FuseboxPopover.qml");
    assert.match(popover, /readonly property var groups: Helpers\.accountGroups\(Fusebox\.accounts\)/,
        "groups follow the accounts, not the clock");
});

test("accounts group by provider, naming a shared plan once on the group's head", () => {
    const max = (id, extra = {}) => account(id, { plan: "max_20x", ...extra });
    const groups = H.accountGroups([max("c"), max("a"), account("k1", { kind: "api-key" }),
        account("x", { provider: "codex", plan: "pro", subscriptionPlan: "chatgptpro" }), max("b", { plan: "pro" }),
        account("k2", { kind: "api-key" })]);
    assert.deepEqual(groups.map(g => [g.name, g.keys, g.accounts.map(a => a.id), g.summary, g.uniformPlan]), [
        ["Claude", false, ["a", "b", "c"], "2 Max 20x, 1 Pro", false],
        ["Codex", false, ["x"], "Pro 200", true],
        ["Claude", true, ["k1", "k2"], "2 keys", false]]);
    assert.equal(H.accountGroups([max("a"), max("b")])[0].summary, "2 × Max 20x");
    assert.equal(H.accountGroups([max("a"), account("b")])[0].summary, "2 accounts", "an unknown plan says only how many");
});

test("who used a window: the largest clients, then the rest, outside use and hidden names", () => {
    const share = { key: "week", name: "week", model: null, used: 62, outside: 4, before: 1, byTokens: 0, clients: [
        { id: "laptop", label: "Laptop", points: 30 }, { id: "app:Claude Code", label: "Claude Code", points: 12 },
        { id: "", label: "", points: 6 }, { id: "ci", label: "CI", points: 5 }, { id: "nas", label: "", points: 3 },
        { id: "pi", label: "Pi", points: 1 }] };
    const a = account("a", { windows: [{ name: "week", used: 62, resetsAt: NOW + MIN, model: null }],
        attribution: { current: [share] } });
    const rows = H.shareRows(share, false);
    assert.deepEqual(rows.map(r => [r.name, r.points, r.other]), [["Laptop", 30, false], ["Claude Code", 12, false],
        ["Other requests", 6, false], ["CI", 5, false], ["2 more clients", 4, true], ["Outside Fusebox", 4, true],
        ["Before Fusebox looked", 1, true]]);
    assert.deepEqual(H.shareRows(share, true).slice(0, 2).map(r => r.name), [H.HIDDEN, "Claude Code"],
        "named clients hide with the emails; programs don't");
    const used = H.windowDetails(a, NOW, false);
    assert.deepEqual(used.map(u => [u.title, u.rows.length]), [["Weekly", 7]]);
    assert.equal(H.sessionQuota(a, { quota: { week: 4.2, "5h": 11, "week · opus": 0 } }), "4% of week · 11% of 5h");
    assert.equal(H.windowName("week", "opus"), "week opus");
});

test("sources and clients read as the dashboard shows them, hidden with the emails", () => {
    const tail = { ip: "100.64.0.3", via: "forwarded", login: "me@github" };
    assert.equal(H.sourceText(tail, false), "100.64.0.3 · via Tailscale · me@github");
    assert.equal(H.sourceText(tail, true), H.HIDDEN + " · via Tailscale · " + H.HIDDEN);
    assert.equal(H.viaText({ ip: "127.0.0.1", via: "direct" }, false), "this machine");
    assert.equal(H.viaText({ ip: "10.0.0.2", via: "proxy_protocol" }, false), "via TCP forwarder");
    assert.equal(H.originText({ keyLabel: "Laptop", source: { ip: "10.0.0.2", via: "direct" } }, false),
        "Laptop · 10.0.0.2 · direct");
    assert.equal(H.originText({ source: tail }, false), "100.64.0.3 · via Tailscale", "rows leave the login out");
    assert.deepEqual(H.namedSessions({ sessions: [{ client: "Codex" }, {}, { model: "m" }] }).length, 2);
    assert.deepEqual(H.namedSessions({ error: "x", sessions: [{ client: "Codex" }] }), []);
    const view = { estimates: true, named: [
        { id: "laptop", label: "Laptop", tokensToday: 4e6, tokensPerDay: 5e6, usdMonth: 12.5, usdPerMonth: 100 },
        { id: "ci", label: "CI", tokensToday: 0, tokensPerDay: null, usdMonth: 99, usdPerMonth: 100 },
        { id: "free", label: "Free", tokensToday: 9, tokensPerDay: null, usdMonth: 1, usdPerMonth: null }],
        connected: [
            { id: "laptop", label: "Laptop", ip: "10.0.0.2", via: "direct", inFlight: 0, sockets: 0, last: NOW - 2 * MIN },
            { id: "app:Codex", label: "Codex", ip: "10.0.0.3", via: "direct", inFlight: 2, sockets: 0, last: NOW }] };
    assert.deepEqual(H.budgets(view, false).map(b => [b.name, b.text, b.level]), [
        ["Laptop", "4.0M of 5.0M tokens today", "warn"], ["Laptop", "$12.50 of $100 this month", "ok"],
        ["CI", "$99.00 of $100 this month", "critical"]]);
    const rows = H.connectedRows(view, true);
    assert.deepEqual(rows.map(r => r.name), ["Codex", H.HIDDEN], "busy first; programs keep their names");
    assert.deepEqual(rows.map(r => H.connectedState(r, NOW)), ["2 requests", "2 min ago"]);
});

test("priority follows the dashboard's First, Normal and Last", () => {
    assert.deepEqual(H.PRIORITIES.map(p => p.value), [10, 0, -10]);
    assert.deepEqual([H.priorityChoice(3), H.priorityChoice(0), H.priorityChoice(-50)], [10, 0, -10]);
    assert.equal(H.priorityHelp(-1), "Only when no other account can");
    assert.equal(H.priorityHelp(0), "By the routing strategy");
    const singleton = read("Common/Fusebox.qml");
    assert.match(singleton, /command\.push\("--priority", String\(Helpers\.priorityChoice\(value\)\)\)/);
});

test("automatic banked resets say what Fusebox will do by itself", () => {
    const at = NOW + 3 * 24 * 60 * MIN;
    assert.equal(H.bankedPlanText(null, NOW), "");
    assert.match(H.bankedPlanText({ expiresAt: at, redeemAt: at - 60 * MIN, auto: false }, NOW),
        /^The next one expires [A-Z][a-z]{2} \d+, \d\d:\d\d\. Automatic redemption is off\.$/);
    assert.match(H.bankedPlanText({ expiresAt: at, redeemAt: at - 60 * MIN, auto: true, prioritized: true }, NOW),
        /at 95% weekly use, or at [A-Z][a-z]{2} \d+, \d\d:\d\d, an hour before it expires\. Until then, this account takes new work first\.$/);
    assert.equal(H.bankedPlanText({ expiresAt: at, auto: true, due: true }, NOW), "Fusebox is about to use one by itself.");
});

test("a rejected key, a lockout and a restart each read as what they are", () => {
    const singleton = read("Common/Fusebox.qml");
    assert.match(singleton, /locked: "Locked out"/);
    assert.match(singleton, /restarting: "Restarting"/);
    assert.match(singleton, /troubled: connection === "auth" \|\| connection === "locked"\s*\|\| \(connection === "offline" && \(longDown \|\| !hasData\)\)/,
        "a short reconnect isn't red");
    assert.match(singleton, /longDown: connection !== "live" && downSince > 0 && now - downSince >= 30000/);
    assert.match(read("Popovers/FuseboxPopover.qml"), /visible: root\.configured && Fusebox\.problemShown/);
    assert.match(read("Bar/Modules/Fusebox.qml"), /readonly property bool troubled: Fusebox\.troubled/);
    const popover = read("Popovers/FuseboxPopover.qml");
    assert.match(popover, /The widget won't try this key again/);
    assert.match(popover, /Fusebox\.lockedUntil - root\.now/);
});
