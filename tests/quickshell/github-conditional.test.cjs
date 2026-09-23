const test = require("node:test");
const assert = require("node:assert/strict");
const { load } = require("./shell.cjs");

const H = load("GitHubHelpers.js");

// Conditional Inbox requests, rate-limit back-off, and the gh watchdog's
// timing contract. The singleton only wires these together; every decision
// about a header lives here.

const NOW = Date.parse("2026-09-23T12:00:00Z");
const LAST_MODIFIED = "Wed, 23 Sep 2026 11:58:07 GMT";

test("included responses expose a Last-Modified validator for notifications", () => {
    const response = H.parseIncludedResponse(
        "HTTP/2.0 200 OK\r\nLast-Modified: " + LAST_MODIFIED + "\r\n"
        + "X-Poll-Interval: 60\r\nX-RateLimit-Remaining: 4990\r\n\r\n[]\n");
    assert.equal(response.lastModified, LAST_MODIFIED);
    assert.equal(response.etag, "");
    assert.equal(response.headers["x-ratelimit-remaining"], "4990");
    assert.equal(response.body, "[]");
});

test("validators that could smuggle a header are discarded", () => {
    assert.equal(H.normalizeEtag('W/"ok"'), 'W/"ok"');
    assert.equal(H.normalizeEtag('"ok"\r\nX-Evil: 1'), "");
    assert.equal(H.normalizeEtag("unquoted"), "");
    assert.equal(H.normalizeEtag(null), "");
    assert.equal(H.normalizeHttpDate(LAST_MODIFIED), LAST_MODIFIED);
    assert.equal(H.normalizeHttpDate(" " + LAST_MODIFIED + " "), LAST_MODIFIED);
    assert.equal(H.normalizeHttpDate("2026-09-23T11:58:07Z"), "");
    assert.equal(H.normalizeHttpDate(LAST_MODIFIED + "\nX-Evil: 1"), "");
    assert.equal(H.parseIncludedResponse(
        "HTTP/2 200 OK\nETag: nope\nLast-Modified: yesterday\n\n[]").etag, "");
});

test("conditional arguments carry each validator exactly and nothing when empty", () => {
    assert.deepEqual(H.conditionalArgs("", ""), []);
    assert.deepEqual(H.conditionalArgs(undefined, undefined), []);
    assert.deepEqual(H.conditionalArgs('W/"abc"', ""), ["-H", 'If-None-Match: W/"abc"']);
    assert.deepEqual(H.conditionalArgs("", LAST_MODIFIED),
        ["-H", "If-Modified-Since: " + LAST_MODIFIED]);
    assert.deepEqual(H.conditionalArgs("bad", "bad"), []);
    assert.deepEqual(Object.keys(H.CONDITIONAL_KINDS).sort(),
        ["events", "notifications", "runs"]);
    assert.equal(H.CONDITIONAL_KINDS.commits, undefined,
        "interactive reads stay unconditional");
});

test("304 is recognised from headers or from gh's own message", () => {
    const headers = H.parseIncludedResponse("HTTP/2 304 Not Modified\nETag: \"a\"\n\n");
    assert.equal(H.notModifiedResponse(headers, 1, ""), true);
    assert.equal(H.notModifiedResponse(null, 1, "gh: HTTP 304"), true);
    assert.equal(H.notModifiedResponse(null, 0, "HTTP 304"), false);
    assert.equal(H.notModifiedResponse(
        H.parseIncludedResponse("HTTP/2 200 OK\n\n[]"), 0, ""), false);
    assert.equal(H.notModifiedResponse(
        H.parseIncludedResponse("HTTP/2 404 Not Found\n\n{}"), 1, "gh: Not Found (HTTP 404)"),
        false);
});

