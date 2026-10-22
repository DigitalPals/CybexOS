pragma Singleton
import QtQuick
import Quickshell
import "T3CodeHelpers.js" as Helpers

// Request/response correlation over the T3 socket. Domain actions live in
// T3Actions; this facade retains the existing public command surface.
//
// This is the layer between the transport (Common/T3Connection.qml, which
// knows only frames) and the domain (Common/T3Code.qml, which knows threads).
// It owns request ids, the in-flight handler table, the deadline sweep that
// expires both, and `actionStates` — the per-button pending/error state the
// popover reads.
//
// T3Code routes incoming frames here by request id; anything on the shell
// stream is domain traffic and never reaches this file.
Singleton {
    id: root

    readonly property var actionStates: T3Actions.actionStates
    readonly property int actionTimeoutMs: T3Actions.actionTimeoutMs
    readonly property bool supportsSettlement: T3Actions.supportsSettlement
    readonly property bool supportsSnooze: T3Actions.supportsSnooze
    readonly property bool supportsTitleRegeneration: T3Actions.supportsTitleRegeneration
    readonly property bool supportsPinning: T3Actions.supportsPinning

    function putRpcHandler(id, handler) {
        dropRpcHandler(id);
        rpcHandlers[id] = handler;
        if (typeof handler.deadline === "number")
            rpcDeadlineCount++;
    }

    function dropRpcHandler(id) {
        const handler = rpcHandlers[id];
        if (handler === undefined)
            return;
        delete rpcHandlers[id];
        if (typeof handler.deadline === "number")
            rpcDeadlineCount--;
    }

    function clearRpcHandlers() {
        rpcHandlers = {};
        rpcDeadlineCount = 0;
    }

    function genId() {
        let s = "";
        for (let i = 0; i < 32; i++)
            s += Math.floor(Math.random() * 16).toString(16);
        return s;
    }

    function sendRequest(id, tag, payload) {
        if (T3Connection.state !== "connected")
            return false;
        T3Connection.send(JSON.stringify({
            _tag: "Request",
            id: id,
            tag: tag,
            payload: payload,
            headers: []
        }));
        return true;
    }

    // Effect RPC sends zero or more Chunk values followed by one Exit. This
    // wrapper retains the final value, applies a hard timeout, and never
    // retries implicitly after a transport loss.
    function requestOnce(tag, payload, onSuccess, onFailure, options) {
        if (T3Connection.state !== "connected") {
            onFailure?.("Not connected");
            return "";
        }
        const id = String(nextReqId++);
        const opts = options ?? {};
        const handler = {
            value: undefined,
            deadline: Date.now() + (opts.timeoutMs ?? actionTimeoutMs),
            actionKey: opts.actionKey ?? "",
            item: value => {
                handler.value = value;
                // Streams that report progress (git.runStackedAction) stay
                // alive as long as chunks keep arriving.
                if (opts.slidingDeadline === true)
                    handler.deadline = Date.now() + (opts.timeoutMs ?? actionTimeoutMs);
                opts.onItem?.(value);
            },
            exit: msg => {
                if (msg.exit && msg.exit._tag === "Failure")
                    onFailure?.(root.failureMessage(msg, opts.fallback ?? "Request failed"));
                else {
                    // Unary Effect RPCs (including server.getConfig and the
                    // full-diff request) return their result on Success.value.
                    // Streams exit with a null value and instead populate
                    // `handler.value` through their final Chunk.
                    const exitValue = msg.exit ? msg.exit.value : undefined;
                    const value = exitValue !== undefined && exitValue !== null
                        ? exitValue : handler.value;
                    onSuccess?.(value);
                }
            },
            timeout: () => onFailure?.("Request timed out"),
            disconnect: () => onFailure?.("Disconnected before confirmation")
        };
        putRpcHandler(id, handler);
        if (!sendRequest(id, tag, payload)) {
            dropRpcHandler(id);
            onFailure?.("Not connected");
            return "";
        }
        return id;
    }

    // Every in-flight request is gone. The detail subsystem listens so it can
    // forget the subscription id it was holding; this layer does not know what
    // that id was for.
    signal aborted()

    function abortPendingRpcs() {
        const handlers = rpcHandlers;
        clearRpcHandlers();
        for (const id in handlers)
            handlers[id].disconnect?.();
        aborted();
    }


    // Only wire requests with deadlines keep this sweep awake. Action
    // feedback has its own lifecycle in T3Actions, independent of streams.
    Timer {
        interval: 500
        repeat: true
        running: T3Connection.state === "connected"
            && root.rpcDeadlineCount > 0
        onTriggered: {
            const now = Date.now();
            for (const id in root.rpcHandlers) {
                const handler = root.rpcHandlers[id];
                if (handler.deadline === undefined || now < handler.deadline)
                    continue;
                T3Connection.send(JSON.stringify({ _tag: "Interrupt", requestId: id }));
                root.dropRpcHandler(id);
                handler.timeout?.();
            }
        }
    }


    // Compatibility facade for domain commands and per-action feedback.

    function actionKey(kind, threadId, requestId) {
        return T3Actions.actionKey(kind, threadId, requestId);
    }

    function actionState(kind, threadId, requestId) {
        return T3Actions.actionState(kind, threadId, requestId);
    }

    function actionPending(kind, threadId, requestId) {
        return T3Actions.actionPending(kind, threadId, requestId);
    }

    function actionError(kind, threadId, requestId) {
        return T3Actions.actionError(kind, threadId, requestId);
    }

    function putActionState(key, value) {
        return T3Actions.putActionState(key, value);
    }

    function beginAction(key, commandId, awaitResolution, timeoutMs) {
        return T3Actions.beginAction(key, commandId, awaitResolution, timeoutMs);
    }

    function failAllPendingActions(message) {
        return T3Actions.failAllPendingActions(message);
    }

    function failAction(key, message) {
        return T3Actions.failAction(key, message);
    }

    function clearAction(key) {
        return T3Actions.clearAction(key);
    }

    function rejectAction(key, message, awaitResolution) {
        return T3Actions.rejectAction(key, message, awaitResolution);
    }

    function dispatchBatch(commands, key, options) {
        return T3Actions.dispatchBatch(commands, key, options);
    }

    function dispatch(command, key, awaitResolution) {
        return T3Actions.dispatch(command, key, awaitResolution);
    }

    function respondApproval(threadId, requestId, decision) {
        return T3Actions.respondApproval(threadId, requestId, decision);
    }

    function respondUserInput(threadId, requestId, answers) {
        return T3Actions.respondUserInput(threadId, requestId, answers);
    }

    function settle(threadId) {
        return T3Actions.settle(threadId);
    }

    function unsettle(threadId) {
        return T3Actions.unsettle(threadId);
    }

    function settleMany(threadIds) {
        return T3Actions.settleMany(threadIds);
    }

    function snooze(threadId, snoozedUntil) {
        return T3Actions.snooze(threadId, snoozedUntil);
    }

    function unsnooze(threadId) {
        return T3Actions.unsnooze(threadId);
    }

    function pin(threadId) {
        return T3Actions.pin(threadId);
    }

    function unpin(threadId) {
        return T3Actions.unpin(threadId);
    }

    function interrupt(threadId) {
        return T3Actions.interrupt(threadId);
    }

    function stopSession(threadId) {
        return T3Actions.stopSession(threadId);
    }

    function renameThread(threadId, title) {
        return T3Actions.renameThread(threadId, title);
    }

    function regenerateTitle(threadId) {
        return T3Actions.regenerateTitle(threadId);
    }

    function cancelActionRequests(key) {
        for (const id in rpcHandlers) {
            const handler = rpcHandlers[id];
            if (!handler || handler.actionKey !== key)
                continue;
            T3Connection.send(JSON.stringify({ _tag: "Interrupt", requestId: id }));
            dropRpcHandler(id);
        }
        clearAction(key);
    }

    function failureMessage(msg, fallback) {
        const found = Helpers.findErrorText(msg ? msg.exit : null, 0);
        return found !== "" ? found.slice(0, 240) : fallback;
    }

    readonly property string shellReqId: "1"
    property int nextReqId: 2
    // requestId → { item(value), exit(msg) } for non-shell streams.
    property var rpcHandlers: ({})
    // rpcHandlers is mutated in place (added and deleted by request id), and
    // an in-place mutation never re-evaluates a binding. This is the notifying
    // mirror the deadline sweep below watches, so every add and delete goes
    // through the three functions here. Only handlers that actually carry a
    // deadline count: an open detail subscription has none and must not keep
    // the sweep awake for as long as the popover shows a thread.
    property int rpcDeadlineCount: 0
}
