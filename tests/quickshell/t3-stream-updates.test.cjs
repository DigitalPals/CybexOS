// Streaming and transport behaviour of the T3 client that used to cost a full
// rebuild per frame or per token, and the connection liveness rules.
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { load, shellDir } = require("./shell.cjs");

const H = load("T3CodeHelpers.js");
const read = relative => fs.readFileSync(path.join(shellDir, relative), "utf8");

// The comparator T3Detail used before keys were precomputed, kept here as the
// reference the new ordering must agree with.
function legacyCompare(left, right) {
    if (typeof left?.sequence === "number" && typeof right?.sequence === "number"
            && left.sequence !== right.sequence)
        return left.sequence - right.sequence;
    const lm = H.parseMs(left?.createdAt ?? left?.updatedAt ?? left?.completedAt);
    const rm = H.parseMs(right?.createdAt ?? right?.updatedAt ?? right?.completedAt);
    if (!isNaN(lm) && !isNaN(rm) && lm !== rm)
        return lm - rm;
    const lid = typeof left?.id === "string" ? left.id : "";
    const rid = typeof right?.id === "string" ? right.id : "";
    return lid.localeCompare(rid);
}

function legacyUpsert(values, value, idField) {
    const next = Array.isArray(values) ? values.slice() : [];
    const key = value ? value[idField] : undefined;
    let at = -1;
    if (key !== undefined && key !== null)
        at = next.findIndex(entry => entry && entry[idField] === key);
    if (at >= 0)
        next[at] = value;
    else if (value)
        next.push(value);
    return next.sort(legacyCompare);
}

function message(id, minute, extra = {}) {
    return Object.assign({
        id: id,
        role: "assistant",
        text: id,
        createdAt: `2026-09-01T10:${String(minute).padStart(2, "0")}:00.000Z`
    }, extra);
}

test("history ordering matches the per-comparison reference", () => {
    const entries = [
        message("c", 5), message("a", 5), message("b", 1),
        { id: "seq-2", sequence: 2, createdAt: "2026-09-01T09:00:00.000Z" },
        { id: "seq-1", sequence: 1, createdAt: "2026-09-01T11:00:00.000Z" },
        { id: "no-time" }, { id: "updated", updatedAt: "2026-09-01T10:03:00.000Z" },
        { checkpointRef: "r", completedAt: "2026-09-01T10:02:00.000Z" }
    ];
    const expected = entries.slice().sort(legacyCompare);
    assert.deepEqual(H.sortHistory(entries).map(e => e.id ?? e.checkpointRef),
        expected.map(e => e.id ?? e.checkpointRef));
    for (const left of entries)
        for (const right of entries)
            assert.equal(Math.sign(H.compareHistory(left, right)),
                Math.sign(legacyCompare(left, right)));
    assert.deepEqual(H.sortHistory(null), []);
});

test("a streamed message keeps its slot and agrees with upsert-then-sort", () => {
    let history = H.sortHistory([message("m1", 1), message("m2", 2), message("m3", 3)]);
    let legacy = history.slice();
    for (let token = 0; token < 20; token++) {
        const update = message("m2", 2, { text: "m2" + "x".repeat(token), streaming: true,
            updatedAt: `2026-09-01T10:30:${String(token).padStart(2, "0")}.000Z` });
        const before = history;
        history = H.upsertHistory(history, update, "id");
        legacy = legacyUpsert(legacy, update, "id");
        assert.notEqual(history, before, "an upsert must produce a new array so QML notices");
        assert.equal(history[1], update);
        assert.deepEqual(history.map(m => m.id), legacy.map(m => m.id));
    }

    // New entries land where a stable sort would put them: after their equals.
    for (const value of [message("m0", 0), message("m9", 9), message("m2b", 2),
        message("m2", 2), message("late", 4), message("m1", 7)]) {
        history = H.upsertHistory(history, value, "id");
        legacy = legacyUpsert(legacy, value, "id");
        assert.deepEqual(history.map(m => m.id), legacy.map(m => m.id));
    }
    assert.deepEqual(H.upsertHistory(history, null, "id"), history);
});

test("long messages are detected by counting newlines, never splitting", () => {
    assert.equal(H.isLongMessage("short"), false);
    assert.equal(H.isLongMessage("x".repeat(1201)), true);
    assert.equal(H.isLongMessage("x".repeat(1200)), false);
    // The card used text.split("\n").length > 12: twelve newlines is long.
    assert.equal(H.isLongMessage("a\n".repeat(11) + "a"), false);
    assert.equal(H.isLongMessage("a\n".repeat(12) + "a"), true);
    assert.equal(H.isLongMessage("\n".repeat(12)), true);
    assert.equal(H.isLongMessage(null), false);
    for (let n = 0; n < 20; n++) {
        const text = "line\n".repeat(n);
        assert.equal(H.exceedsLineCount(text, 12), text.split("\n").length > 12, String(n));
    }
});

