const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { shellDir, load } = require("./shell.cjs");

function read(relative) {
    return fs.readFileSync(path.join(shellDir, relative), "utf8");
}

test("the GitHub singleton publishes the persistent Inbox contract", () => {
    const source = read("Common/GitHub.qml");
    for (const property of ["inboxItems", "inboxReady", "inboxPolling",
        "inboxCheckedAt", "inboxError", "pendingInboxCount", "settledInboxCount",
        "unreadInboxCount", "unreadRepoCount", "workflowRepoErrors", "eventRepoErrors",
        "ciReportsEnabled"])
        assert.match(source, new RegExp(`property[^\n]*\\b${property}:`), property);
    for (const action of ["settleInboxItem", "unsettleInboxItem"])
        assert.match(source, new RegExp(`function ${action}\\(key\\)`));
    assert.match(source, /function settleAllInboxItems\(\)/);
    assert.match(source,
        /property string seenAt:[\s\S]*property string activitySeenAt:[\s\S]*property var lastPush:[\s\S]*property var runBaselines:[\s\S]*property var inboxItems:[\s\S]*property var inboxSourceRevisions:/,
        "Inbox state must append to every legacy state field");
    assert.match(source, /stateData\.inboxItems = Helpers\.compactInboxItems\(root\.inboxState\)/);
    assert.match(source, /stateData\.inboxSourceRevisions = root\.inboxSourceRevisions/);
    assert.match(source, /badgeVisible:[^\n]*pendingInboxCount > 0/);
    assert.doesNotMatch(source, /unreadRepoCount\s*\+/,
        "view-based repository dots must not enter the bar badge count");
    const markSeen = source.match(/function markSeen\(\)[\s\S]*?\n    \}/)?.[0] ?? "";
    assert.match(markSeen, /activitySeenAt = stamp/);
    assert.doesNotMatch(markSeen, /setInboxSettlement|settleInboxItem/,
        "closing the popover only clears emphasis");
});

test("full Inbox and active-workflow sweeps use independent fixed cadences", () => {
    const source = read("Common/GitHub.qml");
    const full = source.match(/Timer \{\s*id: inboxTimer[\s\S]*?\n    \}/)?.[0] ?? "";
    const active = source.match(/Timer \{\s*id: activeInboxTimer[\s\S]*?\n    \}/)?.[0] ?? "";
    assert.match(full, /interval:\s*60000/);
    assert.match(full, /running:\s*root\.pollEnabled/);
    assert.match(full, /root\.refreshInbox\(false\)/);
    assert.match(active, /interval:\s*30000/);
    assert.match(active,
        /running:\s*root\.pollEnabled && root\.ciReportsEnabled && root\.runningCount > 0/);
    assert.match(active, /root\.refreshActiveInbox\(\)/);

    const sweep = source.match(/function startInboxSweep[\s\S]*?\n    \}/)?.[0] ?? "";
    assert.match(sweep, /if \(ciReportsEnabled\)[\s\S]*kind: "runs"/);
    assert.match(sweep, /if \(full\)[\s\S]*kind: "events"[\s\S]*kind: "notifications"/,
        "events and notifications must still poll with workflow reports disabled");
    assert.match(source, /queue = queue\.filter\(job => job\.interactive\)/,
        "turning the module off discards queued background reads");
});

