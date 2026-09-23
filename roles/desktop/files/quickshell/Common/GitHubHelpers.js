// Pure helpers for the GitHub bar module: the watch-list grammar, the shapes
// `gh api` is asked to project, and the two time labels the popover renders.
// Keep this file free of Qt APIs so the same logic stays testable under Node.
//
// Every read goes through `gh api --jq`, so what arrives here is already a
// projection with one-letter keys rather than GitHub's own document. That is
// deliberate: the unprojected /user/repos page is ~1.5 MB of JSON for the same
// six fields, and re-parsing it every poll is the whole cost of the module.
// The projections live in GITHUB_QUERIES below so the contract this file
// parses and the contract the singleton requests cannot drift apart.

// A watch list long enough to be useful and short enough that one poll cannot
// turn into a burst of API calls — each entry costs its own `gh api` run.
var MAX_WATCH = 20;
// Commits fetched per repo. The popover shows the newest handful; the rest is
// headroom for counting what is new since you last looked.
var MAX_COMMITS = 20;
// Workflow discovery is deliberately shallow per repository. The breadth comes from
// monitoring the configured recent repositories plus every explicit watch;
// a deep history here would only crowd the popover and burn API quota.
var MAX_RUNS = 5;
var MAX_ACTIVITY_ROWS = 30;
// Settled Inbox snapshots are only a local convenience. Unsettled entities
// are never capped; this bound applies exclusively to the history drawer.
var MAX_SETTLED_INBOX_ITEMS = 30;
var MAX_INBOX_SOURCES = 100;
var MAX_SOURCE_REVISIONS = 400;
var MAX_ACTIVE_REPOS = 5;
var MAX_BASELINE_ATTEMPTS = 10;
var MAX_BASELINE_REPOS = 40;

// Option bounds, shared by the settings validators and the settings rows so a
// slider and its stored value can never disagree about what is in range.
var REPOS_MIN = 3;
var REPOS_MAX = 15;
var POLL_MIN = 1;
var POLL_MAX = 30;

var BADGE_MODES = ["dot", "count", "off"];

// The `gh api` path and --jq projection for each read. `{repo}` and `{sha}`
// are substituted by the caller; nothing else in a path is interpolated.
var GITHUB_QUERIES = {
    login: {
        path: "/user",
        jq: "{l: .login}"
    },
    repos: {
        path: "/user/repos?sort=pushed&direction=desc&per_page=100"
            + "&affiliation=owner,collaborator,organization_member",
        jq: "[.[] | {n: .full_name, p: .pushed_at, pr: .private,"
            + " ar: .archived, b: .default_branch}]"
    },
    repo: {
        path: "/repos/{repo}",
        jq: "{n: .full_name, p: .pushed_at, pr: .private,"
            + " ar: .archived, b: .default_branch}"
    },
    commits: {
        path: "/repos/{repo}/commits?per_page=" + MAX_COMMITS,
        jq: "[.[] | {s: .sha, m: .commit.message,"
            + " a: (.author.login // .commit.author.name),"
            + " d: (.commit.author.date // .commit.committer.date), u: .html_url}]"
    },
    // Only the counts: the commit's own URL already came back with the list.
    commit: {
        path: "/repos/{repo}/commits/{sha}",
        jq: "{s: .sha, f: (.files | length), add: .stats.additions,"
            + " del: .stats.deletions}"
    },
    runs: {
        path: "/repos/{repo}/actions/runs?per_page=" + MAX_RUNS,
        jq: "[.workflow_runs[] | {i: (.id | tostring), n: (.name // \"Workflow\"),"
            + " t: (.display_title // \"\"), st: (.status // \"\"),"
            + " c: (.conclusion // \"\"), b: (.head_branch // \"\"),"
            + " e: (.event // \"\"), a: (.actor.login // .triggering_actor.login // \"\"),"
            + " num: (.run_number // 0), att: (.run_attempt // 1),"
            + " cr: (.created_at // \"\"), up: (.updated_at // \"\"),"
            + " start: (.run_started_at // .created_at // \"\"), u: (.html_url // \"\")}]"
    },
    notifications: {
        // Omitting `all=true` is important: this is an attention feed, not a
        // second archive of github.com/notifications.
        path: "/notifications?all=false&participating=false&per_page=50",
        jq: "[.[] | {i: (.id | tostring), r: .repository.full_name,"
            + " t: (.subject.title // \"GitHub notification\"),"
            + " ty: (.subject.type // \"\"), su: (.subject.url // \"\"),"
            + " rs: (.reason // \"\"), un: (.unread // false),"
            + " at: (.updated_at // \"\")}]"
    },
    events: {
        path: "/repos/{repo}/events?per_page=30",
        // Like runs and notifications, a conditional request: `--include` is
        // added by the singleton so the ETag and poll interval remain
        // available next to this deliberately small projection.
        jq: "[.[] | {i: (.id | tostring), ty: (.type // \"\"),"
            + " at: (.created_at // \"\"), a: (.actor.login // \"\"),"
            + " ac: (.payload.action // \"\"), ref: (.payload.ref // \"\"),"
            + " rt: (.payload.ref_type // \"\"), size: (.payload.size // 0),"
            + " head: (.payload.head // \"\"),"
            + " num: (.payload.issue.number // .payload.pull_request.number"
            + " // .payload.discussion.number // 0),"
            + " t: (.payload.issue.title // .payload.pull_request.title"
            + " // .payload.discussion.title // \"\"),"
            + " u: (.payload.issue.html_url // .payload.pull_request.html_url"
            + " // .payload.discussion.html_url // .payload.release.html_url // \"\"),"
            + " merged: (.payload.pull_request.merged // false),"
            + " rid: ((.payload.release.id // 0) | tostring),"
            + " tag: (.payload.release.tag_name // \"\"),"
            + " rn: (.payload.release.name // \"\")}]"
    }
};

// A repository reference the shell will accept from the settings field. The
// whole point is that pasting a browser URL works, because that is what is on
// the clipboard when someone decides to watch a repo.
var OWNER_RE = /^[A-Za-z0-9][A-Za-z0-9-]*$/;
var NAME_RE = /^[A-Za-z0-9._-]+$/;