function applyOps(rows, ops) {
    const model = rows.map(row => Object.assign({}, row));
    for (const op of ops) {
        if (op.op === "remove")
            model.splice(op.index, op.count);
        else if (op.op === "insert")
            model.splice(op.index, 0, Object.assign({}, op.row));
        else
            Object.assign(model[op.index], op.changes);
    }
    return model;
}

test("history rows update in place and keep every surviving row", () => {
    const first = [message("u1", 1, { role: "user" }), message("a1", 2), message("a2", 3)];
    const initial = H.historyRowOps([], first);
    assert.deepEqual(initial.ops.map(op => op.op), ["insert", "insert", "insert"]);
    assert.deepEqual(initial.rows.map(row => row.continuation), [false, false, true]);
    assert.deepEqual(applyOps([], initial.ops), initial.rows);

    // A token is one field on one row.
    const streamed = [first[0], first[1], Object.assign({}, first[2], {
        text: "a2 and more", streaming: true })];
    const token = H.historyRowOps(initial.rows, streamed);
    assert.deepEqual(token.ops, [{ op: "set", index: 2,
        changes: { body: "a2 and more", streaming: true } }]);

    // Nothing changed: nothing to do.
    assert.deepEqual(H.historyRowOps(token.rows, streamed).ops, []);

    // The page slides: the oldest leaves, a new one arrives, the rest stay.
    const slid = [streamed[1], streamed[2], message("u2", 4, { role: "user" })];
    const slide = H.historyRowOps(token.rows, slid);
    assert.deepEqual(slide.ops.map(op => op.op), ["remove", "insert"]);
    assert.deepEqual(applyOps(token.rows, slide.ops), slide.rows);
    assert.equal(slide.rows[0].continuation, false,
        "the first row on a page always names its speaker");

    // Show earlier prepends and re-evaluates the old first row's label.
    const earlier = H.historyRowOps(slide.rows,
        [message("a0", 0)].concat(slid));
    assert.deepEqual(earlier.ops.map(op => op.op), ["insert", "set"]);
    assert.deepEqual(earlier.ops[1].changes, { continuation: true });
    assert.deepEqual(applyOps(slide.rows, earlier.ops), earlier.rows);

    // Clearing the thread removes everything in one operation.
    assert.deepEqual(H.historyRowOps(earlier.rows, []).ops,
        [{ op: "remove", index: 0, count: 4 }]);
});

test("history rows are flat and consistently typed for a ListModel", () => {
    const [row] = H.historyRows([{ id: "m", role: "assistant", text: null,
        createdAt: "2026-09-01T10:00:00.000Z", updatedAt: null }]);
    assert.deepEqual(row, {
        messageId: "m", speakerRole: "assistant", body: "", streaming: false,
        timestamp: "2026-09-01T10:00:00.000Z", longMessage: false, continuation: false
    });
    assert.equal(H.historyRows([{ role: "user", text: "x", updatedAt: "" }])[0].timestamp, "",
        "an empty updatedAt wins over createdAt, as `??` did in the card");
});

test("a shell Chunk copies each map once and reports signals in order", () => {
    const threads = { t1: { id: "t1" } };
    const projects = { p1: { id: "p1" } };
    const result = H.applyShellItems(threads, projects, [
        { kind: "thread-upserted", thread: { id: "t2" } },
        { kind: "thread-upserted", thread: { id: "t1", title: "new" } },
        { kind: "thread-removed", threadId: "t2" },
        { kind: "project-upserted", project: { id: "p2" } },
        { kind: "synchronized" },
        { kind: "unknown" },
        null
    ]);
    assert.equal(result.dirty, true);
    assert.equal(result.ready, true);
    assert.deepEqual(Object.keys(result.threadMap), ["t1"]);
    assert.equal(result.threadMap.t1.title, "new");
    assert.deepEqual(Object.keys(result.projectMap).sort(), ["p1", "p2"]);
    assert.deepEqual(threads, { t1: { id: "t1" } }, "the published map is never mutated");
    assert.deepEqual(projects, { p1: { id: "p1" } });
    assert.deepEqual(result.events, [
        { kind: "thread-upserted", threadId: "t2" },
        { kind: "thread-upserted", threadId: "t1" }
    ]);

    const quiet = H.applyShellItems(threads, projects, [{ kind: "synchronized" }]);
    assert.equal(quiet.dirty, false);
    assert.equal(quiet.threadsChanged, false);
    assert.equal(quiet.threadMap, threads);

    const snapshot = H.applyShellItems(threads, projects, [
        { kind: "snapshot", snapshot: { projects: [{ id: "p9" }], threads: [{ id: "t9" }] } },
        { kind: "thread-upserted", thread: { id: "t8" } }
    ]);
    assert.deepEqual(Object.keys(snapshot.threadMap).sort(), ["t8", "t9"]);
    assert.deepEqual(Object.keys(snapshot.projectMap), ["p9"]);
    assert.deepEqual(snapshot.events.map(e => e.kind), ["snapshot", "thread-upserted"]);
});

