pragma Singleton
import QtQuick
import Quickshell
import "T3CodeHelpers.js" as Helpers
import "Format.js" as Format

// What the shell knows about threads: the raw maps the server streams in, the
// classification that turns them into "running / monitoring / needs attention
// / done / settled / snoozed", the projections the inbox lists, and the desktop
// notification raised when a thread changes class.
//
// This is what Bar/T3Chip.qml and T3InboxPage actually read. It holds no
// connection and sends nothing — T3Code hands it items off the shell stream
// and calls scheduleRebuild().
Singleton {
    id: root

    // A snapshot replaced the world. The draft layer reconciles its selections
    // against the new thread and project ids here; this file does not know
    // drafts exist.
    signal snapshotApplied()

    // The projections were recomputed. The detail layer refreshes the
    // session summary of whatever thread it is showing from the new map.
    signal rebuilt()

    // A thread arrived or changed. The draft layer watches for the id it is
    // waiting on after a create, which is the only reason it cares.
    signal threadUpserted(string threadId)

    property var threadMap: ({})
    property var projectMap: ({})
    property bool shellReady: false
    readonly property bool hasProjects: Object.values(projectMap)
        .some(project => project && !project.deletedAt)

    // Derived, popover-ready: the active inbox only (settled and snoozed
    // threads are dropped), sorted by urgency then recency. Pinned threads
    // are their own list — shown first, and never settled away.
    property var threads: []
    property var pinnedThreads: []
    property var snoozedThreads: []
    property var settledThreads: []
    property int runningCount: 0
    property int monitoringCount: 0
    property int attentionCount: 0
    property int doneCount: 0
    property int settledCount: 0
    property int snoozedCount: 0

    // ---- classification ------------------------------------------------

    // Days of quiet after which a thread settles itself. Mirrors the web
    // client's sidebar setting (its default is 3); 0 disables auto-settle.
    property int autoSettleAfterDays: 3

    // Bumped once a minute so settledness and the relative time labels
    // follow the clock — both move without any server event. The working
    // clock ticks independently so a live duration does not rebuild lists.
    property double nowMs: Date.now()
    property double workingNowMs: Date.now()

    function parseMs(iso) {
        return Helpers.parseMs(iso);
    }

    // Newest real activity on a thread (reference: threadLastActivityAt).
    function lastActivityMs(t) {
        return Helpers.lastActivityMs(t);
    }

    // A user message no session has adopted yet: the turn exists but none
    // of the status fields show it, so it has to be detected as a message
    // strictly newer than every timestamp on the latest turn.
    function hasQueuedTurnStart(t, now) {
        return Helpers.hasQueuedTurnStart(t, now);
    }

    // Mirrors the reference client's effectiveSettled, which is what the
    // web sidebar partitions on: blocked or live work stays active whatever
    // the flags say, then an explicit settle/unsettle wins, then a thread
    // quiet past the window settles itself. The reference's third input —
    // pull request state — isn't subscribed here, so a merged PR only
    // settles its thread once the thread also goes quiet.
    function isSettled(t, now) {
        return Helpers.isEffectivelySettled(t, now, autoSettleAfterDays);
    }

    // Shelved until its wake time — unless the thread raises its hand:
    // blocked on the user, freshly failed, or finished a run after the
    // snooze was set.
    function isSnoozed(t, now) {
        return Helpers.isEffectivelySnoozed(t, now);
    }

    // "attention" | "running" | "monitoring" | "error" | "done" | "idle".
    // Only ever asked of active threads — settledness is decided first.
    function threadClass(t) {
        return Helpers.threadClass(t);
    }

    function threadCanPrompt(t, now) {
        return Helpers.canPrompt(t, now);
    }

    function projectTitle(projectId) {
        const p = projectMap[projectId];
        return p ? p.title : "";
    }

    function threadUrl(threadId) {
        if (T3Connection.host === "" || T3Connection.environmentId === "")
            return T3Connection.host;
        return T3Connection.host + "/" + T3Connection.environmentId + "/" + threadId;
    }

    // Where the thread's files live on the server host: its worktree when it
    // has one, the project checkout otherwise. Empty until the shell stream
    // has delivered the thread.
    function threadPath(threadId) {
        const thread = threadMap[threadId];
        if (!thread)
            return "";
        if (typeof thread.worktreePath === "string" && thread.worktreePath.trim() !== "")
            return thread.worktreePath;
        const project = projectMap[thread.projectId];
        return project && typeof project.workspaceRoot === "string"
            ? project.workspaceRoot : "";
    }

    // Reads nowMs so callers' bindings re-run on the minute tick.
    function relTime(iso) {
        if (!iso)
            return "";
        let s = (nowMs - Date.parse(iso)) / 1000;
        if (s < 90)
            return "now";
        if (s < 3600)
            return Math.round(s / 60) + "m";
        if (s < 86400)
            return Math.round(s / 3600) + "h";
        return Math.round(s / 86400) + "d";
    }

    // These read workingNowMs so visible inbox/thread labels update without
    // waiting for orchestration traffic. Invalid timestamps deliberately
    // produce no duration; callers can still show the Working state itself.
    function workingDurationLabel(iso) {
        const startedMs = Helpers.parseMs(iso);
        if (isNaN(startedMs))
            return "";
        return Helpers.formatWorkingDurationLabel(workingNowMs - startedMs);
    }

    function workingTimerLabel(iso) {
        const startedMs = Helpers.parseMs(iso);
        if (isNaN(startedMs))
            return "";
        return Helpers.formatWorkingTimerLabel(workingNowMs - startedMs);
    }

    // Previous class per thread, for transition notifications.
    property var lastClass: ({})
    // Last published list, so a no-op rebuild leaves the popover's
    // delegates (and a half-typed prompt) alone.
    property string listSignature: ""

    // A busy shell stream delivers many Chunk frames per second. Coalesce
    // them: classifying, sorting and fingerprinting every thread happens at
    // most once per event-loop turn.
    property bool rebuildQueued: false

    function scheduleRebuild() {
        if (rebuildQueued)
            return;
        rebuildQueued = true;
        Qt.callLater(root.flushRebuild);
    }

    function flushRebuild() {
        if (rebuildQueued)
            rebuild();
    }

    function rebuild() {
        rebuildQueued = false;
        const now = Date.now();
        const projection = Helpers.classifyThreads(threadMap, projectMap, now,
            autoSettleAfterDays);
        const sig = JSON.stringify({
            active: projection.active,
            pinned: projection.pinned,
            snoozed: projection.snoozed,
            settled: projection.settled
        });
        if (sig === listSignature)
            return;
        listSignature = sig;

        // Hidden threads keep a class of their own so one that comes back —
        // the server un-settles on a new approval or question — reads as a
        // transition and still raises its toast. Pinned threads are live rows
        // and notify like active ones.
        const next = {};
        for (const th of projection.snoozed)
            next[th.id] = "hidden";
        for (const th of projection.settled)
            next[th.id] = "hidden";
        for (const th of projection.active.concat(projection.pinned)) {
            next[th.id] = th.cls;
            const prev = lastClass[th.id];
            if (prev !== undefined && prev !== th.cls)
                notifyTransition(prev, th);
        }
        lastClass = next;

        threads = projection.active;
        pinnedThreads = projection.pinned;
        snoozedThreads = projection.snoozed;
        settledThreads = projection.settled;
        runningCount = projection.runningCount;
        monitoringCount = projection.monitoringCount;
        attentionCount = projection.attentionCount;
        doneCount = projection.doneCount;
        settledCount = projection.settled.length;
        snoozedCount = projection.snoozed.length;

        // Shell updates carry the freshest session/latest-turn summary even
        // while the detailed history stream is catching up. The detail layer
        // takes that from the map itself; this file does not know which thread
        // it happens to be showing.
        rebuilt();
    }

    function projectedThread(threadId) {
        for (const list of [threads, pinnedThreads, snoozedThreads, settledThreads]) {
            const found = list.find(thread => thread.id === threadId);
            if (found)
                return found;
        }
        return null;
    }

    function rawThread(threadId) {
        return threadMap[threadId] ?? null;
    }

    function sortedProjects() {
        return Object.values(projectMap).filter(project => project && !project.deletedAt)
            .sort((left, right) => (left.title ?? "").localeCompare(right.title ?? ""));
    }

    function snoozePresets() {
        return Helpers.resolveSnoozePresets(new Date());
    }

    function snoozeWakeLabel(iso) {
        return Helpers.snoozeWakeLabel(iso, nowMs);
    }

    function historyPage(messages, visibleCount) {
        return Helpers.historyPage(messages, visibleCount);
    }

    // Auto-settle and snooze wake are clock-driven: without a tick a thread
    // would sit in the list until the next server event.
    Timer {
        interval: Format.MS_MINUTE
        repeat: true
        running: T3Connection.state === "connected"
        onTriggered: {
            root.nowMs = Date.now();
            root.rebuild();
        }
    }

    // workingNowMs is read only by workingDurationLabel/workingTimerLabel, and
    // those are read only by the T3 popover's inbox and thread pages — the bar
    // chip shows counts, never a duration. Ticking while the popover is shut
    // would move labels nobody can see. triggeredOnStart refreshes them the
    // moment it opens rather than up to a second later.
    Timer {
        interval: 1000
        repeat: true
        triggeredOnStart: true
        running: T3Connection.state === "connected" && root.runningCount > 0
            && Popouts.open && Popouts.currentName === "t3code"
        onTriggered: root.workingNowMs = Date.now()
    }

    // A session asking for input is always worth a toast; finishing or
    // failing only when it was actually working a moment ago.
    function notifyTransition(prev, th) {
        let what;
        if (th.cls === "attention")
            what = th.pendingApprovals ? "waiting for approval" : "has a question";
        else if (th.cls === "error" && (prev === "running" || prev === "monitoring"
                || prev === "attention"))
            what = "failed";
        else if (th.cls === "done" && (prev === "running" || prev === "monitoring"
                || prev === "attention"))
            what = "finished";
        else
            return;
        Notifs.send({
            appName: "T3 Code",
            appIcon: "utilities-terminal",
            summary: th.title,
            body: th.project + " · " + what
        });
    }


    // Apply one Chunk's items. Each map is copied at most once per frame and
    // assigned once, then the signals go out in item order against the
    // settled maps. Returns whether the projections need a rebuild.
    function applyItems(items) {
        const result = Helpers.applyShellItems(threadMap, projectMap, items);
        if (result.projectsChanged)
            projectMap = result.projectMap;
        if (result.threadsChanged)
            threadMap = result.threadMap;
        if (result.ready)
            shellReady = true;
        for (const event of result.events) {
            if (event.kind === "snapshot")
                snapshotApplied();
            else if (event.kind === "thread-upserted")
                threadUpserted(event.threadId);
        }
        return result.dirty;
    }


}
