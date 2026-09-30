pragma Singleton
import QtQuick
import Quickshell
import "T3CodeHelpers.js" as Helpers

// Domain commands and their per-action feedback. T3Rpc owns wire correlation;
// views continue using its facade, so this boundary changes no public API.
// A command is never retried on transport loss or after partial batch success.
Singleton {
    id: root

    // Per-command UI state, keyed by actionKey(kind, threadId, requestId):
    // { pending, error, commandId, ... }. A finished entry is left in place so
    // the button can keep showing why it failed, which is why the deadline
    // sweep below only ever looks at pending ones.
    property var actionStates: ({})
    readonly property int actionTimeoutMs: 15000

    // Optional-capability gates for the lifecycle commands below. Derived from
    // the connection here — where the commands live — and re-exported by
    // T3Code; a missing key means an older server, so the command is never
    // sent under version skew.
    readonly property bool supportsSettlement:
        T3Connection.environmentCapabilities.threadSettlement === true
    readonly property bool supportsSnooze:
        T3Connection.environmentCapabilities.threadSnooze === true
    readonly property bool supportsTitleRegeneration:
        T3Connection.environmentCapabilities.threadTitleRegeneration === true
    readonly property bool supportsPinning:
        T3Connection.environmentCapabilities.threadPinning === true

    // ---- commands and action state ---------------------------------------

    function actionKey(kind, threadId, requestId) {
        return kind + "|" + threadId + "|" + (requestId ?? "");
    }

    function actionState(kind, threadId, requestId) {
        const states = actionStates;
        return states[actionKey(kind, threadId, requestId)] ?? null;
    }

    function actionPending(kind, threadId, requestId) {
        const current = actionState(kind, threadId, requestId);
        return current !== null && current.pending === true;
    }

    function actionError(kind, threadId, requestId) {
        const current = actionState(kind, threadId, requestId);
        return current && typeof current.error === "string" ? current.error : "";
    }

    function putActionState(key, value) {
        const next = Object.assign({}, actionStates);
        if (value === null)
            delete next[key];
        else
            next[key] = value;
        actionStates = next;
    }

    function beginAction(key, commandId, awaitResolution, timeoutMs) {
        const state = {
            pending: true,
            error: "",
            commandId: commandId,
            awaitResolution: awaitResolution === true,
            startedAt: Date.now()
        };
        if (typeof timeoutMs === "number" && timeoutMs > 0)
            state.timeoutMs = timeoutMs;
        putActionState(key, state);
    }

    function failAllPendingActions(message) {
        const next = Object.assign({}, actionStates);
        let changed = false;
        for (const key in next) {
            if (!next[key] || next[key].pending !== true)
                continue;
            next[key] = Object.assign({}, next[key], {
                pending: false,
                error: message || "Disconnected before confirmation"
            });
            changed = true;
        }
        if (changed)
            actionStates = next;
    }

    function failAction(key, message) {
        const current = actionStates[key];
        if (!current)
            return;
        putActionState(key, Object.assign({}, current, {
            pending: false,
            error: message || "Action failed"
        }));
    }

    function clearAction(key) {
        if (actionStates[key] !== undefined)
            putActionState(key, null);
    }





    function rejectAction(key, message, awaitResolution) {
        putActionState(key, {
            pending: false,
            error: message,
            commandId: "",
            awaitResolution: awaitResolution === true,
            startedAt: Date.now()
        });
        return "";
    }

    // Dispatch commands one at a time. A later command is never attempted
    // after an earlier rejection, and reconnecting never replays the batch.
    function dispatchBatch(commands, key, options) {
        const opts = options ?? {};
        if (!Helpers.canBeginAction(actionStates, key))
            return "";
        if (!T3Connection.canOperate)
            return rejectAction(key, "This pairing is read-only", opts.awaitResolution);
        if (T3Connection.state !== "connected")
            return rejectAction(key, "Not connected", opts.awaitResolution);
        if (!Array.isArray(commands) || commands.length === 0)
            return rejectAction(key, "Nothing to send", opts.awaitResolution);

        const firstId = commands[0].commandId ?? T3Rpc.genId();
        commands[0].commandId = firstId;
        beginAction(key, firstId, opts.awaitResolution);

        function sendAt(index) {
            if (!root.actionStates[key] || root.actionStates[key].pending !== true)
                return;
            if (index >= commands.length) {
                if (opts.awaitResolution !== true && opts.holdAfterSuccess !== true)
                    root.clearAction(key);
                opts.onSuccess?.();
                return;
            }
            const command = commands[index];
            if (!command.commandId)
                command.commandId = T3Rpc.genId();
            const current = root.actionStates[key];
            root.putActionState(key, Object.assign({}, current, {
                commandId: command.commandId,
                startedAt: Date.now()
            }));
            T3Rpc.requestOnce("orchestration.dispatchCommand", command, () => {
                sendAt(index + 1);
            }, error => {
                root.failAction(key, error || "Command rejected");
                opts.onFailure?.(error);
                console.warn("t3code: command rejected:", error);
            }, { actionKey: key, fallback: "Command rejected" });
        }

        sendAt(0);
        return firstId;
    }

    // Approval/input actions remain pending after RPC acceptance until the
    // provider's matching resolution activity arrives.
    function dispatch(command, key, awaitResolution) {
        return dispatchBatch([command], key, { awaitResolution: awaitResolution === true });
    }

    // decision: "accept" | "acceptForSession" | "decline"
    function respondApproval(threadId, requestId, decision) {
        const key = actionKey("approval", threadId, requestId);
        return dispatch({
            type: "thread.approval.respond",
            commandId: T3Rpc.genId(),
            threadId: threadId,
            requestId: requestId,
            decision: decision,
            createdAt: new Date().toISOString()
        }, key, true);
    }

    // Answers are deliberately narrowed to the two provider contract shapes
    // the dropdown can author: a string or an array of strings.
    function respondUserInput(threadId, requestId, answers) {
        const key = actionKey("input", threadId, requestId);
        const normalized = {};
        let answerCount = 0;
        if (!answers || typeof answers !== "object" || Array.isArray(answers)) {
            putActionState(key, { pending: false, error: "Every question needs an answer",
                commandId: "", awaitResolution: true, startedAt: Date.now() });
            return "";
        }
        for (const questionId in answers) {
            const value = answers[questionId];
            if (typeof value === "string") {
                const answer = value.trim();
                if (answer === "")
                    continue;
                normalized[questionId] = answer;
                answerCount++;
            } else if (Array.isArray(value)) {
                const labels = value.filter(label => typeof label === "string")
                    .map(label => label.trim()).filter(label => label !== "");
                if (labels.length === 0)
                    continue;
                normalized[questionId] = Array.from(new Set(labels));
                answerCount++;
            } else {
                putActionState(key, { pending: false, error: "Unsupported answer format",
                    commandId: "", awaitResolution: true, startedAt: Date.now() });
                return "";
            }
        }
        if (answerCount === 0) {
            putActionState(key, { pending: false, error: "Every question needs an answer",
                commandId: "", awaitResolution: true, startedAt: Date.now() });
            return "";
        }
        return dispatch({
            type: "thread.user-input.respond",
            commandId: T3Rpc.genId(),
            threadId: threadId,
            requestId: requestId,
            answers: normalized,
            createdAt: new Date().toISOString()
        }, key, true);
    }

    function settle(threadId) {
        const key = actionKey("settle", threadId, "");
        const thread = T3Threads.threadMap[threadId];
        if (!supportsSettlement)
            return rejectAction(key, "Settlement is not supported by this server", false);
        if (!Helpers.canOperateLifecycle(thread, Date.now()))
            return rejectAction(key, "Wait for the thread to become idle", false);
        return dispatch({
            type: "thread.settle",
            commandId: T3Rpc.genId(),
            threadId: threadId
        }, key, false);
    }

    function unsettle(threadId) {
        const key = actionKey("unsettle", threadId, "");
        if (!supportsSettlement)
            return rejectAction(key, "Settlement is not supported by this server", false);
        return dispatch({
            type: "thread.unsettle",
            commandId: T3Rpc.genId(),
            threadId: threadId,
            reason: "user"
        }, key, false);
    }

    function settleMany(threadIds) {
        const key = actionKey("bulk-settle", "", "");
        if (!supportsSettlement)
            return rejectAction(key, "Settlement is not supported by this server", false);
        const ids = Array.isArray(threadIds) ? threadIds.filter(id =>
            Helpers.canOperateLifecycle(T3Threads.threadMap[id], Date.now())) : [];
        const commands = ids.map(id => ({
            type: "thread.settle", commandId: T3Rpc.genId(), threadId: id
        }));
        return dispatchBatch(commands, key, {});
    }

    function snooze(threadId, snoozedUntil) {
        const key = actionKey("snooze", threadId, "");
        const thread = T3Threads.threadMap[threadId];
        if (!supportsSnooze)
            return rejectAction(key, "Snooze is not supported by this server", false);
        if (!Helpers.canOperateLifecycle(thread, Date.now()))
            return rejectAction(key, "Wait for the thread to become idle", false);
        if (isNaN(Date.parse(snoozedUntil)) || Date.parse(snoozedUntil) <= Date.now())
            return rejectAction(key, "Choose a future wake time", false);
        return dispatch({
            type: "thread.snooze",
            commandId: T3Rpc.genId(),
            threadId: threadId,
            snoozedUntil: snoozedUntil
        }, key, false);
    }

    function unsnooze(threadId) {
        const key = actionKey("unsnooze", threadId, "");
        if (!supportsSnooze)
            return rejectAction(key, "Snooze is not supported by this server", false);
        return dispatch({
            type: "thread.unsnooze",
            commandId: T3Rpc.genId(),
            threadId: threadId,
            reason: "user"
        }, key, false);
    }

    // Pinning is metadata, not lifecycle: the reference client offers it on
    // running and blocked threads alike, so there is no idleness gate here.
    // orderKey is omitted — the bar never reorders pins.
    function pin(threadId) {
        const key = actionKey("pin", threadId, "");
        if (!supportsPinning)
            return rejectAction(key, "Pinning is not supported by this server", false);
        return dispatch({
            type: "thread.pin",
            commandId: T3Rpc.genId(),
            threadId: threadId
        }, key, false);
    }

    function unpin(threadId) {
        const key = actionKey("unpin", threadId, "");
        if (!supportsPinning)
            return rejectAction(key, "Pinning is not supported by this server", false);
        return dispatch({
            type: "thread.unpin",
            commandId: T3Rpc.genId(),
            threadId: threadId
        }, key, false);
    }

    function interrupt(threadId) {
        return dispatch({
            type: "thread.turn.interrupt",
            commandId: T3Rpc.genId(),
            threadId: threadId,
            createdAt: new Date().toISOString()
        }, actionKey("interrupt", threadId, ""), false);
    }

    function stopSession(threadId) {
        return dispatch({
            type: "thread.session.stop",
            commandId: T3Rpc.genId(),
            threadId: threadId,
            createdAt: new Date().toISOString()
        }, actionKey("session-stop", threadId, ""), false);
    }

    function renameThread(threadId, title) {
        const key = actionKey("rename", threadId, "");
        const normalized = typeof title === "string" ? title.trim() : "";
        if (normalized === "")
            return rejectAction(key, "Title cannot be empty", false);
        return dispatch({
            type: "thread.meta.update",
            commandId: T3Rpc.genId(),
            threadId: threadId,
            title: normalized
        }, key, false);
    }

    function regenerateTitle(threadId) {
        const key = actionKey("regenerate-title", threadId, "");
        if (!supportsTitleRegeneration)
            return rejectAction(key, "Title regeneration is not supported", false);
        if (T3Threads.threadMap[threadId]?.titleRegeneration)
            return rejectAction(key, "Title regeneration is already running", false);
        return dispatch({
            type: "thread.meta.update",
            commandId: T3Rpc.genId(),
            threadId: threadId,
            regenerateTitle: true
        }, key, false);
    }


    function expire(now) {
        const result = Helpers.expireActionStates(actionStates, now, actionTimeoutMs);
        if (result.expiredKeys.length > 0)
            actionStates = result.states;
    }

    Timer {
        interval: 500
        repeat: true
        running: T3Connection.state === "connected"
            && Object.values(root.actionStates).some(state => state && state.pending === true)
        onTriggered: root.expire(Date.now())
    }
}