test("Inbox reads use conditional HTTP polling and preserve partial caches", () => {
    const source = read("Common/GitHub.qml");
    const pump = source.match(/function pump\(\)[\s\S]*?\n    \}/)?.[0] ?? "";
    assert.match(pump,
        /Helpers\.CONDITIONAL_KINDS\[job\.kind\] === true[\s\S]*command\.push\("--include"\)/);
    assert.match(pump, /Helpers\.conditionalArgs\(validator\.etag,\s*validator\.lastModified\)/);
    const helpers = load("GitHubHelpers.js");
    assert.deepEqual(Object.keys(helpers.CONDITIONAL_KINDS).sort(),
        ["events", "notifications", "runs"]);
    const validator = source.match(/function conditionalValidator[\s\S]*?\n    \}/)?.[0] ?? "";
    assert.match(validator, /hasInboxSource\("events:" \+ slug\)[\s\S]*eventEtags\[slug\]/);
    assert.match(validator, /hasInboxSource\("workflows:" \+ slug\)[\s\S]*runEtags\[slug\]/);
    assert.match(validator, /hasInboxSource\("notifications"\)[\s\S]*notificationLastModified/,
        "a validator is only sent while its source has a reconciled snapshot");
    assert.match(source, /eventPollDue\(slug, now\)/);
    assert.match(source, /Helpers\.pollDue\(notificationNextPollAt, now\)/,
        "notifications honour X-Poll-Interval");
    assert.match(source, /Helpers\.nextPollInterval\(response, intervals\[key\], 60000\)/);
    assert.match(source,
        /const notModified = Helpers\.notModifiedResponse\(included, exitCode, errText\)/);
    const settleInbox = source.match(/function settleInbox\(job[\s\S]*?\n    \}/)?.[0] ?? "";
    assert.match(settleInbox,
        /job\.kind === "runs"\) \{\s*if \(notModified\) \{\s*patchRunResult\(job\.slug, null, ""\)/,
        "a workflow 304 keeps the previous rows");
    assert.match(settleInbox,
        /if \(notModified\) \{\s*notificationError = "";\s*inboxSweep\.anySuccess = true;/,
        "a notification 304 keeps the previous rows");
    assert.match(settleInbox, /noteRateLimit\(included\.headers\)/);
    assert.match(source, /if \(notModified\)[\s\S]*patchEventResult\(job\.slug, null, ""\)/,
        "304 is successful even though it has no jq body");
    assert.match(source, /patchEventResult\(job\.slug, null, message\)/,
        "a partial repository failure must retain cached rows");
    assert.match(source, /globalInboxFailure/);
    assert.match(source, /inboxBackoffMs/);
    assert.match(helpers.GITHUB_QUERIES.events.path, /events\?per_page=30/);
    const refreshInbox = source.match(/function refreshInbox[\s\S]*?\n    \}/)?.[0] ?? "";
    assert.match(refreshInbox, /!force && \(inboxBackoffUntil > Date\.now\(\) \|\| rateLimited\(\)\)/,
        "timers stand down while the API quota is low");
    const active = source.match(/function refreshActiveInbox[\s\S]*?\n    \}/)?.[0] ?? "";
    assert.match(active, /rateLimited\(\)/);
});