function repoSlug(value) {
    if (typeof value !== "string")
        return "";
    var text = value.trim();
    if (text === "")
        return "";
    text = text.replace(/^[a-z]+:\/\//i, "")
        .replace(/^git@github\.com:/i, "")
        .replace(/^(www\.)?github\.com\//i, "")
        .replace(/\.git$/i, "")
        .replace(/^\/+/, "")
        .replace(/\/+$/, "");
    var parts = text.split("/");
    if (parts.length !== 2)
        return "";
    if (!OWNER_RE.test(parts[0]) || !NAME_RE.test(parts[1]))
        return "";
    // "." and ".." are legal against NAME_RE and are not repositories.
    if (parts[1] === "." || parts[1] === "..")
        return "";
    return parts[0] + "/" + parts[1];
}

// Known-good slugs only, first spelling of a duplicate wins, capped. Case is
// preserved for display but compared case-insensitively, because GitHub
// resolves owner/name that way and a list holding both spellings would poll
// the same repository twice.
function normalizeWatch(list) {
    var out = [];
    var seen = {};
    if (!Array.isArray(list))
        return out;
    for (var i = 0; i < list.length && out.length < MAX_WATCH; i++) {
        var slug = repoSlug(list[i]);
        if (slug === "")
            continue;
        var key = slug.toLowerCase();
        if (seen[key])
            continue;
        seen[key] = true;
        out.push(slug);
    }
    return out;
}

function parseJson(text) {
    if (typeof text !== "string" || text.trim() === "")
        return undefined;
    try {
        return JSON.parse(text);
    } catch (e) {
        return undefined;
    }
}

// One projected repository. Null for anything that is not that shape, so an
// unreadable response can never pass for a repository with no pushes.
function repoRow(raw) {
    if (!raw || typeof raw !== "object" || Array.isArray(raw))
        return null;
    var slug = repoSlug(raw.n);
    if (slug === "")
        return null;
    var parts = slug.split("/");
    return {
        slug: slug,
        owner: parts[0],
        name: parts[1],
        // An empty repository has never been pushed to; "" sorts it last
        // rather than throwing off every comparison against a real stamp.
        pushedAt: typeof raw.p === "string" ? raw.p : "",
        isPrivate: !!raw.pr,
        archived: !!raw.ar,
        branch: typeof raw.b === "string" && raw.b !== "" ? raw.b : "main",
        watched: false
    };
}

function parseRepos(text) {
    var body = parseJson(text);
    if (!Array.isArray(body))
        return null;
    var out = [];
    for (var i = 0; i < body.length; i++) {
        var row = repoRow(body[i]);
        if (row !== null)
            out.push(row);
    }
    return out;
}

function parseRepo(text) {
    return repoRow(parseJson(text));
}

function parseLogin(text) {
    var body = parseJson(text);
    return body && typeof body.l === "string" ? body.l : "";
}

// Newest push first. Repositories that have never been pushed to sort last
// and then alphabetically, so the tail of a long list stays stable between
// polls instead of shuffling.
function sortRepos(rows) {
    return rows.slice().sort(function (a, b) {
        if (a.pushedAt !== b.pushedAt)
            return a.pushedAt < b.pushedAt ? 1 : -1;
        return a.slug.localeCompare(b.slug);
    });
}

// Your repositories plus the watched ones, as a single feed. A watched repo
// you already have access to is not listed twice — it keeps its own row and
// gains the WATCHING mark.
function mergeRepos(own, extra, watch) {
    var watched = {};
    normalizeWatch(watch).forEach(function (slug) {
        watched[slug.toLowerCase()] = true;
    });
    var byKey = {};
    var order = [];
    function take(row, account) {
        if (row === null)
            return;
        var key = row.slug.toLowerCase();
        if (byKey[key] !== undefined)
            return;
        byKey[key] = {
            slug: row.slug,
            owner: row.owner,
            name: row.name,
            pushedAt: row.pushedAt,
            isPrivate: row.isPrivate,
            archived: row.archived,
            branch: row.branch,
            watched: !!watched[key],
            // `account` distinguishes a repository returned by /user/repos
            // from an outside watch. It lets watched repositories be additive
            // to the configured recent-account limit instead of consuming it.
            account: account
        };
        order.push(key);
    }
    (Array.isArray(own) ? own : []).forEach(function (row) { take(row, true); });
    (Array.isArray(extra) ? extra : []).forEach(function (row) { take(row, false); });
    return sortRepos(order.map(function (key) { return byKey[key]; }));
}

// The repository page and activity scope use the same union: N recent
// repositories returned for the account, plus every watched repository no
// matter how old it is. Rows produced before the `account` marker existed are
// treated as account rows, preserving compatibility with test fixtures and
// an in-memory feed surviving a shell update.
function displayedRepos(rows, recentLimit) {
    var feed = Array.isArray(rows) ? rows : [];
    var limit = typeof recentLimit === "number" && isFinite(recentLimit)
        ? Math.max(0, Math.floor(recentLimit)) : 0;
    var selected = feed.filter(function (row) {
        return row && repoSlug(row.slug) !== "" && row.account !== false;
    }).slice(0, limit);
    selected = selected.concat(feed.filter(function (row) {
        return row && repoSlug(row.slug) !== "" && row.watched;
    }));

    var out = [];
    var seen = {};
    selected.forEach(function (row) {
        var key = row.slug.toLowerCase();
        if (seen[key])
            return;
        seen[key] = true;
        out.push(row);
    });
    return sortRepos(out);
}

function monitoredScope(rows, recentLimit, watch) {
    var scope = displayedRepos(rows, recentLimit).map(function (row) { return row.slug; });
    var seen = {};
    scope.forEach(function (slug) { seen[slug.toLowerCase()] = true; });
    normalizeWatch(watch).forEach(function (slug) {
        if (!seen[slug.toLowerCase()]) {
            seen[slug.toLowerCase()] = true;
            scope.push(slug);
        }
    });
    return scope;
}

// Distinct owners in your own repositories that are not you: the "across N
// orgs" the settings account card reports.
function orgCount(rows, login) {
    var seen = {};
    var me = typeof login === "string" ? login.toLowerCase() : "";
    (Array.isArray(rows) ? rows : []).forEach(function (row) {
        var owner = row.owner.toLowerCase();
        if (owner !== me)
            seen[owner] = true;
    });
    return Object.keys(seen).length;
}

// Everything pushed since the watermark. ISO-8601 UTC stamps compare
// correctly as strings, which is why they are never turned into Dates here.
// An empty watermark means "nothing has been seen yet" and reads as nothing
// unread — the singleton sets the watermark on its first poll instead, so a
// fresh install does not open with every repository lit.
function unreadRepos(rows, since) {
    if (typeof since !== "string" || since === "")
        return [];
    return (Array.isArray(rows) ? rows : []).filter(function (row) {
        return row.pushedAt !== "" && row.pushedAt > since;
    });
}

function commitRow(raw) {
    if (!raw || typeof raw !== "object" || Array.isArray(raw))
        return null;
    if (typeof raw.s !== "string" || raw.s === "")
        return null;
    var message = typeof raw.m === "string" ? raw.m : "";
    return {
        sha: raw.s,
        short: raw.s.slice(0, 7),
        subject: subject(message),
        body: messageBody(message),
        author: typeof raw.a === "string" && raw.a !== "" ? raw.a : "unknown",
        date: typeof raw.d === "string" ? raw.d : "",
        url: typeof raw.u === "string" ? raw.u : ""
    };
}

function parseCommits(text) {
    var body = parseJson(text);
    if (!Array.isArray(body))
        return null;
    var out = [];
    for (var i = 0; i < body.length; i++) {
        var row = commitRow(body[i]);
        if (row !== null)
            out.push(row);
    }
    return out;
}

// The per-commit statistics the expanded row shows. Absent counts read as
// zero rather than as a missing line, because a commit that touched nothing
// is a real thing GitHub reports.
function parseCommitStats(text) {
    var body = parseJson(text);
    if (!body || typeof body !== "object" || Array.isArray(body))
        return null;
    if (typeof body.s !== "string" || body.s === "")
        return null;
    function count(value) {
        return typeof value === "number" && isFinite(value) && value > 0
            ? Math.floor(value) : 0;
    }
    return {
        sha: body.s,
        files: count(body.f),
        additions: count(body.add),
        deletions: count(body.del)
    };
}

function newCommits(commits, since) {
    if (typeof since !== "string" || since === "")
        return 0;
    return (Array.isArray(commits) ? commits : []).filter(function (row) {
        return row.date !== "" && row.date > since;
    }).length;
}

// A commit's first line, whitespace collapsed so a wrapped subject does not
// render with the newline still in it.
function subject(message) {
    if (typeof message !== "string")
        return "";
    var first = message.split("\n")[0];
    return first.replace(/\s+/g, " ").trim();
}

// Everything after the subject, with git trailers dropped. The trailers are
// the machine-readable footer (Co-Authored-By, Signed-off-by, Reviewed-by) and
// carry nothing a person reading a bar popover wants; this repository's own
// commits all end with one.
var TRAILER = /^[A-Za-z][A-Za-z-]*:\s/;
// A line that carries its own structure and must keep its break: a list item,
// or anything indented (quoted output, code).
var STRUCTURAL = /^(\s|[-*•]\s|\d+[.)]\s)/;

// Commit bodies are hard-wrapped at about 72 columns. Re-wrapping that inside
// a 376px column turns every paragraph into alternating long and half-empty
// lines — verified against this repository's own commits. Rejoining each
// paragraph lets the popover do the wrapping once, which is the only place
// that knows how wide it is.
function reflow(text) {
    return text.split(/\n{2,}/).map(function (paragraph) {
        var lines = paragraph.split("\n");
        var out = lines[0];
        for (var i = 1; i < lines.length; i++) {
            if (STRUCTURAL.test(lines[i]) || STRUCTURAL.test(lines[i - 1]))
                out += "\n" + lines[i];
            else
                out += " " + lines[i].trim();
        }
        return out;
    }).join("\n\n");
}

function messageBody(message) {
    if (typeof message !== "string")
        return "";
    var lines = message.split("\n").slice(1);
    function dropTrailingBlanks() {
        while (lines.length > 0 && lines[lines.length - 1].trim() === "")
            lines.pop();
    }
    dropTrailingBlanks();
    // git's own definition of the trailer block: the run of "Key: value" lines
    // at the very end, set off from the body by a blank line. Anything less
    // strict eats a body that happens to end in "Note: …".
    var start = lines.length;
    while (start > 0 && TRAILER.test(lines[start - 1]))
        start--;
    if (start < lines.length && (start === 0 || lines[start - 1].trim() === "")) {
        lines = lines.slice(0, start);
        dropTrailingBlanks();
    }
    return reflow(lines.join("\n").replace(/\n{3,}/g, "\n\n").trim());
}

var MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

function elapsed(iso, nowMs) {
    if (typeof iso !== "string" || iso === "")
        return -1;
    var then = Date.parse(iso);
    if (!isFinite(then))
        return -1;
    return Math.max(0, nowMs - then);
}

var MINUTE_MS = 60000;
var HOUR_MS = 3600000;
var DAY_MS = 86400000;

// The right-hand column of a repository row: as few characters as the age
// allows, because the column is right-aligned against elided repository names.
function relTime(iso, nowMs) {
    var age = elapsed(iso, nowMs);
    if (age < 0)
        return "";
    if (age < MINUTE_MS)
        return "now";
    if (age < HOUR_MS)
        return Math.floor(age / MINUTE_MS) + "m";
    if (age < DAY_MS)
        return Math.floor(age / HOUR_MS) + "h";
    if (age < 30 * DAY_MS)
        return Math.floor(age / DAY_MS) + "d";
    if (age < 365 * DAY_MS)
        return Math.floor(age / (30 * DAY_MS)) + "mo";
    return Math.floor(age / (365 * DAY_MS)) + "y";
}

// The prose form, under a commit subject and beside the popover header's
// "checked …". Past a week it becomes a date: "6d ago" still means something,
// "43d ago" does not.
//
// Counted in calendar days, not in elapsed ones, so this agrees with the
// dividers recencyBucket rules between groups. Flooring elapsed hours instead
// put "3d ago" on both sides of a day boundary — the divider said the day had
// changed and the two labels said it had not.
function agoLabel(thenMs, nowMs) {
    if (typeof thenMs !== "number" || !isFinite(thenMs) || thenMs <= 0)
        return "";
    var age = Math.max(0, nowMs - thenMs);
    if (age < MINUTE_MS)
        return "just now";
    var days = calendarDaysBetween(thenMs, nowMs);
    if (days === 0) {
        return age < HOUR_MS ? Math.floor(age / MINUTE_MS) + "m ago"
            : Math.floor(age / HOUR_MS) + "h ago";
    }
    if (days === 1)
        return "yesterday";
    if (days <= 6)
        return days + "d ago";
    var date = new Date(thenMs);
    return date.getDate() + " " + MONTHS[date.getMonth()];
}

// Whole calendar days between two instants, in local time — so "yesterday"
// means yesterday rather than "more than 24 hours ago", which is what a
// commit at 23:50 and one at 00:10 would otherwise disagree about. Rounded
// rather than floored because a DST boundary makes a day 23 or 25 hours long.
function calendarDaysBetween(thenMs, nowMs) {
    function startOfDay(ms) {
        var d = new Date(ms);
        d.setHours(0, 0, 0, 0);
        return d.getTime();
    }
    return Math.max(0, Math.round((startOfDay(nowMs) - startOfDay(thenMs)) / DAY_MS));
}

function calendarDaysAgo(iso, nowMs) {
    var then = Date.parse(iso);
    if (typeof iso !== "string" || iso === "" || !isFinite(then))
        return -1;
    return calendarDaysBetween(then, nowMs);
}

// A key for the age band a timestamp falls in. Two adjacent rows in a
// newest-first list belong to the same band exactly when these match, which is
// all the list needs to know to decide where to rule a line.
//
// The bands tighten towards now, because that is where the reader's sense of
// time is finest: each of the last seven days on its own, then each week for a
// month, then each month. Never a fixed count — an old list keeps getting
// separators, just coarser ones.
function recencyBucket(iso, nowMs) {
    var days = calendarDaysAgo(iso, nowMs);
    if (days < 0)
        return "";
    if (days <= 6)
        return "d" + days;
    if (days <= 34)
        return "w" + Math.floor(days / 7);
    return "m" + Math.floor(days / 30);
}

// Whether a divider belongs above `row` in a newest-first list.
function bucketBreak(iso, previousIso, nowMs) {
    return recencyBucket(iso, nowMs) !== recencyBucket(previousIso, nowMs);
}

function agoLabelIso(iso, nowMs) {
    if (typeof iso !== "string" || iso === "")
        return "";
    var then = Date.parse(iso);
    return isFinite(then) ? agoLabel(then, nowMs) : "";
}

// The toast a watched repository earns when it moves while the popover is
// closed. Null when nothing is worth saying, so the caller never has to decide
// whether a count of zero is a notification.
function pushToast(slug, count, topSubject) {
    if (typeof slug !== "string" || slug === "" || count <= 0)
        return null;
    // Only MAX_COMMITS are ever fetched, so a full page cannot tell 20 from
    // 200. Saying "20" there would be a number this shell does not have.
    var many = count >= MAX_COMMITS ? MAX_COMMITS + "+" : String(count);
    return {
        summary: slug + " — " + many + (count === 1 ? " new commit" : " new commits"),
        body: typeof topSubject === "string" ? topSubject : ""
    };
}

// ---- activity ------------------------------------------------------------

var ACTIVE_RUN_STATUSES = {
    queued: true,
    requested: true,
    waiting: true,
    pending: true,
    in_progress: true
};
var FAILURE_CONCLUSIONS = {
    failure: true,
    timed_out: true,
    startup_failure: true
};
var ATTENTION_CONCLUSIONS = {
    action_required: true,
    stale: true
};
var RECENT_CONCLUSIONS = {
    success: true,
    neutral: true,
    skipped: true,
    cancelled: true
};
var FILTERED_NOTIFICATION_REASONS = {
    ci_activity: true,
    subscribed: true,
    manual: true,
    state_change: true
};
var REASON_LABELS = {
    approval_requested: "approval requested",
    assign: "assigned to you",
    author: "thread you authored",
    comment: "thread you commented on",
    invitation: "repository invitation",
    member_feature_requested: "member feature request",
    mention: "mentioned you",
    review_requested: "review requested",
    security_advisory_credit: "security advisory credit",
    security_alert: "security alert",
    team_mention: "mentioned your team"
};

function lower(value) {
    return typeof value === "string" ? value.trim().toLowerCase() : "";
}

function runClassification(status, conclusion) {
    var state = lower(status);
    var result = lower(conclusion);
    // Some fixtures and older API wrappers put a terminal value in `status`.
    // Treat it exactly like the same value in conclusion.
    if (result === "" && (FAILURE_CONCLUSIONS[state]
            || ATTENTION_CONCLUSIONS[state] || RECENT_CONCLUSIONS[state]))
        result = state;

    if (ACTIVE_RUN_STATUSES[state])
        return { group: "active", active: true, attention: false,
            tone: "accent", severity: 2 };
    if (FAILURE_CONCLUSIONS[result])
        return { group: "attention", active: false, attention: true,
            tone: "red", severity: 5 };
    if (ATTENTION_CONCLUSIONS[result])
        return { group: "attention", active: false, attention: true,
            tone: "amber", severity: 4 };
    if (result === "success")
        return { group: "recent", active: false, attention: false,
            tone: "green", severity: 1 };
    if (result === "neutral" || result === "skipped" || result === "cancelled")
        return { group: "recent", active: false, attention: false,
            tone: "muted", severity: 0 };

    // A new status or conclusion is worth surfacing rather than silently
    // disappearing until this shell learns its semantics.
    return { group: "attention", active: false, attention: true,
        tone: "amber", severity: 3 };
}

function words(value) {
    return lower(value).replace(/_/g, " ");
}

function runStatusLabel(status, conclusion) {
    var state = lower(status);
    var result = lower(conclusion);
    if (state === "in_progress")
        return "in progress";
    if (result === "startup_failure")
        return "startup failed";
    if (result !== "")
        return words(result);
    return words(state) || "unknown";
}

function positiveInt(value, fallback) {
    return typeof value === "number" && isFinite(value) && value > 0
        ? Math.floor(value) : fallback;
}

function runRow(raw, repo) {
    if (!raw || typeof raw !== "object" || Array.isArray(raw))
        return null;
    var slug = repoSlug(repo);
    var runId = typeof raw.i === "number" && isFinite(raw.i)
        ? String(Math.floor(raw.i)) : typeof raw.i === "string" ? raw.i.trim() : "";
    if (slug === "" || runId === "")
        return null;
    var status = lower(raw.st);
    var conclusion = lower(raw.c);
    var classification = runClassification(status, conclusion);
    var attempt = positiveInt(raw.att, 1);
    var at = typeof raw.up === "string" && raw.up !== "" ? raw.up
        : typeof raw.cr === "string" && raw.cr !== "" ? raw.cr
        : typeof raw.start === "string" ? raw.start : "";
    var url = typeof raw.u === "string" ? raw.u : "";
    if (url === "")
        url = "https://github.com/" + slug + "/actions/runs/" + runId;
    var key = "run:" + slug.toLowerCase() + ":" + runId;
    var revision = attempt + ":" + at + ":" + status + ":" + conclusion;
    return {
        id: key,
        key: key,
        revision: revision,
        kind: "run",
        repo: slug,
        title: typeof raw.n === "string" && raw.n.trim() !== ""
            ? raw.n.trim() : "Workflow",
        detail: typeof raw.t === "string" ? raw.t.trim() : "",
        status: status,
        conclusion: conclusion,
        active: classification.active,
        attention: classification.attention,
        tone: classification.tone,
        unread: false,
        lifecycle: classification.active ? "active" : "unsettled",
        noticedAt: "",
        settledAt: "",
        canSettle: !classification.active,
        at: at,
        url: url,
        runId: runId,
        attempt: attempt,
        branch: typeof raw.b === "string" ? raw.b : "",
        event: typeof raw.e === "string" ? raw.e : "",
        actor: typeof raw.a === "string" ? raw.a : "",
        number: positiveInt(raw.num, 0),
        createdAt: typeof raw.cr === "string" ? raw.cr : "",
        startedAt: typeof raw.start === "string" ? raw.start : ""
    };
}

function parseRuns(text, repo) {
    var body = parseJson(text);
    if (!Array.isArray(body) || repoSlug(repo) === "")
        return null;
    var out = [];
    for (var i = 0; i < body.length; i++) {
        var row = runRow(body[i], repo);
        if (row !== null)
            out.push(row);
    }
    return out;
}

function notificationReasonIncluded(reason) {
    var key = lower(reason);
    return key !== "" && !FILTERED_NOTIFICATION_REASONS[key];
}

function notificationReasonLabel(reason) {
    var key = lower(reason);
    return REASON_LABELS[key] || words(key) || "notification";
}

// Notification subjects carry API URLs. They are GET targets, but opening
// them in a browser produces JSON; convert the stable repository forms to
// their github.com counterparts without attempting a second API read.
function apiToBrowserUrl(value) {
    if (typeof value !== "string" || value.trim() === "")
        return "";
    var url = value.trim();
    var prefix = "https://api.github.com/repos/";
    if (url.indexOf(prefix) === 0) {
        url = "https://github.com/" + url.slice(prefix.length);
        url = url.replace(/\/pulls\/(\d+)(?:$|\?)/, "/pull/$1")
            .replace(/\/commits\/([^/?]+)(?:$|\?)/, "/commit/$1");
        return url;
    }
    if (/^https:\/\/api\.github\.com\/notifications\/threads\//.test(url))
        return "https://github.com/notifications";
    return /^https:\/\/github\.com\//.test(url) ? url : "";
}

function notificationRow(raw) {
    if (!raw || typeof raw !== "object" || Array.isArray(raw))
        return null;
    var id = typeof raw.i === "number" && isFinite(raw.i)
        ? String(Math.floor(raw.i)) : typeof raw.i === "string" ? raw.i.trim() : "";
    var slug = repoSlug(raw.r);
    var reason = lower(raw.rs);
    if (id === "" || slug === "" || !notificationReasonIncluded(reason))
        return null;
    var type = typeof raw.ty === "string" ? raw.ty : "";
    var title = typeof raw.t === "string" && raw.t.trim() !== ""
        ? raw.t.trim() : "GitHub notification";
    var url = apiToBrowserUrl(raw.su);
    if (url === "")
        url = "https://github.com/" + slug;
    var security = reason === "security_alert";
    var at = typeof raw.at === "string" ? raw.at : "";
    var key = "notification:" + id;
    return {
        id: key,
        key: key,
        revision: at !== "" ? at : id,
        kind: "notification",
        repo: slug,
        title: title,
        detail: notificationReasonLabel(reason)
            + (type !== "" ? " · " + type : ""),
        status: reason,
        conclusion: "",
        active: false,
        attention: true,
        tone: security ? "red" : "amber",
        unread: false,
        lifecycle: "unsettled",
        noticedAt: "",
        settledAt: "",
        canSettle: true,
        at: at,
        url: url,
        reason: reason,
        subjectType: type,
        githubUnread: raw.un !== false,
        security: security
    };
}

function parseNotifications(text) {
    var body = parseJson(text);
    if (!Array.isArray(body))
        return null;
    var out = [];
    for (var i = 0; i < body.length; i++) {
        var row = notificationRow(body[i]);
        if (row !== null)
            out.push(row);
    }
    return out;
}

var INCLUDED_EVENT_TYPES = {
    PushEvent: true,
    CreateEvent: true,
    DeleteEvent: true,
    IssuesEvent: true,
    PullRequestEvent: true,
    ReleaseEvent: true,
    DiscussionEvent: true
};
var ISSUE_ACTIONS = { opened: true, closed: true, reopened: true };
var PULL_ACTIONS = { opened: true, closed: true, merged: true, reopened: true };

function eventId(raw) {
    if (!raw || typeof raw !== "object" || Array.isArray(raw))
        return "";
    if (typeof raw.i === "number" && isFinite(raw.i))
        return String(Math.floor(raw.i));
    return typeof raw.i === "string" ? raw.i.trim() : "";
}

function eventNumber(value) {
    if (typeof value === "number" && isFinite(value) && value > 0)
        return Math.floor(value);
    if (typeof value === "string" && /^\d+$/.test(value) && Number(value) > 0)
        return Math.floor(Number(value));
    return 0;
}

function eventEntityId(value) {
    if (typeof value === "number" && isFinite(value) && value > 0)
        return String(Math.floor(value));
    if (typeof value === "string" && /^\d+$/.test(value) && !/^0+$/.test(value))
        return value.replace(/^0+(?=\d)/, "");
    return "";
}

function githubUrl(value, fallback) {
    var url = typeof value === "string" ? value.trim() : "";
    if (/^https:\/\/github\.com\//.test(url))
        return url;
    return typeof fallback === "string" ? fallback : "";
}

function shortRef(ref) {
    if (typeof ref !== "string")
        return "";
    return ref.replace(/^refs\/(?:heads|tags)\//, "");
}

function eventDetail(label, number, actor) {
    var parts = [label + (number > 0 ? " #" + number : "")];
    if (actor !== "")
        parts.push("@" + actor);
    return parts.join(" · ");
}

// One curated repository event. Event ids are revisions, not identities: an
// issue being closed must replace (and wake) the earlier opened snapshot.
function eventRow(raw, repo) {
    if (!raw || typeof raw !== "object" || Array.isArray(raw))
        return null;
    var slug = repoSlug(repo);
    var id = eventId(raw);
    var type = typeof raw.ty === "string" ? raw.ty.trim() : "";
    var at = typeof raw.at === "string" ? raw.at : "";
    if (slug === "" || id === "" || at === "" || !isFinite(Date.parse(at))
            || !INCLUDED_EVENT_TYPES[type])
        return null;

    var repoKey = slug.toLowerCase();
    var actor = typeof raw.a === "string" ? raw.a.trim() : "";
    var action = lower(raw.ac);
    var number = eventNumber(raw.num);
    var title = typeof raw.t === "string" ? raw.t.trim() : "";
    var key = "";
    var kind = "";
    var detail = "";
    var status = action;
    var url = "";
    var ref = typeof raw.ref === "string" ? raw.ref.trim() : "";
    var refType = lower(raw.rt);
    var releaseId = eventEntityId(raw.rid);

    switch (type) {
    case "PushEvent": {
        if (ref === "")
            return null;
        var pushedRef = shortRef(ref);
        var size = positiveInt(raw.size, 0);
        key = "push:" + repoKey + ":" + ref;
        kind = "push";
        title = "Pushed to " + pushedRef;
        detail = (size > 0 ? size + (size === 1 ? " commit" : " commits") : "New commits")
            + (actor !== "" ? " · @" + actor : "");
        status = "pushed";
        var target = typeof raw.head === "string" && raw.head.trim() !== ""
            ? raw.head.trim() : pushedRef;
        url = "https://github.com/" + slug + "/commits/" + encodeURIComponent(target);
        break;
    }
    case "CreateEvent":
    case "DeleteEvent": {
        if ((refType !== "branch" && refType !== "tag") || ref === "")
            return null;
        var created = type === "CreateEvent";
        key = "ref:" + repoKey + ":" + refType + ":" + ref;
        kind = "ref";
        status = created ? "created" : "deleted";
        title = (created ? "Created " : "Deleted ") + refType + " " + ref;
        detail = actor !== "" ? "@" + actor : slug;
        if (created) {
            url = "https://github.com/" + slug + "/tree/" + encodeURIComponent(ref);
        } else {
            url = "https://github.com/" + slug
                + (refType === "branch" ? "/branches" : "/tags");
        }
        break;
    }
    case "IssuesEvent":
        if (!ISSUE_ACTIONS[action] || number === 0)
            return null;
        key = "issue:" + repoKey + ":" + number;
        kind = "issue";
        title = title || "Issue #" + number;
        detail = eventDetail("Issue " + action, number, actor);
        url = githubUrl(raw.u, "https://github.com/" + slug + "/issues/" + number);
        break;
    case "PullRequestEvent":
        if (action === "closed" && raw.merged === true)
            action = "merged";
        if (!PULL_ACTIONS[action] || number === 0)
            return null;
        key = "pr:" + repoKey + ":" + number;
        kind = "pull_request";
        status = action;
        title = title || "Pull request #" + number;
        detail = eventDetail("Pull request " + action, number, actor);
        url = githubUrl(raw.u, "https://github.com/" + slug + "/pull/" + number);
        break;
    case "ReleaseEvent": {
        if (action !== "published" || releaseId === "")
            return null;
        var tag = typeof raw.tag === "string" ? raw.tag.trim() : "";
        var releaseName = typeof raw.rn === "string" ? raw.rn.trim() : "";
        key = "release:" + repoKey + ":" + releaseId;
        kind = "release";
        title = releaseName || tag || "Published release";
        detail = "Release" + (tag !== "" ? " " + tag : "") + " published"
            + (actor !== "" ? " · @" + actor : "");
        url = githubUrl(raw.u, tag !== ""
            ? "https://github.com/" + slug + "/releases/tag/" + encodeURIComponent(tag)
            : "https://github.com/" + slug + "/releases");
        break;
    }
    case "DiscussionEvent":
        if (action !== "created" || number === 0)
            return null;
        key = "discussion:" + repoKey + ":" + number;
        kind = "discussion";
        title = title || "Discussion #" + number;
        detail = eventDetail("New discussion", number, actor);
        url = githubUrl(raw.u, "https://github.com/" + slug + "/discussions/" + number);
        break;
    }

    return {
        id: key,
        key: key,
        revision: id + ":" + at,
        eventId: id,
        kind: kind,
        repo: slug,
        title: title,
        detail: detail,
        status: status,
        conclusion: "",
        active: false,
        attention: false,
        tone: "accent",
        unread: false,
        lifecycle: "unsettled",
        noticedAt: "",
        settledAt: "",
        canSettle: true,
        at: at,
        url: url,
        actor: actor,
        number: number,
        ref: ref,
        refType: refType,
        eventType: type
    };
}

function revisionCompare(left, right) {
    var a = typeof left === "string" ? left : "";
    var b = typeof right === "string" ? right : "";
    var headA = a.split(":")[0].replace(/^0+/, "") || "0";
    var headB = b.split(":")[0].replace(/^0+/, "") || "0";
    if (/^\d+$/.test(headA) && /^\d+$/.test(headB)) {
        if (headA.length !== headB.length)
            return headA.length > headB.length ? 1 : -1;
        if (headA !== headB)
            return headA > headB ? 1 : -1;
    }
    return a === b ? 0 : a > b ? 1 : -1;
}

function newestEntityRows(rows) {
    var byKey = {};
    var order = [];
    (Array.isArray(rows) ? rows : []).forEach(function (row) {
        if (!row || typeof row.key !== "string" || row.key === "")
            return;
        if (byKey[row.key] === undefined) {
            byKey[row.key] = row;
            order.push(row.key);
            return;
        }
        var current = byKey[row.key];
        if (atMs(row) > atMs(current)
                || (atMs(row) === atMs(current)
                    && revisionCompare(row.revision, current.revision) > 0))
            byKey[row.key] = row;
    });
    return order.map(function (key) { return byKey[key]; });
}

function parseEvents(text, repo) {
    var body = parseJson(text);
    if (!Array.isArray(body) || repoSlug(repo) === "")
        return null;
    var rows = [];
    for (var i = 0; i < body.length; i++) {
        var row = eventRow(body[i], repo);
        if (row !== null)
            rows.push(row);
    }
    return newestEntityRows(rows);
}

// `gh api --include` writes an HTTP status line and headers before the jq
// result. It may return several HTTP blocks (for example through a proxy), so
// the final block is authoritative. Header names are normalized, values are
// not: weak ETags must be sent back byte-for-byte.
function parseIncludedResponse(text) {
    if (typeof text !== "string" || text === "")
        return null;
    var normalized = text.replace(/\r\n/g, "\n");
    var pattern = /^HTTP\/[^\s]+\s+(\d{3})[^\n]*$/gm;
    var match;
    var last = null;
    while ((match = pattern.exec(normalized)) !== null)
        last = { index: match.index, end: pattern.lastIndex, status: Number(match[1]) };
    if (last === null)
        return null;

    var separator = normalized.indexOf("\n\n", last.end);
    var headerEnd = separator >= 0 ? separator : normalized.length;
    var headerText = normalized.slice(last.end, headerEnd).replace(/^\n/, "");
    var headers = {};
    if (headerText !== "") {
        var lines = headerText.split("\n");
        for (var i = 0; i < lines.length; i++) {
            if (lines[i].trim() === "")
                continue;
            var colon = lines[i].indexOf(":");
            if (colon <= 0)
                return null;
            headers[lines[i].slice(0, colon).trim().toLowerCase()]
                = lines[i].slice(colon + 1).trim();
        }
    }
    var body = separator >= 0 ? normalized.slice(separator + 2) : "";
    var seconds = Number(headers["x-poll-interval"]);
    return {
        status: last.status,
        headers: headers,
        body: body.trim(),
        etag: normalizeEtag(headers.etag),
        lastModified: normalizeHttpDate(headers["last-modified"]),
        pollIntervalMs: isFinite(seconds) && seconds > 0
            ? Math.floor(seconds * 1000) : 0,
        notModified: last.status === 304
    };
}

// Entity tags are quoted; the optional W/ prefix must survive exactly, since
// If-None-Match compares it byte-for-byte.
function normalizeEtag(value) {
    var etag = typeof value === "string" ? value.trim() : "";
    return /^(?:W\/)?"[^"\r\n]+"$/.test(etag) ? etag : "";
}

// Last-Modified is echoed back verbatim as If-Modified-Since, so only the
// IMF-fixdate form HTTP servers emit is accepted — nothing that could smuggle
// a second header line into the gh argument.
function normalizeHttpDate(value) {
    var stamp = typeof value === "string" ? value.trim() : "";
    return /^[A-Z][a-z]{2}, \d{2} [A-Z][a-z]{2} \d{4} \d{2}:\d{2}:\d{2} GMT$/.test(stamp)
        && isFinite(Date.parse(stamp)) ? stamp : "";
}

function includedResponseOk(response, exitCode) {
    return response !== null && (response.status === 304
        || (response.status >= 200 && response.status < 300 && exitCode === 0));
}

function normalizeEventEtags(value) {
    var out = {};
    if (!value || typeof value !== "object" || Array.isArray(value))
        return out;
    Object.keys(value).slice(0, MAX_INBOX_SOURCES).forEach(function (repo) {
        var slug = repoSlug(repo);
        var etag = normalizeEtag(value[repo]);
        if (slug !== "" && etag !== "")
            out[slug.toLowerCase()] = etag;
    });
    return out;
}

function normalizeEventPollIntervals(value) {
    var out = {};
    if (!value || typeof value !== "object" || Array.isArray(value))
        return out;
    Object.keys(value).slice(0, MAX_INBOX_SOURCES).forEach(function (repo) {
        var slug = repoSlug(repo);
        var interval = value[repo];
        if (slug !== "" && typeof interval === "number" && isFinite(interval)
                && interval > 0)
            out[slug.toLowerCase()] = Math.max(1000, Math.floor(interval));
    });
    return out;
}

// ---- conditional Inbox requests ----------------------------------------
// Every Inbox read (workflow runs, repository events, notifications) is
// fetched with `--include` so its validators, poll interval, and rate-limit
// headers are visible. A 304 does not count against the primary rate limit,
// which is what makes a 60-second sweep over dozens of repositories cheap.
var CONDITIONAL_KINDS = { runs: true, events: true, notifications: true };

// The `-H` arguments for a conditional read. An empty validator sends
// nothing, so the first request after a restart (or after a malformed
// response) is always unconditional.
function conditionalArgs(etag, lastModified) {
    var args = [];
    var tag = normalizeEtag(etag);
    var since = normalizeHttpDate(lastModified);
    if (tag !== "")
        args.push("-H", "If-None-Match: " + tag);
    if (since !== "")
        args.push("-H", "If-Modified-Since: " + since);
    return args;
}

// `gh api --jq` exits nonzero on a 304 because the empty body is not JSON, so
// the header block — or, failing that, gh's own "HTTP 304" message — decides.
function notModifiedResponse(response, exitCode, errText) {
    if (response !== null && typeof response === "object" && response.notModified === true)
        return true;
    return exitCode !== 0 && typeof errText === "string" && /\bHTTP 304\b/i.test(errText);
}

// Primary-rate-limit headroom kept for everything else that uses the same
// token (the user's own `gh`, other tools). Below it the Inbox stands down
// until GitHub's reset instead of spending the remainder one repository at a
// time.
var RATE_LIMIT_FLOOR = 200;
var RATE_LIMIT_MIN_PAUSE_MS = 60000;
var RATE_LIMIT_MAX_PAUSE_MS = 3600000;
var RATE_LIMIT_DEFAULT_PAUSE_MS = 900000;

// What an included response says about the token's primary rate limit.
// `known` is false when the headers are absent, so a header-less response
// (a proxy error, a gh failure) neither pauses nor lifts a pause. `until` is
// 0 while there is headroom, otherwise the absolute time the Inbox may resume.
function rateLimitPause(headers, nowMs) {
    var source = headers && typeof headers === "object" ? headers : {};
    var raw = typeof source["x-ratelimit-remaining"] === "string"
        ? source["x-ratelimit-remaining"].trim() : "";
    if (!/^\d+$/.test(raw))
        return { known: false, remaining: -1, until: 0 };
    var remaining = Number(raw);
    if (remaining >= RATE_LIMIT_FLOOR)
        return { known: true, remaining: remaining, until: 0 };
    var now = typeof nowMs === "number" && isFinite(nowMs) ? nowMs : Date.now();
    var reset = Number(source["x-ratelimit-reset"]);
    var wait = isFinite(reset) && reset > 0 ? reset * 1000 - now
        : RATE_LIMIT_DEFAULT_PAUSE_MS;
    wait = Math.min(RATE_LIMIT_MAX_PAUSE_MS, Math.max(RATE_LIMIT_MIN_PAUSE_MS, wait));
    return { known: true, remaining: remaining, until: now + wait };
}

function rateLimitMessage(untilMs, nowMs) {
    var now = typeof nowMs === "number" && isFinite(nowMs) ? nowMs : Date.now();
    var minutes = Math.max(1, Math.ceil((untilMs - now) / 60000));
    return "GitHub API quota is low; Inbox checks resume in "
        + minutes + (minutes === 1 ? " minute" : " minutes");
}

// How long until a conditional source may be read again. GitHub's
// X-Poll-Interval can only lengthen the Inbox cadence, never shorten it; a
// response without the header keeps whatever interval was last announced.
function nextPollInterval(response, previousMs, floorMs) {
    var floor = typeof floorMs === "number" && isFinite(floorMs) && floorMs > 0
        ? floorMs : 60000;
    var announced = response && typeof response === "object"
        && typeof response.pollIntervalMs === "number" && response.pollIntervalMs > 0
        ? response.pollIntervalMs
        : (typeof previousMs === "number" && isFinite(previousMs) && previousMs > 0
            ? previousMs : floor);
    return Math.max(floor, Math.floor(announced));
}

// Poll times are stamped from the sweep's start, and the sweep timer itself
// is coarse (Qt may fire it a few percent early). Without slack an interval
// equal to the sweep cadence would miss every other sweep and silently double.
var POLL_SLACK_MS = 5000;

function pollDue(nextAtMs, nowMs) {
    var next = typeof nextAtMs === "number" && isFinite(nextAtMs) ? nextAtMs : 0;
    return next - nowMs <= POLL_SLACK_MS;
}

// ---- gh watchdog ---------------------------------------------------------
// One queued `gh` process serves every read, so a stalled request would hold
// the queue — and every polling flag — forever. Interactive reads are the
// ones someone is watching a spinner for, so they give up sooner.
var GH_TIMEOUT_MS = 60000;
var GH_INTERACTIVE_TIMEOUT_MS = 30000;
// After SIGTERM, how long to wait for the falling edge before SIGKILL.
var GH_KILL_GRACE_MS = 5000;
// timeout(1)'s status, so a timed-out read reads like one in the logs.
var GH_TIMEOUT_EXIT = 124;

function ghTimeoutMs(job) {
    return job && job.interactive === true ? GH_INTERACTIVE_TIMEOUT_MS : GH_TIMEOUT_MS;
}

function ghTimeoutMessage(job) {
    return "gh api timed out after " + Math.round(ghTimeoutMs(job) / 1000) + " s";
}

function atMs(row) {
    var stamp = row && typeof row.at === "string" ? Date.parse(row.at) : NaN;
    return isFinite(stamp) ? stamp : 0;
}

function toneSeverity(tone) {
    switch (tone) {
    case "red": return 5;
    case "amber": return 4;
    case "accent": return 3;
    case "green": return 2;
    default: return 1;
    }
}

function newerOrStronger(a, b) {
    var timeA = atMs(a);
    var timeB = atMs(b);
    if (timeA !== timeB)
        return timeA > timeB ? a : b;
    return toneSeverity(a.tone) >= toneSeverity(b.tone) ? a : b;
}

function dedupeActivities(rows) {
    var byId = {};
    var order = [];
    (Array.isArray(rows) ? rows : []).forEach(function (row) {
        if (!row || typeof row.id !== "string" || row.id === "")
            return;
        if (byId[row.id] === undefined)
            order.push(row.id);
        byId[row.id] = byId[row.id] === undefined
            ? row : newerOrStronger(row, byId[row.id]);
    });
    return order.map(function (id) { return byId[id]; });
}

function withActivityUnread(rows, since) {
    var watermark = typeof since === "string" ? since : "";
    return dedupeActivities(rows).map(function (row) {
        var copy = {};
        Object.keys(row).forEach(function (key) { copy[key] = row[key]; });
        copy.unread = !!row.attention && watermark !== ""
            && typeof row.at === "string" && row.at !== "" && row.at > watermark;
        return copy;
    });
}

function unseenActivities(rows, since) {
    var decorated = typeof since === "string" ? withActivityUnread(rows, since)
        : dedupeActivities(rows);
    return decorated.filter(function (row) { return row.attention && row.unread; });
}

function groupFor(row) {
    return row && row.active ? "active" : row && row.attention ? "attention" : "recent";
}

function activitySort(a, b) {
    if (!!a.unread !== !!b.unread)
        return a.unread ? -1 : 1;
    var severity = toneSeverity(b.tone) - toneSeverity(a.tone);
    if (severity !== 0)
        return severity;
    var byTime = atMs(b) - atMs(a);
    if (byTime !== 0)
        return byTime;
    return a.id.localeCompare(b.id);
}

function activitySections(rows) {
    var groups = { active: [], attention: [], recent: [] };
    dedupeActivities(rows).forEach(function (row) {
        groups[groupFor(row)].push(row);
    });
    groups.active.sort(activitySort);
    groups.attention.sort(activitySort);
    groups.recent.sort(activitySort);
    return [
        { id: "active", title: "Active", rows: groups.active },
        { id: "attention", title: "Attention", rows: groups.attention },
        { id: "recent", title: "Recent", rows: groups.recent }
    ];
}

// The limit is soft: currently-running work and unseen attention can exceed
// it. Only acknowledged attention and routine recent runs compete for the
// remaining slots.
function prioritizeActivities(rows, limit) {
    var cap = typeof limit === "number" && isFinite(limit)
        ? Math.max(0, Math.floor(limit)) : MAX_ACTIVITY_ROWS;
    var sections = activitySections(rows);
    var active = sections[0].rows;
    var attention = sections[1].rows;
    var recent = sections[2].rows;
    var unseen = attention.filter(function (row) { return row.unread; });
    var acknowledged = attention.filter(function (row) { return !row.unread; });
    var mandatory = active.concat(unseen);
    var room = Math.max(0, cap - mandatory.length);
    var optional = acknowledged.concat(recent).slice(0, room);
    var chosen = {};
    mandatory.concat(optional).forEach(function (row) { chosen[row.id] = true; });
    return active.filter(function (row) { return chosen[row.id]; })
        .concat(attention.filter(function (row) { return chosen[row.id]; }))
        .concat(recent.filter(function (row) { return chosen[row.id]; }));
}

function combineActivities(runRows, notificationRows, since) {
    var runs = Array.isArray(runRows) ? runRows : [];
    var notifications = Array.isArray(notificationRows) ? notificationRows : [];
    return withActivityUnread(runs.concat(notifications), since);
}

function activityCounts(rows) {
    var counts = { running: 0, attention: 0, unseen: 0 };
    dedupeActivities(rows).forEach(function (row) {
        if (row.active)
            counts.running++;
        if (row.attention) {
            counts.attention++;
            if (row.unread)
                counts.unseen++;
        }
    });
    return counts;
}

function combinedUnreadCount(repoCount, rows, since) {
    var repos = typeof repoCount === "number" && isFinite(repoCount)
        ? Math.max(0, Math.floor(repoCount)) : 0;
    return repos + unseenActivities(rows, since).length;
}

function badgeTone(repoCount, rows, since) {
    var unseen = unseenActivities(rows, since);
    if (unseen.some(function (row) { return row.tone === "red"; }))
        return "red";
    if (unseen.length > 0)
        return "amber";
    return repoCount > 0 ? "accent" : "none";
}

function durationLabel(startIso, endIso, nowMs) {
    var start = typeof startIso === "string" ? Date.parse(startIso) : NaN;
    var end = typeof endIso === "string" && endIso !== "" ? Date.parse(endIso) : nowMs;
    if (!isFinite(start) || !isFinite(end))
        return "";
    var totalMinutes = Math.max(0, Math.floor((end - start) / MINUTE_MS));
    if (totalMinutes < 1)
        return "<1m";
    if (totalMinutes < 60)
        return totalMinutes + "m";
    var hours = Math.floor(totalMinutes / 60);
    var minutes = totalMinutes % 60;
    if (hours < 24)
        return hours + "h" + (minutes > 0 ? " " + minutes + "m" : "");
    var days = Math.floor(hours / 24);
    hours %= 24;
    return days + "d" + (hours > 0 ? " " + hours + "h" : "");
}

function activityTimeLabel(row, nowMs) {
    if (!row)
        return "";
    if (row.active) {
        var span = durationLabel(row.startedAt || row.createdAt || row.at, "", nowMs);
        return span === "" ? "running" : span + " running";
    }
    return agoLabelIso(row.at, nowMs);
}

function inboxTimeLabel(row, nowMs) {
    return activityTimeLabel(row, nowMs);
}

function activeRepositories(rows, limit) {
    var cap = typeof limit === "number" && isFinite(limit)
        ? Math.max(0, Math.floor(limit)) : MAX_ACTIVE_REPOS;
    var seen = {};
    return dedupeActivities(rows).filter(function (row) { return row.active; })
        .sort(function (a, b) { return atMs(b) - atMs(a); })
        .filter(function (row) {
            var key = row.repo.toLowerCase();
            if (seen[key])
                return false;
            seen[key] = true;
            return true;
        }).slice(0, cap).map(function (row) { return row.repo; });
}

// ---- persistent Inbox ---------------------------------------------------

var INBOX_KINDS = {
    run: true,
    notification: true,
    push: true,
    ref: true,
    issue: true,
    pull_request: true,
    release: true,
    discussion: true
};
var INBOX_TONES = { red: true, amber: true, accent: true, green: true, muted: true };

function cleanText(value, limit) {
    if (typeof value !== "string")
        return "";
    return value.replace(/[\u0000-\u001f\u007f]/g, " ")
        .replace(/\s+/g, " ").trim().slice(0, limit);
}

function cleanStamp(value) {
    var stamp = cleanText(value, 64);
    return stamp !== "" && isFinite(Date.parse(stamp)) ? stamp : "";
}

function inboxSourceForRow(row) {
    if (!row || typeof row !== "object")
        return "";
    if (row.kind === "notification")
        return "notifications";
    var slug = repoSlug(row.repo);
    if (slug === "")
        return "";
    return (row.kind === "run" ? "workflows:" : "events:") + slug.toLowerCase();
}

function validInboxSource(value) {
    if (value === "notifications")
        return value;
    if (typeof value !== "string")
        return "";
    var colon = value.indexOf(":");
    var prefix = value.slice(0, colon);
    var slug = value.slice(colon + 1);
    return (prefix === "workflows" || prefix === "events") && repoSlug(slug) !== ""
        ? prefix + ":" + repoSlug(slug).toLowerCase() : "";
}

// Persist only fields that the popover knows how to render. Besides keeping
// the state file compact, this means an API payload can never smuggle an
// arbitrary URL or object graph into a later shell process.
function normalizeInboxSnapshot(raw, sourceOverride) {
    if (!raw || typeof raw !== "object" || Array.isArray(raw))
        return null;
    var key = cleanText(typeof raw.key === "string" ? raw.key : raw.id, 600);
    var revision = cleanText(raw.revision, 600);
    var kind = cleanText(raw.kind, 40);
    var slug = repoSlug(raw.repo);
    if (key === "" || revision === "" || !INBOX_KINDS[kind] || slug === ""
            || !/^(?:run|notification|push|ref|issue|pr|release|discussion):/.test(key))
        return null;
    var active = kind === "run" && raw.active === true;
    var source = validInboxSource(sourceOverride)
        || validInboxSource(raw.source) || inboxSourceForRow(raw);
    if (source === "")
        return null;
    var lifecycle = active ? "active" : raw.lifecycle === "settled"
        ? "settled" : "unsettled";
    var tone = cleanText(raw.tone, 20);
    if (!INBOX_TONES[tone])
        tone = active ? "accent" : "muted";
    var url = githubUrl(raw.url, "https://github.com/" + slug);
    var row = {
        id: key,
        key: key,
        revision: revision,
        source: source,
        kind: kind,
        repo: slug,
        title: cleanText(raw.title, 300) || "GitHub update",
        detail: cleanText(raw.detail, 600),
        status: cleanText(raw.status, 80),
        conclusion: cleanText(raw.conclusion, 80),
        active: active,
        attention: !active && raw.attention === true,
        tone: tone,
        unread: false,
        lifecycle: lifecycle,
        noticedAt: cleanStamp(raw.noticedAt),
        settledAt: lifecycle === "settled" ? cleanStamp(raw.settledAt) : "",
        canSettle: !active,
        at: cleanStamp(raw.at),
        url: url,
        actor: cleanText(raw.actor, 100),
        number: positiveInt(raw.number, 0),
        branch: cleanText(raw.branch, 300),
        event: cleanText(raw.event, 80),
        runId: cleanText(raw.runId, 80),
        attempt: positiveInt(raw.attempt, 1),
        createdAt: cleanStamp(raw.createdAt),
        startedAt: cleanStamp(raw.startedAt),
        reason: cleanText(raw.reason, 80),
        subjectType: cleanText(raw.subjectType, 80),
        security: raw.security === true,
        githubUnread: raw.githubUnread !== false,
        ref: cleanText(raw.ref, 500),
        refType: cleanText(raw.refType, 40),
        eventType: cleanText(raw.eventType, 80)
    };
    return row;
}

function pruneSettledInbox(items, limit) {
    var source = items && typeof items === "object" && !Array.isArray(items) ? items : {};
    var cap = typeof limit === "number" && isFinite(limit)
        ? Math.max(0, Math.floor(limit)) : MAX_SETTLED_INBOX_ITEMS;
    var settled = Object.keys(source).filter(function (key) {
        return source[key] && source[key].lifecycle === "settled";
    }).sort(function (a, b) {
        var left = source[a].settledAt || source[a].noticedAt || source[a].at;
        var right = source[b].settledAt || source[b].noticedAt || source[b].at;
        var byTime = Date.parse(right || "") - Date.parse(left || "");
        if (isFinite(byTime) && byTime !== 0)
            return byTime;
        var bySnapshot = atMs(source[b]) - atMs(source[a]);
        if (bySnapshot !== 0)
            return bySnapshot;
        return a.localeCompare(b);
    });
    var keep = {};
    settled.slice(0, cap).forEach(function (key) { keep[key] = true; });
    var out = {};
    Object.keys(source).forEach(function (key) {
        if (source[key].lifecycle !== "settled" || keep[key])
            out[key] = source[key];
    });
    return out;
}

function normalizeInboxItems(value) {
    var out = {};
    if (Array.isArray(value)) {
        value.forEach(function (raw) {
            var row = normalizeInboxSnapshot(raw, "");
            if (row !== null)
                out[row.key] = row;
        });
    } else if (value && typeof value === "object") {
        Object.keys(value).forEach(function (key) {
            var row = normalizeInboxSnapshot(value[key], "");
            if (row !== null)
                out[row.key] = row;
        });
    }
    return pruneSettledInbox(out, MAX_SETTLED_INBOX_ITEMS);
}

function compactInboxItems(value) {
    var items = normalizeInboxItems(value);
    var out = {};
    Object.keys(items).forEach(function (key) {
        var row = items[key];
        var compact = {
            key: row.key,
            revision: row.revision,
            source: row.source,
            kind: row.kind,
            repo: row.repo,
            title: row.title,
            tone: row.tone,
            lifecycle: row.lifecycle,
            noticedAt: row.noticedAt,
            settledAt: row.settledAt,
            at: row.at,
            url: row.url
        };
        ["detail", "status", "conclusion", "actor", "branch", "event", "runId",
            "createdAt", "startedAt", "reason", "subjectType", "ref", "refType",
            "eventType"].forEach(function (field) {
            if (row[field] !== "")
                compact[field] = row[field];
        });
        if (row.active)
            compact.active = true;
        if (row.attention)
            compact.attention = true;
        if (row.security)
            compact.security = true;
        if (row.number > 0)
            compact.number = row.number;
        if (row.kind === "run" && row.attempt > 1)
            compact.attempt = row.attempt;
        out[key] = compact;
    });
    return out;
}

function normalizeSourceRevisions(value) {
    var out = {};
    if (!value || typeof value !== "object" || Array.isArray(value))
        return out;
    Object.keys(value).slice(0, MAX_INBOX_SOURCES).forEach(function (rawSource) {
        var source = validInboxSource(rawSource);
        var rawMap = value[rawSource];
        if (source === "" || !rawMap || typeof rawMap !== "object" || Array.isArray(rawMap))
            return;
        var revisions = {};
        Object.keys(rawMap).slice(0, MAX_SOURCE_REVISIONS).forEach(function (key) {
            var revision = cleanText(rawMap[key], 600);
            if (revision !== "")
                revisions[cleanText(key, 600)] = revision;
        });
        // Preserve an empty map: its presence is the successful baseline.
        out[source] = revisions;
    });
    return out;
}

function sourceRevisionMap(oldMap, incoming, items, source) {
    var out = {};
    var keys = [];
    incoming.forEach(function (row) { keys.push(row.key); });
    Object.keys(items).forEach(function (key) {
        if (items[key].source === source)
            keys.push(key);
    });
    keys = keys.concat(Object.keys(oldMap));
    keys.forEach(function (key) {
        if (out[key] !== undefined || Object.keys(out).length >= MAX_SOURCE_REVISIONS)
            return;
        var incomingRow = incoming.find(function (row) { return row.key === key; });
        var revision = incomingRow ? incomingRow.revision : oldMap[key];
        if (typeof revision === "string" && revision !== "")
            out[key] = revision;
    });
    return out;
}

// Reconcile one independently-baselined API source. Missing terminal rows are
// intentionally retained: both notifications and repository events are
// bounded server-side feeds, while an unsettled Inbox entity is not.
function reconcileInboxSource(itemsValue, revisionsValue, sourceValue, rows, noticedAt) {
    var source = validInboxSource(sourceValue);
    var items = normalizeInboxItems(itemsValue);
    var revisions = normalizeSourceRevisions(revisionsValue);
    if (source === "" || !Array.isArray(rows))
        return { items: items, sourceRevisions: revisions, baseline: false };
    var known = Object.prototype.hasOwnProperty.call(revisions, source);
    var oldMap = known ? revisions[source] : {};
    var stamp = cleanStamp(noticedAt);
    var incoming = newestEntityRows(rows.map(function (raw) {
        return normalizeInboxSnapshot(raw, source);
    }).filter(function (row) { return row !== null; }));
    var present = {};
    incoming.forEach(function (row) { present[row.key] = true; });

    // A live workflow that vanished from a successful response is no longer
    // live. Terminal and directed rows stay until local settlement.
    Object.keys(items).forEach(function (key) {
        if (items[key].source === source && items[key].lifecycle === "active"
                && !present[key])
            delete items[key];
    });

    incoming.forEach(function (row) {
        var existing = items[row.key];
        var previousRevision = oldMap[row.key];
        var same = previousRevision === row.revision
            || (existing && existing.revision === row.revision);
        // Do not let a lagging event page replace a newer snapshot.
        if (!same && existing && (atMs(existing) > atMs(row)
                || (source.indexOf("events:") === 0 && atMs(existing) === atMs(row)
                    && revisionCompare(existing.revision, row.revision) > 0))) {
            row.revision = previousRevision || existing.revision;
            return;
        }
        // A pruned settled row must not be recreated by an unchanged API page.
        if (known && same && !existing && !row.active)
            return;

        if (!known) {
            if (!row.active && existing && existing.lifecycle !== "active") {
                // Re-baselining a temporarily disabled source is quiet, but it
                // is never an implicit local settlement action.
                row.lifecycle = existing.lifecycle;
                row.noticedAt = existing.noticedAt;
                row.settledAt = existing.settledAt;
            } else {
                row.lifecycle = row.active ? "active" : "settled";
                row.noticedAt = stamp || row.at;
                row.settledAt = row.active ? "" : (stamp || row.at);
            }
        } else if (row.active) {
            row.lifecycle = "active";
            row.noticedAt = existing ? existing.noticedAt : (stamp || row.at);
            row.settledAt = "";
        } else if (!same || !existing || existing.lifecycle === "active") {
            row.lifecycle = "unsettled";
            row.noticedAt = stamp || row.at;
            row.settledAt = "";
        } else {
            row.lifecycle = existing.lifecycle;
            row.noticedAt = existing.noticedAt;
            row.settledAt = existing.settledAt;
        }
        row.canSettle = !row.active;
        items[row.key] = row;
    });

    var nextRevisions = {};
    Object.keys(revisions).forEach(function (key) { nextRevisions[key] = revisions[key]; });
    nextRevisions[source] = sourceRevisionMap(oldMap, incoming, items, source);
    return {
        items: pruneSettledInbox(items, MAX_SETTLED_INBOX_ITEMS),
        sourceRevisions: nextRevisions,
        baseline: !known
    };
}

function setInboxSettlement(itemsValue, keyValue, settled, at) {
    var items = normalizeInboxItems(itemsValue);
    var key = cleanText(keyValue, 600);
    var row = items[key];
    if (!row || !row.canSettle)
        return items;
    var copy = {};
    Object.keys(row).forEach(function (field) { copy[field] = row[field]; });
    copy.lifecycle = settled ? "settled" : "unsettled";
    copy.settledAt = settled ? (cleanStamp(at) || row.settledAt || row.noticedAt) : "";
    items[key] = copy;
    return pruneSettledInbox(items, MAX_SETTLED_INBOX_ITEMS);
}

// Settle the whole actionable Inbox in one immutable pass. Live workflow
// rows deliberately remain active, and previously settled timestamps remain
// untouched so bulk cleanup does not reorder retained history unnecessarily.
function settleAllInboxItems(itemsValue, at) {
    var items = normalizeInboxItems(itemsValue);
    var stamp = cleanStamp(at);
    Object.keys(items).forEach(function (key) {
        var row = items[key];
        if (!row.canSettle || row.lifecycle !== "unsettled")
            return;
        var copy = {};
        Object.keys(row).forEach(function (field) { copy[field] = row[field]; });
        copy.lifecycle = "settled";
        copy.settledAt = stamp || row.noticedAt || row.at;
        items[key] = copy;
    });
    return pruneSettledInbox(items, MAX_SETTLED_INBOX_ITEMS);
}

function removeInboxSources(itemsValue, revisionsValue, prefix) {
    var items = normalizeInboxItems(itemsValue);
    var revisions = normalizeSourceRevisions(revisionsValue);
    var wanted = typeof prefix === "string" ? prefix : "";
    Object.keys(revisions).forEach(function (source) {
        if (source.indexOf(wanted) === 0)
            delete revisions[source];
    });
    Object.keys(items).forEach(function (key) {
        if (items[key].source.indexOf(wanted) === 0 && items[key].lifecycle === "active")
            delete items[key];
    });
    return { items: items, sourceRevisions: revisions };
}

function inboxRows(itemsValue, seenAt) {
    var watermark = cleanStamp(seenAt);
    var items = normalizeInboxItems(itemsValue);
    return Object.keys(items).map(function (key) {
        var row = {};
        Object.keys(items[key]).forEach(function (field) { row[field] = items[key][field]; });
        row.unread = row.lifecycle === "unsettled" && watermark !== ""
            && row.noticedAt !== "" && row.noticedAt > watermark;
        return row;
    });
}

function inboxSort(a, b) {
    if (!!a.unread !== !!b.unread)
        return a.unread ? -1 : 1;
    var severity = toneSeverity(b.tone) - toneSeverity(a.tone);
    if (severity !== 0)
        return severity;
    var stampA = a.lifecycle === "settled" ? a.settledAt : a.at;
    var stampB = b.lifecycle === "settled" ? b.settledAt : b.at;
    var byTime = Date.parse(stampB || "") - Date.parse(stampA || "");
    if (isFinite(byTime) && byTime !== 0)
        return byTime;
    return a.key.localeCompare(b.key);
}

function inboxSections(rows) {
    var groups = { active: [], attention: [], updates: [], settled: [] };
    (Array.isArray(rows) ? rows : []).forEach(function (row) {
        if (!row || typeof row.key !== "string")
            return;
        if (row.lifecycle === "active")
            groups.active.push(row);
        else if (row.lifecycle === "settled")
            groups.settled.push(row);
        else if (row.attention)
            groups.attention.push(row);
        else
            groups.updates.push(row);
    });
    Object.keys(groups).forEach(function (key) { groups[key].sort(inboxSort); });
    return [
        { id: "active", title: "Active", rows: groups.active },
        { id: "attention", title: "Attention", rows: groups.attention },
        { id: "updates", title: "Updates", rows: groups.updates },
        { id: "settled", title: "Settled", rows: groups.settled }
    ];
}

// ---- keyed popover lists ------------------------------------------------
// The popover's Repeaters read their model out of a JSON string of row keys:
// a string property only notifies when the keys or their order really
// change, so a changed status updates a delegate in place instead of
// recreating it (and its hover and keyboard focus). Delegates look their live
// row up by key.
var INBOX_SECTION_IDS = ["active", "attention", "updates", "settled"];

function listKey(rows, field) {
    return JSON.stringify((Array.isArray(rows) ? rows : []).map(function (row) {
        return row && typeof row[field] === "string" ? row[field] : "";
    }));
}

// The keys a listKey names; a malformed key names none.
function listIds(key) {
    try {
        var ids = JSON.parse(key);
        return Array.isArray(ids) ? ids.filter(function (id) {
            return typeof id === "string";
        }) : [];
    } catch (e) {
        return [];
    }
}

function rowIndex(rows, field) {
    var index = {};
    (Array.isArray(rows) ? rows : []).forEach(function (row) {
        if (row && typeof row[field] === "string" && index[row[field]] === undefined)
            index[row[field]] = row;
    });
    return index;
}

function inboxSectionFor(sections, id) {
    var list = Array.isArray(sections) ? sections : [];
    for (var i = 0; i < list.length; i++) {
        if (list[i] && list[i].id === id)
            return list[i];
    }
    return { id: id, title: "", rows: [] };
}

// A delegate can briefly outlive its row between the rows and their key
// updating, so a missing key reads as an inert, settled, unlinked row rather
// than undefined.
function inboxRowFor(index, key) {
    var row = index && typeof index === "object" ? index[key] : undefined;
    if (row)
        return row;
    return {
        id: key, key: key, kind: "", repo: "", title: "", detail: "", status: "",
        conclusion: "", active: false, attention: false, tone: "muted", unread: false,
        lifecycle: "settled", noticedAt: "", settledAt: "", canSettle: false,
        at: "", url: "", missing: true
    };
}

function repoFor(index, slug) {
    var row = index && typeof index === "object" ? index[slug] : undefined;
    if (row)
        return row;
    var parts = typeof slug === "string" ? slug.split("/") : [];
    return {
        slug: typeof slug === "string" ? slug : "", owner: parts[0] || "",
        name: parts[1] || "", pushedAt: "", isPrivate: false, archived: false,
        branch: "", watched: false, account: true, missing: true
    };
}

function inboxCounts(rows) {
    var counts = { running: 0, attention: 0, updates: 0, pending: 0, settled: 0,
        unread: 0 };
    (Array.isArray(rows) ? rows : []).forEach(function (row) {
        if (!row)
            return;
        if (row.lifecycle === "active") {
            counts.running++;
            return;
        }
        if (row.lifecycle === "settled") {
            counts.settled++;
            return;
        }
        if (!row.canSettle)
            return;
        counts.pending++;
        if (row.attention)
            counts.attention++;
        else
            counts.updates++;
        if (row.unread)
            counts.unread++;
    });
    return counts;
}

function inboxBadgeTone(rows) {
    var pending = (Array.isArray(rows) ? rows : []).filter(function (row) {
        return row && row.canSettle && row.lifecycle === "unsettled";
    });
    if (pending.some(function (row) { return row.tone === "red"; }))
        return "red";
    if (pending.some(function (row) { return row.attention || row.tone === "amber"; }))
        return "amber";
    return pending.length > 0 ? "accent" : "none";
}

// A failed repository read patches only its error field. Its previous rows
// survive and remain useful until that one endpoint recovers.
function patchRunCache(cache, repo, rows, error, at) {
    var next = {};
    var source = cache && typeof cache === "object" ? cache : {};
    Object.keys(source).forEach(function (key) { next[key] = source[key]; });
    var previous = source[repo] && typeof source[repo] === "object"
        ? source[repo] : { rows: [], error: "", at: 0 };
    next[repo] = {
        rows: Array.isArray(rows) ? rows : Array.isArray(previous.rows) ? previous.rows : [],
        error: typeof error === "string" ? error : "",
        at: typeof at === "number" && isFinite(at) ? at : previous.at || 0
    };
    return next;
}

function patchSourceCache(cache, repo, rows, error, at) {
    return patchRunCache(cache, repo, rows, error, at);
}

function flattenRunCache(cache) {
    var out = [];
    var source = cache && typeof cache === "object" ? cache : {};
    Object.keys(source).forEach(function (repo) {
        var entry = source[repo];
        if (entry && Array.isArray(entry.rows))
            out = out.concat(entry.rows);
    });
    return dedupeActivities(out);
}

function isToastableRun(row) {
    var conclusion = lower(row && row.conclusion);
    return row && row.kind === "run"
        && (FAILURE_CONCLUSIONS[conclusion] || conclusion === "action_required");
}

function runAttemptKey(row) {
    return String(row.runId || "") + ":" + positiveInt(row.attempt, 1);
}

function baselineState(row) {
    if (row.active)
        return "active";
    if (isToastableRun(row))
        return "alert";
    return "done";
}

function normalizeRunBaselines(value) {
    var out = {};
    if (!value || typeof value !== "object" || Array.isArray(value))
        return out;
    Object.keys(value).slice(0, MAX_BASELINE_REPOS).forEach(function (repo) {
        if (repoSlug(repo) === "" || !value[repo] || typeof value[repo] !== "object"
                || Array.isArray(value[repo]))
            return;
        var attempts = {};
        Object.keys(value[repo]).slice(0, MAX_BASELINE_ATTEMPTS).forEach(function (key) {
            var entry = value[repo][key];
            var state = typeof entry === "string" ? entry
                : entry && typeof entry.s === "string" ? entry.s : "";
            var stamp = entry && typeof entry === "object" && typeof entry.at === "string"
                ? entry.at : "";
            if (state === "active" || state === "alert" || state === "done")
                attempts[key] = { s: state, at: stamp };
        });
        out[repo] = attempts;
    });
    return out;
}

// Advances just the repositories represented by `rows`; other baselines are
// retained for partial and fast sweeps. A repository with no previous entry
// establishes a silent baseline independently, which also makes adding an old
// watched repository safe after the global first run.
function advanceRunBaselines(value, rows, silent) {
    var previous = normalizeRunBaselines(value);
    var next = {};
    Object.keys(previous).forEach(function (repo) { next[repo] = previous[repo]; });
    var grouped = {};
    (Array.isArray(rows) ? rows : []).forEach(function (row) {
        if (!row || row.kind !== "run" || repoSlug(row.repo) === "")
            return;
        if (!grouped[row.repo])
            grouped[row.repo] = [];
        grouped[row.repo].push(row);
    });
    var transitions = [];
    Object.keys(grouped).forEach(function (repo) {
        var knownRepo = Object.prototype.hasOwnProperty.call(previous, repo);
        var old = previous[repo] || {};
        var attempts = {};
        grouped[repo].slice().sort(function (a, b) { return atMs(b) - atMs(a); })
            .forEach(function (row) {
                if (Object.keys(attempts).length >= MAX_BASELINE_ATTEMPTS)
                    return;
                var key = runAttemptKey(row);
                var state = baselineState(row);
                var oldEntry = old[key];
                var oldState = typeof oldEntry === "string" ? oldEntry
                    : oldEntry && oldEntry.s;
                if (!silent && knownRepo && state === "alert" && oldState !== "alert")
                    transitions.push(row);
                attempts[key] = { s: state, at: row.at || "" };
            });
        Object.keys(old).forEach(function (key) {
            if (attempts[key] === undefined
                    && Object.keys(attempts).length < MAX_BASELINE_ATTEMPTS)
                attempts[key] = old[key];
        });
        next[repo] = attempts;
    });

    // Scope changes can accumulate old repository keys forever; retain the
    // repositories touched now first, then the newest remaining baseline set.
    var bounded = {};
    Object.keys(grouped).concat(Object.keys(next)).forEach(function (repo) {
        if (bounded[repo] !== undefined || Object.keys(bounded).length >= MAX_BASELINE_REPOS)
            return;
        bounded[repo] = next[repo];
    });
    return { baselines: bounded, transitions: dedupeActivities(transitions) };
}

function coalescedFailureToast(rows) {
    var failures = dedupeActivities(Array.isArray(rows) ? rows : [])
        .filter(isToastableRun).sort(activitySort);
    if (failures.length === 0)
        return null;
    if (failures.length === 1) {
        var row = failures[0];
        return {
            summary: row.repo + " — " + runStatusLabel(row.status, row.conclusion),
            body: row.title + (row.detail !== "" ? " · " + row.detail : "")
        };
    }
    return {
        summary: failures.length + " workflows need attention",
        body: failures.slice(0, 3).map(function (row) {
            return row.repo + " · " + row.title;
        }).join("\n") + (failures.length > 3 ? "\n+" + (failures.length - 3) + " more" : "")
    };
}

function activityBackoffMs(failures) {
    var count = typeof failures === "number" && isFinite(failures)
        ? Math.max(1, Math.floor(failures)) : 1;
    return Math.min(15 * MINUTE_MS, MINUTE_MS * Math.pow(2, Math.min(4, count - 1)));
}

function globalActivityFailure(exitCode, text) {
    var error = typeof text === "string" ? text.toLowerCase() : "";
    if (exitCode === -1 || exitCode === 127)
        return true;
    return /not logged|not authenticated|authentication|bad credentials|http 401|requires authentication|gh auth login|no oauth token/.test(error)
        || /rate limit|http 429|secondary rate/.test(error)
        || /could not resolve|network|failed to connect|error connecting|connection (?:refused|reset|failed)|timed? out|tls|dns/.test(error);
}

function inboxBackoffMs(failures) {
    return activityBackoffMs(failures);
}

function globalInboxFailure(exitCode, text) {
    return globalActivityFailure(exitCode, text);
}

function githubTooltip(running, attention, repos) {
    var parts = [];
    if (running > 0)
        parts.push(running + (running === 1 ? " workflow running" : " workflows running"));
    if (attention > 0)
        parts.push(attention + (attention === 1 ? " pending Inbox item"
            : " pending Inbox items"));
    if (repos > 0)
        parts.push(repos + (repos === 1 ? " updated repository" : " updated repositories"));
    return parts.length === 0 ? "GitHub" : "GitHub · " + parts.join(" · ");
}

var exported = {
    MAX_WATCH: MAX_WATCH,
    MAX_COMMITS: MAX_COMMITS,
    MAX_RUNS: MAX_RUNS,
    MAX_ACTIVITY_ROWS: MAX_ACTIVITY_ROWS,
    MAX_SETTLED_INBOX_ITEMS: MAX_SETTLED_INBOX_ITEMS,
    MAX_INBOX_SOURCES: MAX_INBOX_SOURCES,
    MAX_SOURCE_REVISIONS: MAX_SOURCE_REVISIONS,
    MAX_ACTIVE_REPOS: MAX_ACTIVE_REPOS,
    MAX_BASELINE_ATTEMPTS: MAX_BASELINE_ATTEMPTS,
    MAX_BASELINE_REPOS: MAX_BASELINE_REPOS,
    REPOS_MIN: REPOS_MIN,
    REPOS_MAX: REPOS_MAX,
    POLL_MIN: POLL_MIN,
    POLL_MAX: POLL_MAX,
    BADGE_MODES: BADGE_MODES,
    GITHUB_QUERIES: GITHUB_QUERIES,
    repoSlug: repoSlug,
    normalizeWatch: normalizeWatch,
    parseRepos: parseRepos,
    parseRepo: parseRepo,
    parseLogin: parseLogin,
    sortRepos: sortRepos,
    mergeRepos: mergeRepos,
    displayedRepos: displayedRepos,
    monitoredScope: monitoredScope,
    orgCount: orgCount,
    unreadRepos: unreadRepos,
    parseCommits: parseCommits,
    parseCommitStats: parseCommitStats,
    newCommits: newCommits,
    subject: subject,
    messageBody: messageBody,
    relTime: relTime,
    calendarDaysAgo: calendarDaysAgo,
    recencyBucket: recencyBucket,
    bucketBreak: bucketBreak,
    agoLabel: agoLabel,
    agoLabelIso: agoLabelIso,
    pushToast: pushToast,
    runClassification: runClassification,
    runStatusLabel: runStatusLabel,
    parseRuns: parseRuns,
    notificationReasonIncluded: notificationReasonIncluded,
    notificationReasonLabel: notificationReasonLabel,
    apiToBrowserUrl: apiToBrowserUrl,
    parseNotifications: parseNotifications,
    eventRow: eventRow,
    parseEvents: parseEvents,
    newestEntityRows: newestEntityRows,
    parseIncludedResponse: parseIncludedResponse,
    includedResponseOk: includedResponseOk,
    normalizeEventEtags: normalizeEventEtags,
    normalizeEventPollIntervals: normalizeEventPollIntervals,
    normalizeEtag: normalizeEtag,
    normalizeHttpDate: normalizeHttpDate,
    CONDITIONAL_KINDS: CONDITIONAL_KINDS,
    conditionalArgs: conditionalArgs,
    notModifiedResponse: notModifiedResponse,
    RATE_LIMIT_FLOOR: RATE_LIMIT_FLOOR,
    rateLimitPause: rateLimitPause,
    rateLimitMessage: rateLimitMessage,
    nextPollInterval: nextPollInterval,
    POLL_SLACK_MS: POLL_SLACK_MS,
    pollDue: pollDue,
    GH_TIMEOUT_MS: GH_TIMEOUT_MS,
    GH_INTERACTIVE_TIMEOUT_MS: GH_INTERACTIVE_TIMEOUT_MS,
    GH_KILL_GRACE_MS: GH_KILL_GRACE_MS,
    GH_TIMEOUT_EXIT: GH_TIMEOUT_EXIT,
    ghTimeoutMs: ghTimeoutMs,
    ghTimeoutMessage: ghTimeoutMessage,
    toneSeverity: toneSeverity,
    dedupeActivities: dedupeActivities,
    withActivityUnread: withActivityUnread,
    unseenActivities: unseenActivities,
    activitySections: activitySections,
    prioritizeActivities: prioritizeActivities,
    combineActivities: combineActivities,
    activityCounts: activityCounts,
    combinedUnreadCount: combinedUnreadCount,
    badgeTone: badgeTone,
    durationLabel: durationLabel,
    elapsedLabel: durationLabel,
    activityTimeLabel: activityTimeLabel,
    inboxTimeLabel: inboxTimeLabel,
    runElapsedLabel: activityTimeLabel,
    activeRepositories: activeRepositories,
    inboxSourceForRow: inboxSourceForRow,
    normalizeInboxSnapshot: normalizeInboxSnapshot,
    normalizeInboxItems: normalizeInboxItems,
    compactInboxItems: compactInboxItems,
    normalizeSourceRevisions: normalizeSourceRevisions,
    reconcileInboxSource: reconcileInboxSource,
    setInboxSettlement: setInboxSettlement,
    settleAllInboxItems: settleAllInboxItems,
    removeInboxSources: removeInboxSources,
    inboxRows: inboxRows,
    inboxSections: inboxSections,
    INBOX_SECTION_IDS: INBOX_SECTION_IDS,
    listKey: listKey,
    listIds: listIds,
    rowIndex: rowIndex,
    inboxSectionFor: inboxSectionFor,
    inboxRowFor: inboxRowFor,
    repoFor: repoFor,
    inboxCounts: inboxCounts,
    inboxBadgeTone: inboxBadgeTone,
    patchRunCache: patchRunCache,
    patchSourceCache: patchSourceCache,
    flattenRunCache: flattenRunCache,
    isToastableRun: isToastableRun,
    runAttemptKey: runAttemptKey,
    normalizeRunBaselines: normalizeRunBaselines,
    advanceRunBaselines: advanceRunBaselines,
    coalescedFailureToast: coalescedFailureToast,
    activityBackoffMs: activityBackoffMs,
    inboxBackoffMs: inboxBackoffMs,
    globalActivityFailure: globalActivityFailure,
    globalInboxFailure: globalInboxFailure,
    githubTooltip: githubTooltip
};

if (typeof module !== "undefined" && module.exports)
    module.exports = exported;
