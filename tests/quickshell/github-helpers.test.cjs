const test = require("node:test");
const assert = require("node:assert/strict");
const { load } = require("./shell.cjs");

const H = load("GitHubHelpers.js");

// Everything reaching this file has already been through `gh api --jq`, so the
// parsers are checked against that projection rather than against GitHub's own
// documents. The projections themselves live in the same file, which is what
// keeps the two contracts from drifting.

const NOW = Date.parse("2026-08-09T12:00:00Z");

function iso(msAgo) {
    return new Date(NOW - msAgo).toISOString();
}

const MINUTE = 60000;
const HOUR = 3600000;
const DAY = 86400000;

test("repoSlug accepts every shape a repository reference is pasted in", () => {
    assert.equal(H.repoSlug("DigitalPals/CybexOS"), "DigitalPals/CybexOS");
    assert.equal(H.repoSlug("  hyprwm/Hyprland  "), "hyprwm/Hyprland");
    assert.equal(H.repoSlug("https://github.com/quickshell/quickshell"),
        "quickshell/quickshell");
    assert.equal(H.repoSlug("https://www.github.com/quickshell/quickshell/"),
        "quickshell/quickshell");
    assert.equal(H.repoSlug("github.com/cli/cli"), "cli/cli");
    assert.equal(H.repoSlug("git@github.com:cli/cli.git"), "cli/cli");
    assert.equal(H.repoSlug("https://github.com/cli/cli.git"), "cli/cli");
});

test("repoSlug refuses everything that is not one repository", () => {
    for (const bad of ["", "   ", "CybexOS", "a/b/c", "/leading",
                       "-owner/repo", "owner/", "/repo", "own er/repo",
                       "owner/re po", "owner/.", "owner/..", "owner/a\nb",
                       42, null, undefined, ["a/b"]])
        assert.equal(H.repoSlug(bad), "", `accepted ${JSON.stringify(bad)}`);
});

test("normalizeWatch dedupes case-insensitively, keeps order and caps", () => {
    assert.deepEqual(H.normalizeWatch([
        "hyprwm/Hyprland", "nope", "HYPRWM/hyprland",
        "https://github.com/cli/cli"
    ]), ["hyprwm/Hyprland", "cli/cli"]);
    assert.deepEqual(H.normalizeWatch(null), []);
    assert.deepEqual(H.normalizeWatch("a/b"), []);
    const many = Array.from({ length: 40 }, (_, i) => "o/r" + i);
    assert.equal(H.normalizeWatch(many).length, H.MAX_WATCH);
});

test("parseRepos reads the projection and drops rows that are not repos", () => {
    const rows = H.parseRepos(JSON.stringify([
        { n: "DigitalPals/CybexOS", p: "2026-08-08T17:26:44Z", pr: false,
            ar: false, b: "main" },
        { n: "not-a-repo", p: "2026-08-08T00:00:00Z" },
        { n: "hyprwm/Hyprland", p: null, pr: true, ar: true, b: "" }
    ]));
    assert.equal(rows.length, 2);
    assert.deepEqual(rows[0], {
        slug: "DigitalPals/CybexOS", owner: "DigitalPals", name: "CybexOS",
        pushedAt: "2026-08-08T17:26:44Z", isPrivate: false, archived: false,
        branch: "main", watched: false
    });
    // A repository with no push and no default branch still renders.
    assert.equal(rows[1].pushedAt, "");
    assert.equal(rows[1].branch, "main");
    assert.equal(rows[1].isPrivate, true);
    assert.equal(rows[1].archived, true);
});

test("an unreadable repository response is null, never an empty account", () => {
    // The distinction the Tailscale peer list already draws: a failed read
    // must not render as "you have no repositories".
    assert.equal(H.parseRepos(""), null);
    assert.equal(H.parseRepos("gh: not logged in"), null);
    assert.equal(H.parseRepos("{}"), null);
    assert.deepEqual(H.parseRepos("[]"), []);
    assert.equal(H.parseRepo("[]"), null);
    assert.equal(H.parseRepo('{"n": "x"}'), null);
    assert.equal(H.parseLogin("nonsense"), "");
    assert.equal(H.parseLogin('{"l": "DigitalPals"}'), "DigitalPals");
});

test("mergeRepos folds the watch list into one feed, newest push first", () => {
    const own = H.parseRepos(JSON.stringify([
        { n: "DigitalPals/CybexOS", p: iso(4 * MINUTE), b: "main" },
        { n: "digitalbrain/website", p: iso(3 * HOUR), b: "main" }
    ]));
    const extra = H.parseRepos(JSON.stringify([
        { n: "hyprwm/Hyprland", p: iso(HOUR), b: "main" }
    ]));
    const feed = H.mergeRepos(own, extra, ["hyprwm/Hyprland", "DigitalPals/CybexOS"]);
    assert.deepEqual(feed.map(r => r.slug),
        ["DigitalPals/CybexOS", "hyprwm/Hyprland", "digitalbrain/website"]);
    assert.deepEqual(feed.map(r => r.watched), [true, true, false]);
});

test("a watched repository the account can already see is listed once", () => {
    const own = H.parseRepos('[{"n": "a/b", "p": "2026-08-01T00:00:00Z"}]');
    const extra = H.parseRepos('[{"n": "A/B", "p": "2026-08-02T00:00:00Z"}]');
    const feed = H.mergeRepos(own, extra, ["a/b"]);
    assert.equal(feed.length, 1);
    assert.equal(feed[0].pushedAt, "2026-08-01T00:00:00Z", "your own row wins");
    assert.equal(feed[0].watched, true);
});

test("repositories with no push sort last, then alphabetically", () => {
    const rows = H.sortRepos(H.parseRepos(JSON.stringify([
        { n: "z/never", p: null },
        { n: "a/never", p: null },
        { n: "m/pushed", p: "2020-01-01T00:00:00Z" }
    ])));
    assert.deepEqual(rows.map(r => r.slug), ["m/pushed", "a/never", "z/never"]);
});

test("orgCount counts the owners that are not you", () => {
    const rows = H.parseRepos(JSON.stringify([
        { n: "DigitalPals/one", p: "" }, { n: "DigitalPals/two", p: "" },
        { n: "CybexHQ/three", p: "" }, { n: "digitalpals/four", p: "" }
    ]));
    assert.equal(H.orgCount(rows, "CybexHQ"), 1);
    assert.equal(H.orgCount(rows, "nobody"), 2);
    assert.equal(H.orgCount([], "x"), 0);
});

test("nothing is unread until a watermark exists", () => {
    const rows = H.parseRepos(JSON.stringify([
        { n: "a/new", p: "2026-08-09T10:00:00Z" },
        { n: "a/old", p: "2026-08-01T10:00:00Z" },
        { n: "a/empty", p: null }
    ]));
    // A fresh install would otherwise open with every repository lit.
    assert.deepEqual(H.unreadRepos(rows, ""), []);
    assert.deepEqual(H.unreadRepos(rows, undefined), []);
    assert.deepEqual(H.unreadRepos(rows, "2026-08-05T00:00:00Z").map(r => r.slug),
        ["a/new"]);
});