test("a DPoP token refresh is not a new credential session", () => {
    const cloud = {
        httpBaseUrl: "https://env.example", wsBaseUrl: "wss://env.example",
        accessToken: "token-1", authMode: "cloud", tokenType: "DPoP",
        cloudStatus: "connected", cloudIdentity: "me", environmentId: "env-1"
    };
    const fp = H.credentialFingerprint;
    assert.equal(fp(Object.assign({}, cloud, { accessToken: "token-2" })), fp(cloud),
        "the ticket helper's near-expiry refresh must not reset the transport");
    for (const change of [{ accessToken: "" }, { httpBaseUrl: "https://other" },
        { wsBaseUrl: "wss://other" }, { cloudIdentity: "you" }, { environmentId: "env-2" },
        { cloudStatus: "no-environments" }, { tokenType: "Bearer" }, { authMode: "" }])
        assert.notEqual(fp(Object.assign({}, cloud, change)), fp(cloud), JSON.stringify(change));

    const bearer = { httpBaseUrl: "https://host", accessToken: "pairing-1" };
    assert.notEqual(fp(Object.assign({}, bearer, { accessToken: "pairing-2" })), fp(bearer),
        "a bearer token is the pairing itself");
    assert.equal(fp({}), fp({ tokenType: "", cloudStatus: "" }));
});

test("an unanswered ping recycles a silent socket", () => {
    const interval = 30000;
    assert.equal(H.socketSilent(0, 1e12, interval), false, "no frame yet: not judged");
    // Healthy: the Pong to the previous ping arrived about one interval ago.
    assert.equal(H.socketSilent(1000, 1000 + interval, interval), false);
    // One ping went unanswered: nothing since the one before it.
    assert.equal(H.socketSilent(1000, 1000 + 2 * interval - 200, interval), true);
    // Resumed from a long suspend.
    assert.equal(H.socketSilent(1000, 1000 + 3600 * 1000, interval), true);

    const connection = read("Common/T3Connection.qml");
    assert.match(connection, /onMessage: lastFrameMs = Date\.now\(\)/);
    assert.match(connection,
        /id: pingTimer[\s\S]*?Helpers\.socketSilent\(root\.lastFrameMs[\s\S]*?root\.scheduleRetry\(root\.sessionEpoch\);\s*return;[\s\S]*?_tag: "Ping"/,
        "the ping tick must check for silence before sending the next ping");
    assert.match(connection,
        /st === 1\) \{[\s\S]*?root\.lastFrameMs = Date\.now\(\);[\s\S]*?root\.state = "connected";/,
        "a fresh socket starts its silence clock at open");
    assert.match(connection, /function fingerprint\(data\) \{\s*return Helpers\.credentialFingerprint\(data\);/);
});

test("stream consumers coalesce their per-frame work", () => {
    const threads = read("Common/T3Threads.qml");
    const facade = read("Common/T3Code.qml");
    const detail = read("Common/T3Detail.qml");
    const page = read("Popovers/T3ThreadPage.qml");

    assert.match(facade, /dirty = T3Threads\.applyItems\(msg\.values\) \|\| dirty;/);
    assert.match(facade, /if \(dirty\)\s*T3Threads\.scheduleRebuild\(\);/);
    assert.match(threads, /function scheduleRebuild\(\)[\s\S]*?Qt\.callLater\(root\.flushRebuild\)/);
    assert.match(threads, /function rebuild\(\) \{\s*rebuildQueued = false;/);
    assert.doesNotMatch(threads, /Object\.assign\(\{\}, threadMap\)/,
        "the thread map is copied once per frame by the helper, not once per item");

    assert.match(detail, /scheduleDetailRecompute\(event\.type === "thread\.activity-appended"\);/);
    assert.match(detail, /Qt\.callLater\(root\.flushDetailRecompute\)/);
    assert.doesNotMatch(detail, /sortedHistory\(detail(Messages|Activities)\)/,
        "derived projections walk the already-ordered histories");
    assert.match(detail,
        /JSON\.stringify\(nextApprovals\) !== JSON\.stringify\(detailApprovals\)\)\s*detailApprovals = nextApprovals;/);
    assert.match(detail,
        /JSON\.stringify\(nextInputs\) !== JSON\.stringify\(detailPendingInputs\)\)\s*detailPendingInputs = nextInputs;/);

    assert.match(page, /Repeater \{\s*model: historyModel\s*delegate: MessageCard \{\}/);
    assert.match(page, /onHistoryChanged: syncHistory\(\)/);
    assert.match(page, /readonly property bool expanded: root\.expandedMessages\[messageId\] === true/);
    assert.doesNotMatch(page, /\.split\("\\n"\)/, "no per-binding split of message text");
    assert.doesNotMatch(page, /root\.history\.items\[/);
});
