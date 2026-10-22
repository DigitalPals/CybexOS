// Pure helpers shared by the T3 Code QML singleton and Node tests.
// Keep this file free of Qt APIs so it remains deterministic outside QML.

var DAY_MS = 24 * 60 * 60 * 1000;
var HOUR_MS = 60 * 60 * 1000;
var QUEUED_TURN_GRACE_MS = 2 * 60 * 1000;
var MAX_PROMPT_CHARS = 120000;
var MAX_DIFF_CHARS = 100000;
var MAX_DIFF_LINES = 2000;

function parseMs(value) {
    return typeof value === "string" && value !== "" ? Date.parse(value) : NaN;
}

function firstValidTimestamp() {
    for (var i = 0; i < arguments.length; i++) {
        if (!isNaN(parseMs(arguments[i])))
            return arguments[i];
    }
    return null;
}

// Keep the elapsed clock anchored to the running turn, including the short
// period before the session adopts it. A session transition is the fallback
// when the turn projection is late or has malformed timestamps.
function resolveWorkingStartedAt(thread) {
    var turn = thread && thread.latestTurn ? thread.latestTurn : null;
    var session = thread && thread.session ? thread.session : null;
    if (turn && turn.completedAt === null)
        return firstValidTimestamp(turn.startedAt, turn.requestedAt,
            session ? session.updatedAt : null);
    return firstValidTimestamp(session ? session.updatedAt : null);
}

// Compact duration used by an inbox row, matching T3 Code's sidebar label.
function formatWorkingDurationLabel(elapsedMs) {
    var seconds = typeof elapsedMs === "number" && isFinite(elapsedMs)
        ? Math.max(0, Math.floor(elapsedMs / 1000)) : 0;
    if (seconds < 60)
        return seconds + "s";
    var minutes = Math.floor(seconds / 60);
    if (minutes < 60)
        return minutes + "m";
    return Math.floor(minutes / 60) + "h " + (minutes % 60) + "m";
}

// Conversation-tail variant keeps seconds visible until a full minute rolls
// over, as in T3 Code's live "Working for …" row.
function formatWorkingTimerLabel(elapsedMs) {
    var seconds = typeof elapsedMs === "number" && isFinite(elapsedMs)
        ? Math.max(0, Math.floor(elapsedMs / 1000)) : 0;
    if (seconds < 60)
        return seconds + "s";
    var hours = Math.floor(seconds / 3600);
    var minutes = Math.floor((seconds % 3600) / 60);
    var remainingSeconds = seconds % 60;
    if (hours > 0)
        return minutes > 0 ? hours + "h " + minutes + "m" : hours + "h";
    return remainingSeconds > 0
        ? minutes + "m " + remainingSeconds + "s" : minutes + "m";
}

// T3 Code's detail stream persists task lifecycle activities rather than a
// ready-made agent count. Fold just the liveness part of its agent-panel
// model: membership is stamped once with agentKind="agent", later rows inherit
// it, terminal rows are idempotent, and an explicit running update may
// reactivate a reusable agent identity. Background shells and watch tasks do
// not belong in the count.
function liveAgentCount(activities, sessionLive) {
    var agents = Object.create(null);
    var terminal = function(status) {
        return status === "completed" || status === "failed" || status === "cancelled"
            || status === "interrupted";
    };
    var active = function(status) {
        return status === "pending" || status === "running" || status === "waiting";
    };
    var knownStatus = function(value) {
        switch (value) {
        case "pending":
        case "running":
        case "waiting":
        case "idle":
        case "completed":
        case "failed":
        case "cancelled":
        case "interrupted":
            return value;
        default:
            return "";
        }
    };
    var applyStatus = function(agent, status) {
        if (status === "" || terminal(agent.status) && terminal(status))
            return;
        agent.status = status;
    };
    var values = Array.isArray(activities) ? activities : [];
    for (var i = 0; i < values.length; i++) {
        var activity = values[i];
        if (!activity || typeof activity !== "object"
                || !activity.payload || typeof activity.payload !== "object")
            continue;
        var payload = activity.payload;
        var taskId = typeof payload.taskId === "string" ? payload.taskId.trim() : "";
        if (taskId === "")
            continue;
        var agent = agents[taskId];
        var existed = agent !== undefined;
        // Classification is sticky. Terminal/progress rows routinely omit the
        // marker, but an unseen unmarked task is an ordinary background job.
        if (!existed && payload.agentKind !== "agent")
            continue;
        if (!existed) {
            agent = {
                id: taskId,
                status: "pending",
                kind: payload.taskType === "local_workflow" ? "workflow" : "agent",
                parentAgentId: typeof payload.parentAgentId === "string"
                    ? payload.parentAgentId : ""
            };
            agents[taskId] = agent;
        } else {
            if (payload.taskType === "local_workflow")
                agent.kind = "workflow";
            if (typeof payload.parentAgentId === "string" && payload.parentAgentId !== "")
                agent.parentAgentId = payload.parentAgentId;
        }

        switch (activity.kind) {
        case "task.started":
            // A late start only fills membership; it cannot reopen a terminal
            // or waiting agent. Idle is explicitly resumable.
            if (!existed || agent.status === "idle")
                applyStatus(agent, "running");
            break;
        case "task.progress": {
            var progressStatus = knownStatus(payload.status);
            if (progressStatus !== "")
                applyStatus(agent, progressStatus);
            else if ((payload.usageSnapshot !== true || !existed)
                    && !terminal(agent.status) && agent.status !== "idle")
                applyStatus(agent, "running");
            break;
        }
        case "task.updated":
            applyStatus(agent, knownStatus(payload.status));
            break;
        case "task.completed":
            if (!terminal(agent.status)) {
                var completedStatus = payload.status === "failed" ? "failed"
                    : payload.status === "stopped" ? "interrupted" : "completed";
                applyStatus(agent, completedStatus);
            }
            break;
        default:
            break;
        }
    }

    // A settled workflow coordinator implies that members missing their own
    // terminal row are no longer live either.
    var ids = Object.keys(agents);
    for (var coordinatorIndex = 0; coordinatorIndex < ids.length; coordinatorIndex++) {
        var coordinator = agents[ids[coordinatorIndex]];
        if (coordinator.kind !== "workflow" || !terminal(coordinator.status))
            continue;
        for (var memberIndex = 0; memberIndex < ids.length; memberIndex++) {
            var member = agents[ids[memberIndex]];
            if (member.parentAgentId === coordinator.id && active(member.status))
                member.status = coordinator.status === "completed" ? "completed" : "interrupted";
        }
    }
    if (sessionLive === false) {
        for (var stoppedIndex = 0; stoppedIndex < ids.length; stoppedIndex++) {
            var stopped = agents[ids[stoppedIndex]];
            if (active(stopped.status))
                stopped.status = "interrupted";
        }
    }
    var count = 0;
    for (var countIndex = 0; countIndex < ids.length; countIndex++) {
        if (active(agents[ids[countIndex]].status))
            count++;
    }
    return count;
}

// The provider's update_plan calls arrive in the detail stream as persisted
// turn.plan.updated activities. Reduce the latest update for the current turn
// to the small, stable shape the compact thread progress card needs.
function taskProgress(activities, turnId) {
    var targetTurnId = typeof turnId === "string" ? turnId : "";
    var values = Array.isArray(activities) ? activities : [];
    var latest = null;
    for (var i = 0; i < values.length; i++) {
        var activity = values[i];
        if (!activity || activity.kind !== "turn.plan.updated"
                || targetTurnId !== "" && activity.turnId !== targetTurnId)
            continue;
        var rawPlan = activity.payload && Array.isArray(activity.payload.plan)
            ? activity.payload.plan : [];
        var items = [];
        for (var planIndex = 0; planIndex < rawPlan.length; planIndex++) {
            var raw = rawPlan[planIndex];
            if (!raw || typeof raw.step !== "string" || raw.step.trim() === "")
                continue;
            var compactStatus = typeof raw.status === "string"
                ? raw.status.replace(/[_-]/g, "").toLowerCase() : "";
            var status = compactStatus === "completed" || compactStatus === "done"
                ? "completed"
                : compactStatus === "inprogress" || compactStatus === "running"
                    ? "inProgress" : "pending";
            items.push({ step: raw.step.trim(), status: status });
        }
        if (items.length > 0)
            latest = { activity: activity, items: items };
    }
    if (!latest)
        return null;

    var completedCount = 0;
    var currentIndex = -1;
    for (var itemIndex = 0; itemIndex < latest.items.length; itemIndex++) {
        if (latest.items[itemIndex].status === "completed")
            completedCount++;
        else if (currentIndex < 0 && latest.items[itemIndex].status === "inProgress")
            currentIndex = itemIndex;
    }
    if (currentIndex < 0) {
        for (var pendingIndex = 0; pendingIndex < latest.items.length; pendingIndex++) {
            if (latest.items[pendingIndex].status === "pending") {
                currentIndex = pendingIndex;
                break;
            }
        }
    }
    return {
        key: typeof latest.activity.id === "string" && latest.activity.id !== ""
            ? latest.activity.id
            : (latest.activity.createdAt || targetTurnId || JSON.stringify(latest.items)),
        items: latest.items,
        total: latest.items.length,
        completedCount: completedCount,
        currentIndex: currentIndex,
        activeStep: currentIndex >= 0 ? latest.items[currentIndex].step : "All tasks complete"
    };
}

function lastActivityMs(thread) {
    var turn = thread && thread.latestTurn ? thread.latestTurn : null;
    var stamps = [thread ? thread.latestUserMessageAt : null,
                  turn ? turn.requestedAt : null,
                  turn ? turn.startedAt : null,
                  turn ? turn.completedAt : null];
    var latest = NaN;
    for (var i = 0; i < stamps.length; i++) {
        var ms = parseMs(stamps[i]);
        if (!isNaN(ms) && (isNaN(latest) || ms > latest))
            latest = ms;
    }
    return latest;
}

function hasQueuedTurnStart(thread, nowMs) {
    if (!thread)
        return false;
    var messageMs = parseMs(thread.latestUserMessageAt);
    if (isNaN(messageMs))
        return false;
    if (thread.session && thread.session.status === "error")
        return false;
    if (Math.abs(nowMs - messageMs) > QUEUED_TURN_GRACE_MS)
        return false;
    var turn = thread.latestTurn;
    if (!turn)
        return true;
    var stamps = [turn.requestedAt, turn.startedAt, turn.completedAt];
    for (var i = 0; i < stamps.length; i++) {
        var ms = parseMs(stamps[i]);
        if (!isNaN(ms) && ms >= messageMs)
            return false;
    }
    return true;
}