test("parseCommits splits the subject from the body and drops git trailers", () => {
    const rows = H.parseCommits(JSON.stringify([
        {
            s: "a41c9e2f0000000000000000000000000000abcd",
            m: "popouts: seat a reused slot on its own tab\n\nA latched panel swept"
                + " across the bar while it grew.\n\nCo-Authored-By: Someone <x@y>\n"
                + "Signed-off-by: Someone Else <a@b>\n",
            a: "john",
            d: "2026-08-09T11:36:00Z",
            u: "https://github.com/o/r/commit/a41c9e2"
        },
        { m: "no sha here" }
    ]));
    assert.equal(rows.length, 1);
    assert.equal(rows[0].short, "a41c9e2");
    assert.equal(rows[0].subject, "popouts: seat a reused slot on its own tab");
    assert.equal(rows[0].body, "A latched panel swept across the bar while it grew.");
    assert.equal(rows[0].author, "john");
    assert.equal(H.parseCommits("nonsense"), null);
});

test("a commit with no author falls back rather than rendering nothing", () => {
    const rows = H.parseCommits('[{"s": "abcdef1234", "m": "x", "a": null, "d": null}]');
    assert.equal(rows[0].author, "unknown");
    assert.equal(rows[0].date, "");
    assert.equal(rows[0].url, "");
});

test("subject collapses whitespace and messageBody survives odd messages", () => {
    assert.equal(H.subject("  fix:   two   spaces  "), "fix: two spaces");
    assert.equal(H.subject(""), "");
    assert.equal(H.subject(null), "");
    assert.equal(H.messageBody("subject only"), "");
    assert.equal(H.messageBody("s\n\n\n\n\nbody"), "body");
    assert.equal(H.messageBody("s\n\nSigned-off-by: a <b>"), "",
        "a message that is only trailers has no body");
});

test("messageBody rejoins the 72-column hard wrap git commits carry", () => {
    // Without this, a 376px column re-wraps an already-wrapped paragraph into
    // alternating long and half-empty lines.
    assert.equal(
        H.messageBody("subject\n\nBoth fell through to Theme.hoverFill rather\n"
            + "than \"transparent\", so they carried a permanent\npill."),
        "Both fell through to Theme.hoverFill rather than \"transparent\", "
            + "so they carried a permanent pill.");
    assert.equal(H.messageBody("s\n\none\ntwo\n\nthree\nfour"), "one two\n\nthree four",
        "paragraph breaks survive");
});

test("messageBody keeps the breaks that carry structure", () => {
    assert.equal(H.messageBody("s\n\nWhat changed:\n- one thing\n- another\n- third"),
        "What changed:\n- one thing\n- another\n- third");
    assert.equal(H.messageBody("s\n\nRan:\n    make test\n    make lint"),
        "Ran:\n    make test\n    make lint");
    assert.equal(H.messageBody("s\n\nSteps:\n1. first\n2. second"),
        "Steps:\n1. first\n2. second");
});

test("parseCommitStats defaults missing counts to zero", () => {
    assert.deepEqual(H.parseCommitStats('{"s": "abc", "f": 3, "add": 32, "del": 4}'),
        { sha: "abc", files: 3, additions: 32, deletions: 4 });
    assert.deepEqual(H.parseCommitStats('{"s": "abc", "f": null, "add": null, "del": null}'),
        { sha: "abc", files: 0, additions: 0, deletions: 0 });
    assert.equal(H.parseCommitStats("[]"), null);
    assert.equal(H.parseCommitStats('{"f": 1}'), null);
});

test("newCommits counts only what landed after the watermark", () => {
    const rows = H.parseCommits(JSON.stringify([
        { s: "aaaaaaa1", m: "new", d: "2026-08-09T11:00:00Z" },
        { s: "bbbbbbb2", m: "new", d: "2026-08-09T10:00:00Z" },
        { s: "ccccccc3", m: "old", d: "2026-08-01T10:00:00Z" }
    ]));
    assert.equal(H.newCommits(rows, "2026-08-05T00:00:00Z"), 2);
    assert.equal(H.newCommits(rows, ""), 0);
    assert.equal(H.newCommits([], "2026-08-05T00:00:00Z"), 0);
});

test("relTime stays as short as the age allows", () => {
    assert.equal(H.relTime(iso(10000), NOW), "now");
    assert.equal(H.relTime(iso(4 * MINUTE), NOW), "4m");
    assert.equal(H.relTime(iso(38 * MINUTE), NOW), "38m");
    assert.equal(H.relTime(iso(HOUR), NOW), "1h");
    assert.equal(H.relTime(iso(9 * HOUR), NOW), "9h");
    assert.equal(H.relTime(iso(2 * DAY), NOW), "2d");
    assert.equal(H.relTime(iso(60 * DAY), NOW), "2mo");
    assert.equal(H.relTime(iso(800 * DAY), NOW), "2y");
    assert.equal(H.relTime("", NOW), "");
    assert.equal(H.relTime("not a date", NOW), "");
    assert.equal(H.relTime(iso(-HOUR), NOW), "now", "a clock skewed forward reads as now");
});

test("agoLabel becomes a date once the count stops meaning anything", () => {
    assert.equal(H.agoLabel(NOW - 10000, NOW), "just now");
    assert.equal(H.agoLabel(NOW - 24 * MINUTE, NOW), "24m ago");
    assert.equal(H.agoLabel(NOW - 2 * HOUR, NOW), "2h ago");
    assert.equal(H.agoLabel(NOW - 30 * HOUR, NOW), "yesterday");
    assert.equal(H.agoLabel(NOW - 3 * DAY, NOW), "3d ago");
    assert.equal(H.agoLabel(NOW - 40 * DAY, NOW), "30 Jun");
    assert.equal(H.agoLabel(0, NOW), "", "never checked says nothing");
    assert.equal(H.agoLabelIso("2026-08-09T11:36:00Z", NOW), "24m ago");
    assert.equal(H.agoLabelIso("", NOW), "");
});

test("calendarDaysAgo counts days, not 24-hour spans", () => {
    // Local midnight, so a 23:50 commit and a 00:10 one land on the days a
    // reader would put them on rather than 20 minutes apart in one bucket.
    const lateYesterday = new Date(NOW);
    lateYesterday.setDate(lateYesterday.getDate() - 1);
    lateYesterday.setHours(23, 50, 0, 0);
    const earlyToday = new Date(NOW);
    earlyToday.setHours(0, 10, 0, 0);

    assert.equal(H.calendarDaysAgo(earlyToday.toISOString(), NOW), 0);
    assert.equal(H.calendarDaysAgo(lateYesterday.toISOString(), NOW), 1,
        "ten hours apart, but a different day");
    assert.equal(H.calendarDaysAgo("", NOW), -1);
    assert.equal(H.calendarDaysAgo("not a date", NOW), -1);
    assert.equal(H.calendarDaysAgo(iso(-2 * DAY), NOW), 0,
        "a clock skewed forward never counts negative days");
});

