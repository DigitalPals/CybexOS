const test = require("node:test");
const assert = require("node:assert/strict");
const { load } = require("./shell.cjs");
const Q = load("GitHubQueue.js");

test("interactive gh reads preserve FIFO priority and promote richer queued jobs", () => {
    let queue = [];
    const add = job => { const result = Q.enqueue(queue, null, job); queue = result.queue; return result.added; };
    add({ kind: "repos" });
    add({ kind: "commits", slug: "a/b", toast: true, since: "yesterday" });
    add({ kind: "stats", sha: "first", interactive: true });
    assert.equal(add({ kind: "commits", slug: "a/b", interactive: true }), false);
    assert.deepEqual(queue.map(Q.jobKey), ["stats:first", "commits:a/b", "repos"]);
    assert.equal(queue[1].toast, true);
    assert.equal(queue[1].since, "yesterday");
    assert.equal(queue[1].interactive, true);
});

test("deduplication separates stale generations and never duplicates an active request", () => {
    const active = { kind: "events", slug: "a/b", generation: 1 };
    const original = [];
    assert.strictEqual(Q.enqueue(original, active, { ...active, interactive: true }).queue, original);
    const result = Q.enqueue(original, active, { ...active, generation: 2 });
    assert.equal(result.added, true);
    assert.equal(result.queue.length, 1);
    assert.equal(result.queue[0].generation, 2);
    assert.equal(original.length, 0, "queue policy must not mutate prior published state");
});
