pragma Singleton
import QtQuick
import Quickshell
import "T3CodeHelpers.js" as Helpers

// Everything about the one thread the popover currently has open: the detail
// subscription, the history/activity/approval streams it carries, and the
// derived projections T3ThreadPage renders.
//
// Only T3ThreadPage consumes this. It is separate from T3Threads because the
// inbox never needs any of it — the shell stream carries a summary per thread,
// and this is the second, per-thread stream opened on demand.
//
// Note for WP5.6: `detailVcs` and `detailGit` live here because
// resetDetailData() owns their lifecycle, but they are written by the git
// actions still in T3Code. When git moves out, they should go with it.
Singleton {
    id: root

    // Request activities already turned into an approval or input prompt.
    // Only this file has ever read it.
    property var handledRequestActivities: ({})

    // The server confirmed a message this shell sent, or resolved an input
    // request. The draft layer clears its optimistic copy on these; this
    // file does not know drafts exist.
    signal draftMessageConfirmed(string threadId, string messageId)
    signal userInputResolved(string threadId, string requestId)

    // The working tree may have moved under this thread. Git owns the
    // actual status fetch (WP5.6 takes it out of T3Code).
    signal vcsRefreshWanted(string threadId)

    // The detail view is switching threads or closing. T3Git clears the
    // repository card on this; their lifecycle is ours, their state is not.
    signal detailReset()

    // The shell stream carries a fresher session/latest-turn summary than the
    // detail stream while that one is still catching up. T3Code hands it over
    // on every rebuild; a thread we are not showing is simply null.
    function adoptShellSummary(thread) {
        if (!thread)
            return;
        detailSession = thread.session ?? null;
        detailLatestTurn = thread.latestTurn ?? null;
        recomputeDetailDerived();
    }

    property string detailThreadId: ""
    // The popover itself is disposable, but closing it is not navigation.
    // Retain the last expanded thread here so a fresh popover can restore it;
    // explicit Back/Escape clears this separately from closeDetail().
    property string lastViewedThreadId: ""
    property bool detailLoading: false
    property string detailError: ""
    property var detailMessages: []
    property var detailActivities: []
    property var detailProposedPlans: []
    property var detailCheckpoints: []
    property var detailSession: null
    property var detailLatestTurn: null
    property var detailApprovals: []
    property var detailPendingInputs: []
    property var detailLatestAssistant: null
    property var detailLatestActivity: null
    property var detailActionablePlan: null
    property var detailCheckpointSummary: null
    readonly property int detailLiveAgentCount: Helpers.liveAgentCount(detailActivities,
        detailSession === null ? null : detailSession.status !== "stopped")
    readonly property var detailTaskProgress: Helpers.taskProgress(detailActivities,
        detailLatestTurn && typeof detailLatestTurn.turnId === "string"
            ? detailLatestTurn.turnId : "")
    property var detailDiff: ({ checkpointRef: "", loading: false, error: "",
        text: "", truncated: false, totalChars: 0, totalLines: 0 })

    // Repository status for the selected thread (vcs.refreshStatus), fetched
    // per detail open and after git actions; drives which git actions are
    // shown at all. detailGit tracks the one in-flight/last stacked action.

    // Action state is keyed by kind/thread/request. Generic commands clear
    // when T3Rpc.dispatch succeeds; approvals and structured input wait for the
    // provider's matching resolution activity.

    // ---- selected thread detail -----------------------------------------

    property string detailReqId: ""
    property string pendingDetailResubscribeId: ""

    function rememberThread(threadId) {
        if (typeof threadId === "string" && threadId !== "")
            lastViewedThreadId = threadId;
    }

    function forgetThread(threadId) {
        if (threadId === undefined || threadId === "" || lastViewedThreadId === threadId)
            lastViewedThreadId = "";
    }

    function resetDetailData() {
        checkpointSummarySource = null;
        detailLoading = false;
        detailError = "";
        detailMessages = [];
        detailActivities = [];
        detailProposedPlans = [];
        detailCheckpoints = [];
        detailSession = null;
        detailLatestTurn = null;
        detailApprovals = [];
        detailPendingInputs = [];
        detailLatestAssistant = null;
        detailLatestActivity = null;
        detailActionablePlan = null;
        detailCheckpointSummary = null;
        detailDiff = ({ checkpointRef: "", loading: false, error: "", text: "",
            truncated: false, totalChars: 0, totalLines: 0 });
        detailReset();
    }

    // Every history array here is kept in this order by the only two
    // writers, sortedHistory() and upsertHistory(), so readers walk them
    // as they are instead of sorting a copy.
    function historyCompare(left, right) {
        return Helpers.compareHistory(left, right);
    }

    function sortedHistory(values) {
        return Helpers.sortHistory(values);
    }

    function upsertHistory(values, value, idField) {
        return Helpers.upsertHistory(values, value, idField);
    }

    function approvalKind(requestType) {
        switch (requestType) {
        case "file_read_approval":
            return "file-read";
        case "file_change_approval":
        case "apply_patch_approval":
            return "file-change";
        default:
            return "command";
        }
    }

    function stalePendingFailure(detail) {
        return /stale pending (approval|user[- ]input) request|unknown pending (approval|permission|user[- ]input|codex user input) request/i
            .test(typeof detail === "string" ? detail : "");
    }

    function parseInputQuestions(payload) {
        if (!payload || !Array.isArray(payload.questions))
            return null;
        const questions = [];
        for (const raw of payload.questions) {
            if (!raw || typeof raw !== "object" || typeof raw.id !== "string"
                    || typeof raw.question !== "string" || !Array.isArray(raw.options))
                continue;
            const options = [];
            for (const rawOption of raw.options) {
                if (!rawOption || typeof rawOption !== "object"
                        || typeof rawOption.label !== "string")
                    continue;
                const label = rawOption.label.trim();
                if (label === "")
                    continue;
                options.push({
                    label: label,
                    description: typeof rawOption.description === "string"
                        ? rawOption.description : ""
                });
            }
            if (raw.id.trim() === "" || raw.question.trim() === "" || options.length === 0)
                continue;
            questions.push({
                id: raw.id,
                header: typeof raw.header === "string" && raw.header.trim() !== ""
                    ? raw.header : "Question",
                question: raw.question,
                options: options,
                multiSelect: raw.multiSelect === true
            });
        }
        return questions.length > 0 ? questions : null;
    }

    function requestActivityId(activity) {
        if (activity && typeof activity.id === "string" && activity.id !== "")
            return activity.id;
        const payload = activity && typeof activity.payload === "object" ? activity.payload : {};
        return (activity?.kind ?? "") + "|" + (payload.requestId ?? "") + "|"
            + (activity?.createdAt ?? "");
    }

    function reconcileRequestActivity(activity, threadId) {
        if (!activity)
            return;
        const terminal = activity.kind === "approval.resolved"
            || activity.kind === "user-input.resolved"
            || activity.kind === "provider.approval.respond.failed"
            || activity.kind === "provider.user-input.respond.failed";
        if (!terminal)
            return;
        const identity = requestActivityId(activity);
        if (handledRequestActivities[identity] === true)
            return;
        const handled = Object.assign({}, handledRequestActivities);
        handled[identity] = true;
        handledRequestActivities = handled;

        const payload = activity.payload && typeof activity.payload === "object"
            ? activity.payload : {};
        const requestId = typeof payload.requestId === "string" ? payload.requestId : "";
        if (requestId === "")
            return;
        if (activity.kind === "approval.resolved") {
            T3Rpc.clearAction(T3Rpc.actionKey("approval", threadId, requestId));
        } else if (activity.kind === "user-input.resolved") {
            T3Rpc.clearAction(T3Rpc.actionKey("input", threadId, requestId));
            userInputResolved(threadId, requestId);
        } else if (activity.kind === "provider.approval.respond.failed") {
            T3Rpc.failAction(T3Rpc.actionKey("approval", threadId, requestId),
                typeof payload.detail === "string" ? payload.detail : activity.summary);
        } else if (activity.kind === "provider.user-input.respond.failed") {
            T3Rpc.failAction(T3Rpc.actionKey("input", threadId, requestId),
                typeof payload.detail === "string" ? payload.detail : activity.summary);
        }
    }

    // Mirrors the reference client's pending approval/user-input derivation.
    function recomputePendingRequests() {
        const approvals = {};
        const inputs = {};
        for (const activity of detailActivities) {
            const payload = activity && activity.payload && typeof activity.payload === "object"
                ? activity.payload : {};
            const requestId = typeof payload.requestId === "string" ? payload.requestId : "";
            if (requestId !== "") {
                if (activity.kind === "approval.requested") {
                    approvals[requestId] = {
                        requestId: requestId,
                        kind: payload.requestKind === "file-read"
                            || payload.requestKind === "file-change"
                            || payload.requestKind === "command"
                            ? payload.requestKind : approvalKind(payload.requestType),
                        detail: typeof payload.detail === "string" ? payload.detail : "",
                        createdAt: activity.createdAt ?? ""
                    };
                } else if (activity.kind === "approval.resolved") {
                    delete approvals[requestId];
                } else if (activity.kind === "provider.approval.respond.failed"
                           && stalePendingFailure(payload.detail)) {
                    delete approvals[requestId];
                } else if (activity.kind === "user-input.requested") {
                    const questions = parseInputQuestions(payload);
                    if (questions) {
                        inputs[requestId] = {
                            requestId: requestId,
                            createdAt: activity.createdAt ?? "",
                            questions: questions
                        };
                    }
                } else if (activity.kind === "user-input.resolved") {
                    delete inputs[requestId];
                } else if (activity.kind === "provider.user-input.respond.failed"
                           && stalePendingFailure(payload.detail)) {
                    delete inputs[requestId];
                }
            }
            reconcileRequestActivity(activity, detailThreadId);
        }
        // Reassign only on a real change: the request cards are delegates of
        // these arrays, and a fresh-but-equal array would recreate them and
        // drop a half-made choice along with keyboard focus.
        const nextApprovals = Object.values(approvals)
            .sort((a, b) => a.createdAt.localeCompare(b.createdAt));
        if (JSON.stringify(nextApprovals) !== JSON.stringify(detailApprovals))
            detailApprovals = nextApprovals;
        const nextInputs = Object.values(inputs)
            .sort((a, b) => a.createdAt.localeCompare(b.createdAt));
        if (JSON.stringify(nextInputs) !== JSON.stringify(detailPendingInputs))
            detailPendingInputs = nextInputs;
    }

    function recomputeDetailDerived() {
        let assistant = null;
        for (let i = detailMessages.length - 1; i >= 0; i--) {
            const message = detailMessages[i];
            if (message && message.role === "assistant" && typeof message.text === "string"
                    && message.text.trim() !== "") {
                assistant = message;
                break;
            }
        }
        detailLatestAssistant = assistant;

        const ignoredKinds = {
            "approval.requested": true,
            "approval.resolved": true,
            "user-input.requested": true,
            "user-input.resolved": true,
            "turn.plan.updated": true,
            "tool.started": true,
            "task.started": true,
            "context-window.updated": true
        };
        let latestActivity = null;
        for (let i = detailActivities.length - 1; i >= 0; i--) {
            const activity = detailActivities[i];
            if (!activity || typeof activity.summary !== "string"
                    || activity.summary.trim() === "")
                continue;
            if (activity.tone !== "error" && (ignoredKinds[activity.kind] === true
                    || activity.summary === "Checkpoint captured"))
                continue;
            latestActivity = activity;
            break;
        }
        if (detailSession && detailSession.status === "error"
                && typeof detailSession.lastError === "string"
                && detailSession.lastError.trim() !== "") {
            const sessionError = {
                tone: "error",
                kind: "session.error",
                summary: detailSession.lastError,
                createdAt: detailSession.updatedAt ?? ""
            };
            if (!latestActivity || historyCompare(latestActivity, sessionError) <= 0)
                latestActivity = sessionError;
        }
        detailLatestActivity = latestActivity;

        const plans = (Array.isArray(detailProposedPlans) ? detailProposedPlans.slice() : [])
            .filter(plan => plan && typeof plan === "object")
            .sort((left, right) => {
                const lm = T3Threads.parseMs(left?.updatedAt ?? left?.createdAt);
                const rm = T3Threads.parseMs(right?.updatedAt ?? right?.createdAt);
                if (!isNaN(lm) && !isNaN(rm) && lm !== rm)
                    return lm - rm;
                return (left?.id ?? "").localeCompare(right?.id ?? "");
            });
        let latestPlan = null;
        const latestTurnId = detailLatestTurn ? detailLatestTurn.turnId : null;
        if (latestTurnId) {
            const matchingPlans = plans.filter(plan => plan.turnId === latestTurnId);
            if (matchingPlans.length > 0)
                latestPlan = matchingPlans[matchingPlans.length - 1];
        }
        if (!latestPlan && plans.length > 0)
            latestPlan = plans[plans.length - 1];
        detailActionablePlan = latestPlan
            && (latestPlan.implementedAt === null || latestPlan.implementedAt === undefined)
            ? latestPlan : null;

        let checkpoint = null;
        for (let i = detailCheckpoints.length - 1; i >= 0; i--) {
            if (detailCheckpoints[i] && detailCheckpoints[i].status === "ready") {
                checkpoint = detailCheckpoints[i];
                break;
            }
        }
        if (checkpoint === null) {
            checkpointSummarySource = null;
            detailCheckpointSummary = null;
            if (detailDiff.checkpointRef !== "") {
                cancelDiffRequests(detailThreadId);
                detailDiff = ({ checkpointRef: "", loading: false, error: "", text: "",
                    truncated: false, totalChars: 0, totalLines: 0 });
            }
        } else {
            // The same history entry makes the same summary; rebuilding it on
            // every streamed token would notify the page for nothing.
            if (checkpoint !== checkpointSummarySource) {
                checkpointSummarySource = checkpoint;
                const files = Array.isArray(checkpoint.files) ? checkpoint.files : [];
                let additions = 0, deletions = 0;
                const filenames = [];
                for (const file of files) {
                    if (!file || typeof file !== "object")
                        continue;
                    if (typeof file.additions === "number" && isFinite(file.additions))
                        additions += Math.max(0, file.additions);
                    if (typeof file.deletions === "number" && isFinite(file.deletions))
                        deletions += Math.max(0, file.deletions);
                    if (typeof file.path === "string" && file.path !== "")
                        filenames.push(file.path);
                }
                detailCheckpointSummary = Object.assign({}, checkpoint, {
                    fileCount: files.length,
                    additions: additions,
                    deletions: deletions,
                    filenames: filenames.slice(0, 3)
                });
            }
            if (detailDiff.checkpointRef !== ""
                    && detailDiff.checkpointRef !== checkpoint.checkpointRef) {
                cancelDiffRequests(detailThreadId);
                detailDiff = ({ checkpointRef: "", loading: false, error: "", text: "",
                    truncated: false, totalChars: 0, totalLines: 0 });
            }
        }
    }

    function recomputeDetail() {
        detailRecomputeQueued = false;
        requestsRecomputeQueued = false;
        recomputePendingRequests();
        recomputeDetailDerived();
    }

    // Stream events arrive in bursts — a Chunk carries many, and a reply
    // streams one per token — so the projections are brought up to date once
    // per event-loop turn. Pending approvals and questions derive from
    // activities alone and are only redone when an activity arrived.
    property bool detailRecomputeQueued: false
    property bool requestsRecomputeQueued: false
    property var checkpointSummarySource: null

    function scheduleDetailRecompute(requests) {
        if (requests)
            requestsRecomputeQueued = true;
        if (detailRecomputeQueued)
            return;
        detailRecomputeQueued = true;
        Qt.callLater(root.flushDetailRecompute);
    }

    function flushDetailRecompute() {
        if (!detailRecomputeQueued)
            return;
        detailRecomputeQueued = false;
        if (requestsRecomputeQueued) {
            requestsRecomputeQueued = false;
            recomputePendingRequests();
        }
        recomputeDetailDerived();
    }

    function cancelDiffRequests(threadId) {
        if (typeof threadId !== "string" || threadId === "")
            return;
        T3Rpc.cancelActionRequests(T3Rpc.actionKey("diff", threadId, ""));
        T3Rpc.cancelActionRequests(T3Rpc.actionKey("diff-copy", threadId, ""));
    }

    function loadFullThreadDiff(threadId, checkpoint) {
        const key = T3Rpc.actionKey("diff", threadId, "");
        if (!T3Connection.canRead)
            return T3Rpc.rejectAction(key, "This pairing cannot read thread data", false);
        if (!checkpoint || checkpoint.status !== "ready"
                || typeof checkpoint.checkpointTurnCount !== "number")
            return T3Rpc.rejectAction(key, "No ready checkpoint is available", false);
        if (!Helpers.canBeginAction(T3Rpc.actionStates, key))
            return "";
        T3Rpc.beginAction(key, "", false);
        detailDiff = ({ checkpointRef: checkpoint.checkpointRef ?? "", loading: true,
            error: "", text: "", truncated: false,
            totalChars: 0, totalLines: 0 });
        return T3Rpc.requestOnce("orchestration.getFullThreadDiff", {
            threadId: threadId,
            toTurnCount: checkpoint.checkpointTurnCount,
            ignoreWhitespace: false
        }, value => {
            if (root.detailThreadId !== threadId
                    || root.detailDiff.checkpointRef !== (checkpoint.checkpointRef ?? "")
                    || root.detailCheckpointSummary?.checkpointRef !== checkpoint.checkpointRef) {
                T3Rpc.clearAction(key);
                return;
            }
            if (!value || typeof value.diff !== "string") {
                T3Rpc.failAction(key, "Malformed diff response");
                root.detailDiff = Object.assign({}, root.detailDiff, {
                    loading: false, error: "Malformed diff response"
                });
                return;
            }
            const rendered = Helpers.truncateDiff(value.diff);
            root.detailDiff = Object.assign({
                checkpointRef: checkpoint.checkpointRef ?? "", loading: false, error: ""
            }, rendered);
            T3Rpc.clearAction(key);
        }, error => {
            if (root.detailThreadId !== threadId
                    || root.detailDiff.checkpointRef !== (checkpoint.checkpointRef ?? "")) {
                T3Rpc.clearAction(key);
                return;
            }
            T3Rpc.failAction(key, error);
            root.detailDiff = Object.assign({}, root.detailDiff, {
                loading: false, error: error
            });
        }, { actionKey: key, fallback: "Diff unavailable" });
    }

    // Fetch the full patch only in direct response to the copy action. The
    // singleton keeps the bounded preview; the full response exists only for
    // this callback and is handed straight to the compositor clipboard.
    function copyFullThreadDiff(threadId, checkpoint) {
        const key = T3Rpc.actionKey("diff-copy", threadId, "");
        if (!T3Connection.canRead)
            return T3Rpc.rejectAction(key, "This pairing cannot read thread data", false);
        if (!checkpoint || checkpoint.status !== "ready"
                || typeof checkpoint.checkpointTurnCount !== "number")
            return T3Rpc.rejectAction(key, "No ready checkpoint is available", false);
        if (!Helpers.canBeginAction(T3Rpc.actionStates, key))
            return "";
        T3Rpc.beginAction(key, "", false);
        return T3Rpc.requestOnce("orchestration.getFullThreadDiff", {
            threadId: threadId,
            toTurnCount: checkpoint.checkpointTurnCount,
            ignoreWhitespace: false
        }, value => {
            if (root.detailThreadId !== threadId
                    || root.detailCheckpointSummary?.checkpointRef !== checkpoint.checkpointRef) {
                T3Rpc.clearAction(key);
                return;
            }
            if (!value || typeof value.diff !== "string") {
                T3Rpc.failAction(key, "Malformed diff response");
                return;
            }
            Quickshell.clipboardText = value.diff;
            T3Rpc.clearAction(key);
        }, error => {
            if (root.detailThreadId !== threadId
                    || root.detailCheckpointSummary?.checkpointRef !== checkpoint.checkpointRef) {
                T3Rpc.clearAction(key);
                return;
            }
            T3Rpc.failAction(key, error);
        }, { actionKey: key, fallback: "Full diff copy unavailable" });
    }


    function reconcileCommandEvent(event) {
        if (!event || typeof event.commandId !== "string" || event.commandId === "")
            return;
        for (const key in T3Rpc.actionStates) {
            const current = T3Rpc.actionStates[key];
            if (!current || current.commandId !== event.commandId)
                continue;
            // A subscription event may race ahead of dispatchCommand's RPC
            // response. The batch owns live action progress; clearing it here
            // could otherwise prevent the next sequenced command from running.
            if (current.pending === true)
                return;
            if (current.awaitResolution === true
                    && (event.type === "thread.approval-response-requested"
                        || event.type === "thread.user-input-response-requested"))
                return;
            T3Rpc.clearAction(key);
            return;
        }
    }

    function applyDetailEvent(event, threadId) {
        if (!event || typeof event !== "object")
            return;
        const payload = event.payload && typeof event.payload === "object" ? event.payload : {};
        if (typeof payload.threadId === "string" && payload.threadId !== threadId)
            return;
        reconcileCommandEvent(event);

        switch (event.type) {
        case "thread.message-sent": {
            if (typeof payload.messageId === "string") {
                const existing = detailMessages.find(message =>
                    message && message.id === payload.messageId);
                const incomingText = typeof payload.text === "string" ? payload.text : "";
                const existingText = existing && typeof existing.text === "string"
                    ? existing.text : "";
                const text = existing
                    ? (payload.streaming === true ? existingText + incomingText
                        : incomingText !== "" ? incomingText : existingText)
                    : incomingText;
                const message = {
                    id: payload.messageId,
                    role: payload.role ?? "system",
                    text: text,
                    attachments: Array.isArray(payload.attachments) ? payload.attachments
                        : (existing?.attachments ?? []),
                    turnId: payload.turnId ?? null,
                    streaming: payload.streaming === true,
                    createdAt: existing?.createdAt ?? payload.createdAt ?? event.occurredAt ?? "",
                    updatedAt: payload.updatedAt ?? event.occurredAt ?? ""
                };
                detailMessages = upsertHistory(detailMessages, message, "id");
                draftMessageConfirmed(threadId, payload.messageId);
            }
            break;
        }
        case "thread.activity-appended":
            if (payload.activity && typeof payload.activity === "object")
                detailActivities = upsertHistory(detailActivities, payload.activity, "id");
            break;
        case "thread.proposed-plan-upserted":
            if (payload.proposedPlan && typeof payload.proposedPlan === "object")
                detailProposedPlans = upsertHistory(detailProposedPlans,
                    payload.proposedPlan, "id");
            break;
        case "thread.turn-diff-completed": {
            const checkpoint = {
                turnId: payload.turnId,
                checkpointTurnCount: payload.checkpointTurnCount ?? 0,
                checkpointRef: payload.checkpointRef,
                status: payload.status,
                files: Array.isArray(payload.files) ? payload.files : [],
                assistantMessageId: payload.assistantMessageId ?? null,
                completedAt: payload.completedAt ?? event.occurredAt ?? ""
            };
            detailCheckpoints = upsertHistory(detailCheckpoints, checkpoint, "checkpointRef");
            // A finished turn usually changed the working tree.
            if (payload.status === "ready")
                vcsRefreshWanted(threadId);
            break;
        }
        case "thread.session-set":
            detailSession = payload.session ?? null;
            break;
        case "thread.reverted":
            // Revert invalidates message, activity, plan, and checkpoint
            // histories. A fresh snapshot is the only safe reconciliation.
            pendingDetailResubscribeId = threadId;
            detailLoading = true;
            detailResubscribeTimer.restart();
            break;
        case "thread.deleted":
            closeDetail();
            return;
        }
        scheduleDetailRecompute(event.type === "thread.activity-appended");
    }

    function applyDetailSnapshot(snapshot, threadId) {
        const thread = snapshot && snapshot.thread;
        if (!thread || typeof thread !== "object" || (thread.id && thread.id !== threadId)) {
            detailLoading = false;
            detailError = "Malformed thread snapshot";
            return;
        }
        detailMessages = sortedHistory(thread.messages);
        for (const message of detailMessages) {
            if (message && typeof message.id === "string")
                draftMessageConfirmed(threadId, message.id);
        }
        detailActivities = sortedHistory(thread.activities);
        detailProposedPlans = sortedHistory(thread.proposedPlans);
        detailCheckpoints = sortedHistory(thread.checkpoints);
        detailSession = thread.session ?? null;
        detailLatestTurn = thread.latestTurn ?? null;
        detailLoading = false;
        detailError = "";
        recomputeDetail();
    }

    function stopDetailRequest() {
        if (detailReqId === "")
            return;
        T3Connection.send(JSON.stringify({ _tag: "Interrupt", requestId: detailReqId }));
        T3Rpc.dropRpcHandler(detailReqId);
        detailReqId = "";
    }

    function startDetailSubscription(threadId) {
        detailResubscribeTimer.stop();
        pendingDetailResubscribeId = "";
        stopDetailRequest();
        cancelDiffRequests(threadId);
        resetDetailData();
        if (T3Connection.state !== "connected" || threadId === "")
            return;

        detailLoading = true;
        const shell = T3Threads.threadMap[threadId];
        if (shell) {
            detailSession = shell.session ?? null;
            detailLatestTurn = shell.latestTurn ?? null;
        }
        const id = String(T3Rpc.nextReqId++);
        detailReqId = id;
        T3Rpc.putRpcHandler(id, {
            item: item => {
                if (root.detailReqId !== id || root.detailThreadId !== threadId)
                    return;
                if (item.kind === "snapshot")
                    root.applyDetailSnapshot(item.snapshot, threadId);
                else if (item.kind === "event")
                    root.applyDetailEvent(item.event, threadId);
            },
            exit: msg => {
                if (root.detailReqId !== id)
                    return;
                root.detailReqId = "";
                root.detailLoading = false;
                if (msg.exit && msg.exit._tag === "Failure")
                    root.detailError = T3Rpc.failureMessage(msg, "Thread details unavailable");
            }
        });
        T3Rpc.sendRequest(id, "orchestration.subscribeThread", { threadId: threadId });
        vcsRefreshWanted(threadId);
    }

    function openDetail(threadId) {
        if (typeof threadId !== "string" || threadId === "") {
            closeDetail();
            return;
        }
        rememberThread(threadId);
        if (detailThreadId === threadId && detailReqId !== "")
            return;
        if (detailThreadId !== "" && detailThreadId !== threadId)
            cancelDiffRequests(detailThreadId);
        detailThreadId = threadId;
        startDetailSubscription(threadId);
    }

    function closeDetail() {
        if (detailThreadId !== "")
            cancelDiffRequests(detailThreadId);
        detailResubscribeTimer.stop();
        pendingDetailResubscribeId = "";
        stopDetailRequest();
        detailThreadId = "";
        resetDetailData();
    }

    Timer {
        id: detailResubscribeTimer
        interval: 1
        onTriggered: {
            const threadId = root.pendingDetailResubscribeId;
            root.pendingDetailResubscribeId = "";
            if (threadId !== "" && root.detailThreadId === threadId
                    && T3Connection.state === "connected")
                root.startDetailSubscription(threadId);
        }
    }
}