test("recencyBucket tightens towards now and never stops banding", () => {
    const at = days => {
        const d = new Date(NOW);
        d.setDate(d.getDate() - days);
        d.setHours(12, 0, 0, 0);
        return d.toISOString();
    };
    // Each of the last seven days on its own.
    assert.equal(H.recencyBucket(at(0), NOW), "d0");
    assert.equal(H.recencyBucket(at(1), NOW), "d1");
    assert.equal(H.recencyBucket(at(6), NOW), "d6");
    // Then a week at a time for a month.
    assert.equal(H.recencyBucket(at(7), NOW), "w1");
    assert.equal(H.recencyBucket(at(13), NOW), "w1");
    assert.equal(H.recencyBucket(at(14), NOW), "w2");
    assert.equal(H.recencyBucket(at(34), NOW), "w4");
    // Then a month at a time, with no upper bound.
    assert.equal(H.recencyBucket(at(35), NOW), "m1");
    assert.equal(H.recencyBucket(at(400), NOW), "m13");
    assert.equal(H.recencyBucket("", NOW), "");
});

test("recencyBucket keys are distinct as the age grows", () => {
    // A band that repeated an earlier key would rule a second line under a
    // group it had already closed.
    const at = days => {
        const d = new Date(NOW);
        d.setDate(d.getDate() - days);
        d.setHours(12, 0, 0, 0);
        return d.toISOString();
    };
    const seen = new Map();
    let previous = null;
    for (let days = 0; days <= 800; days++) {
        const key = H.recencyBucket(at(days), NOW);
        if (key !== previous) {
            assert.ok(!seen.has(key),
                `bucket ${key} came back at ${days}d, first seen at ${seen.get(key)}d`);
            seen.set(key, days);
            previous = key;
        }
    }
    assert.ok(seen.size > 20, `only ${seen.size} bands across two years`);
});

test("a row's label never contradicts the divider above it", () => {
    // The bug this pins: agoLabel floored elapsed hours while the bands count
    // calendar days, so a commit at Thu 07:56 and one at Wed 23:48 both read
    // "3d ago" with a divider ruled between them — the line said the day had
    // changed and both labels said it had not.
    const at = (days, hour) => {
        const d = new Date(NOW);
        d.setDate(d.getDate() - days);
        d.setHours(hour, 0, 0, 0);
        return d;
    };
    const label = d => H.agoLabel(d.getTime(), NOW);
    const bucket = d => H.recencyBucket(d.toISOString(), NOW);

    // Across a day boundary: different band, and different words for it.
    const lateThatNight = at(4, 23);
    const earlyNextDay = at(3, 0);
    assert.notEqual(bucket(lateThatNight), bucket(earlyNextDay));
    assert.notEqual(label(lateThatNight), label(earlyNextDay),
        "an hour apart, but the divider says they are different days");
    assert.equal(label(earlyNextDay), "3d ago");
    assert.equal(label(lateThatNight), "4d ago");

    // Inside a day band, every row says the same thing, so no reader looks
    // for a divider that is not there.
    for (const days of [1, 2, 3, 4, 5, 6]) {
        const labels = [0, 6, 12, 18, 23].map(hour => label(at(days, hour)));
        assert.equal(new Set(labels).size, 1,
            `day ${days} renders as ${[...new Set(labels)].join(" / ")}`);
        const buckets = [0, 6, 12, 18, 23].map(hour => bucket(at(days, hour)));
        assert.equal(new Set(buckets).size, 1);
    }
    // Today is the exception, and deliberately so: it is one band, but the
    // hours inside it are the useful part.
    assert.equal(H.recencyBucket(at(0, 2).toISOString(), NOW),
        H.recencyBucket(at(0, 13).toISOString(), NOW));
});

test("bucketBreak marks exactly the rows that open a band", () => {
    const at = days => {
        const d = new Date(NOW);
        d.setDate(d.getDate() - days);
        d.setHours(12, 0, 0, 0);
        return d.toISOString();
    };
    assert.equal(H.bucketBreak(at(0), at(0), NOW), false, "same day, no line");
    assert.equal(H.bucketBreak(at(1), at(0), NOW), true, "today → yesterday");
    assert.equal(H.bucketBreak(at(2), at(1), NOW), true, "yesterday → 2 days");
    assert.equal(H.bucketBreak(at(8), at(7), NOW), false, "both inside last week");
    assert.equal(H.bucketBreak(at(7), at(6), NOW), true, "6 days → last week");
    assert.equal(H.bucketBreak("", "", NOW), false,
        "two repositories with no push are one group, not two");
});

test("pushToast says nothing when there is nothing to say", () => {
    assert.deepEqual(H.pushToast("hyprwm/Hyprland", 2, "renderer: clamp blur passes"), {
        summary: "hyprwm/Hyprland — 2 new commits",
        body: "renderer: clamp blur passes"
    });
    assert.equal(H.pushToast("a/b", 1, "x").summary, "a/b — 1 new commit");
    assert.equal(H.pushToast("a/b", 0, "x"), null);
    assert.equal(H.pushToast("", 3, "x"), null);
    // A full page cannot tell 20 from 200, so it must not claim 20.
    assert.equal(H.pushToast("a/b", H.MAX_COMMITS, "x").summary,
        "a/b — " + H.MAX_COMMITS + "+ new commits");
});

test("the queries this file parses are the queries the singleton asks for", () => {
    // Both halves of the contract live here, so a projection cannot be widened
    // in one place and read in another.
    for (const key of ["login", "repos", "repo", "commits", "commit", "runs",
                       "notifications", "events"]) {
        const query = H.GITHUB_QUERIES[key];
        assert.ok(query && query.path.startsWith("/"), `${key} needs an API path`);
        assert.ok(query.jq.length > 0, `${key} needs a projection`);
    }
    assert.match(H.GITHUB_QUERIES.repos.path, /sort=pushed&direction=desc/);
    assert.match(H.GITHUB_QUERIES.commits.path, /per_page=20/);
    // The two paths the singleton substitutes into, and nothing else.
    assert.ok(H.GITHUB_QUERIES.repo.path.includes("{repo}"));
    assert.ok(H.GITHUB_QUERIES.commit.path.includes("{repo}")
        && H.GITHUB_QUERIES.commit.path.includes("{sha}"));
    assert.match(H.GITHUB_QUERIES.runs.path, /\{repo\}\/actions\/runs\?per_page=5/);
    assert.match(H.GITHUB_QUERIES.runs.jq, /workflow_runs/);
    assert.match(H.GITHUB_QUERIES.notifications.path, /^\/notifications\?/);
    assert.match(H.GITHUB_QUERIES.notifications.jq, /\.reason/);
    assert.match(H.GITHUB_QUERIES.events.path, /\{repo\}\/events\?per_page=30/);
    assert.match(H.GITHUB_QUERIES.events.jq, /ReleaseEvent|\.payload\.release|release/);
});