test("a stalled gh read is bounded by a watchdog that releases the queue", () => {
    const source = read("Common/GitHub.qml");
    const pump = source.match(/function pump\(\)[\s\S]*?\n    \}/)?.[0] ?? "";
    assert.match(pump,
        /ghWatchdog\.interval = Helpers\.ghTimeoutMs\(job\);\s*ghWatchdog\.restart\(\);\s*ghProc\.running = true;/,
        "the watchdog is armed before launch so a synchronous failed start disarms it");
    const fired = source.match(/function ghWatchdogFired\(\)[\s\S]*?\n    \}/)?.[0] ?? "";
    assert.match(fired, /ghProc\.timedOut = true[\s\S]*ghProc\.running = false/,
        "first firing terminates through the normal falling edge");
    assert.match(fired, /ghProc\.signal\(9\)[\s\S]*ghProc\.abandoned = true;\s*settle\(Helpers\.GH_TIMEOUT_EXIT/,
        "a process that ignores SIGTERM is killed and its job settled directly");
    const proc = source.match(/Process \{\s*id: ghProc[\s\S]*?\n    \}/)?.[0] ?? "";
    assert.match(proc, /ghWatchdog\.stop\(\)/);
    assert.match(proc, /if \(abandoned\) \{[\s\S]*root\.pump\(\);\s*return;/,
        "an abandoned job must not settle twice");
    assert.match(proc, /if \(timedOut\)\s*root\.settle\(Helpers\.GH_TIMEOUT_EXIT, "", timeoutText\)/);
    assert.match(proc, /ProcHelpers\.NOT_STARTED/,
        "a never-started gh still settles through the falling edge");
    assert.match(source, /Timer \{\s*id: ghWatchdog[\s\S]*?onTriggered: root\.ghWatchdogFired\(\)/);
    const helpers = load("GitHubHelpers.js");
    assert.equal(helpers.globalInboxFailure(helpers.GH_TIMEOUT_EXIT,
        helpers.ghTimeoutMessage({ interactive: false })), true,
        "a timed-out Inbox read pauses the sweep with backoff");
});

test("interactive reads outrank polling and stale Inbox scopes are rejected", () => {
    const source = read("Common/GitHub.qml");
    assert.match(source, /firstBackground = queue\.findIndex\(queued => !queued\.interactive\)/);
    assert.match(source, /kind: "commits"[\s\S]{0,180}?interactive: true/);
    assert.match(source, /kind: "stats"[\s\S]{0,100}?interactive: true/);
    assert.match(source, /job\.generation !== scopeGeneration \|\| inboxSweep === null/);
    assert.match(source,
        /onCiReportsEnabledChanged:[\s\S]*runCache = \(\{\}\);[\s\S]*runBaselines = \(\{\}\);[\s\S]*removeInboxSources[\s\S]*invalidateInboxScope\(\)/,
        "re-enabling workflows must establish a fresh source baseline");
    assert.match(source,
        /onMonitoredKeyChanged:[\s\S]*invalidateInboxScope\(\);[\s\S]*refreshInbox\(true\)/,
        "scope changes refresh repository events even when workflow reporting is off");
});

test("the popover defaults to Inbox and exposes accessible top-level tabs", () => {
    const source = read("Popovers/GitHubPopover.qml");
    assert.match(source, /property string page:\s*"inbox"/);
    assert.match(source, /label:\s*"Inbox"[\s\S]{0,80}?pageName:\s*"inbox"/);
    assert.match(source, /label:\s*"Repositories"[\s\S]{0,80}?pageName:\s*"repos"/);
    assert.match(source, /Accessible\.role:\s*Accessible\.PageTab/);
    assert.match(source, /Accessible\.selected:\s*selected/);
    assert.match(source, /accessibleName:\s*"Refresh GitHub repositories and Inbox"/);
    assert.match(source, /property bool settledExpanded:\s*false/);
    assert.match(source, /Accessible\.name:\s*"Settled, "/);
    assert.deepEqual(load("GitHubHelpers.js").inboxSections([]).map(group => group.title),
        ["Active", "Attention", "Updates", "Settled"]);
});

test("the GitHub workspace follows the integrated T3 module hierarchy", () => {
    const source = read("Popovers/GitHubPopover.qml");
    assert.match(source, /padding:\s*T3Theme\.pagePadding/);
    assert.match(source, /surfaceColor:\s*Theme\.barSurface/);
    // The header stopped being a card when T3's did: copy over the panel,
    // closed by a hairline, with no branded wash behind the title.
    assert.match(source, /id:\s*moduleHeader[\s\S]{0,240}?color:\s*T3Theme\.border/);
    assert.doesNotMatch(source, /id:\s*moduleHeader[\s\S]{0,240}?gradient:\s*Gradient/,
        "no accent wash behind the module title");
    assert.match(source,
        /component TabButton[\s\S]{0,400}?color:\s*selected \? T3Theme\.hoverStrong/,
        "a selected tab lights the held chip rather than the accent");
    assert.match(source, /component GroupHeader: SectionLabel/);

    // T3 and GitHub share one flat-line list grammar. The Inbox is the
    // quietest form: one coloured status glyph and one meaningful title.
    // Workflow display titles win over generic workflow names such as "CI";
    // other detail remains available to accessibility and the page being opened.
    const inboxRow = source.match(
        /component InboxRow: Rectangle \{([\s\S]*?)\n {4}\}\n\n {4}\/\/ ---- header/)?.[1] ?? "";
    assert.match(inboxRow, /height:\s*T3Theme\.quietRowHeight/);
    assert.match(inboxRow, /color:\s*"transparent"/);
    assert.match(inboxRow, /border\.width:\s*activeFocus \? 1 : 0/,
        "attention must not bring back a resting border");
    assert.match(inboxRow,
        /name:\s*root\.inboxStatusIcon\(inboxCard\.row\)[\s\S]{0,140}?color:\s*inboxCard\.statusColor/,
        "status belongs to one semantic glyph");
    assert.doesNotMatch(inboxRow, /id:\s*inboxContext|id:\s*statusPill/,
        "Inbox rows should show no provenance or written status");
    assert.match(inboxRow,
        /displayTitle:\s*row\.kind === "run" && row\.detail !== ""[\s\S]{0,100}?\? row\.detail : row\.title/,
        "workflow rows should expose the GitHub display title, not a generic workflow name");
    assert.match(inboxRow,
        /id:\s*inboxTitle[\s\S]{0,420}?text:\s*inboxCard\.displayTitle/);

    const repoRow = source.match(
        /id:\s*repoRow([\s\S]*?)\n {16}\}\n {12}\}\n {8}\}/)?.[1] ?? "";
    assert.match(repoRow, /height:\s*T3Theme\.quietRowHeight/);
    assert.match(repoRow, /color:\s*"transparent"/);
    assert.match(repoRow, /id:\s*repoContext/);
    assert.match(repoRow, /id:\s*openRepoAction[\s\S]*symbol:\s*"open_in_new"/,
        "repository rows drill in while retaining a direct browser action");

    const collapsedCommit = source.match(
        /id:\s*collapsed\b([\s\S]*?)\n {20}\}\n\n {20}\/\/ Expanded/)?.[1] ?? "";
    assert.match(collapsedCommit, /height:\s*T3Theme\.quietRowHeight/);
    assert.match(collapsedCommit, /color:\s*"transparent"/);
    assert.match(collapsedCommit, /id:\s*commitContext/);

    const t3Theme = read("Common/T3Theme.qml");
    assert.match(t3Theme,
        /readonly property int quietRowHeight:\s*Theme\.listRowHeight/);
    assert.doesNotMatch(t3Theme, /activeRowHeight/,
        "the obsolete GitHub-only two-line token must not return");
    assert.doesNotMatch(source, /T3Theme\.activeRowHeight/);
    assert.match(source, /label:\s*"Working"|\?\s*"Working"/);
    assert.match(source, /label:\s*"Repositories"[\s\S]{0,80}?root\.filteredRepos\.length/);
    assert.match(source, /text:\s*"Search repositories"/);
    assert.match(source,
        /page === "repos" && repoSearchText !== ""[\s\S]{0,100}?repoSearchText = ""/,
        "Escape should clear repository search before closing the panel");
});