function isEffectivelySettled(thread, nowMs, autoSettleAfterDays) {
    if (!thread || thread.hasPendingApprovals || thread.hasPendingUserInput)
        return false;
    var sessionStatus = thread.session && typeof thread.session.status === "string"
        ? thread.session.status : "";
    if (sessionStatus === "starting" || sessionStatus === "running")
        return false;
    if (hasQueuedTurnStart(thread, nowMs)) {
        var adjudicated = thread.settledOverride === "settled"
            && parseMs(thread.settledAt) >= parseMs(thread.latestUserMessageAt);
        if (!adjudicated)
            return false;
    }
    if (thread.settledOverride === "settled")
        return true;
    if (thread.settledOverride === "active")
        return false;
    if (!(autoSettleAfterDays > 0))
        return false;
    var last = lastActivityMs(thread);
    return !isNaN(last) && last < nowMs - autoSettleAfterDays * DAY_MS;
}

function isEffectivelySnoozed(thread, nowMs) {
    if (!thread)
        return false;
    var wake = parseMs(thread.snoozedUntil);
    if (isNaN(wake) || wake <= nowMs)
        return false;
    if (thread.hasPendingApprovals || thread.hasPendingUserInput)
        return false;
    var snoozedAt = parseMs(thread.snoozedAt);
    if (thread.session && thread.session.status === "error"
            && (isNaN(snoozedAt) || parseMs(thread.session.updatedAt) > snoozedAt))
        return false;
    var turn = thread.latestTurn;
    if (!isNaN(snoozedAt) && turn && turn.state === "completed"
            && parseMs(turn.completedAt) > snoozedAt)
        return false;
    return true;
}

function threadClass(thread) {
    if (thread.hasPendingApprovals || thread.hasPendingUserInput)
        return "attention";
    var sessionStatus = thread.session && typeof thread.session.status === "string"
        ? thread.session.status : "";
    var turnStatus = thread.latestTurn && typeof thread.latestTurn.state === "string"
        ? thread.latestTurn.state : "";
    if (sessionStatus === "starting" || sessionStatus === "running" || turnStatus === "running")
        return "running";
    if (sessionStatus === "error" || turnStatus === "error")
        return "error";
    // Native background work can outlive the foreground turn. The shell
    // summary carries that separately because the session is already ready
    // and the latest turn already completed by then. A session failure wins
    // above so stale liveness never hides something that needs attention.
    if (thread.backgroundLiveness === "working")
        return "running";
    if (thread.backgroundLiveness === "monitoring")
        return "monitoring";
    if (turnStatus === "completed")
        return "done";
    return "idle";
}

function canOperateLifecycle(thread, nowMs) {
    if (!thread || thread.hasPendingApprovals || thread.hasPendingUserInput)
        return false;
    var sessionStatus = thread.session && typeof thread.session.status === "string"
        ? thread.session.status : "";
    var turnStatus = thread.latestTurn && typeof thread.latestTurn.state === "string"
        ? thread.latestTurn.state : "";
    // The dropdown deliberately keeps both settle and snooze unavailable
    // while work is live, even though the upstream server permits snoozing it.
    if (sessionStatus === "starting" || sessionStatus === "running" || turnStatus === "running")
        return false;
    return !hasQueuedTurnStart(thread, nowMs);
}

function canPrompt(thread, nowMs) {
    return canOperateLifecycle(thread, nowMs)
        && thread.hasActionableProposedPlan !== true;
}

function projectThread(thread, projectMap, nowMs, lifecycle) {
    var project = projectMap && projectMap[thread.projectId]
        ? projectMap[thread.projectId] : null;
    var cls = lifecycle === "active" ? threadClass(thread) : lifecycle;
    var modelSelection = thread.modelSelection && typeof thread.modelSelection === "object"
        ? thread.modelSelection : {};
    var sessionStatus = thread.session && typeof thread.session.status === "string"
        ? thread.session.status : "";
    var turnStatus = thread.latestTurn && typeof thread.latestTurn.state === "string"
        ? thread.latestTurn.state : "";
    return {
        id: thread.id,
        projectId: thread.projectId,
        title: typeof thread.title === "string" ? thread.title : "Untitled thread",
        project: project && typeof project.title === "string" ? project.title : "",
        cls: cls,
        lifecycle: lifecycle,
        model: typeof modelSelection.model === "string" ? modelSelection.model : "",
        modelSelection: modelSelection,
        runtimeMode: typeof thread.runtimeMode === "string" ? thread.runtimeMode : "full-access",
        interactionMode: typeof thread.interactionMode === "string"
            ? thread.interactionMode : "default",
        branch: thread.branch === null || typeof thread.branch === "string" ? thread.branch : null,
        worktreePath: thread.worktreePath === null || typeof thread.worktreePath === "string"
            ? thread.worktreePath : null,
        pendingApprovals: thread.hasPendingApprovals === true,
        pendingInput: thread.hasPendingUserInput === true,
        planReady: thread.hasActionableProposedPlan === true,
        sessionStatus: sessionStatus,
        foregroundWorking: sessionStatus === "starting" || sessionStatus === "running"
            || turnStatus === "running",
        backgroundLiveness: thread.backgroundLiveness === "working"
                || thread.backgroundLiveness === "monitoring"
            ? thread.backgroundLiveness : null,
        workingStartedAt: cls === "running" ? resolveWorkingStartedAt(thread) : null,
        canPrompt: lifecycle === "active" && canPrompt(thread, nowMs),
        canLifecycle: canOperateLifecycle(thread, nowMs),
        started: thread.latestTurn !== null && thread.latestTurn !== undefined
            || thread.session !== null && thread.session !== undefined,
        settledOverride: thread.settledOverride || null,
        settledAt: thread.settledAt || null,
        snoozedUntil: thread.snoozedUntil || null,
        snoozedAt: thread.snoozedAt || null,
        pinned: typeof thread.pinnedAt === "string",
        pinnedAt: typeof thread.pinnedAt === "string" ? thread.pinnedAt : null,
        pinOrderKey: typeof thread.pinOrderKey === "string" ? thread.pinOrderKey : null,
        titleRegeneration: thread.titleRegeneration || null,
        updatedAt: typeof thread.updatedAt === "string" ? thread.updatedAt : "",
        createdAt: typeof thread.createdAt === "string" ? thread.createdAt : ""
    };
}

function classifyThreads(threadMap, projectMap, nowMs, autoSettleAfterDays) {
    var active = [];
    var pinned = [];
    var snoozed = [];
    var settled = [];
    var runningCount = 0;
    var monitoringCount = 0;
    var attentionCount = 0;
    var doneCount = 0;
    var rank = { attention: 0, error: 1, running: 2, monitoring: 3, done: 4, idle: 5 };
    var countClass = function(cls) {
        if (cls === "running")
            runningCount++;
        else if (cls === "monitoring")
            monitoringCount++;
        else if (cls === "attention" || cls === "error")
            attentionCount++;
        else if (cls === "done")
            doneCount++;
    };
    var source = threadMap && typeof threadMap === "object" ? threadMap : {};
    for (var id in source) {
        var thread = source[id];
        if (!thread || thread.archivedAt)
            continue;
        // Snooze is an overlay and therefore wins over settledness — and over
        // a pin, matching the reference sidebar.
        if (isEffectivelySnoozed(thread, nowMs)) {
            snoozed.push(projectThread(thread, projectMap, nowMs, "snoozed"));
            continue;
        }
        // A pin beats settledness: the reference client keeps a pinned thread
        // in its Pinned section however quiet it goes, so it stays a live row
        // here too — classified and counted like any active thread.
        if (typeof thread.pinnedAt === "string") {
            var pinnedProjected = projectThread(thread, projectMap, nowMs, "active");
            pinned.push(pinnedProjected);
            countClass(pinnedProjected.cls);
            continue;
        }
        if (isEffectivelySettled(thread, nowMs, autoSettleAfterDays)) {
            settled.push(projectThread(thread, projectMap, nowMs, "settled"));
            continue;
        }
        var projected = projectThread(thread, projectMap, nowMs, "active");
        active.push(projected);
        countClass(projected.cls);
    }
    active.sort(function(left, right) {
        var rankDelta = rank[left.cls] - rank[right.cls];
        if (rankDelta !== 0)
            return rankDelta;
        var timeDelta = parseMs(right.updatedAt) - parseMs(left.updatedAt);
        if (!isNaN(timeDelta) && timeDelta !== 0)
            return timeDelta;
        return String(left.id).localeCompare(String(right.id));
    });
    pinned.sort(comparePinned);
    var byRecent = function(left, right) {
        var delta = parseMs(right.updatedAt) - parseMs(left.updatedAt);
        return !isNaN(delta) && delta !== 0
            ? delta : String(left.id).localeCompare(String(right.id));
    };
    snoozed.sort(byRecent);
    settled.sort(byRecent);
    return {
        active: active,
        pinned: pinned,
        snoozed: snoozed,
        settled: settled,
        runningCount: runningCount,
        monitoringCount: monitoringCount,
        attentionCount: attentionCount,
        doneCount: doneCount
    };
}

// The reference client's pinned order: threads carrying an orderKey first,
// ascending (plain string comparison — the keys are fractional indexes),
// then keyless pins newest-created first.
function comparePinned(left, right) {
    var tieBreak = String(left.id).localeCompare(String(right.id));
    if (left.pinOrderKey !== null && right.pinOrderKey !== null) {
        if (left.pinOrderKey < right.pinOrderKey)
            return -1;
        if (left.pinOrderKey > right.pinOrderKey)
            return 1;
        return tieBreak;
    }
    if (left.pinOrderKey !== null)
        return -1;
    if (right.pinOrderKey !== null)
        return 1;
    var delta = parseMs(right.createdAt) - parseMs(left.createdAt);
    return !isNaN(delta) && delta !== 0 ? delta : tieBreak;
}

function normalizeScopes(rawScope, metadataKnown) {
    var known = metadataKnown === true;
    var values = [];
    if (known && typeof rawScope === "string") {
        values = rawScope.split(/\s+/).map(function(value) { return value.trim(); })
            .filter(function(value) { return value !== ""; });
    } else if (known && Array.isArray(rawScope)) {
        values = rawScope.filter(function(value) { return typeof value === "string"; });
    }
    return {
        known: known,
        values: values,
        canRead: !known || values.indexOf("orchestration:read") >= 0,
        canOperate: !known || values.indexOf("orchestration:operate") >= 0
    };
}

function sanitizeChoice(raw) {
    if (!raw || typeof raw.id !== "string" || raw.id.trim() === ""
            || typeof raw.label !== "string" || raw.label.trim() === "")
        return null;
    return {
        id: raw.id.trim(),
        label: raw.label.trim(),
        description: typeof raw.description === "string" ? raw.description.trim() : "",
        isDefault: raw.isDefault === true
    };
}