function projectedRun(overrides = {}) {
    return {
        i: "123", n: "Checks", t: "helpers: add Inbox", st: "completed",
        c: "success", b: "main", e: "push", a: "octocat", num: 42, att: 1,
        cr: iso(12 * MINUTE), start: iso(11 * MINUTE), up: iso(2 * MINUTE),
        u: "https://github.com/o/r/actions/runs/123", ...overrides
    };
}

test("workflow projections normalize to stable Inbox entities", () => {
    const rows = H.parseRuns(JSON.stringify([
        projectedRun({ st: "in_progress", c: "" }),
        { n: "missing id" },
        projectedRun({ i: "124", n: "", t: "", u: "", att: 0 })
    ]), "o/r");
    assert.equal(rows.length, 2);
    assert.deepEqual(Object.keys(rows[0]).filter(key => ["id", "kind", "repo", "title",
        "detail", "status", "conclusion", "active", "attention", "tone", "unread",
        "at", "url"].includes(key)).sort(),
    ["active", "at", "attention", "conclusion", "detail", "id", "kind", "repo",
        "status", "title", "tone", "unread", "url"]);
    assert.equal(rows[0].id, "run:o/r:123");
    assert.equal(rows[0].key, "run:o/r:123");
    assert.match(rows[0].revision, /^1:/);
    assert.equal(rows[0].active, true);
    assert.equal(rows[0].branch, "main");
    assert.equal(rows[0].number, 42);
    assert.equal(rows[1].title, "Workflow");
    assert.equal(rows[1].attempt, 1);
    assert.equal(rows[1].url, "https://github.com/o/r/actions/runs/124");
    assert.equal(H.parseRuns("nonsense", "o/r"), null);
    assert.equal(H.parseRuns("[]", "not a slug"), null,
        "an unreadable repository scope is not an empty workflow list");
});

test("every workflow status and conclusion lands in the intended group", () => {
    for (const status of ["queued", "requested", "waiting", "pending", "in_progress"])
        assert.deepEqual(H.runClassification(status, ""), {
            group: "active", active: true, attention: false, tone: "accent", severity: 2
        });
    for (const conclusion of ["failure", "timed_out", "startup_failure"])
        assert.equal(H.runClassification("completed", conclusion).tone, "red", conclusion);
    for (const conclusion of ["action_required", "stale"])
        assert.equal(H.runClassification("completed", conclusion).tone, "amber", conclusion);
    assert.equal(H.runClassification("completed", "success").tone, "green");
    for (const conclusion of ["neutral", "skipped", "cancelled"])
        assert.equal(H.runClassification("completed", conclusion).tone, "muted", conclusion);
    assert.equal(H.runClassification("completed", "future_conclusion").attention, true,
        "future terminal values remain visible");
    assert.equal(H.runStatusLabel("completed", "startup_failure"), "startup failed");
    assert.equal(H.runStatusLabel("in_progress", ""), "in progress");
});

test("Inbox elapsed labels are compact and terminal rows use relative time", () => {
    assert.equal(H.durationLabel(iso(20 * 1000), "", NOW), "<1m");
    assert.equal(H.durationLabel(iso(18 * MINUTE), "", NOW), "18m");
    assert.equal(H.durationLabel(iso(2 * HOUR + 7 * MINUTE), "", NOW), "2h 7m");
    assert.equal(H.durationLabel(iso(2 * DAY + 3 * HOUR), "", NOW), "2d 3h");
    assert.equal(H.durationLabel("bad", "", NOW), "");
    const active = H.parseRuns(JSON.stringify([
        projectedRun({ st: "in_progress", c: "", start: iso(11 * MINUTE) })
    ]), "o/r")[0];
    assert.equal(H.inboxTimeLabel(active, NOW), "11m running");
    const done = H.parseRuns(JSON.stringify([projectedRun({ up: iso(2 * MINUTE) })]),
        "o/r")[0];
    assert.equal(H.inboxTimeLabel(done, NOW), "2m ago");
});

test("recent account repositories and watched repositories form an additive scope", () => {
    const own = H.parseRepos(JSON.stringify([
        { n: "o/one", p: iso(MINUTE) }, { n: "o/two", p: iso(2 * MINUTE) },
        { n: "o/old-watch", p: iso(DAY) }, { n: "o/old", p: iso(2 * DAY) }
    ]));
    const outside = H.parseRepos(JSON.stringify([{ n: "x/external", p: iso(3 * DAY) }]));
    const merged = H.mergeRepos(own, outside, ["o/old-watch", "x/external", "gone/private"]);
    assert.deepEqual(H.displayedRepos(merged, 2).map(row => row.slug),
        ["o/one", "o/two", "o/old-watch", "x/external"]);
    assert.deepEqual(H.monitoredScope(merged, 2,
        ["o/old-watch", "x/external", "gone/private"]),
    ["o/one", "o/two", "o/old-watch", "x/external", "gone/private"],
    "even an unreadable watch remains in the Actions scope");
});

test("notifications keep attention reasons, filter routine noise, and convert links", () => {
    const reasons = ["approval_requested", "assign", "author", "comment", "invitation",
        "mention", "review_requested", "security_alert", "team_mention", "future_reason"];
    const projected = reasons.concat(["ci_activity", "subscribed", "manual", "state_change"])
        .map((reason, index) => ({ i: String(index), r: "o/r", t: `Notice ${index}`,
            ty: "PullRequest", su: `https://api.github.com/repos/o/r/pulls/${index}`,
            rs: reason, un: true, at: iso(index * MINUTE) }));
    const rows = H.parseNotifications(JSON.stringify(projected));
    assert.deepEqual(rows.map(row => row.reason), reasons);
    assert.equal(rows.find(row => row.reason === "security_alert").tone, "red");
    assert.equal(rows.find(row => row.reason === "future_reason").attention, true);
    assert.equal(rows[0].url, "https://github.com/o/r/pull/0");
    assert.equal(H.apiToBrowserUrl("https://api.github.com/repos/o/r/issues/4"),
        "https://github.com/o/r/issues/4");
    assert.equal(H.apiToBrowserUrl("https://api.github.com/repos/o/r/commits/abc"),
        "https://github.com/o/r/commit/abc");
    assert.equal(H.apiToBrowserUrl("https://example.com/nope"), "");
    assert.equal(H.parseNotifications("{}"), null);
});

function projectedEvent(overrides = {}) {
    return {
        i: "900", ty: "PushEvent", at: iso(MINUTE), a: "octocat", ac: "",
        ref: "refs/heads/main", rt: "", size: 2, head: "abcdef1234", num: 0,
        t: "", u: "", merged: false, rid: "0", tag: "", rn: "", ...overrides
    };
}