test("Inbox rows open GitHub and expose local hover/focus settlement actions", () => {
    const source = read("Popovers/GitHubPopover.qml");
    assert.match(source, /function openInbox\(row\)[\s\S]*GitHub\.open\(row\.url\)/);
    assert.match(source,
        /actionsRevealed:\s*row\.canSettle[\s\S]{0,100}?inboxHover\.hovered \|\| activeFocus \|\| settleAction\.activeFocus/);
    assert.match(source, /HoverHandler \{\s*id: inboxHover/);
    assert.match(source,
        /component RowAction: IconButton \{\s*controlSize:\s*Theme\.chipInnerHeight/);
    assert.match(source,
        /symbol: inboxCard\.quiet \? "undo" : "check"/);
    assert.match(source,
        /accessibleName: inboxCard\.row\.lifecycle === "settled" \? "Unsettle" : "Settle"/);
    assert.match(source, /GitHub\.settleInboxItem\(inboxCard\.row\.key\)/);
    assert.match(source, /GitHub\.unsettleInboxItem\(inboxCard\.row\.key\)/);
    assert.match(source,
        /id:\s*settleScope[\s\S]{0,180}?anchors\.verticalCenter:\s*parent\.verticalCenter/,
        "the compact action must remain centered in the one-line row");
    assert.match(source, /label:\s*"Settle all"/);
    assert.match(source, /onTriggered:\s*GitHub\.settleAllInboxItems\(\)/);
    assert.match(source, /Accessible\.description:\s*"Open on GitHub"/);
    assert.doesNotMatch(source,
        /mark.*(?:notification|thread).*read|\/notifications\/threads\/[^"\s]*\b(?:PATCH|PUT)|\/rerun|\/cancel/i,
        "Inbox actions must remain local and read-only");
    assert.match(source,
        /Accessible\.name:\s*displayTitle[\s\S]{0,180}?root\.inboxStatus\(row\)/,
        "hidden detail and status must remain available to assistive technology");
    assert.match(source, /Helpers\.runStatusLabel\(row\.status, row\.conclusion\)/);
});

test("the bar keeps its live-workflow marker clear of the GitHub mark", () => {
    const source = read("Bar/Modules/GitHub.qml");
    assert.match(source,
        /width:\s*GitHub\.runningCount > 0 \? 5 : 0[\s\S]{0,80}?opacity:\s*GitHub\.runningCount > 0 \? 1 : 0/);
    const marker = source.match(
        /\/\/ Static by design:[\s\S]*?Rectangle \{([\s\S]*?)\n {12}\}/)?.[1] ?? "";
    assert.match(marker, /width:\s*5[\s\S]*height:\s*5/);
    assert.match(marker, /color:\s*Theme\.barAccent/);
    assert.doesNotMatch(marker, /Animation|Animator|Timer|opacity:/,
        "the dot itself stays static even while its lane opens and closes");
    assert.match(source, /GitHub\.badgeTone === "red" \? Theme\.barRed/);
    assert.match(source, /GitHub\.badgeTone === "amber" \? Theme\.barAmber/);
    assert.doesNotMatch(source, /id:\s*badge(?:Count)?\b|GitHub\.badgeVisible/,
        "pending Inbox state must not draw a badge over the GitHub mark");
    assert.match(source,
        /id:\s*countLabel[\s\S]*text:\s*GitHub\.pendingInboxCount \+ " pending"/);
    assert.match(source,
        /githubTooltip\(GitHub\.runningCount,[\s\S]*GitHub\.pendingInboxCount,[\s\S]*GitHub\.unreadRepoCount/);
});

test("settings explain repository refresh and Inbox polling separately", () => {
    const options = read("Settings/ModuleDetailView.qml");
    const watches = read("Settings/GitHubWatchList.qml");
    assert.match(options, /label:\s*"Recent account repos"/);
    assert.match(options, /label:\s*"Repo refresh"/);
    assert.match(options, /optionLabelWidth:\s*156/);
    assert.match(options, /label:\s*"CI reports"[\s\S]{0,220}?view\.opts\.ciActivity/);
    assert.match(options, /Workflow rows in the Inbox/);
    assert.match(options, /failed\/action-required workflows/);
    assert.match(watches, /Every watched repository is additive/);
    assert.match(watches, /Inbox checks repository events and GitHub notifications every minute/);
    assert.match(watches, /GitHub\.watchError\(modelData\)/);
    const defaults = load("SettingsHelpers.js").defaultModOpts().gh;
    assert.deepEqual(Object.keys(defaults).sort(),
        ["badge", "ciActivity", "pollMins", "repos", "toasts", "watch"]);
});