function sanitizeDescriptor(raw) {
    if (!raw || typeof raw.id !== "string" || raw.id.trim() === ""
            || typeof raw.label !== "string" || raw.label.trim() === "")
        return null;
    if (raw.type === "boolean") {
        return {
            id: raw.id.trim(),
            label: raw.label.trim(),
            description: typeof raw.description === "string" ? raw.description.trim() : "",
            type: "boolean",
            currentValue: typeof raw.currentValue === "boolean" ? raw.currentValue : false
        };
    }
    if (raw.type !== "select" || !Array.isArray(raw.options))
        return null;
    var choices = raw.options.map(sanitizeChoice).filter(function(choice) { return choice !== null; });
    if (choices.length === 0)
        return null;
    return {
        id: raw.id.trim(),
        label: raw.label.trim(),
        description: typeof raw.description === "string" ? raw.description.trim() : "",
        type: "select",
        options: choices,
        currentValue: typeof raw.currentValue === "string" ? raw.currentValue.trim() : "",
        promptInjectedValues: Array.isArray(raw.promptInjectedValues)
            ? raw.promptInjectedValues.filter(function(value) {
                return typeof value === "string" && value.trim() !== "";
            }).map(function(value) { return value.trim(); }) : []
    };
}

function sanitizeModel(raw) {
    if (!raw || typeof raw.slug !== "string" || raw.slug.trim() === "")
        return null;
    var descriptors = raw.capabilities && Array.isArray(raw.capabilities.optionDescriptors)
        ? raw.capabilities.optionDescriptors.map(sanitizeDescriptor)
            .filter(function(value) { return value !== null; }) : [];
    return {
        slug: raw.slug.trim(),
        name: typeof raw.name === "string" && raw.name.trim() !== ""
            ? raw.name.trim() : raw.slug.trim(),
        shortName: typeof raw.shortName === "string" ? raw.shortName.trim() : "",
        subProvider: typeof raw.subProvider === "string" ? raw.subProvider.trim() : "",
        isCustom: raw.isCustom === true,
        isDefault: raw.isDefault === true,
        isLegacy: raw.isLegacy === true,
        optionDescriptors: descriptors
    };
}

function sanitizeServerConfig(config) {
    var environment = config && config.environment && typeof config.environment === "object"
        ? config.environment : {};
    var rawCapabilities = environment.capabilities && typeof environment.capabilities === "object"
        ? environment.capabilities : {};
    var capabilities = {
        repositoryIdentity: rawCapabilities.repositoryIdentity === true,
        connectionProbe: rawCapabilities.connectionProbe === true,
        threadSettlement: rawCapabilities.threadSettlement === true,
        threadSnooze: rawCapabilities.threadSnooze === true,
        threadPinning: rawCapabilities.threadPinning === true,
        threadPinReorder: rawCapabilities.threadPinReorder === true,
        threadTitleRegeneration: rawCapabilities.threadTitleRegeneration === true
    };
    var providers = [];
    var rawProviders = config && Array.isArray(config.providers) ? config.providers : [];
    for (var i = 0; i < rawProviders.length; i++) {
        var raw = rawProviders[i];
        if (!raw || typeof raw.instanceId !== "string" || raw.instanceId.trim() === ""
                || typeof raw.driver !== "string" || raw.driver.trim() === "")
            continue;
        var models = Array.isArray(raw.models) ? raw.models.map(sanitizeModel)
            .filter(function(value) { return value !== null; }) : [];
        providers.push({
            instanceId: raw.instanceId.trim(),
            driver: raw.driver.trim(),
            displayName: typeof raw.displayName === "string" && raw.displayName.trim() !== ""
                ? raw.displayName.trim() : raw.instanceId.trim(),
            accentColor: typeof raw.accentColor === "string" ? raw.accentColor.trim() : "",
            continuationGroupKey: raw.continuation && typeof raw.continuation.groupKey === "string"
                ? raw.continuation.groupKey : "",
            showInteractionModeToggle: raw.showInteractionModeToggle !== false,
            requiresNewThreadForModelChange: raw.requiresNewThreadForModelChange === true,
            enabled: raw.enabled === true,
            installed: raw.installed === true,
            available: raw.availability !== "unavailable",
            status: typeof raw.status === "string" ? raw.status : "error",
            ready: raw.enabled === true && raw.availability !== "unavailable"
                && raw.status === "ready",
            message: typeof raw.message === "string" ? raw.message : "",
            models: models
        });
    }
    return {
        environmentId: typeof environment.environmentId === "string"
            ? environment.environmentId : "",
        label: typeof environment.label === "string" ? environment.label : "",
        serverVersion: typeof environment.serverVersion === "string"
            ? environment.serverVersion : "",
        capabilities: capabilities,
        providers: providers
    };
}

function findProvider(providers, instanceId) {
    var list = Array.isArray(providers) ? providers : [];
    for (var i = 0; i < list.length; i++) {
        if (list[i].instanceId === instanceId)
            return list[i];
    }
    return null;
}

function findModel(provider, slug) {
    if (!provider || !Array.isArray(provider.models))
        return null;
    for (var i = 0; i < provider.models.length; i++) {
        if (provider.models[i].slug === slug)
            return provider.models[i];
    }
    return null;
}

// Map a provider driver (or any provider-ish hint string) onto one of the
// bundled brand glyphs. Servers name drivers freely ("claudeAgent", "codex"),
// so match by family rather than exact id.
function providerIconName(hint) {
    if (typeof hint !== "string" || hint === "")
        return "";
    if (/claude|anthropic/i.test(hint))
        return "claude";
    if (/codex|openai|gpt/i.test(hint))
        return "openai";
    if (/kimi|moonshot/i.test(hint))
        return "kimi";
    return "";
}

// Resolve the glyph for a raw thread. Prefer the live session's provider,
// then the persisted selection; fall back to matching the hint strings
// directly so the glyph survives a missing provider snapshot.
function threadProviderIconName(thread, providers) {
    var persisted = thread && thread.modelSelection
        && typeof thread.modelSelection === "object" ? thread.modelSelection : {};
    var session = thread && thread.session && typeof thread.session === "object"
        ? thread.session : {};
    var hints = [
        session.providerInstanceId,
        persisted.instanceId,
        persisted.providerInstanceId,
        session.providerName,
        persisted.provider,
        persisted.driver
    ];
    for (var i = 0; i < hints.length; i++) {
        var hint = hints[i];
        if (typeof hint !== "string" || hint === "")
            continue;
        var provider = findProvider(providers, hint);
        var icon = providerIconName(provider ? provider.driver : hint);
        if (icon !== "")
            return icon;
    }
    return "";
}

// "Claude · Opus 4.5"-style summary of the provider/model a thread would
// continue with; empty while no provider snapshot is available.
function threadSelectionLabel(thread, providers) {
    var selection = selectionForThread(thread, providers);
    if (!selection)
        return "";
    var provider = findProvider(providers, selection.instanceId);
    if (!provider)
        return "";
    var model = findModel(provider, selection.model);
    var modelName = typeof selection.model === "string" ? selection.model : "";
    if (model) {
        if (typeof model.shortName === "string" && model.shortName !== "")
            modelName = model.shortName;
        else if (typeof model.name === "string" && model.name !== "")
            modelName = model.name;
    }
    return modelName !== "" ? provider.displayName + " · " + modelName
        : provider.displayName;
}

function defaultModel(provider) {
    if (!provider || !Array.isArray(provider.models) || provider.models.length === 0)
        return "";
    var i;
    for (i = 0; i < provider.models.length; i++) {
        if (provider.models[i].isDefault && !provider.models[i].isCustom)
            return provider.models[i].slug;
    }
    for (i = 0; i < provider.models.length; i++) {
        if (!provider.models[i].isCustom)
            return provider.models[i].slug;
    }
    return provider.models[0].slug;
}

function selectionObject(instanceId, model, options) {
    var result = { instanceId: instanceId, model: model };
    if (Array.isArray(options) && options.length > 0)
        result.options = options;
    return result;
}

function selectionValues(rawSelections) {
    var values = {};
    if (Array.isArray(rawSelections)) {
        for (var i = 0; i < rawSelections.length; i++) {
            var selection = rawSelections[i];
            if (selection && typeof selection.id === "string"
                    && (typeof selection.value === "string" || typeof selection.value === "boolean"))
                values[selection.id] = selection.value;
        }
    } else if (rawSelections && typeof rawSelections === "object") {
        for (var id in rawSelections) {
            if (typeof rawSelections[id] === "string" || typeof rawSelections[id] === "boolean")
                values[id] = rawSelections[id];
        }
    }
    return values;
}

function normalizeTraits(descriptors, rawSelections) {
    var values = selectionValues(rawSelections);
    var normalized = [];
    var source = Array.isArray(descriptors) ? descriptors : [];
    for (var i = 0; i < source.length; i++) {
        var descriptor = sanitizeDescriptor(source[i]);
        if (!descriptor)
            continue;
        var selected = values[descriptor.id];
        if (descriptor.type === "boolean") {
            descriptor.currentValue = typeof selected === "boolean"
                ? selected : descriptor.currentValue;
        } else {
            var advertisedCurrent = descriptor.currentValue;
            var candidate = typeof selected === "string" ? selected : descriptor.currentValue;
            var valid = descriptor.options.some(function(option) { return option.id === candidate; });
            var injected = descriptor.promptInjectedValues.indexOf(candidate) >= 0;
            if (!valid || injected) {
                var currentValid = descriptor.options.some(function(option) {
                    return option.id === advertisedCurrent;
                }) && descriptor.promptInjectedValues.indexOf(advertisedCurrent) < 0;
                var fallback = !injected && currentValid
                    ? { id: advertisedCurrent }
                    : descriptor.options.find(function(option) { return option.isDefault; });
                candidate = fallback ? fallback.id : descriptor.options[0].id;
            }
            descriptor.currentValue = candidate;
        }
        normalized.push(descriptor);
    }
    return normalized;
}

function traitSelections(descriptors) {
    var result = [];
    var source = Array.isArray(descriptors) ? descriptors : [];
    for (var i = 0; i < source.length; i++) {
        var descriptor = source[i];
        if (!descriptor || typeof descriptor.id !== "string")
            continue;
        var value = descriptor.currentValue;
        if (descriptor.type === "boolean" && typeof value === "boolean")
            result.push({ id: descriptor.id, value: value });
        else if (descriptor.type === "select" && typeof value === "string" && value !== "")
            result.push({ id: descriptor.id, value: value });
    }
    return result;
}

function isUltrathinkPrompt(prompt) {
    return typeof prompt === "string" && /\bultrathink\b/i.test(prompt);
}

