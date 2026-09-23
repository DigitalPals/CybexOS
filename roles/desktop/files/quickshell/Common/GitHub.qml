pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "GitHubHelpers.js" as Helpers
import "ProcHelpers.js" as ProcHelpers
import "ExternalUrl.js" as ExternalUrl

// Read-only GitHub repository and Inbox feeds, backed by the authenticated
// gh CLI. Interactive commit/stat reads and background discovery share one
// serialized queue; interactive jobs are inserted ahead of polling work.
Singleton {
    id: root

    readonly property var opts: Settings.modOpts.gh
    readonly property var watch: Helpers.normalizeWatch(opts.watch)
    readonly property string watchKey: watch.join(",")
    readonly property int pollMins: opts.pollMins
    readonly property bool ciReportsEnabled: opts.ciActivity
    readonly property bool toastsEnabled: opts.toasts

    readonly property bool pollEnabled: {
        const mods = Settings.mods;
        for (const col of ["left", "center", "right"]) {
            const hit = mods[col].find(m => m.id === "gh");
            if (hit)
                return hit.on;
        }
        return false;
    }

    // ---- repository state ------------------------------------------------
    property var repos: []
    property string login: ""
    property int orgCount: 0
    property string error: ""
    property double checkedAt: 0
    property bool polling: false
    property bool ready: false
    // A typo, removed repository, or inaccessible private watch is isolated
    // here rather than turning the account repository feed into an error.
    property var watchErrors: ({})

    property var commitCache: ({})
    property var statsCache: ({})
    readonly property int commitCacheMs: 60000

    // ---- Inbox state -----------------------------------------------------
    // `inboxState` is the compact persisted record. `inboxItems` is its safe,
    // rendered projection with view-based unread emphasis applied.
    property var inboxState: ({})
    property var inboxItems: []
    property var inboxSourceRevisions: ({})
    property var runCache: ({})
    property var eventCache: ({})
    property var notificationRows: []
    property string notificationError: ""
    property var workflowRepoErrors: ({})
    property var eventRepoErrors: ({})
    property var inboxRepoErrors: ({})
    property bool inboxReady: false
    property bool inboxPolling: false
    property double inboxCheckedAt: 0
    // Global auth/network/rate-limit failures pause a sweep. Endpoint-specific
    // failures remain in the notification/repository error maps instead.
    property string inboxError: ""
    property int inboxFailureCount: 0
    property double inboxBackoffUntil: 0
    property string lastInboxLogged: ""

    // Conditional repository-event polling metadata. ETags and intervals are
    // persisted; absolute next-poll times are process-local.
    property var eventEtags: ({})
    property var eventPollIntervals: ({})
    property var eventNextPollAt: ({})

    readonly property var monitoredRepos: Helpers.monitoredScope(repos, opts.repos, watch)
    readonly property string monitoredKey: monitoredRepos.join(",")
    property int scopeGeneration: 0

    readonly property int runningCount: Helpers.inboxCounts(inboxItems).running
    readonly property int inboxAttentionCount: Helpers.inboxCounts(inboxItems).attention
    readonly property int inboxUpdateCount: Helpers.inboxCounts(inboxItems).updates
    readonly property int pendingInboxCount: Helpers.inboxCounts(inboxItems).pending
    readonly property int settledInboxCount: Helpers.inboxCounts(inboxItems).settled
    readonly property int unreadInboxCount: Helpers.inboxCounts(inboxItems).unread

    // ---- local acknowledgement ------------------------------------------
    property string seenAt: ""
    property string activitySeenAt: ""
    readonly property var unread: Helpers.unreadRepos(
        Helpers.displayedRepos(repos, opts.repos), seenAt)
    readonly property int unreadRepoCount: unread.length

    readonly property string badgeMode: opts.badge
    readonly property string badgeTone: Helpers.inboxBadgeTone(inboxItems)
    readonly property bool badgeVisible: badgeMode !== "off" && pendingInboxCount > 0

    function repoUrl(slug) {
        return "https://github.com/" + slug;
    }

    function open(url) {
        const safe = ExternalUrl.safeHttpUrl(url);
        if (safe !== "")
            Quickshell.execDetached(["xdg-open", safe]);
    }

    function copy(text) {
        if (typeof text === "string" && text !== "")
            Quickshell.execDetached(["wl-copy", text]);
    }

    function nowIso() {
        return new Date().toISOString();
    }

    function markSeen() {
        const stamp = nowIso();
        seenAt = stamp;
        activitySeenAt = stamp;
        publishInbox();
        persist();
    }

    function settleInboxItem(key) {
        inboxState = Helpers.setInboxSettlement(inboxState, key, true, nowIso());
        publishInbox();
        persist();
    }

    function settleAllInboxItems() {
        inboxState = Helpers.settleAllInboxItems(inboxState, nowIso());
        publishInbox();
        persist();
    }

    function unsettleInboxItem(key) {
        inboxState = Helpers.setInboxSettlement(inboxState, key, false, nowIso());
        publishInbox();
        persist();
    }

    // Push baselines are independent of local acknowledgement. Workflow run
    // baselines likewise suppress old/repeated failures across shell restarts.
    property var lastPush: ({})
    property var runBaselines: ({})

    function persist() {
        // FileView.adapter ids are absent from the shipped static type data.
        // qmllint disable unqualified
        stateData.seenAt = root.seenAt;
        stateData.activitySeenAt = root.activitySeenAt;
        stateData.lastPush = root.lastPush;
        stateData.runBaselines = root.runBaselines;
        stateData.inboxItems = Helpers.compactInboxItems(root.inboxState);
        stateData.inboxSourceRevisions = root.inboxSourceRevisions;
        stateData.eventEtags = root.eventEtags;
        stateData.eventPollIntervals = root.eventPollIntervals;
        // qmllint enable unqualified
        stateFile.writeAdapter();
    }

    FileView {
        id: stateFile
        path: Quickshell.env("HOME") + "/.local/state/cybexos/shell/github.json"
        printErrors: false
        blockLoading: true
        // qmllint disable unqualified
        onLoaded: {
            root.seenAt = typeof stateData.seenAt === "string" ? stateData.seenAt : "";
            root.activitySeenAt = typeof stateData.activitySeenAt === "string"
                ? stateData.activitySeenAt : "";
            root.lastPush = stateData.lastPush && typeof stateData.lastPush === "object"
                ? stateData.lastPush : ({});
            root.runBaselines = Helpers.normalizeRunBaselines(stateData.runBaselines);
            root.inboxState = Helpers.normalizeInboxItems(stateData.inboxItems);
            root.inboxSourceRevisions = Helpers.normalizeSourceRevisions(
                stateData.inboxSourceRevisions);
            root.eventEtags = Helpers.normalizeEventEtags(stateData.eventEtags);
            root.eventPollIntervals = Helpers.normalizeEventPollIntervals(
                stateData.eventPollIntervals);
            if (!root.ciReportsEnabled) {
                const reset = Helpers.removeInboxSources(root.inboxState,
                    root.inboxSourceRevisions, "workflows:");
                root.inboxState = reset.items;
                root.inboxSourceRevisions = reset.sourceRevisions;
                root.runBaselines = ({});
            }
            root.publishInbox();
        }
        // qmllint enable unqualified

        JsonAdapter {
            id: stateData
            property string seenAt: ""
            property string activitySeenAt: ""
            property var lastPush: ({})
            property var runBaselines: ({})
            property var inboxItems: ({})
            property var inboxSourceRevisions: ({})
            property var eventEtags: ({})
            property var eventPollIntervals: ({})
        }
    }

    // ---- serialized gh queue --------------------------------------------
    // Jobs are deduplicated by resource. The generation remains part of an
    // Inbox key so a replacement scope may wait behind an already-running
    // stale read without adopting its result.
    property var queue: []
    property var active: null

    function jobKey(job) {
        switch (job.kind) {
        case "watch": return "watch:" + job.slug;
        case "commits": return "commits:" + job.slug;
        case "stats": return "stats:" + job.sha;
        case "runs": return "runs:" + job.slug + ":" + job.generation;
        case "events": return "events:" + job.slug + ":" + job.generation;
        case "notifications": return "notifications:" + job.generation;
        default: return job.kind;
        }
    }

    function enqueue(job) {
        const key = jobKey(job);
        if (active !== null && jobKey(active) === key)
            return false;
        const queuedAt = queue.findIndex(queued => jobKey(queued) === key);
        if (queuedAt >= 0) {
            // A popover request can overlap a background toast/cache read.
            // Keep the richer existing job, but move it into the interactive
            // lane so deduplication never costs the user's priority.
            if (job.interactive === true && !queue[queuedAt].interactive) {
                const promoted = Object.assign({}, queue[queuedAt], { interactive: true });
                const without = queue.slice(0, queuedAt).concat(queue.slice(queuedAt + 1));
                const firstBackground = without.findIndex(queued => !queued.interactive);
                const at = firstBackground < 0 ? without.length : firstBackground;
                queue = without.slice(0, at).concat([promoted], without.slice(at));
            }
            return false;
        }
        const next = Object.assign({}, job, { interactive: job.interactive === true });
        if (!next.interactive) {
            queue = queue.concat([next]);
        } else {
            const firstBackground = queue.findIndex(queued => !queued.interactive);
            const at = firstBackground < 0 ? queue.length : firstBackground;
            queue = queue.slice(0, at).concat([next], queue.slice(at));
        }
        pump();
        return true;
    }

    function pump() {
        if (active !== null || queue.length === 0 || ghProc.running)
            return;
        // Disabling the module drops background work. An already-running gh
        // command is allowed to finish, but its stale Inbox result is ignored.
        if (!pollEnabled && !queue[0].interactive) {
            queue = queue.slice(1);
            pump();
            return;
        }
        const job = queue[0];
        queue = queue.slice(1);
        active = job;
        const query = Helpers.GITHUB_QUERIES[job.kind === "watch" ? "repo"
            : job.kind === "stats" ? "commit" : job.kind];
        const path = query.path.replace("{repo}", job.slug ?? "")
            .replace("{sha}", job.sha ?? "");
        let command = ["gh", "api", path];
        if (job.kind === "events") {
            command.push("--include");
            const source = "events:" + job.slug.toLowerCase();
            const etag = Object.prototype.hasOwnProperty.call(inboxSourceRevisions, source)
                ? (eventEtags[job.slug.toLowerCase()] ?? "") : "";
            if (etag !== "")
                command.push("-H", "If-None-Match: " + etag);
        }
        command.push("--jq", query.jq);
        ghProc.command = command;
        ghProc.running = true;
    }

    // ---- repository discovery -------------------------------------------
    property var ownRepos: []
    property var extraRepos: []
    property int pendingWatch: 0
    property var nextWatchErrors: ({})
    property string lastLogged: ""

    function refresh() {
        if (!pollEnabled || polling)
            return;
        polling = true;
        ownRepos = [];
        extraRepos = [];
        pendingWatch = 0;
        nextWatchErrors = ({});
        if (login === "")
            enqueue({ kind: "login" });
        enqueue({ kind: "repos" });
    }

    function refreshAll() {
        inboxBackoffUntil = 0;
        refresh();
        refreshInbox(true);
    }

    function refreshIfStale(maxAgeMs) {
        if (checkedAt <= 0 || Date.now() - checkedAt > maxAgeMs)
            refresh();
        if (inboxCheckedAt <= 0 || Date.now() - inboxCheckedAt > maxAgeMs)
            refreshInbox(false);
    }

    function failPoll(label, exitCode, errText) {
        error = ProcHelpers.commandError(label, exitCode, errText);
        polling = false;
        pendingWatch = 0;
        checkedAt = Date.now();
        if (error !== lastLogged) {
            console.warn("github:", error);
            lastLogged = error;
        }
    }

    function fanOutWatched() {
        const known = {};
        ownRepos.forEach(row => known[row.slug.toLowerCase()] = true);
        const missing = watch.filter(slug => !known[slug.toLowerCase()]);
        pendingWatch = missing.length;
        if (pendingWatch === 0) {
            publishRepos();
            return;
        }
        missing.forEach(slug => enqueue({ kind: "watch", slug: slug }));
    }

    function patchNextWatchError(slug, message) {
        const next = {};
        Object.keys(nextWatchErrors).forEach(key => next[key] = nextWatchErrors[key]);
        if (message !== "")
            next[slug] = message;
        nextWatchErrors = next;
    }

    function publishRepos() {
        repos = Helpers.mergeRepos(ownRepos, extraRepos, watch);
        watchErrors = nextWatchErrors;
        orgCount = Helpers.orgCount(ownRepos, login);
        checkedAt = Date.now();
        error = "";
        lastLogged = "";
        polling = false;
        const first = !ready;
        ready = true;
        if (seenAt === "") {
            seenAt = nowIso();
            queuePushToasts(true);
        } else {
            queuePushToasts(false);
        }
        // The first usable repository scope should not wait for the next
        // 60-second Inbox tick.
        if (first)
            refreshInbox(true);
    }

    function queuePushToasts(silent) {
        const seen = lastPush ?? ({});
        const next = {};
        for (const row of repos) {
            if (!row.watched)
                continue;
            const previous = seen[row.slug];
            next[row.slug] = row.pushedAt;
            if (silent || !toastsEnabled || previous === undefined
                    || row.pushedAt === "" || row.pushedAt <= previous)
                continue;
            enqueue({ kind: "commits", slug: row.slug, toast: true,
                since: previous, interactive: false });
        }
        lastPush = next;
        persist();
    }

    // ---- Inbox discovery ------------------------------------------------
    property int inboxSweepSeq: 0
    property var inboxSweep: null

    function publishInbox() {
        const workflowErrors = {};
        const repositoryEventErrors = {};
        for (const slug of monitoredRepos) {
            const workflow = runCache[slug];
            const events = eventCache[slug];
            if (ciReportsEnabled && workflow && workflow.error)
                workflowErrors[slug] = workflow.error;
            if (events && events.error)
                repositoryEventErrors[slug] = events.error;
        }
        const combined = {};
        for (const slug of Object.keys(workflowErrors))
            combined[slug] = workflowErrors[slug];
        for (const slug of Object.keys(repositoryEventErrors))
            combined[slug] = combined[slug]
                ? combined[slug] + " · " + repositoryEventErrors[slug]
                : repositoryEventErrors[slug];
        workflowRepoErrors = workflowErrors;
        eventRepoErrors = repositoryEventErrors;
        inboxRepoErrors = combined;
        inboxItems = Helpers.inboxRows(inboxState, activitySeenAt);
    }

    function dropStaleActiveItems() {
        const allowed = {};
        if (ciReportsEnabled) {
            for (const slug of monitoredRepos)
                allowed["workflows:" + slug.toLowerCase()] = true;
        }
        const next = Helpers.normalizeInboxItems(inboxState);
        for (const key of Object.keys(next)) {
            if (next[key].lifecycle === "active" && !allowed[next[key].source])
                delete next[key];
        }
        inboxState = next;
    }

    function invalidateInboxScope() {
        scopeGeneration++;
        queue = queue.filter(job => job.kind !== "runs" && job.kind !== "events"
            && job.kind !== "notifications");
        inboxSweep = null;
        inboxPolling = false;
        dropStaleActiveItems();
        publishInbox();
    }

    function refreshInbox(force) {
        if (!pollEnabled || !ready || inboxPolling)
            return;
        if (!force && inboxBackoffUntil > Date.now())
            return;
        startInboxSweep(monitoredRepos, true);
    }

    function refreshActiveInbox() {
        if (!pollEnabled || !ciReportsEnabled || inboxPolling
                || inboxBackoffUntil > Date.now())
            return;
        const activeRepos = Helpers.activeRepositories(inboxItems, Helpers.MAX_ACTIVE_REPOS);
        if (activeRepos.length > 0)
            startInboxSweep(activeRepos, false);
    }

    function eventPollDue(slug, now) {
        return (eventNextPollAt[slug.toLowerCase()] ?? 0) <= now;
    }

    function startInboxSweep(slugs, full) {
        inboxSweepSeq++;
        const sweep = {
            id: inboxSweepSeq,
            generation: scopeGeneration,
            pending: 0,
            transitions: [],
            anySuccess: false,
            full: full
        };
        inboxSweep = sweep;
        inboxPolling = true;
        const jobs = [];
        if (ciReportsEnabled) {
            for (const slug of slugs)
                jobs.push({ kind: "runs", slug: slug });
        }
        if (full) {
            const now = Date.now();
            for (const slug of slugs) {
                if (eventPollDue(slug, now))
                    jobs.push({ kind: "events", slug: slug });
            }
            jobs.push({ kind: "notifications" });
        }
        for (const job of jobs) {
            if (enqueue(Object.assign({}, job, { sweep: sweep.id,
                    generation: sweep.generation, interactive: false })))
                sweep.pending++;
        }
        if (sweep.pending === 0)
            finishInboxSweep();
    }

    function finishInboxJob() {
        if (inboxSweep === null)
            return;
        inboxSweep.pending = Math.max(0, inboxSweep.pending - 1);
        if (inboxSweep.pending === 0)
            finishInboxSweep();
    }

    function finishInboxSweep() {
        const sweep = inboxSweep;
        inboxSweep = null;
        inboxPolling = false;
        if (sweep === null || sweep.generation !== scopeGeneration)
            return;
        inboxCheckedAt = Date.now();
        if (sweep.anySuccess)
            inboxReady = true;
        inboxError = "";
        lastInboxLogged = "";
        inboxFailureCount = 0;
        inboxBackoffUntil = 0;
        // A migration/fresh install sees each source as settled. The legacy
        // view watermark is advanced too, preventing an unread-emphasis flood.
        if (activitySeenAt === "" && sweep.anySuccess)
            activitySeenAt = nowIso();
        publishInbox();
        if (toastsEnabled && sweep.transitions.length > 0)
            raiseWorkflowToast(sweep.transitions);
        persist();
    }

    function failInboxSweep(label, exitCode, errText) {
        const sweep = inboxSweep;
        if (sweep === null)
            return;
        inboxError = ProcHelpers.commandError(label, exitCode, errText);
        inboxFailureCount++;
        inboxBackoffUntil = Date.now() + Helpers.inboxBackoffMs(inboxFailureCount);
        inboxCheckedAt = Date.now();
        inboxReady = inboxReady || sweep.anySuccess;
        queue = queue.filter(job => job.sweep !== sweep.id);
        inboxSweep = null;
        inboxPolling = false;
        publishInbox();
        persist();
        if (inboxError !== lastInboxLogged) {
            console.warn("github inbox:", inboxError);
            lastInboxLogged = inboxError;
        }
    }

    function reconcileInboxRows(source, rows) {
        const reconciled = Helpers.reconcileInboxSource(inboxState,
            inboxSourceRevisions, source, rows, nowIso());
        inboxState = reconciled.items;
        inboxSourceRevisions = reconciled.sourceRevisions;
        publishInbox();
    }

    function patchRunResult(slug, rows, message) {
        runCache = Helpers.patchSourceCache(runCache, slug, rows, message, Date.now());
        publishInbox();
    }

    function patchEventResult(slug, rows, message) {
        eventCache = Helpers.patchSourceCache(eventCache, slug, rows, message, Date.now());
        publishInbox();
    }

    function updateEventPolling(slug, response) {
        const key = slug.toLowerCase();
        const etags = Helpers.normalizeEventEtags(eventEtags);
        const intervals = Helpers.normalizeEventPollIntervals(eventPollIntervals);
        const nextPolls = Object.assign({}, eventNextPollAt);
        if (response.etag !== "")
            etags[key] = response.etag;
        const interval = response.pollIntervalMs > 0 ? response.pollIntervalMs
            : (intervals[key] ?? 60000);
        intervals[key] = interval;
        nextPolls[key] = Date.now() + interval;
        eventEtags = etags;
        eventPollIntervals = intervals;
        eventNextPollAt = nextPolls;
    }

    function settleInbox(job, exitCode, body, errText) {
        if (job.generation !== scopeGeneration || inboxSweep === null
                || job.sweep !== inboxSweep.id) {
            return;
        }
        const commandFailed = exitCode !== 0;
        const included = job.kind === "events"
            ? (Helpers.parseIncludedResponse(body)
                ?? Helpers.parseIncludedResponse(errText)) : null;
        const notModified = job.kind === "events" && ((included !== null
            && included.notModified) || (commandFailed && /\bHTTP 304\b/i.test(errText)));
        const failureText = errText + (included !== null ? " HTTP " + included.status : "");
        if (!notModified && commandFailed
                && Helpers.globalInboxFailure(exitCode, failureText)) {
            failInboxSweep("gh api Inbox", exitCode, failureText);
            return;
        }

        if (job.kind === "runs") {
            const rows = commandFailed ? null : Helpers.parseRuns(body, job.slug);
            if (rows === null) {
                const message = commandFailed
                    ? ProcHelpers.commandError("gh api Actions", exitCode, errText)
                    : "GitHub returned malformed workflow data";
                patchRunResult(job.slug, null, message);
            } else {
                const source = "workflows:" + job.slug.toLowerCase();
                const sourceWasKnown = Object.prototype.hasOwnProperty.call(
                    inboxSourceRevisions, source);
                patchRunResult(job.slug, rows, "");
                const advanced = Helpers.advanceRunBaselines(runBaselines, rows,
                    !sourceWasKnown);
                runBaselines = advanced.baselines;
                inboxSweep.transitions = inboxSweep.transitions.concat(advanced.transitions);
                reconcileInboxRows(source, rows);
                inboxSweep.anySuccess = true;
            }
        } else if (job.kind === "events") {
            if (included !== null)
                updateEventPolling(job.slug, included);
            if (notModified) {
                patchEventResult(job.slug, null, "");
                inboxSweep.anySuccess = true;
            } else if (!Helpers.includedResponseOk(included, exitCode)) {
                const message = commandFailed
                    ? ProcHelpers.commandError("gh api repository events", exitCode, failureText)
                    : "GitHub returned malformed repository-event headers";
                patchEventResult(job.slug, null, message);
            } else {
                const rows = Helpers.parseEvents(included.body, job.slug);
                if (rows === null) {
                    patchEventResult(job.slug, null,
                        "GitHub returned malformed repository-event data");
                } else {
                    patchEventResult(job.slug, rows, "");
                    reconcileInboxRows("events:" + job.slug.toLowerCase(), rows);
                    inboxSweep.anySuccess = true;
                }
            }
        } else {
            const rows = commandFailed ? null : Helpers.parseNotifications(body);
            if (rows === null) {
                notificationError = commandFailed
                    ? ProcHelpers.commandError("gh api notifications", exitCode, errText)
                    : "GitHub returned malformed notification data";
            } else {
                notificationRows = rows;
                notificationError = "";
                reconcileInboxRows("notifications", rows);
                inboxSweep.anySuccess = true;
            }
        }
        finishInboxJob();
    }

    function watchError(slug) {
        const wanted = typeof slug === "string" ? slug.toLowerCase() : "";
        for (const key of Object.keys(watchErrors)) {
            if (key.toLowerCase() === wanted)
                return watchErrors[key];
        }
        for (const key of Object.keys(inboxRepoErrors)) {
            if (key.toLowerCase() === wanted)
                return inboxRepoErrors[key];
        }
        return "";
    }

    // ---- interactive commits --------------------------------------------
    function commitsFor(slug) {
        return commitCache[slug] ?? null;
    }

    function requestCommits(slug, force) {
        if (typeof slug !== "string" || slug === "")
            return;
        const cached = commitCache[slug];
        if (!force && cached && cached.error === ""
                && Date.now() - cached.at < commitCacheMs)
            return;
        if (active !== null && active.kind === "commits" && active.slug === slug)
            return;
        patchCommits(slug, { rows: cached ? cached.rows : [], error: "", loading: true,
            at: cached ? cached.at : 0 });
        enqueue({ kind: "commits", slug: slug, toast: false, since: "",
            interactive: true });
    }

    function patchCommits(slug, entry) {
        const next = {};
        Object.keys(commitCache).forEach(key => next[key] = commitCache[key]);
        next[slug] = entry;
        commitCache = next;
    }

    function statsFor(sha) {
        return statsCache[sha] ?? null;
    }

    function requestStats(slug, sha) {
        if (typeof sha !== "string" || sha === "" || statsCache[sha] !== undefined)
            return;
        if (queue.some(job => job.kind === "stats" && job.sha === sha)
                || (active !== null && active.kind === "stats" && active.sha === sha))
            return;
        enqueue({ kind: "stats", slug: slug, sha: sha, interactive: true });
    }

    function patchStats(sha, entry) {
        const next = {};
        Object.keys(statsCache).forEach(key => next[key] = statsCache[key]);
        next[sha] = entry;
        statsCache = next;
    }

    // ---- process results -------------------------------------------------
    function settle(exitCode, body, errText) {
        const job = active;
        active = null;
        if (job === null) {
            pump();
            return;
        }
        if (job.kind === "runs" || job.kind === "events"
                || job.kind === "notifications") {
            settleInbox(job, exitCode, body, errText);
            pump();
            return;
        }
        if (!pollEnabled && !job.interactive) {
            polling = false;
            pendingWatch = 0;
            pump();
            return;
        }

        const failed = exitCode !== 0;
        switch (job.kind) {
        case "login":
            if (!failed)
                login = Helpers.parseLogin(body);
            break;
        case "repos": {
            const rows = failed ? null : Helpers.parseRepos(body);
            if (rows === null) {
                failPoll("gh api /user/repos", exitCode, errText);
                break;
            }
            ownRepos = rows;
            fanOutWatched();
            break;
        }
        case "watch": {
            const row = failed ? null : Helpers.parseRepo(body);
            if (row !== null) {
                extraRepos = extraRepos.concat([row]);
                patchNextWatchError(job.slug, "");
            } else {
                patchNextWatchError(job.slug,
                    ProcHelpers.commandError("gh api repository", exitCode, errText));
            }
            pendingWatch = Math.max(0, pendingWatch - 1);
            if (pendingWatch === 0)
                publishRepos();
            break;
        }
        case "commits": {
            const rows = failed ? null : Helpers.parseCommits(body);
            patchCommits(job.slug, {
                rows: rows ?? [],
                error: rows === null
                    ? ProcHelpers.commandError("gh api commits", exitCode, errText) : "",
                loading: false,
                at: Date.now()
            });
            if (job.toast && rows !== null)
                raisePushToast(job.slug, rows, job.since);
            break;
        }
        case "stats": {
            const stats = failed ? null : Helpers.parseCommitStats(body);
            patchStats(job.sha,
                stats ?? ({ sha: job.sha, files: 0, additions: 0, deletions: 0 }));
            break;
        }
        }
        pump();
    }

    function raisePushToast(slug, rows, since) {
        const toast = Helpers.pushToast(slug, Helpers.newCommits(rows, since),
            rows.length > 0 ? rows[0].subject : "");
        if (toast !== null)
            sendToast(toast);
    }

    function raiseWorkflowToast(rows) {
        const toast = Helpers.coalescedFailureToast(rows);
        if (toast !== null)
            sendToast(toast);
    }

    function sendToast(toast) {
        Notifs.send({
            appName: "GitHub",
            appIcon: "github",
            brandIcon: "github",
            summary: toast.summary,
            body: toast.body
        });
    }

    Process {
        id: ghProc
        property string body: ""
        property string errText: ""
        property bool exitSeen: false
        property int lastExit: 0

        stdout: StdioCollector {
            onStreamFinished: ghProc.body = text
        }
        stderr: StdioCollector {
            onStreamFinished: ghProc.errText = text
        }
        onExited: (exitCode, exitStatus) => {
            ghProc.exitSeen = true;
            ghProc.lastExit = exitCode;
        }
        onRunningChanged: {
            if (running) {
                body = "";
                errText = "";
                exitSeen = false;
                lastExit = 0;
                return;
            }
            root.settle(exitSeen ? lastExit : ProcHelpers.NOT_STARTED, body, errText);
        }
    }

    Timer {
        id: pollTimer
        interval: root.pollMins * 60000
        running: root.pollEnabled
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }

    Timer {
        id: inboxTimer
        interval: 60000
        running: root.pollEnabled
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refreshInbox(false)
    }

    Timer {
        id: activeInboxTimer
        interval: 30000
        running: root.pollEnabled && root.ciReportsEnabled && root.runningCount > 0
        repeat: true
        onTriggered: root.refreshActiveInbox()
    }

    Timer {
        id: watchApply
        interval: 500
        onTriggered: {
            if (!root.pollEnabled)
                return;
            if (root.polling)
                restart();
            else
                root.refresh();
        }
    }

    onMonitoredKeyChanged: {
        invalidateInboxScope();
        if (pollEnabled && ready)
            refreshInbox(true);
    }

    onCiReportsEnabledChanged: {
        inboxBackoffUntil = 0;
        inboxFailureCount = 0;
        inboxError = "";
        // Runs completed while reporting was off are the new baseline when it
        // is enabled again; opting back in must not emit retroactive toasts.
        if (!ciReportsEnabled) {
            runCache = ({});
            runBaselines = ({});
            const reset = Helpers.removeInboxSources(inboxState,
                inboxSourceRevisions, "workflows:");
            inboxState = reset.items;
            inboxSourceRevisions = reset.sourceRevisions;
        }
        invalidateInboxScope();
        if (pollEnabled && ready)
            refreshInbox(true);
    }

    onWatchKeyChanged: {
        if (pollEnabled && ready)
            watchApply.restart();
    }

    onPollEnabledChanged: {
        if (!pollEnabled) {
            watchApply.stop();
            queue = queue.filter(job => job.interactive);
            inboxSweep = null;
            inboxPolling = false;
            polling = false;
            pendingWatch = 0;
        }
    }
}
