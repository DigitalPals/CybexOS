const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { shellDir, load } = require("./shell.cjs");

const H = load("HermesHelpers.js");

function read(relative) {
    return fs.readFileSync(path.join(shellDir, relative), "utf8");
}

test("streamed deltas keep the fields an existing message already has", () => {
    let messages = H.applyMessageEvent([], "message-created", {
        id: "a1", role: "assistant", text: "", createdAt: "2026-09-01T10:00:00Z",
        model: "fixture/model", parentId: "u1", sourceIndex: 7, order: 7000,
        attachments: [{ name: "plan.pdf", mime: "application/pdf", size: 3 }],
    });
    messages = H.applyMessageEvent(messages, "message-delta", {
        id: "a1", role: "assistant", text: "Hel", order: 7000,
    });
    messages = H.applyMessageEvent(messages, "message-delta", {
        id: "a1", text: "lo",
    });
    assert.equal(messages.length, 1);
    const [message] = messages;
    assert.equal(message.text, "Hello");
    assert.equal(message.streaming, true);
    assert.equal(message.createdAt, "2026-09-01T10:00:00Z");
    assert.equal(message.model, "fixture/model");
    assert.equal(message.parentId, "u1");
    assert.equal(message.sourceIndex, 7);
    assert.equal(message.order, 7000);
    assert.deepEqual(message.attachments.map(item => item.name), ["plan.pdf"]);

    // A completion without text or metadata settles the row without wiping it.
    messages = H.applyMessageEvent(messages, "message-complete", { id: "a1" });
    assert.equal(messages[0].text, "Hello");
    assert.equal(messages[0].streaming, false);
    assert.equal(messages[0].createdAt, "2026-09-01T10:00:00Z");
    assert.equal(messages[0].sourceIndex, 7);

    // Fields the event does carry still win.
    messages = H.applyMessageEvent(messages, "message-complete", {
        id: "a1", text: "Hello!", error: "late failure",
    });
    assert.equal(messages[0].text, "Hello!");
    assert.equal(messages[0].error, "late failure");
    assert.equal(messages[0].model, "fixture/model");
});

test("a delta for an unknown id still creates a streaming row with defaults", () => {
    const messages = H.applyMessageEvent([{ id: "u1", role: "user", text: "Hi" }],
        "message-delta", { id: "a9", role: "assistant", text: "Yo" });
    assert.equal(messages.length, 2);
    assert.equal(messages[1].streaming, true);
    assert.equal(messages[1].text, "Yo");
    assert.deepEqual(messages[1].attachments, []);
    assert.equal(messages[0].text, "Hi", "the existing row is untouched");
});

test("messagePatch reports only fields present in the payload", () => {
    const payload = { id: "x", text: "t" };
    const patch = H.messagePatch(payload, H.normalizeMessage(payload, 3));
    assert.deepEqual(Object.keys(patch).sort(), ["id", "text"]);
});

test("line counting stops early and matches split semantics", () => {
    assert.equal(H.exceedsLineCount("", 12), false);
    assert.equal(H.exceedsLineCount("a\n".repeat(11) + "b", 12), false);
    assert.equal(H.exceedsLineCount("a\n".repeat(12) + "b", 12), true);
    for (const text of ["", "x", "x\n", "\n\n\n", "a\nb\nc"])
        for (const limit of [0, 1, 2, 3, 4])
            assert.equal(H.exceedsLineCount(text, limit),
                text.split("\n").length > limit, JSON.stringify([text, limit]));
});

function applyOps(current, desired) {
    const model = current.slice();
    const kept = [];
    for (const op of H.listSyncOps(current, desired)) {
        if (op.op === "remove")
            model.splice(op.at, op.count);
        else if (op.op === "insert")
            model.splice(op.at, 0, desired[op.index]);
        else {
            assert.equal(model[op.at], desired[op.index]);
            kept.push(desired[op.index]);
        }
    }
    return { model, kept };
}

test("keyed list sync keeps surviving rows and only touches the difference", () => {
    const cases = [
        [[], ["a", "b"]],
        [["a", "b"], ["a", "b"]],
        [["a", "b"], ["a", "b", "c"]],
        [["b", "c"], ["a", "b", "c"]],
        [["a", "b", "c"], ["b", "c"]],
        [["a", "b", "c"], ["a", "c"]],
        [["a", "b", "c"], []],
        [["a", "b", "c"], ["c", "b", "a"]],
        [["a", "x", "b"], ["a", "b", "y"]],
    ];
    for (const [current, desired] of cases) {
        const { model } = applyOps(current, desired);
        assert.deepEqual(model, desired, JSON.stringify([current, desired]));
    }

    // Streaming (same keys) and appending never remove or re-create a row.
    const append = H.listSyncOps(["a", "b"], ["a", "b", "c"]);
    assert.deepEqual(append.map(op => op.op), ["keep", "keep", "insert"]);
    const prepend = H.listSyncOps(["b", "c"], ["a", "b", "c"]);
    assert.deepEqual(prepend.map(op => op.op), ["insert", "keep", "keep"]);
    const same = H.listSyncOps(["a", "b"], ["a", "b"]);
    assert.ok(same.every(op => op.op === "keep"));
});

test("conversation sorting uses the precomputed numeric key", () => {
    const older = H.normalizeConversation({ id: "old", title: "B",
        updatedAt: "2026-09-01T10:00:00Z" }, 0);
    const newer = H.normalizeConversation({ id: "new", title: "A",
        updated_at: 1789000000 }, 1);
    assert.equal(typeof older.updatedAtMs, "number");
    assert.ok(newer.updatedAtMs > older.updatedAtMs);
    assert.deepEqual(H.sortedConversations([older, newer]).map(row => row.id),
        ["new", "old"]);
    assert.equal(H.sameConversation(older, Object.assign({}, older)), true);
    assert.equal(H.sameConversation(older,
        Object.assign({}, older, { statusText: "Hermes is reading…" })), false);
});

test("streaming updates the visible transcript in place", () => {
    const conversations = read("Common/HermesConversations.qml");
    const transcript = read("Popovers/HermesTranscript.qml");

    // No per-token reassign of the whole transcript map.
    const messageBranch = conversations.slice(
        conversations.indexOf("event.indexOf(\"message-\") === 0"),
        conversations.indexOf("event.indexOf(\"tool-\") === 0"));
    assert.doesNotMatch(messageBranch, /messagesByConversation\s*=/);
    assert.match(conversations, /function storeMessages\(/);
    assert.match(conversations, /id:\s*persistTimer/);
    assert.match(conversations, /function flushDrafts\(/);

    assert.match(transcript, /ListModel\s*\{\s*id:\s*transcriptModel/);
    assert.match(transcript, /model:\s*transcriptModel/);
    assert.match(transcript, /Helpers\.listSyncOps\(/);
    assert.match(transcript, /setProperty\(/);
    assert.match(transcript, /Helpers\.exceedsLineCount\(/);
    assert.doesNotMatch(transcript, /split\("\\n"\)/);
    assert.match(transcript, /property var expandedById:/,
        "row UI state is keyed by message id on the transcript");
});

test("the attachment picker outlives the popover", () => {
    const facade = read("Common/Hermes.qml");
    const composer = read("Popovers/HermesComposer.qml");
    assert.match(facade, /"zenity", "--file-selection", "--multiple"/);
    assert.match(facade, /function pickAttachments\(conversationId\)/);
    assert.doesNotMatch(composer, /\bProcess\s*\{/);
    assert.match(composer, /Hermes\.pickAttachments\(/);
});