// Prompt-injected values are not persisted in modelSelection.options, but the
// picker still needs to display the effective value. Upstream treats the first
// advertised select trait as the prompt-controlled effort selector.
function traitsForPrompt(descriptors, rawSelections, prompt) {
    var normalized = normalizeTraits(descriptors, rawSelections);
    if (!isUltrathinkPrompt(prompt))
        return normalized;
    for (var i = 0; i < normalized.length; i++) {
        var descriptor = normalized[i];
        if (descriptor.type !== "select")
            continue;
        if (descriptor.promptInjectedValues.indexOf("ultrathink") >= 0)
            descriptor.currentValue = "ultrathink";
        break;
    }
    return normalized;
}

function applyTraitValue(descriptors, descriptorId, rawValue, prompt) {
    var normalized = normalizeTraits(descriptors, traitSelections(descriptors));
    var at = normalized.findIndex(function(descriptor) { return descriptor.id === descriptorId; });
    if (at < 0)
        return { descriptors: normalized, selections: traitSelections(normalized), prompt: prompt, error: "Unknown trait" };
    var descriptor = normalized[at];
    var nextPrompt = typeof prompt === "string" ? prompt : "";
    if (descriptor.type === "boolean") {
        if (typeof rawValue !== "boolean")
            return { descriptors: normalized, selections: traitSelections(normalized), prompt: nextPrompt, error: "Invalid trait value" };
        descriptor.currentValue = rawValue;
    } else {
        if (typeof rawValue !== "string"
                || !descriptor.options.some(function(option) { return option.id === rawValue; }))
            return { descriptors: normalized, selections: traitSelections(normalized), prompt: nextPrompt, error: "Invalid trait value" };
        if (descriptor.promptInjectedValues.indexOf(rawValue) >= 0 && rawValue === "ultrathink") {
            var trimmed = nextPrompt.trim();
            nextPrompt = trimmed === "" ? "Ultrathink:\n"
                : /^Ultrathink:/i.test(trimmed) ? trimmed : "Ultrathink:\n" + trimmed;
            return { descriptors: normalized, selections: traitSelections(normalized), prompt: nextPrompt, error: "" };
        }
        var withoutPrefix = nextPrompt.replace(/^Ultrathink:\s*/i, "");
        if (isUltrathinkPrompt(withoutPrefix) && descriptor.promptInjectedValues.length > 0)
            return { descriptors: normalized, selections: traitSelections(normalized), prompt: nextPrompt,
                error: "Remove ultrathink from the prompt before changing this trait" };
        if (descriptor.promptInjectedValues.length > 0 && /^Ultrathink:/i.test(nextPrompt))
            nextPrompt = withoutPrefix;
        descriptor.currentValue = rawValue;
    }
    return { descriptors: normalized, selections: traitSelections(normalized), prompt: nextPrompt, error: "" };
}

function preferredEffortSelection(model, requestedEffort) {
    if (!model || !Array.isArray(model.optionDescriptors)
            || typeof requestedEffort !== "string" || requestedEffort === "")
        return null;
    var wanted = requestedEffort.toLowerCase();
    for (var i = 0; i < model.optionDescriptors.length; i++) {
        var descriptor = sanitizeDescriptor(model.optionDescriptors[i]);
        if (!descriptor || descriptor.type !== "select")
            continue;
        var id = descriptor.id.toLowerCase().replace(/[^a-z0-9]/g, "");
        var label = descriptor.label.toLowerCase().replace(/[^a-z0-9]/g, "");
        if (id !== "effort" && id !== "reasoning" && id !== "reasoningeffort"
                && label !== "effort" && label !== "reasoning"
                && label !== "reasoningeffort")
            continue;
        var option = descriptor.options.find(function(candidate) {
            return candidate.id.toLowerCase() === wanted;
        });
        if (option)
            return { id: descriptor.id, value: option.id };
    }
    return null;
}

// The menubar has one global new-thread preference, independent of per-project
// defaults. Prefer a provider that can satisfy both the requested model and
// effort; retain the project's advertised selection as a compatibility fallback.
function selectionForNewThread(project, providers, preference) {
    var fallback = selectionForProject(project, providers);
    if (!preference || typeof preference.model !== "string" || preference.model === "")
        return fallback;
    var ready = (Array.isArray(providers) ? providers : []).filter(function(provider) {
        return provider.ready === true && Array.isArray(provider.models)
            && provider.models.length > 0;
    });
    var candidates = [];
    for (var i = 0; i < ready.length; i++) {
        var model = findModel(ready[i], preference.model);
        if (model) {
            candidates.push({
                provider: ready[i],
                model: model,
                effort: preferredEffortSelection(model, preference.effort)
            });
        }
    }
    if (candidates.length === 0)
        return fallback;

    var effortCandidates = candidates.filter(function(candidate) {
        return candidate.effort !== null;
    });
    var pool = effortCandidates.length > 0 ? effortCandidates : candidates;
    var preferredInstance = typeof preference.instanceId === "string"
        ? preference.instanceId : "";
    var projectInstance = project && project.defaultModelSelection
        && typeof project.defaultModelSelection.instanceId === "string"
        ? project.defaultModelSelection.instanceId : "";
    var chosen = pool.find(function(candidate) {
        return preferredInstance !== "" && candidate.provider.instanceId === preferredInstance;
    }) || pool.find(function(candidate) {
        return projectInstance !== "" && candidate.provider.instanceId === projectInstance;
    }) || pool[0];
    var selections = chosen.effort ? [chosen.effort] : null;
    var traits = normalizeTraits(chosen.model.optionDescriptors, selections);
    return selectionObject(chosen.provider.instanceId, chosen.model.slug,
        traitSelections(traits));
}

function selectionForProject(project, providers) {
    var ready = (Array.isArray(providers) ? providers : []).filter(function(provider) {
        return provider.ready === true && Array.isArray(provider.models) && provider.models.length > 0;
    });
    var preferred = project && project.defaultModelSelection
        ? project.defaultModelSelection : null;
    if (preferred && typeof preferred.instanceId === "string" && typeof preferred.model === "string") {
        var preferredProvider = findProvider(ready, preferred.instanceId);
        var preferredModel = findModel(preferredProvider, preferred.model);
        if (preferredProvider && preferredModel) {
            var preferredTraits = normalizeTraits(preferredModel.optionDescriptors, preferred.options);
            return selectionObject(preferredProvider.instanceId, preferredModel.slug,
                traitSelections(preferredTraits));
        }
    }
    if (ready.length === 0)
        return null;
    var provider = ready[0];
    var modelSlug = defaultModel(provider);
    var model = findModel(provider, modelSlug);
    var traits = normalizeTraits(model ? model.optionDescriptors : [], null);
    return selectionObject(provider.instanceId, modelSlug, traitSelections(traits));
}

// Resolve a persisted thread selection against the latest provider snapshot.
// The live session instance wins because it is the provider that must continue
// the conversation. Older shells may only expose a driver-shaped `provider`
// field, so that is accepted as a compatibility fallback. If a configured
// model disappeared, show the provider's current default instead of leaving
// the composer in an impossible, unsendable state.
function selectionForThread(thread, providers) {
    var ready = (Array.isArray(providers) ? providers : []).filter(function(provider) {
        return provider.ready === true && Array.isArray(provider.models)
            && provider.models.length > 0;
    });
    if (ready.length === 0)
        return null;

    var persisted = thread && thread.modelSelection
        && typeof thread.modelSelection === "object" ? thread.modelSelection : {};
    var session = thread && thread.session && typeof thread.session === "object"
        ? thread.session : {};
    var instanceCandidates = [
        session.providerInstanceId,
        persisted.instanceId,
        persisted.providerInstanceId
    ];
    var provider = null;
    for (var i = 0; i < instanceCandidates.length && !provider; i++) {
        if (typeof instanceCandidates[i] === "string" && instanceCandidates[i] !== "")
            provider = findProvider(ready, instanceCandidates[i]);
    }

    if (!provider) {
        var driverCandidates = [session.providerName, persisted.provider, persisted.driver];
        for (var j = 0; j < driverCandidates.length && !provider; j++) {
            var driver = driverCandidates[j];
            if (typeof driver !== "string" || driver === "")
                continue;
            provider = ready.find(function(candidate) {
                return candidate.driver === driver || candidate.instanceId === driver;
            }) || null;
        }
    }
    if (!provider)
        provider = ready[0];

    var persistedModel = typeof persisted.model === "string" ? persisted.model : "";
    var modelSlug = findModel(provider, persistedModel)
        ? persistedModel : defaultModel(provider);
    var model = findModel(provider, modelSlug);
    var traits = normalizeTraits(model ? model.optionDescriptors : [], persisted.options);
    return selectionObject(provider.instanceId, modelSlug, traitSelections(traits));
}

function threadStarted(thread, detailMessageCount) {
    return !!thread && (thread.started === true || thread.latestTurn != null
        || thread.session != null || detailMessageCount > 0);
}

function selectableProvidersForThread(thread, providers, detailMessageCount) {
    var ready = (Array.isArray(providers) ? providers : []).filter(function(provider) {
        return provider.ready === true && provider.models.length > 0;
    });
    if (!threadStarted(thread, detailMessageCount))
        return ready;
    var currentId = thread && thread.session && typeof thread.session.providerInstanceId === "string"
        ? thread.session.providerInstanceId
        : thread && thread.modelSelection ? thread.modelSelection.instanceId : "";
    var current = findProvider(providers, currentId);
    if (!current)
        return ready;
    return ready.filter(function(provider) {
        return provider.driver === current.driver
            && (current.continuationGroupKey === ""
                || provider.continuationGroupKey === current.continuationGroupKey);
    });
}

function modelChangeAllowed(thread, nextSelection, providers, detailMessageCount) {
    if (!thread || !nextSelection)
        return false;
    var currentSelection = thread.modelSelection || {};
    var currentInstanceId = thread.session
        && typeof thread.session.providerInstanceId === "string"
        ? thread.session.providerInstanceId : currentSelection.instanceId;
    if (currentInstanceId === nextSelection.instanceId
            && currentSelection.model === nextSelection.model)
        return true;
    if (!threadStarted(thread, detailMessageCount))
        return true;
    var selectable = selectableProvidersForThread(thread, providers, detailMessageCount);
    if (!findProvider(selectable, nextSelection.instanceId))
        return false;
    var current = findProvider(providers, currentInstanceId);
    var next = findProvider(providers, nextSelection.instanceId);
    return !(current && current.requiresNewThreadForModelChange
        || next && next.requiresNewThreadForModelChange);
}

// ---- model picker ------------------------------------------------------
//
// The reference client's picker is a provider rail beside one list: pick a
// provider on the left, see its models on the right, with the retired ones
// folded into a "Legacy models" section you open when you want them. Typing
// abandons the rail entirely and ranks every ready provider's models at once,
// because a search you have to scope first is not a search.
//
// All of it is arithmetic over the config snapshot, so it lives here where it
// can be tested without a running shell.