test("a low primary quota pauses until GitHub's reset, bounded both ways", () => {
    const headers = remaining => ({ "x-ratelimit-remaining": String(remaining),
        "x-ratelimit-reset": String(Math.floor(NOW / 1000) + 600) });
    assert.deepEqual(H.rateLimitPause({}, NOW), { known: false, remaining: -1, until: 0 });
    assert.deepEqual(H.rateLimitPause(null, NOW), { known: false, remaining: -1, until: 0 });
    assert.deepEqual(H.rateLimitPause({ "x-ratelimit-remaining": "lots" }, NOW).known, false);
    assert.deepEqual(H.rateLimitPause(headers(H.RATE_LIMIT_FLOOR), NOW),
        { known: true, remaining: H.RATE_LIMIT_FLOOR, until: 0 });
    assert.equal(H.rateLimitPause(headers(H.RATE_LIMIT_FLOOR - 1), NOW).until, NOW + 600000);
    assert.equal(H.rateLimitPause(headers(0), NOW).until, NOW + 600000);
    // A reset already past (clock skew) still waits a minute; a far one is capped.
    assert.equal(H.rateLimitPause({ "x-ratelimit-remaining": "3",
        "x-ratelimit-reset": String(Math.floor(NOW / 1000) - 30) }, NOW).until, NOW + 60000);
    assert.equal(H.rateLimitPause({ "x-ratelimit-remaining": "3",
        "x-ratelimit-reset": String(Math.floor(NOW / 1000) + 86400) }, NOW).until,
        NOW + 3600000);
    assert.equal(H.rateLimitPause({ "x-ratelimit-remaining": "3" }, NOW).until, NOW + 900000);
    assert.equal(H.rateLimitMessage(NOW + 600000, NOW),
        "GitHub API quota is low; Inbox checks resume in 10 minutes");
    assert.equal(H.rateLimitMessage(NOW + 1000, NOW),
        "GitHub API quota is low; Inbox checks resume in 1 minute");
});

test("X-Poll-Interval can lengthen but never shorten the sweep cadence", () => {
    assert.equal(H.nextPollInterval({ pollIntervalMs: 120000 }, 60000, 60000), 120000);
    assert.equal(H.nextPollInterval({ pollIntervalMs: 30000 }, 60000, 60000), 60000);
    assert.equal(H.nextPollInterval({ pollIntervalMs: 0 }, 180000, 60000), 180000,
        "a response without the header keeps the last announced interval");
    assert.equal(H.nextPollInterval(null, undefined, 60000), 60000);
    assert.equal(H.nextPollInterval(null, 5000), 60000);
});

test("poll due times tolerate a coarse sweep timer", () => {
    assert.equal(H.pollDue(0, NOW), true);
    assert.equal(H.pollDue(undefined, NOW), true);
    assert.equal(H.pollDue(NOW - 1, NOW), true);
    // A sweep that starts 3 s early for a 60 s interval must not skip a turn.
    assert.equal(H.pollDue(NOW + 3000, NOW), true);
    assert.equal(H.pollDue(NOW + H.POLL_SLACK_MS + 1, NOW), false);
    assert.equal(H.pollDue(NOW + 60000, NOW), false);
});

test("the gh watchdog is shorter for interactive reads and reports as a timeout", () => {
    assert.equal(H.ghTimeoutMs({ interactive: true }), H.GH_INTERACTIVE_TIMEOUT_MS);
    assert.equal(H.ghTimeoutMs({ interactive: false }), H.GH_TIMEOUT_MS);
    assert.equal(H.ghTimeoutMs(null), H.GH_TIMEOUT_MS);
    assert.ok(H.GH_INTERACTIVE_TIMEOUT_MS < H.GH_TIMEOUT_MS);
    assert.ok(H.GH_KILL_GRACE_MS < H.GH_INTERACTIVE_TIMEOUT_MS);
    assert.equal(H.ghTimeoutMessage({ interactive: false }), "gh api timed out after 60 s");
    assert.equal(H.ghTimeoutMessage({ interactive: true }), "gh api timed out after 30 s");
    assert.notEqual(H.GH_TIMEOUT_EXIT, 0);
    // A stalled Inbox read is treated like a network failure: the sweep pauses
    // with backoff instead of retrying every job.
    assert.equal(H.globalInboxFailure(H.GH_TIMEOUT_EXIT,
        H.ghTimeoutMessage({ interactive: false })), true);
});