test("push events aggregate by repository and ref using the newest event", () => {
    const rows = H.parseEvents(JSON.stringify([
        projectedEvent({ i: "9", at: iso(MINUTE), size: 1, head: "oldhead" }),
        projectedEvent({ i: "10", at: iso(MINUTE), size: 4, head: "newhead" }),
        projectedEvent({ i: "topic", ref: "refs/heads/topic", head: "topichead" })
    ]), "O/R");
    assert.equal(rows.length, 2);
    const main = rows.find(row => row.ref === "refs/heads/main");
    assert.equal(main.key, "push:o/r:refs/heads/main");
    assert.equal(main.revision, "10:" + iso(MINUTE));
    assert.equal(main.title, "Pushed to main");
    assert.match(main.detail, /4 commits/);
    assert.equal(main.url, "https://github.com/O/R/commits/newhead");
    assert.equal(main.lifecycle, "unsettled");
    assert.equal(main.canSettle, true);
});

test("branch and tag creation/deletion events have stable ref keys and useful links", () => {
    const rows = H.parseEvents(JSON.stringify([
        projectedEvent({ i: "1", ty: "CreateEvent", ref: "feature/x", rt: "branch" }),
        projectedEvent({ i: "2", ty: "DeleteEvent", ref: "retired", rt: "branch" }),
        projectedEvent({ i: "3", ty: "CreateEvent", ref: "v2.0", rt: "tag" }),
        projectedEvent({ i: "4", ty: "DeleteEvent", ref: "v1.0", rt: "tag" })
    ]), "o/r");
    assert.deepEqual(rows.map(row => row.key), [
        "ref:o/r:branch:feature/x", "ref:o/r:branch:retired",
        "ref:o/r:tag:v2.0", "ref:o/r:tag:v1.0"
    ]);
    assert.equal(rows[0].status, "created");
    assert.equal(rows[0].url, "https://github.com/o/r/tree/feature%2Fx");
    assert.equal(rows[1].status, "deleted");
    assert.equal(rows[1].url, "https://github.com/o/r/branches");
    assert.equal(rows[3].url, "https://github.com/o/r/tags");
});

test("issue and pull-request projections include only requested lifecycle actions", () => {
    const issues = ["opened", "closed", "reopened"].map((action, index) =>
        projectedEvent({ i: `i${index}`, ty: "IssuesEvent", ac: action,
            num: index + 1, t: `Issue ${index + 1}` }));
    const pulls = [
        projectedEvent({ i: "p1", ty: "PullRequestEvent", ac: "opened", num: 11,
            t: "Open PR", u: "https://github.com/o/r/pull/11" }),
        projectedEvent({ i: "p2", ty: "PullRequestEvent", ac: "closed", num: 12,
            t: "Closed PR" }),
        projectedEvent({ i: "p3", ty: "PullRequestEvent", ac: "closed", merged: true,
            num: 13, t: "Merged PR" }),
        projectedEvent({ i: "p4", ty: "PullRequestEvent", ac: "reopened", num: 14,
            t: "Reopened PR" })
    ];
    const rows = H.parseEvents(JSON.stringify(issues.concat(pulls, [
        projectedEvent({ i: "assigned", ty: "IssuesEvent", ac: "assigned", num: 20 }),
        projectedEvent({ i: "review", ty: "PullRequestEvent", ac: "review_requested",
            num: 21 })
    ])), "o/r");
    assert.deepEqual(rows.filter(row => row.kind === "issue").map(row => row.status),
        ["opened", "closed", "reopened"]);
    assert.deepEqual(rows.filter(row => row.kind === "pull_request").map(row => row.status),
        ["opened", "closed", "merged", "reopened"]);
    assert.equal(rows.find(row => row.status === "merged").key, "pr:o/r:13");
    assert.equal(rows.find(row => row.key === "issue:o/r:1").url,
        "https://github.com/o/r/issues/1");
    assert.equal(rows.find(row => row.key === "pr:o/r:11").url,
        "https://github.com/o/r/pull/11");
});

test("published releases and new discussions project while other actions do not", () => {
    const rows = H.parseEvents(JSON.stringify([
        projectedEvent({ i: "r1", ty: "ReleaseEvent", ac: "published", rid: "77",
            tag: "v2.1", rn: "Summer", u: "https://github.com/o/r/releases/tag/v2.1" }),
        projectedEvent({ i: "r2", ty: "ReleaseEvent", ac: "created", rid: "78" }),
        projectedEvent({ i: "d1", ty: "DiscussionEvent", ac: "created", num: 9,
            t: "Design", u: "https://github.com/o/r/discussions/9" }),
        projectedEvent({ i: "d2", ty: "DiscussionEvent", ac: "edited", num: 10 })
    ]), "o/r");
    assert.deepEqual(rows.map(row => row.key), ["release:o/r:77", "discussion:o/r:9"]);
    assert.equal(rows[0].title, "Summer");
    assert.match(rows[0].detail, /v2\.1 published/);
    assert.equal(rows[1].url, "https://github.com/o/r/discussions/9");
});

test("comments, reviews, labels, stars, forks, wiki, members, and malformed events drop", () => {
    const excluded = [
        projectedEvent({ i: "1", ty: "IssueCommentEvent" }),
        projectedEvent({ i: "2", ty: "PullRequestReviewEvent" }),
        projectedEvent({ i: "3", ty: "IssuesEvent", ac: "labeled", num: 1 }),
        projectedEvent({ i: "4", ty: "WatchEvent" }),
        projectedEvent({ i: "5", ty: "ForkEvent" }),
        projectedEvent({ i: "6", ty: "GollumEvent" }),
        projectedEvent({ i: "7", ty: "MemberEvent" }),
        projectedEvent({ i: "", ty: "PushEvent" }),
        projectedEvent({ i: "8", ty: "PushEvent", ref: "" }),
        projectedEvent({ i: "9", ty: "IssuesEvent", ac: "opened", num: 0 }),
        projectedEvent({ i: "10", ty: "PushEvent", at: "not-a-date" }),
        null
    ];
    assert.deepEqual(H.parseEvents(JSON.stringify(excluded), "o/r"), []);
    assert.equal(H.parseEvents("{}", "o/r"), null);
    assert.equal(H.parseEvents("[]", "not-a-repo"), null);
});