var FAVORITES_RAIL_ID = "favorites";

function modelFavoriteKey(instanceId, slug) {
    return String(instanceId || "") + ":" + String(slug || "");
}

function favoriteKeySet(favorites) {
    var keys = {};
    var list = Array.isArray(favorites) ? favorites : [];
    for (var i = 0; i < list.length; i++) {
        var entry = list[i];
        if (entry && typeof entry.instanceId === "string" && typeof entry.model === "string")
            keys[modelFavoriteKey(entry.instanceId, entry.model)] = true;
    }
    return keys;
}

// Rail entries are every *configured* instance, not only the working ones:
// a provider that needs a login should be visible and say so, not vanish.
function providerRailEntries(providers) {
    var list = Array.isArray(providers) ? providers : [];
    var entries = [];
    for (var i = 0; i < list.length; i++) {
        var provider = list[i];
        if (!provider || provider.enabled !== true)
            continue;
        entries.push({
            instanceId: provider.instanceId,
            driver: provider.driver,
            displayName: provider.displayName,
            icon: providerIconName(provider.driver),
            ready: provider.ready === true,
            message: typeof provider.message === "string" ? provider.message : "",
            tooltip: providerRailTooltip(provider)
        });
    }
    return entries;
}

function providerRailTooltip(provider) {
    var label = provider.displayName;
    if (provider.ready === true)
        return label;
    var kind = provider.status === "error" ? "Unavailable"
        : provider.available === false ? "Not installed"
        : provider.status === "warning" ? "Limited" : "Not ready";
    var message = typeof provider.message === "string" ? provider.message.trim() : "";
    return message !== "" ? label + " — " + kind + ". " + message : label + " — " + kind + ".";
}

// Dots survive normalization because model names are versions: splitting
// "5.4" into "5" and "4" makes it match "Opus 4.5" as well as "GPT-5.4",
// which is the one comparison this search exists to get right.
function normalizeSearchText(value) {
    return String(value === undefined || value === null ? "" : value)
        .toLowerCase().replace(/[^a-z0-9.]+/g, " ").replace(/\s+/g, " ").trim();
}

// The shell's established tiering — exact, prefix, word-prefix, substring —
// applied per token so "codex sol" and "sol codex" both land. A token that
// matches nothing disqualifies the row, which is what makes multi-word
// queries narrow instead of widen.
function modelSearchScore(model, query) {
    var tokens = normalizeSearchText(query).split(" ").filter(function(token) {
        return token !== "";
    });
    if (tokens.length === 0)
        return 0;
    var fields = [
        normalizeSearchText(model.label),
        normalizeSearchText(model.slug),
        normalizeSearchText(model.subProvider),
        normalizeSearchText(model.providerLabel),
        normalizeSearchText(model.driver)
    ].filter(function(field) { return field !== ""; });
    var total = 0;
    for (var i = 0; i < tokens.length; i++) {
        var best = -1;
        for (var f = 0; f < fields.length; f++) {
            var score = fieldTokenScore(fields[f], tokens[i], f);
            if (score > best)
                best = score;
        }
        if (best < 0)
            return -1;
        total += best;
    }
    return total;
}

function fieldTokenScore(field, token, fieldIndex) {
    // Later fields are weaker evidence: a hit on the model's own name should
    // outrank the same hit on its provider's.
    var penalty = fieldIndex * 200;
    if (field === token)
        return 10000 - penalty;
    if (field.indexOf(token) === 0)
        return 8000 - penalty;
    var parts = field.split(" ");
    for (var i = 0; i < parts.length; i++) {
        if (parts[i].indexOf(token) === 0)
            return 6000 - penalty;
    }
    if (field.indexOf(token) !== -1)
        return 4000 - penalty;
    return -1;
}

function pickerModelRow(provider, model, favorites) {
    return {
        kind: "model",
        id: modelFavoriteKey(provider.instanceId, model.slug),
        instanceId: provider.instanceId,
        slug: model.slug,
        driver: provider.driver,
        label: model.shortName !== "" ? model.shortName : model.name,
        providerLabel: model.subProvider !== ""
            ? provider.displayName + " · " + model.subProvider : provider.displayName,
        subProvider: model.subProvider,
        icon: providerIconName(provider.driver),
        isLegacy: model.isLegacy === true,
        favorite: favorites[modelFavoriteKey(provider.instanceId, model.slug)] === true
    };
}

// Every model the picker could offer, already flattened and enriched. The
// `allow` predicate is where a thread's model-change guard enters: a model it
// rejects still appears, but carries the reason it cannot be chosen, because
// a silently missing option looks like a bug in the server.
function pickerModelRows(providers, favorites, allow) {
    var list = Array.isArray(providers) ? providers : [];
    var keys = favoriteKeySet(favorites);
    var rows = [];
    for (var i = 0; i < list.length; i++) {
        var provider = list[i];
        if (!provider || provider.ready !== true)
            continue;
        for (var m = 0; m < provider.models.length; m++) {
            var row = pickerModelRow(provider, provider.models[m], keys);
            row.disabledReason = typeof allow === "function"
                ? String(allow(provider.instanceId, provider.models[m].slug) || "") : "";
            rows.push(row);
        }
    }
    return rows;
}

function compareByFavoriteThenOrder(a, b) {
    if (a.favorite !== b.favorite)
        return a.favorite ? -1 : 1;
    return a.order - b.order;
}

/**
 * The rows the panel draws, in order.
 *
 * `railId` is a provider instanceId or "favorites". A non-empty `query`
 * overrides it: search is global by design, so the caller hides the rail
 * while one is typed. Legacy models are split into their own collapsed
 * section per provider, never while searching — a query the user typed is a
 * more specific request than the section's default.
 */
function modelPickerRows(options) {
    var settings = options || {};
    var rows = pickerModelRows(settings.providers, settings.favorites, settings.allow);
    var query = typeof settings.query === "string" ? settings.query.trim() : "";
    var i;
    for (i = 0; i < rows.length; i++)
        rows[i].order = i;

    if (query !== "") {
        var ranked = [];
        for (i = 0; i < rows.length; i++) {
            var score = modelSearchScore(rows[i], query);
            if (score >= 0) {
                rows[i].score = score;
                ranked.push(rows[i]);
            }
        }
        ranked.sort(function(a, b) {
            if (a.score !== b.score)
                return b.score - a.score;
            return compareByFavoriteThenOrder(a, b);
        });
        return ranked;
    }

    var railId = typeof settings.railId === "string" ? settings.railId : "";
    var scoped = [];
    for (i = 0; i < rows.length; i++) {
        if (railId === FAVORITES_RAIL_ID ? rows[i].favorite : rows[i].instanceId === railId)
            scoped.push(rows[i]);
    }
    // The favorites view is a cross-provider shortlist with nothing retired
    // hidden inside it, so it keeps its own flat order.
    if (railId === FAVORITES_RAIL_ID)
        return scoped;

    var current = [];
    var legacy = [];
    for (i = 0; i < scoped.length; i++)
        (scoped[i].isLegacy ? legacy : current).push(scoped[i]);
    current.sort(compareByFavoriteThenOrder);
    if (legacy.length === 0)
        return current;

    var expanded = settings.legacyExpanded === true;
    var section = {
        kind: "legacy",
        id: "legacy:" + railId,
        instanceId: railId,
        count: legacy.length,
        expanded: expanded
    };
    return expanded ? current.concat([section], legacy) : current.concat([section]);
}

// A row's keyboard shortcut is its position among the rows that can actually
// be chosen, so a disabled model does not consume a digit.
function assignPickerShortcuts(rows) {
    var next = 1;
    var list = Array.isArray(rows) ? rows : [];
    for (var i = 0; i < list.length; i++) {
        var usable = list[i].kind === "model" && !list[i].disabledReason;
        list[i].shortcut = usable && next <= 9 ? String(next) : "";
        if (usable && next <= 9)
            next += 1;
    }
    return list;
}

function sameSelection(left, right) {
    if (!left || !right || left.instanceId !== right.instanceId || left.model !== right.model)
        return false;
    var leftOptions = Array.isArray(left.options) ? left.options : [];
    var rightOptions = Array.isArray(right.options) ? right.options : [];
    return JSON.stringify(leftOptions) === JSON.stringify(rightOptions);
}

function normalizedTitle(prompt) {
    if (typeof prompt !== "string")
        return "";
    return prompt.replace(/\s+/g, " ").trim().slice(0, 50);
}

function escapeHtml(value) {
    return String(value == null ? "" : value)
        .replace(/&/g, "&amp;")
        .replace(/</g, "&lt;")
        .replace(/>/g, "&gt;");
}

