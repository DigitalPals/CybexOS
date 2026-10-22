const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { shellDir, load } = require("./shell.cjs");

// Exercise the singleton's request/settlement code, with only process launch
// replaced. No credentials, gh binary, timers or network are involved.
function harness() {
    const source = fs.readFileSync(path.join(shellDir, "Common/GitHub.qml"), "utf8");
    const context = vm.createContext({
        statsCache: {}, statsErrors: {}, queue: [], active: null, pollEnabled: true,
        Helpers: load("GitHubHelpers.js"), Queue: load("GitHubQueue.js"),
        ProcHelpers: load("ProcHelpers.js"), pump() {}
    });
    for (const name of ["statsFor", "requestStats", "patchStats", "patchStatsError", "enqueue", "settle"])
        vm.runInContext(source.match(new RegExp("^    function " + name + "\\([^]*?^    }", "m"))[0], context);
    context.finish = (code, body = "", error = "") => {
        assert.equal(context.active, null);
        assert.equal(context.queue.length, 1);
        context.active = context.queue[0];
        context.queue = context.queue.slice(1);
        // A second consumer while in flight must not add another request.
        context.requestStats("example/repo", "abc");
        assert.equal(context.queue.length, 0);
        context.settle(code, body, error);
        assert.equal(context.active, null);
    };
    return context;
}

test("failed stats remain unavailable, deduplicate retries and recover through settlement", () => {
    const h = harness();
    const failures = [
        [1, "", "offline"], [-1, "", ""],
        [h.Helpers.GH_TIMEOUT_EXIT, "", "request timed out"],
        [0, "truncated json", ""], [0, '{"s":"another-commit","f":3}', ""]
    ];
    for (const [code, body, error] of failures) {
        h.requestStats("example/repo", "abc");
        h.requestStats("example/repo", "abc");
        assert.equal(h.queue.length, 1);
        assert.equal(h.statsErrors.abc, undefined, "retry clears the unavailable state while pending");
        h.finish(code, body, error);
        assert.equal(h.statsFor("abc"), null, "failures must never look like an empty commit");
        assert.ok(h.statsErrors.abc);
    }
    // Reopening the row invokes the same request path as the explicit Retry.
    h.requestStats("example/repo", "abc");
    h.finish(0, '{"s":"abc","f":2,"add":17,"del":4}');
    assert.equal(h.statsErrors.abc, undefined);
    assert.equal(h.statsFor("abc").additions, 17);
    const cached = h.statsFor("abc");
    h.requestStats("example/repo", "abc");
    assert.equal(h.queue.length, 0, "a successful immutable result is reused on reopen");
    assert.equal(h.statsFor("abc"), cached);
});

test("a legitimate empty success is cached, even following a failure", () => {
    const h = harness();
    h.requestStats("example/repo", "abc");
    h.finish(1, "", "temporary failure");
    h.requestStats("example/repo", "abc");
    h.finish(0, '{"s":"abc","f":0,"add":0,"del":0}');
    assert.equal(JSON.stringify(h.statsFor("abc")), '{"sha":"abc","files":0,"additions":0,"deletions":0}');
    assert.equal(h.statsErrors.abc, undefined);
    h.requestStats("example/repo", "abc");
    assert.equal(h.queue.length, 0);
});