test("included HTTP responses preserve weak ETags and GitHub poll intervals", () => {
    const response = H.parseIncludedResponse(
        "HTTP/2.0 200 OK\r\nETag: W/\"opaque-value\"\r\n"
        + "X-Poll-Interval: 90\r\nContent-Type: application/json\r\n\r\n[{\"i\":\"1\"}]\n");
    assert.equal(response.status, 200);
    assert.equal(response.etag, 'W/"opaque-value"');
    assert.equal(response.pollIntervalMs, 90000);
    assert.equal(response.body, '[{"i":"1"}]');
    assert.equal(H.includedResponseOk(response, 0), true);
    assert.deepEqual(H.normalizeEventEtags({ "O/R": response.etag, bad: "nope",
        "x/y": "contains\nnewline" }), { "o/r": 'W/"opaque-value"' });
    assert.deepEqual(H.normalizeEventPollIntervals({ "O/R": 90000, bad: -1 }),
        { "o/r": 90000 });
});

test("304 headers are success even when gh exits nonzero with an empty jq body", () => {
    const response = H.parseIncludedResponse(
        "HTTP/2 304 Not Modified\nETag: \"strong\"\nX-Poll-Interval: 60\n\n");
    assert.equal(response.notModified, true);
    assert.equal(response.body, "");
    assert.equal(H.includedResponseOk(response, 1), true);
    assert.equal(H.includedResponseOk(H.parseIncludedResponse(
        "HTTP/2 403 Forbidden\n\n{}"), 1), false);
    assert.equal(H.parseIncludedResponse("[]"), null);
    assert.equal(H.parseIncludedResponse("HTTP/2 200 OK\nnot a header\n\n[]"), null);
});

test("the final HTTP block wins when an included response traverses a proxy", () => {
    const response = H.parseIncludedResponse(
        "HTTP/1.1 200 Connection established\nProxy-Agent: example\n\n"
        + "HTTP/2 304 Not Modified\nETag: W/\"next\"\nX-Poll-Interval: 120\n\n");
    assert.equal(response.status, 304);
    assert.equal(response.etag, 'W/"next"');
    assert.equal(response.pollIntervalMs, 120000);
});

function reconcile(state, source, rows, at) {
    return H.reconcileInboxSource(state.items, state.sourceRevisions, source, rows, at);
}

test("each notifications/events/workflows source establishes its own settled baseline", () => {
    const notification = H.parseNotifications(JSON.stringify([{ i: "n1", r: "o/r",
        t: "Review", ty: "PullRequest", su: "", rs: "review_requested", un: true,
        at: iso(4 * MINUTE) }]));
    const event = H.parseEvents(JSON.stringify([projectedEvent()]), "o/r");
    const runs = H.parseRuns(JSON.stringify([
        projectedRun({ i: "active", st: "in_progress", c: "" }),
        projectedRun({ i: "failed", c: "failure" })
    ]), "o/r");
    let state = { items: {}, sourceRevisions: {} };
    state = reconcile(state, "notifications", notification, iso(3 * MINUTE));
    state = reconcile(state, "events:o/r", event, iso(2 * MINUTE));
    state = reconcile(state, "workflows:o/r", runs, iso(MINUTE));
    const rows = H.inboxRows(state.items, iso(10 * MINUTE));
    assert.deepEqual(Object.keys(state.sourceRevisions).sort(),
        ["events:o/r", "notifications", "workflows:o/r"]);
    assert.equal(rows.find(row => row.kind === "notification").lifecycle, "settled");
    assert.equal(rows.find(row => row.kind === "push").lifecycle, "settled");
    assert.equal(rows.find(row => row.key === "run:o/r:failed").lifecycle, "settled");
    assert.equal(rows.find(row => row.key === "run:o/r:active").lifecycle, "active");
    assert.equal(H.inboxCounts(rows).pending, 0);
    assert.equal(H.inboxCounts(rows).running, 1);
});

test("new entities persist across restart and settlement is entirely local", () => {
    let state = reconcile({ items: {}, sourceRevisions: {} }, "notifications", [],
        iso(10 * MINUTE));
    const notice = H.parseNotifications(JSON.stringify([{ i: "thread", r: "o/r",
        t: "Please review", ty: "PullRequest", su: "", rs: "review_requested", un: true,
        at: iso(2 * MINUTE) }]));
    state = reconcile(state, "notifications", notice, iso(MINUTE));
    let rows = H.inboxRows(state.items, iso(3 * MINUTE));
    assert.equal(rows[0].key, "notification:thread");
    assert.equal(rows[0].lifecycle, "unsettled");
    assert.equal(rows[0].unread, true);

    state.items = H.setInboxSettlement(state.items, rows[0].key, true, iso(30000));
    rows = H.inboxRows(state.items, iso(3 * MINUTE));
    assert.equal(rows[0].lifecycle, "settled");
    assert.equal(rows[0].settledAt, iso(30000));
    assert.equal(rows[0].githubUnread, true,
        "local settlement never changes the GitHub thread's unread bit");

    const restarted = {
        items: H.normalizeInboxItems(JSON.parse(JSON.stringify(state.items))),
        sourceRevisions: H.normalizeSourceRevisions(
            JSON.parse(JSON.stringify(state.sourceRevisions)))
    };
    state = reconcile(restarted, "notifications", notice, iso(10000));
    assert.equal(H.inboxRows(state.items, "")[0].lifecycle, "settled",
        "the same source revision remains settled after restart");
    state.items = H.setInboxSettlement(state.items, rows[0].key, false, iso(5000));
    assert.equal(H.inboxRows(state.items, "")[0].lifecycle, "unsettled");
});

test("bulk settlement clears actionable items but preserves live workflows", () => {
    const issue = H.parseEvents(JSON.stringify([projectedEvent({ i: "bulk-issue",
        ty: "IssuesEvent", ac: "opened", num: 91, t: "Review me",
        at: iso(3 * MINUTE) })]), "o/r")[0];
    issue.lifecycle = "unsettled";
    issue.noticedAt = iso(2 * MINUTE);
    const notice = H.parseNotifications(JSON.stringify([{ i: "bulk-notice", r: "o/r",
        t: "Mention", ty: "Issue", su: "", rs: "mention", un: true,
        at: iso(2 * MINUTE) }]))[0];
    notice.lifecycle = "unsettled";
    notice.noticedAt = iso(MINUTE);
    const active = H.parseRuns(JSON.stringify([projectedRun({ i: "bulk-running",
        st: "in_progress", c: "", up: iso(MINUTE) })]), "o/r")[0];
    const items = H.settleAllInboxItems({
        [issue.key]: issue,
        [notice.key]: notice,
        [active.key]: active
    }, iso(30000));
    const rows = H.inboxRows(items, "");
    assert.equal(rows.find(row => row.key === issue.key).lifecycle, "settled");
    assert.equal(rows.find(row => row.key === notice.key).lifecycle, "settled");
    assert.equal(rows.find(row => row.key === active.key).lifecycle, "active");
    assert.equal(H.inboxCounts(rows).pending, 0);
    assert.equal(H.inboxCounts(rows).running, 1);
});