function escapeHtmlAttribute(value) {
    return escapeHtml(value)
        .replace(/"/g, "&quot;")
        .replace(/'/g, "&#39;");
}

function markdownLinkLabel(label) {
    var code = /^`([^`\n]+)`$/.exec(label);
    if (code)
        return "<tt>" + escapeHtml(code[1]) + "</tt>";
    return escapeHtml(label);
}

// QML Text.linkColor only applies to StyledText. MarkdownText is backed by a
// rich QTextDocument and otherwise keeps Qt's literal #0000ff default. Turn
// ordinary Markdown anchors into equivalent supported inline HTML so their
// foreground is explicit while the rest of the document remains Markdown.
function styleMarkdownLinks(markdown, linkColor) {
    var source = String(markdown == null ? "" : markdown);
    var color = String(linkColor == null ? "" : linkColor).trim();
    if (!/^#[0-9a-f]{6}$/i.test(color))
        color = "#ffffff";
    var linkPattern = /(^|[^!\\])\[([^\]\n]+)\]\((<[^>\n]+>|[^)\s]+)(?:\s+(?:"[^"\n]*"|'[^'\n]*'))?\)/g;
    return source.replace(linkPattern, function(match, prefix, label, destination) {
        if (destination.charAt(0) === "<"
                && destination.charAt(destination.length - 1) === ">")
            destination = destination.slice(1, -1);
        return prefix + "<a href=\"" + escapeHtmlAttribute(destination)
            + "\"><font color=\"" + color + "\">"
            + markdownLinkLabel(label) + "</font></a>";
    });
}

function buildPlanImplementationPrompt(planMarkdown) {
    return "PLEASE IMPLEMENT THIS PLAN:\n" + String(planMarkdown || "").trim();
}

function idSource(input) {
    if (input && typeof input.nextId === "function")
        return input.nextId;
    return function() { return Math.random().toString(16).slice(2); };
}

function buildExistingTurnCommands(input) {
    var nextId = idSource(input);
    var commands = [];
    var current = input.currentThread;
    var selection = input.modelSelection;
    if (!sameSelection(current.modelSelection, selection)) {
        commands.push({
            type: "thread.meta.update",
            commandId: nextId(),
            threadId: current.id,
            modelSelection: selection
        });
    }
    if (input.runtimeMode !== current.runtimeMode) {
        commands.push({
            type: "thread.runtime-mode.set",
            commandId: nextId(),
            threadId: current.id,
            runtimeMode: input.runtimeMode,
            createdAt: input.createdAt
        });
    }
    if (input.interactionMode !== current.interactionMode) {
        commands.push({
            type: "thread.interaction-mode.set",
            commandId: nextId(),
            threadId: current.id,
            interactionMode: input.interactionMode,
            createdAt: input.createdAt
        });
    }
    var turn = {
        type: "thread.turn.start",
        commandId: nextId(),
        threadId: current.id,
        message: {
            messageId: input.messageId || nextId(),
            role: "user",
            text: input.text,
            attachments: []
        },
        modelSelection: selection,
        titleSeed: current.title,
        runtimeMode: input.runtimeMode,
        interactionMode: input.interactionMode,
        createdAt: input.createdAt
    };
    if (input.sourceProposedPlan)
        turn.sourceProposedPlan = input.sourceProposedPlan;
    commands.push(turn);
    return commands;
}

function buildNewThreadCommand(input) {
    var nextId = idSource(input);
    var title = normalizedTitle(input.text);
    var createdAt = input.createdAt;
    var command = {
        type: "thread.turn.start",
        commandId: nextId(),
        threadId: input.threadId,
        message: {
            messageId: input.messageId || nextId(),
            role: "user",
            text: input.text,
            attachments: []
        },
        modelSelection: input.modelSelection,
        titleSeed: title,
        runtimeMode: input.runtimeMode,
        interactionMode: input.interactionMode,
        bootstrap: {
            createThread: {
                projectId: input.projectId,
                title: title,
                modelSelection: input.modelSelection,
                runtimeMode: input.runtimeMode,
                interactionMode: input.interactionMode,
                branch: null,
                worktreePath: null,
                createdAt: createdAt
            }
        },
        createdAt: createdAt
    };
    if (input.sourceProposedPlan)
        command.sourceProposedPlan = input.sourceProposedPlan;
    return command;
}

function resolveSnoozePresets(nowValue) {
    var now = nowValue instanceof Date ? new Date(nowValue.getTime()) : new Date(nowValue);
    var inAnHour = new Date(now.getTime() + HOUR_MS);
    var timeLabel = function(date) {
        return date.toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" });
    };
    var presets = [{ id: "hour", label: "In 1 hour", whenLabel: timeLabel(inAnHour),
        snoozedUntil: inAnHour.toISOString() }];
    var evening = new Date(now.getTime());
    evening.setHours(18, 0, 0, 0);
    if (evening.getTime() - now.getTime() > HOUR_MS)
        presets.push({ id: "evening", label: "This evening", whenLabel: timeLabel(evening),
            snoozedUntil: evening.toISOString() });
    var tomorrow = new Date(now.getTime());
    tomorrow.setDate(tomorrow.getDate() + 1);
    tomorrow.setHours(9, 0, 0, 0);
    presets.push({ id: "tomorrow", label: "Tomorrow", whenLabel: timeLabel(tomorrow),
        snoozedUntil: tomorrow.toISOString() });
    var daysUntilMonday = (1 - now.getDay() + 7) % 7 || 7;
    var nextWeek = new Date(now.getTime());
    nextWeek.setDate(nextWeek.getDate() + daysUntilMonday);
    nextWeek.setHours(9, 0, 0, 0);
    presets.push({ id: "next-week", label: "Next week",
        whenLabel: nextWeek.toLocaleDateString(undefined, { weekday: "short" })
            + " " + timeLabel(nextWeek), snoozedUntil: nextWeek.toISOString() });
    return presets;
}

function snoozeWakeLabel(snoozedUntil, nowMs) {
    var remaining = parseMs(snoozedUntil) - nowMs;
    if (isNaN(remaining) || remaining <= 0)
        return "now";
    if (remaining < HOUR_MS)
        return Math.max(1, Math.ceil(remaining / 60000)) + "m";
    if (remaining < DAY_MS)
        return Math.ceil(remaining / HOUR_MS) + "h";
    return Math.ceil(remaining / DAY_MS) + "d";
}

function historyPage(messages, visibleCount) {
    var source = Array.isArray(messages) ? messages : [];
    var count = Math.max(10, Math.floor(visibleCount || 10));
    var start = Math.max(0, source.length - count);
    return { items: source.slice(start), hasEarlier: start > 0, hiddenCount: start };
}

// ---- detail history order ---------------------------------------------
// Messages, activities, plans and checkpoints arrive as histories ordered by
// server sequence, then timestamp, then id. A streaming reply upserts its
// message once per token, so the order is decided on keys parsed once per
// entry rather than by re-parsing two ISO strings inside every comparison.

function historySortKey(entry) {
    var stamp = entry ? entry.createdAt : undefined;
    if (stamp === undefined || stamp === null)
        stamp = entry ? entry.updatedAt : undefined;
    if (stamp === undefined || stamp === null)
        stamp = entry ? entry.completedAt : undefined;
    return {
        sequence: entry && typeof entry.sequence === "number" ? entry.sequence : null,
        ms: parseMs(stamp),
        id: entry && typeof entry.id === "string" ? entry.id : ""
    };
}

function compareHistoryKeys(left, right) {
    if (left.sequence !== null && right.sequence !== null
            && left.sequence !== right.sequence)
        return left.sequence - right.sequence;
    if (!isNaN(left.ms) && !isNaN(right.ms) && left.ms !== right.ms)
        return left.ms - right.ms;
    return left.id.localeCompare(right.id);
}

function compareHistory(left, right) {
    return compareHistoryKeys(historySortKey(left), historySortKey(right));
}

// A sorted copy. Keys are computed once per entry; ties keep input order.
function sortHistory(values) {
    var source = Array.isArray(values) ? values : [];
    var decorated = [];
    for (var i = 0; i < source.length; i++)
        decorated.push({ key: historySortKey(source[i]), value: source[i], at: i });
    decorated.sort(function(left, right) {
        return compareHistoryKeys(left.key, right.key) || left.at - right.at;
    });
    var sorted = [];
    for (var j = 0; j < decorated.length; j++)
        sorted.push(decorated[j].value);
    return sorted;
}

// Insert or replace `value` (matched on `idField`) in a history that is
// already in sortHistory order, returning a new array in that order. The
// common case — a streaming message growing in place — keeps its slot and
// costs one comparison with each neighbour; anything else is a binary insert
// after its equals, which is where a push followed by a stable sort puts it.
function upsertHistory(values, value, idField) {
    var next = Array.isArray(values) ? values.slice() : [];
    if (!value)
        return next;
    var key = value[idField];
    var at = -1;
    if (key !== undefined && key !== null) {
        for (var i = 0; i < next.length; i++) {
            if (next[i] && next[i][idField] === key) {
                at = i;
                break;
            }
        }
    }
    var valueKey = historySortKey(value);
    if (at >= 0) {
        var afterPrevious = at === 0
            || compareHistoryKeys(historySortKey(next[at - 1]), valueKey) <= 0;
        var beforeNext = at === next.length - 1
            || compareHistoryKeys(valueKey, historySortKey(next[at + 1])) <= 0;
        if (afterPrevious && beforeNext) {
            next[at] = value;
            return next;
        }
        next.splice(at, 1);
    }
    var low = 0;
    var high = next.length;
    while (low < high) {
        var middle = (low + high) >> 1;
        if (compareHistoryKeys(historySortKey(next[middle]), valueKey) <= 0)
            low = middle + 1;
        else
            high = middle;
    }
    next.splice(low, 0, value);
    return next;
}

// ---- conversation rows --------------------------------------------------
// The thread page draws its visible page of messages from a ListModel keyed
// by message id, so a streaming token rewrites one row's text instead of
// rebuilding (and re-parsing the Markdown of) every card on the page.

var LONG_MESSAGE_CHARS = 1200;
var LONG_MESSAGE_LINES = 12;

// True when `text` has more than `maxLines` lines, counted by scanning for
// newlines and stopping at the first one past the limit — never splitting.
function exceedsLineCount(text, maxLines) {
    if (typeof text !== "string")
        return false;
    var newlines = 0;
    var cursor = text.indexOf("\n");
    while (cursor >= 0) {
        newlines++;
        if (newlines >= maxLines)
            return true;
        cursor = text.indexOf("\n", cursor + 1);
    }
    return false;
}

function isLongMessage(text) {
    return typeof text === "string"
        && (text.length > LONG_MESSAGE_CHARS || exceedsLineCount(text, LONG_MESSAGE_LINES));
}

var HISTORY_ROW_FIELDS = ["speakerRole", "body", "streaming", "timestamp", "longMessage",
    "continuation"];

// One flat, consistently typed ListModel row per message. `continuation`
// marks a message whose speaker matches the one before it on this page.
function historyRows(items) {
    var source = Array.isArray(items) ? items : [];
    var rows = [];
    var previousRole = null;
    for (var i = 0; i < source.length; i++) {
        var message = source[i] || {};
        var role = typeof message.role === "string" ? message.role : "";
        var text = message.text === undefined || message.text === null ? ""
            : String(message.text);
        var stamp = message.updatedAt;
        if (stamp === undefined || stamp === null)
            stamp = message.createdAt;
        rows.push({
            messageId: typeof message.id === "string" ? message.id : "#" + i,
            speakerRole: role,
            body: text,
            streaming: message.streaming === true,
            timestamp: typeof stamp === "string" ? stamp : "",
            longMessage: isLongMessage(message.text),
            continuation: i > 0 && previousRole === role
        });
        previousRole = role;
    }
    return rows;
}

// Edit script that turns `current` rows into `next`, preserving every row
// whose id survives in the same relative order. Operations apply in sequence:
// { op: "remove", index, count }, { op: "insert", index, row } and
// { op: "set", index, changes } with only the fields that differ.
function keyedRowOps(current, next, keyField, fields) {
    var work = Array.isArray(current) ? current.slice() : [];
    var wanted = Array.isArray(next) ? next : [];
    var ops = [];
    for (var n = 0; n < wanted.length; n++) {
        var row = wanted[n];
        var at = -1;
        for (var j = n; j < work.length; j++) {
            if (work[j][keyField] === row[keyField]) {
                at = j;
                break;
            }
        }
        if (at < 0) {
            ops.push({ op: "insert", index: n, row: row });
            work.splice(n, 0, row);
            continue;
        }
        if (at > n) {
            ops.push({ op: "remove", index: n, count: at - n });
            work.splice(n, at - n);
        }
        var changes = null;
        for (var f = 0; f < fields.length; f++) {
            var field = fields[f];
            if (work[n][field] !== row[field]) {
                changes = changes || {};
                changes[field] = row[field];
            }
        }
        if (changes)
            ops.push({ op: "set", index: n, changes: changes });
        work[n] = row;
    }
    if (work.length > wanted.length)
        ops.push({ op: "remove", index: wanted.length, count: work.length - wanted.length });
    return ops;
}

function historyRowOps(currentRows, items) {
    var rows = historyRows(items);
    return { rows: rows, ops: keyedRowOps(currentRows, rows, "messageId", HISTORY_ROW_FIELDS) };
}

// ---- shell stream -------------------------------------------------------
// Fold one Chunk's worth of shell items into the thread and project maps.
// Each map is copied at most once per frame, however many items touch it;
// the caller assigns the results once and then relays `events` in order.
function applyShellItems(threadMap, projectMap, items) {
    var threads = threadMap || {};
    var projects = projectMap || {};
    var ownThreads = false;
    var ownProjects = false;
    var result = {
        dirty: false, ready: false, threadsChanged: false, projectsChanged: false,
        events: []
    };
    var source = Array.isArray(items) ? items : [];
    for (var i = 0; i < source.length; i++) {
        var item = source[i];
        if (!item || typeof item !== "object")
            continue;
        switch (item.kind) {
        case "snapshot": {
            var snapshot = item.snapshot || {};
            threads = {};
            projects = {};
            ownThreads = ownProjects = true;
            var snapshotProjects = Array.isArray(snapshot.projects) ? snapshot.projects : [];
            var snapshotThreads = Array.isArray(snapshot.threads) ? snapshot.threads : [];
            for (var p = 0; p < snapshotProjects.length; p++)
                projects[snapshotProjects[p].id] = snapshotProjects[p];
            for (var t = 0; t < snapshotThreads.length; t++)
                threads[snapshotThreads[t].id] = snapshotThreads[t];
            result.threadsChanged = result.projectsChanged = true;
            result.ready = true;
            result.dirty = true;
            result.events.push({ kind: "snapshot" });
            break;
        }
        case "synchronized":
            result.ready = true;
            break;
        case "project-upserted":
        case "project-removed":
            if (!ownProjects) {
                projects = Object.assign({}, projects);
                ownProjects = true;
            }
            if (item.kind === "project-upserted")
                projects[item.project.id] = item.project;
            else
                delete projects[item.projectId];
            result.projectsChanged = true;
            result.dirty = true;
            break;
        case "thread-upserted":
        case "thread-removed":
            if (!ownThreads) {
                threads = Object.assign({}, threads);
                ownThreads = true;
            }
            if (item.kind === "thread-upserted") {
                threads[item.thread.id] = item.thread;
                result.events.push({ kind: "thread-upserted", threadId: item.thread.id });
            } else {
                delete threads[item.threadId];
            }
            result.threadsChanged = true;
            result.dirty = true;
            break;
        default:
            break;
        }
    }
    result.threadMap = threads;
    result.projectMap = projects;
    return result;
}

// ---- transport ----------------------------------------------------------

// What identifies the credential session, as opposed to its current token.
// A DPoP T3 Connect token is owned by scripts/t3-cloud.mjs, which refreshes it
// in the state file while exchanging a WebSocket ticket; that write must not
// read as a new session and invalidate the very ticket it is producing. A
// bearer token is the pairing itself, so replacing it still is one.
function credentialFingerprint(data) {
    var source = data || {};
    var authMode = source.authMode || "";
    var tokenType = source.tokenType || "Bearer";
    var token = source.accessToken || "";
    var helperOwned = authMode === "cloud" && tokenType === "DPoP";
    return JSON.stringify([
        source.httpBaseUrl || "", source.wsBaseUrl || "",
        helperOwned ? token !== "" : token, authMode,
        tokenType, source.cloudStatus || "signed-out",
        helperOwned ? source.cloudIdentity || "" : "",
        helperOwned ? source.environmentId || "" : ""
    ]);
}

// The socket answers every app-level Ping with a Pong, so a connected link
// that has delivered nothing for one and a half ping intervals has missed a
// reply: typically a half-open TCP connection left behind by a suspend.
function socketSilent(lastFrameMs, nowMs, pingIntervalMs) {
    if (typeof lastFrameMs !== "number" || !isFinite(lastFrameMs) || lastFrameMs <= 0)
        return false;
    return nowMs - lastFrameMs > pingIntervalMs * 1.5;
}

// Whether a server origin is this machine, which needs no network to reach.
function isLoopbackOrigin(url) {
    var match = /^[a-z][a-z0-9+.-]*:\/\/(\[[^\]]*\]|[^\/:?#]*)/i
        .exec(typeof url === "string" ? url.trim() : "");
    if (match === null)
        return false;
    var host = match[1].toLowerCase();
    return host === "localhost" || host === "[::1]"
        || /^127\.\d{1,3}\.\d{1,3}\.\d{1,3}$/.test(host);
}

// Why an automatic reconnect should wait instead of starting now: "network"
// while NetworkManager knows the machine is offline (unless the server is on
// loopback), "idle" while nobody is at it, "" to go ahead. An unknown network
// state holds nothing back — a broken status probe must not strand the link.
// Only automatic retries ask; a credential change or a click connects anyway.
function reconnectHold(networkKnown, networkOnline, loopback, idle) {
    if (networkKnown === true && networkOnline !== true && loopback !== true)
        return "network";
    if (idle === true)
        return "idle";
    return "";
}

function truncateDiff(rawDiff, maxChars, maxLines) {
    var source = typeof rawDiff === "string" ? rawDiff : "";
    var charLimit = Math.max(0, Math.floor(
        typeof maxChars === "number" ? maxChars : MAX_DIFF_CHARS));
    var lineLimit = Math.max(1, Math.floor(
        typeof maxLines === "number" ? maxLines : MAX_DIFF_LINES));
    // Never split the untrusted response into an array proportional to its
    // total size. Scan at most the preview budget and stop as soon as either
    // bound is reached.
    var scanLimit = Math.min(source.length, charLimit);
    var cut = scanLimit;
    var newlineCount = 0;
    var cursor = 0;
    var lineTruncated = false;
    while (cursor < scanLimit && newlineCount < lineLimit) {
        var newline = source.indexOf("\n", cursor);
        if (newline < 0 || newline >= scanLimit)
            break;
        newlineCount++;
        if (newlineCount === lineLimit) {
            cut = newline;
            lineTruncated = newline < source.length;
            break;
        }
        cursor = newline + 1;
    }
    var charTruncated = source.length > charLimit && cut === scanLimit;
    var text = source.slice(0, cut);
    var truncated = lineTruncated || charTruncated || source.length > text.length;
    return {
        text: text,
        truncated: truncated,
        totalChars: source.length,
        // Exact counting beyond the preview would defeat the bounded parser.
        totalLines: truncated ? null : newlineCount + 1
    };
}

function canBeginAction(states, key) {
    return !(states && states[key] && states[key].pending === true);
}

// Best-effort human text from an Effect RPC Failure exit. Causes serialize
// as nested tagged objects and ARRAYS (e.g. `cause: [{_tag: "Fail",
// error: {detail}}]`), so both named keys and array entries are walked.
var ERROR_TEXT_KEYS = ["message", "detail", "reason", "error", "cause", "failure", "defect"];

function findErrorText(value, depth) {
    if (depth > 6 || value === null || value === undefined)
        return "";
    if (typeof value === "string")
        return value.trim();
    if (typeof value !== "object")
        return "";
    var found;
    if (Array.isArray(value)) {
        for (var i = 0; i < value.length; i++) {
            found = findErrorText(value[i], depth + 1);
            if (found !== "" && found !== "Failure")
                return found;
        }
        return "";
    }
    for (var k = 0; k < ERROR_TEXT_KEYS.length; k++) {
        var key = ERROR_TEXT_KEYS[k];
        if (value[key] !== undefined) {
            found = findErrorText(value[key], depth + 1);
            if (found !== "" && found !== "Failure")
                return found;
        }
    }
    return "";
}

// ---- connection failures ---------------------------------------------------

// Connecting has two hops — an HTTP ticket request and the WebSocket itself —
// and a bar chip that only ever says "off" hides which one broke. These turn
// either hop into one short phrase. Qt's errorString is free-form and often
// says nothing ("", "Unknown error", "QQmlWebSocket is not ready."), and it
// prefixes handshake failures with the C++ frame that raised them; anything
// carrying no information collapses to "", which every caller reads as "keep
// the wording you had before".
var MAX_CONNECTION_ERROR_CHARS = 48;
var EMPTY_SOCKET_ERRORS = /^(unknown error|qqmlwebsocket is not ready)\.?$/i;

function shortenErrorText(text) {
    if (text.length <= MAX_CONNECTION_ERROR_CHARS)
        return text;
    var cut = text.slice(0, MAX_CONNECTION_ERROR_CHARS);
    var space = cut.lastIndexOf(" ");
    if (space > MAX_CONNECTION_ERROR_CHARS / 2)
        cut = cut.slice(0, space);
    return cut.replace(/[\s,.;:-]+$/, "") + "…";
}

function socketErrorText(raw) {
    if (typeof raw !== "string")
        return "";
    var text = raw.replace(/\s+/g, " ").trim();
    // "QWebSocketPrivate::processHandshake: Unhandled http status code: 401
    // (Unauthorized)" — the frame is noise, but it identifies the hop.
    var handshake = /processHandshake/i.test(text);
    text = text.replace(/^[A-Za-z_]\w*::[A-Za-z_]\w*:\s*/, "");
    if (text === "" || EMPTY_SOCKET_ERRORS.test(text))
        return "";
    if (/^error during ssl handshake/i.test(text)) {
        // OpenSSL states the reason last: "Error during SSL handshake:
        // error:0A00010B:SSL routines::wrong version number".
        var reason = text.split("::").pop().trim();
        return shortenErrorText(reason !== "" && !/ssl handshake/i.test(reason)
            ? "TLS handshake failed: " + reason : "TLS handshake failed");
    }
    var status = text.match(/http status code:?\s*(\d{3})/i);
    if (status !== null)
        return "WebSocket rejected (HTTP " + status[1] + ")";
    if (handshake)
        return "WebSocket handshake rejected";
    return shortenErrorText(text);
}

// The websocket-ticket POST. QML's XMLHttpRequest reports every transport
// failure — refused, DNS, TLS, timeout — as status 0 with no error text, so
// a dead host can only be reported as silence.
function ticketErrorText(status) {
    var code = typeof status === "number" && isFinite(status) ? Math.trunc(status) : 0;
    if (code <= 0)
        return "Server did not respond";
    if (code === 401 || code === 403)
        return "Pairing token rejected";
    if (code >= 500)
        return "Server error " + code;
    return "Ticket request failed (HTTP " + code + ")";
}

function expireActionStates(states, nowMs, timeoutMs) {
    var next = Object.assign({}, states || {});
    var expired = [];
    for (var key in next) {
        var value = next[key];
        // A state may carry its own budget (git actions stream for minutes
        // while the server generates a commit message or runs hooks).
        var limit = value && typeof value.timeoutMs === "number" ? value.timeoutMs : timeoutMs;
        if (value && value.pending === true && nowMs - value.startedAt >= limit) {
            next[key] = Object.assign({}, value, { pending: false, error: "Action timed out" });
            expired.push(key);
        }
    }
    return { states: next, expiredKeys: expired };
}

// ---- git actions (vcs.refreshStatus / git.runStackedAction) ----------------

var GIT_STACKED_ACTIONS = ["commit_push", "push"];

// Where git commands run for a thread: its worktree when it has one,
// otherwise the project checkout — the same fallback the server uses.
function resolveThreadCwd(thread, project) {
    if (thread && typeof thread.worktreePath === "string" && thread.worktreePath.trim() !== "")
        return thread.worktreePath;
    if (project && typeof project.workspaceRoot === "string" && project.workspaceRoot.trim() !== "")
        return project.workspaceRoot;
    return "";
}

// featureBranch is deliberately never set: the default is to commit on the
// thread's current branch (usually main) and push it. An omitted
// commitMessage makes the server generate one from the staged diff.
function buildGitActionPayload(input) {
    if (!input || typeof input !== "object")
        return null;
    var actionId = typeof input.actionId === "string" ? input.actionId.trim() : "";
    var cwd = typeof input.cwd === "string" ? input.cwd.trim() : "";
    if (actionId === "" || cwd === "" || GIT_STACKED_ACTIONS.indexOf(input.action) < 0)
        return null;
    var payload = { actionId: actionId, cwd: cwd, action: input.action };
    var message = typeof input.commitMessage === "string" ? input.commitMessage.trim() : "";
    if (message !== "")
        payload.commitMessage = message;
    return payload;
}

function sanitizeVcsStatus(raw) {
    if (!raw || typeof raw !== "object" || raw.isRepo !== true) {
        return { isRepo: false, refName: "", isDefaultRef: false,
            hasWorkingTreeChanges: false, fileCount: 0, insertions: 0, deletions: 0,
            hasPrimaryRemote: false, hasUpstream: false, aheadCount: 0, behindCount: 0,
            pr: null };
    }
    var workingTree = raw.workingTree && typeof raw.workingTree === "object"
        ? raw.workingTree : {};
    var count = function(value) {
        return typeof value === "number" && isFinite(value)
            ? Math.max(0, Math.floor(value)) : 0;
    };
    var pr = null;
    if (raw.pr && typeof raw.pr === "object"
            && typeof raw.pr.url === "string" && raw.pr.url !== "") {
        pr = {
            number: count(raw.pr.number),
            title: typeof raw.pr.title === "string" ? raw.pr.title : "",
            url: raw.pr.url,
            state: typeof raw.pr.state === "string" ? raw.pr.state : ""
        };
    }
    return {
        isRepo: true,
        refName: typeof raw.refName === "string" ? raw.refName : "",
        isDefaultRef: raw.isDefaultRef === true,
        hasWorkingTreeChanges: raw.hasWorkingTreeChanges === true,
        fileCount: Array.isArray(workingTree.files) ? workingTree.files.length : 0,
        insertions: count(workingTree.insertions),
        deletions: count(workingTree.deletions),
        hasPrimaryRemote: raw.hasPrimaryRemote === true,
        hasUpstream: raw.hasUpstream === true,
        aheadCount: count(raw.aheadCount),
        behindCount: count(raw.behindCount),
        pr: pr
    };
}

// Visibility, not enablement: an action that does not currently apply is
// hidden, matching the reference client. Push also covers publishing a
// branch that has a remote but no upstream yet.
function gitActionVisible(status, action) {
    if (!status || status.isRepo !== true)
        return false;
    if (action === "commit_push")
        return status.hasWorkingTreeChanges === true;
    if (action === "push")
        return status.hasWorkingTreeChanges !== true
            && status.hasPrimaryRemote === true
            && (status.aheadCount > 0 || status.hasUpstream !== true);
    return false;
}

// Live label for a streamed progress event; "" keeps the previous label.
function gitProgressLabel(event) {
    if (!event || typeof event !== "object")
        return "";
    if (event.kind === "phase_started" && typeof event.label === "string"
            && event.label !== "")
        return event.label;
    if (event.kind === "hook_started" && typeof event.hookName === "string"
            && event.hookName !== "")
        return "Running " + event.hookName + "…";
    return "";
}

function gitFailureMessage(event) {
    if (!event || event.kind !== "action_failed" || typeof event.message !== "string"
            || event.message === "")
        return "";
    return typeof event.phase === "string" && event.phase !== ""
        ? event.message + " (" + event.phase + ")" : event.message;
}

function gitResultSummary(result) {
    if (!result || typeof result !== "object")
        return { text: "", prUrl: "" };
    var parts = [];
    var commit = result.commit && typeof result.commit === "object" ? result.commit : {};
    var push = result.push && typeof result.push === "object" ? result.push : {};
    if (commit.status === "created") {
        var sha = typeof commit.commitSha === "string" ? commit.commitSha.slice(0, 7) : "";
        var subject = typeof commit.subject === "string" ? commit.subject : "";
        parts.push(("committed " + sha).trim() + (subject !== "" ? " · " + subject : ""));
    } else if (commit.status === "skipped_no_changes") {
        parts.push("nothing to commit");
    }
    if (push.status === "pushed") {
        parts.push(typeof push.branch === "string" && push.branch !== ""
            ? "pushed to " + push.branch : "pushed");
    } else if (push.status === "skipped_up_to_date") {
        parts.push("already up to date");
    }
    var prUrl = "";
    var pr = result.pr && typeof result.pr === "object" ? result.pr : {};
    if (typeof pr.url === "string" && pr.url !== "")
        prUrl = pr.url;
    else if (result.toast && result.toast.cta && result.toast.cta.kind === "open_pr"
            && typeof result.toast.cta.url === "string")
        prUrl = result.toast.cta.url;
    var text = parts.join(" — ");
    return {
        text: text === "" ? "Done" : text.charAt(0).toUpperCase() + text.slice(1),
        prUrl: prUrl
    };
}

function draftAfterOutcome(draft, outcome) {
    if (outcome === "confirmed")
        return Object.assign({}, draft || {}, { prompt: "" });
    return Object.assign({}, draft || {});
}

var exported = {
    DAY_MS: DAY_MS,
    HOUR_MS: HOUR_MS,
    QUEUED_TURN_GRACE_MS: QUEUED_TURN_GRACE_MS,
    MAX_PROMPT_CHARS: MAX_PROMPT_CHARS,
    MAX_DIFF_CHARS: MAX_DIFF_CHARS,
    MAX_DIFF_LINES: MAX_DIFF_LINES,
    parseMs: parseMs,
    firstValidTimestamp: firstValidTimestamp,
    resolveWorkingStartedAt: resolveWorkingStartedAt,
    formatWorkingDurationLabel: formatWorkingDurationLabel,
    formatWorkingTimerLabel: formatWorkingTimerLabel,
    liveAgentCount: liveAgentCount,
    taskProgress: taskProgress,
    lastActivityMs: lastActivityMs,
    hasQueuedTurnStart: hasQueuedTurnStart,
    isEffectivelySettled: isEffectivelySettled,
    isEffectivelySnoozed: isEffectivelySnoozed,
    threadClass: threadClass,
    canOperateLifecycle: canOperateLifecycle,
    canPrompt: canPrompt,
    classifyThreads: classifyThreads,
    normalizeScopes: normalizeScopes,
    sanitizeDescriptor: sanitizeDescriptor,
    sanitizeServerConfig: sanitizeServerConfig,
    findProvider: findProvider,
    findModel: findModel,
    defaultModel: defaultModel,
    providerIconName: providerIconName,
    threadProviderIconName: threadProviderIconName,
    threadSelectionLabel: threadSelectionLabel,
    normalizeTraits: normalizeTraits,
    traitSelections: traitSelections,
    isUltrathinkPrompt: isUltrathinkPrompt,
    traitsForPrompt: traitsForPrompt,
    applyTraitValue: applyTraitValue,
    selectionForNewThread: selectionForNewThread,
    selectionForProject: selectionForProject,
    selectionForThread: selectionForThread,
    selectableProvidersForThread: selectableProvidersForThread,
    modelChangeAllowed: modelChangeAllowed,
    modelFavoriteKey: modelFavoriteKey,
    providerRailEntries: providerRailEntries,
    modelSearchScore: modelSearchScore,
    modelPickerRows: modelPickerRows,
    assignPickerShortcuts: assignPickerShortcuts,
    sameSelection: sameSelection,
    normalizedTitle: normalizedTitle,
    styleMarkdownLinks: styleMarkdownLinks,
    buildPlanImplementationPrompt: buildPlanImplementationPrompt,
    buildExistingTurnCommands: buildExistingTurnCommands,
    buildNewThreadCommand: buildNewThreadCommand,
    resolveSnoozePresets: resolveSnoozePresets,
    snoozeWakeLabel: snoozeWakeLabel,
    historyPage: historyPage,
    historySortKey: historySortKey,
    compareHistoryKeys: compareHistoryKeys,
    compareHistory: compareHistory,
    sortHistory: sortHistory,
    upsertHistory: upsertHistory,
    exceedsLineCount: exceedsLineCount,
    isLongMessage: isLongMessage,
    historyRows: historyRows,
    keyedRowOps: keyedRowOps,
    historyRowOps: historyRowOps,
    applyShellItems: applyShellItems,
    credentialFingerprint: credentialFingerprint,
    socketSilent: socketSilent,
    isLoopbackOrigin: isLoopbackOrigin,
    reconnectHold: reconnectHold,
    truncateDiff: truncateDiff,
    canBeginAction: canBeginAction,
    findErrorText: findErrorText,
    socketErrorText: socketErrorText,
    ticketErrorText: ticketErrorText,
    expireActionStates: expireActionStates,
    draftAfterOutcome: draftAfterOutcome,
    resolveThreadCwd: resolveThreadCwd,
    buildGitActionPayload: buildGitActionPayload,
    sanitizeVcsStatus: sanitizeVcsStatus,
    gitActionVisible: gitActionVisible,
    gitProgressLabel: gitProgressLabel,
    gitFailureMessage: gitFailureMessage,
    gitResultSummary: gitResultSummary
};

if (typeof module !== "undefined" && module.exports)
    module.exports = exported;