test("persisted Inbox snapshots whitelist rendered fields and GitHub links", () => {
    const raw = H.parseEvents(JSON.stringify([projectedEvent({ i: "safe", ty: "IssuesEvent",
        ac: "opened", num: 8, t: "Line one\nline two" })]), "o/r")[0];
    raw.url = "https://example.com/collect";
    raw.unrenderedPayload = { token: "must not persist" };
    raw.lifecycle = "settled";
    raw.noticedAt = iso(2 * MINUTE);
    raw.settledAt = iso(MINUTE);
    const state = H.normalizeInboxItems({ [raw.key]: raw });
    assert.equal(state[raw.key].title, "Line one line two");
    assert.equal(state[raw.key].url, "https://github.com/o/r");
    assert.equal(Object.hasOwn(state[raw.key], "unrenderedPayload"), false);
    for (const field of ["key", "revision", "lifecycle", "noticedAt", "settledAt",
        "canSettle"])
        assert.ok(Object.hasOwn(state[raw.key], field), field);
    const compact = H.compactInboxItems(state);
    assert.equal(Object.hasOwn(compact[raw.key], "id"), false);
    assert.equal(Object.hasOwn(compact[raw.key], "unread"), false);
    assert.equal(Object.hasOwn(compact[raw.key], "canSettle"), false,
        "derived display fields do not bloat the state file");
    assert.equal(H.normalizeInboxItems(compact)[raw.key].canSettle, true);
});

test("a newer revision replaces the safe snapshot and wakes a settled entity", () => {
    const opened = H.parseEvents(JSON.stringify([projectedEvent({ i: "open", ty: "IssuesEvent",
        ac: "opened", num: 42, t: "Old title", at: iso(5 * MINUTE) })]), "o/r");
    let state = reconcile({ items: {}, sourceRevisions: {} }, "events:o/r", opened,
        iso(4 * MINUTE));
    const key = "issue:o/r:42";
    assert.equal(state.items[key].lifecycle, "settled", "first response is baseline");
    const closed = H.parseEvents(JSON.stringify([projectedEvent({ i: "close",
        ty: "IssuesEvent", ac: "closed", num: 42, t: "Fixed title",
        at: iso(2 * MINUTE) })]), "o/r");
    state = reconcile(state, "events:o/r", closed, iso(MINUTE));
    assert.equal(state.items[key].lifecycle, "unsettled");
    assert.equal(state.items[key].title, "Fixed title");
    assert.equal(state.items[key].status, "closed");
    assert.equal(state.items[key].settledAt, "");
    const stale = reconcile(state, "events:o/r", opened, iso(1000));
    assert.equal(stale.items[key].revision, state.items[key].revision,
        "a lagging event page cannot regress or re-wake the snapshot");
});

test("repeated pushes to one ref share an entity and wake it on each revision", () => {
    const first = H.parseEvents(JSON.stringify([projectedEvent({ i: "p1", size: 1,
        at: iso(5 * MINUTE) })]), "o/r");
    let state = reconcile({ items: {}, sourceRevisions: {} }, "events:o/r", first,
        iso(4 * MINUTE));
    const key = "push:o/r:refs/heads/main";
    const second = H.parseEvents(JSON.stringify([projectedEvent({ i: "p2", size: 2,
        at: iso(2 * MINUTE) })]), "o/r");
    state = reconcile(state, "events:o/r", second, iso(MINUTE));
    assert.equal(Object.keys(state.items).length, 1);
    assert.equal(state.items[key].lifecycle, "unsettled");
    state.items = H.setInboxSettlement(state.items, key, true, iso(30000));
    const third = H.parseEvents(JSON.stringify([projectedEvent({ i: "p3", size: 3,
        at: iso(20000) })]), "o/r");
    state = reconcile(state, "events:o/r", third, iso(10000));
    assert.equal(Object.keys(state.items).length, 1);
    assert.equal(state.items[key].lifecycle, "unsettled");
    assert.match(state.items[key].detail, /3 commits/);
});

test("a workflow lifecycle revision wakes even when GitHub reuses its timestamp", () => {
    const stamp = iso(2 * MINUTE);
    const active = H.parseRuns(JSON.stringify([projectedRun({ i: "same-time",
        st: "in_progress", c: "", up: stamp })]), "o/r");
    let state = reconcile({ items: {}, sourceRevisions: {} }, "workflows:o/r", active,
        iso(MINUTE));
    assert.equal(state.items["run:o/r:same-time"].lifecycle, "active");
    const complete = H.parseRuns(JSON.stringify([projectedRun({ i: "same-time",
        st: "completed", c: "success", up: stamp })]), "o/r");
    state = reconcile(state, "workflows:o/r", complete, iso(30000));
    assert.equal(state.items["run:o/r:same-time"].lifecycle, "unsettled");
    assert.equal(state.items["run:o/r:same-time"].conclusion, "success");
});

test("unsettled rows survive source-page eviction and only settled history is pruned", () => {
    let state = reconcile({ items: {}, sourceRevisions: {} }, "events:o/r", [],
        iso(20 * MINUTE));
    const events = Array.from({ length: 35 }, (_, index) => projectedEvent({
        i: String(index + 1), ty: "IssuesEvent", ac: "opened", num: index + 1,
        t: `Issue ${index + 1}`, at: new Date(NOW - (35 - index) * 1000).toISOString()
    }));
    state = reconcile(state, "events:o/r", H.parseEvents(JSON.stringify(events), "o/r"),
        iso(10 * MINUTE));
    assert.equal(H.inboxCounts(H.inboxRows(state.items, "")).pending, 35,
        "the pending Inbox is not capped at the API page or history limit");
    state = reconcile(state, "events:o/r", [], iso(9 * MINUTE));
    assert.equal(H.inboxCounts(H.inboxRows(state.items, "")).pending, 35,
        "a later empty page keeps every unsettled entity");

    Object.keys(state.items).sort().forEach((key, index) => {
        state.items = H.setInboxSettlement(state.items, key, true,
            new Date(NOW + index * 1000).toISOString());
    });
    const rows = H.inboxRows(state.items, "");
    assert.equal(rows.length, H.MAX_SETTLED_INBOX_ITEMS);
    assert.equal(H.inboxCounts(rows).settled, H.MAX_SETTLED_INBOX_ITEMS);
    state = reconcile(state, "events:o/r", H.parseEvents(JSON.stringify(events), "o/r"),
        iso(MINUTE));
    assert.equal(H.inboxCounts(H.inboxRows(state.items, "")).pending, 0,
        "unchanged pruned snapshots do not reappear");
});

test("badge lifecycle is independent from view emphasis and active workflows", () => {
    let state = { items: {}, sourceRevisions: {} };
    for (const source of ["notifications", "workflows:o/r"])
        state = reconcile(state, source, [], iso(20 * MINUTE));
    const notification = H.parseNotifications(JSON.stringify([{ i: "n", r: "o/r",
        t: "Review", ty: "PullRequest", su: "", rs: "review_requested", un: true,
        at: iso(4 * MINUTE) }]));
    const runs = H.parseRuns(JSON.stringify([
        projectedRun({ i: "bad", c: "failure", up: iso(3 * MINUTE) }),
        projectedRun({ i: "ok", c: "success", up: iso(2 * MINUTE) }),
        projectedRun({ i: "live", st: "in_progress", c: "", up: iso(MINUTE) })
    ]), "o/r");
    state = reconcile(state, "notifications", notification, iso(3 * MINUTE));
    state = reconcile(state, "workflows:o/r", runs, iso(MINUTE));
    let rows = H.inboxRows(state.items, iso(10 * MINUTE));
    assert.deepEqual(H.inboxCounts(rows), {
        running: 1, attention: 2, updates: 1, pending: 3, settled: 0, unread: 3
    });
    assert.equal(H.inboxBadgeTone(rows), "red");
    assert.deepEqual(H.inboxSections(rows).map(group => group.title),
        ["Active", "Attention", "Updates", "Settled"]);

    rows = H.inboxRows(state.items, iso(1000));
    assert.equal(H.inboxCounts(rows).unread, 0, "closing the popover clears emphasis");
    assert.equal(H.inboxCounts(rows).pending, 3, "viewing never settles an entity");
    assert.equal(H.inboxBadgeTone(rows), "red");
    state.items = H.setInboxSettlement(state.items, "run:o/r:bad", true, iso(500));
    assert.equal(H.inboxBadgeTone(H.inboxRows(state.items, iso(1000))), "amber");
    state.items = H.setInboxSettlement(state.items, "notification:n", true, iso(400));
    assert.equal(H.inboxBadgeTone(H.inboxRows(state.items, iso(1000))), "accent");
    state.items = H.setInboxSettlement(state.items, "run:o/r:ok", true, iso(300));
    assert.equal(H.inboxBadgeTone(H.inboxRows(state.items, iso(1000))), "none");
});

test("disabling a workflow scope drops live rows and re-baselines without losing history", () => {
    const active = H.parseRuns(JSON.stringify([
        projectedRun({ i: "live", st: "in_progress", c: "" }),
        projectedRun({ i: "old", st: "completed", c: "failure" })
    ]), "o/r");
    let state = reconcile({ items: {}, sourceRevisions: {} }, "workflows:o/r", active,
        iso(3 * MINUTE));
    state.items = H.setInboxSettlement(state.items, "run:o/r:old", false, iso(MINUTE));
    state.sourceRevisions.notifications = {};
    const reset = H.removeInboxSources(state.items, state.sourceRevisions, "workflows:");
    assert.equal(reset.items["run:o/r:live"], undefined);
    assert.equal(reset.items["run:o/r:old"].lifecycle, "unsettled");
    assert.equal(H.inboxCounts(H.inboxRows(reset.items, "")).pending, 1,
        "a scope change cannot silently clear the persistent badge");
    assert.equal(reset.sourceRevisions["workflows:o/r"], undefined);
    assert.deepEqual(reset.sourceRevisions.notifications, {});
    const whileDisabled = H.parseRuns(JSON.stringify([
        projectedRun({ i: "old", st: "completed", c: "failure" }),
        projectedRun({ i: "during", st: "completed", c: "success" })
    ]), "o/r");
    const rebased = reconcile(reset, "workflows:o/r", whileDisabled, iso(30000));
    assert.equal(rebased.items["run:o/r:old"].lifecycle, "unsettled",
        "re-enabling is not an implicit settlement action");
    assert.equal(rebased.items["run:o/r:during"].lifecycle, "settled",
        "completions first discovered while disabled form the quiet baseline");
});

test("partial repository-source errors retain cached workflow and event rows", () => {
    const good = H.parseRuns(JSON.stringify([projectedRun()]), "o/r");
    let cache = H.patchRunCache({}, "o/r", good, "", NOW);
    cache = H.patchRunCache(cache, "o/r", null, "HTTP 403", NOW + MINUTE);
    assert.equal(cache["o/r"].rows.length, 1);
    assert.equal(cache["o/r"].error, "HTTP 403");
    cache = H.patchRunCache(cache, "x/y", [], "", NOW);
    assert.deepEqual(H.flattenRunCache(cache).map(row => row.id), [good[0].id]);
    const event = H.parseEvents(JSON.stringify([projectedEvent()]), "o/r");
    let eventCache = H.patchSourceCache({}, "o/r", event, "", NOW);
    eventCache = H.patchSourceCache(eventCache, "o/r", null, "HTTP 403", NOW + MINUTE);
    assert.equal(eventCache["o/r"].rows[0].key, "push:o/r:refs/heads/main");
    assert.equal(eventCache["o/r"].error, "HTTP 403");
});

test("run-attempt baselines are silent initially and dedupe transitions across restart", () => {
    const running = H.parseRuns(JSON.stringify([
        projectedRun({ st: "in_progress", c: "" })
    ]), "o/r")[0];
    const failed = H.parseRuns(JSON.stringify([
        projectedRun({ st: "completed", c: "failure", up: iso(MINUTE) })
    ]), "o/r")[0];

    const initial = H.advanceRunBaselines({}, [failed], false);
    assert.deepEqual(initial.transitions, [], "a repository's first discovery is silent");
    const activeBaseline = H.advanceRunBaselines({}, [running], true);
    const transition = H.advanceRunBaselines(activeBaseline.baselines, [failed], false);
    assert.equal(transition.transitions.length, 1);
    const restarted = H.advanceRunBaselines(
        JSON.parse(JSON.stringify(transition.baselines)), [failed], false);
    assert.equal(restarted.transitions.length, 0, "the same failed attempt stays silent");

    const rerun = { ...failed, id: "run:o/r:123:2", attempt: 2 };
    const rerunTransition = H.advanceRunBaselines(restarted.baselines, [rerun], false);
    assert.equal(rerunTransition.transitions.length, 1);
    assert.ok(Object.keys(rerunTransition.baselines["o/r"]).length
        <= H.MAX_BASELINE_ATTEMPTS);
});

test("workflow failure toasts coalesce and global retry backoff is bounded", () => {
    const failures = [
        H.parseRuns(JSON.stringify([projectedRun({ c: "failure" })]), "o/one")[0],
        H.parseRuns(JSON.stringify([projectedRun({ i: "2", c: "action_required" })]),
            "o/two")[0]
    ];
    const toast = H.coalescedFailureToast(failures);
    assert.equal(toast.summary, "2 workflows need attention");
    assert.match(toast.body, /o\/one/);
    assert.equal(H.coalescedFailureToast([]), null);
    assert.equal(H.globalInboxFailure(1, "HTTP 403: Resource not accessible"), false,
        "a repository permission error is partial");
    assert.equal(H.globalInboxFailure(1, "API rate limit exceeded"), true);
    assert.equal(H.globalInboxFailure(1, "could not resolve host"), true);
    assert.equal(H.inboxBackoffMs(1), MINUTE);
    assert.equal(H.inboxBackoffMs(99), 15 * MINUTE);
});
