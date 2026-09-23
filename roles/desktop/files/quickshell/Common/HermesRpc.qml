pragma Singleton
import QtQuick
import Quickshell

// JSON-RPC 2.0 request correlation, timeouts and action feedback. No request
// is ever replayed after reconnect: callers explicitly reconcile state through
// conversations.list/session.history/session.status instead.
Singleton {
    id: root

    property int nextId: 1
    // Correlation table, mutated in place: nothing binds to it (the deadline
    // Timer keys off deadlineCount), so a copy per request/response is waste.
    property var handlers: ({})
    property int deadlineCount: 0
    // Only pending and failed actions are kept: views read `pending` and
    // `error`, and a success leaves neither, so its entry is removed rather
    // than accumulating one row per action ever performed.
    property var actionStates: ({})
    readonly property int defaultTimeoutMs: 20000

    signal eventReceived(string type, var payload)
    signal protocolError(string message)

    function actionKey(kind, conversationId, requestId) {
        return kind + "|" + (conversationId || "") + "|" + (requestId || "");
    }

    function actionState(kind, conversationId, requestId) {
        return actionStates[actionKey(kind, conversationId, requestId)] ?? null;
    }

    function actionPending(kind, conversationId, requestId) {
        const value = actionState(kind, conversationId, requestId);
        return value !== null && value.pending === true;
    }

    function actionError(kind, conversationId, requestId) {
        const value = actionState(kind, conversationId, requestId);
        return value && typeof value.error === "string" ? value.error : "";
    }

    function putAction(key, value) {
        const next = Object.assign({}, actionStates);
        if (value === null)
            delete next[key];
        else
            next[key] = value;
        actionStates = next;
    }

    function beginAction(key, method) {
        if (key === "")
            return;
        putAction(key, { pending: true, error: "", method: method,
            startedAt: Date.now() });
    }

    function finishAction(key, error) {
        if (key === "")
            return;
        const message = typeof error === "string" ? error : "";
        if (message === "") {
            if (actionStates[key] !== undefined)
                putAction(key, null);
            return;
        }
        const current = actionStates[key] ?? {};
        putAction(key, Object.assign({}, current, {
            pending: false,
            error: message
        }));
    }

    // A deleted conversation's failed actions can never be retried or shown.
    function forgetConversation(conversationId) {
        if (typeof conversationId !== "string" || conversationId === "")
            return;
        const marker = "|" + conversationId + "|";
        let next = null;
        for (const key in actionStates) {
            if (key.indexOf(marker) < 0 || actionStates[key]?.pending === true)
                continue;
            next = next ?? Object.assign({}, actionStates);
            delete next[key];
        }
        if (next !== null)
            actionStates = next;
    }

    function kindPending(kind, conversationId) {
        const prefix = kind + "|" + (conversationId || "") + "|";
        for (const key in actionStates)
            if (key.indexOf(prefix) === 0 && actionStates[key]?.pending === true)
                return true;
        return false;
    }

    function errorText(error, fallback) {
        if (typeof error === "string" && error.trim() !== "")
            return error.trim();
        if (error && typeof error === "object") {
            if (typeof error.message === "string" && error.message.trim() !== "")
                return error.message.trim();
            if (error.data && typeof error.data.message === "string")
                return error.data.message.trim();
        }
        return fallback || "Hermes request failed";
    }

    function request(method, params, onSuccess, onFailure, options) {
        if (HermesConnection.state !== "connected") {
            onFailure?.("Hermes bridge is offline");
            return "";
        }
        const opts = options ?? {};
        const id = String(nextId++);
        const key = typeof opts.actionKey === "string" ? opts.actionKey : "";
        const handler = {
            success: onSuccess,
            failure: onFailure,
            deadline: Date.now() + (opts.timeoutMs ?? defaultTimeoutMs),
            actionKey: key,
            fallback: opts.fallback ?? "Hermes request failed"
        };
        handlers[id] = handler;
        deadlineCount++;
        beginAction(key, method);
        if (!HermesConnection.send(JSON.stringify({
            jsonrpc: "2.0", id: id, method: method, params: params ?? {}
        }))) {
            drop(id);
            finishAction(key, "Hermes bridge is offline");
            onFailure?.("Hermes bridge is offline");
            return "";
        }
        return id;
    }

    function notify(method, params) {
        return HermesConnection.send(JSON.stringify({
            jsonrpc: "2.0", method: method, params: params ?? {}
        }));
    }

    function drop(id) {
        const current = handlers[id];
        if (current === undefined)
            return null;
        delete handlers[id];
        deadlineCount = Math.max(0, deadlineCount - 1);
        return current;
    }

    function handleObject(message) {
        if (!message || typeof message !== "object")
            return;
        if (message.id !== undefined && message.id !== null) {
            const id = String(message.id);
            const handler = drop(id);
            if (!handler)
                return;
            if (message.error !== undefined && message.error !== null) {
                const reason = errorText(message.error, handler.fallback);
                finishAction(handler.actionKey, reason);
                handler.failure?.(reason);
            } else {
                finishAction(handler.actionKey, "");
                handler.success?.(message.result);
            }
            return;
        }
        const params = message.params && typeof message.params === "object"
            ? message.params : message;
        const routedPayload = value => {
            if (!value || typeof value !== "object" || Array.isArray(value))
                return value;
            // Keep routing metadata from the JSON-RPC envelope when a bridge
            // wraps the upstream payload. Payload fields remain authoritative.
            const routing = {};
            for (const key of ["conversationId", "conversation_id",
                    "sessionId", "session_id"])
                if (params[key] !== undefined)
                    routing[key] = params[key];
            return Object.assign(routing, value);
        };
        if (message.method === "event" || message.method === "bridge.event") {
            const type = typeof params.type === "string" ? params.type
                : typeof params.event === "string" ? params.event : "";
            if (type !== "")
                eventReceived(type, routedPayload(params.payload !== undefined
                    ? params.payload : params.data));
            return;
        }
        if (typeof message.method === "string" && message.method !== "") {
            eventReceived(message.method, routedPayload(params.payload !== undefined
                ? params.payload : params));
            return;
        }
        if (typeof message.type === "string")
            eventReceived(message.type, message.payload !== undefined
                ? message.payload : message.data);
    }

    function handleFrame(text) {
        let parsed;
        try {
            parsed = JSON.parse(text);
        } catch (error) {
            protocolError("Hermes bridge sent malformed JSON");
            return;
        }
        const messages = Array.isArray(parsed) ? parsed : [parsed];
        for (const message of messages)
            handleObject(message);
    }

    function abortAll(reason) {
        const current = handlers;
        handlers = ({});
        deadlineCount = 0;
        for (const id in current) {
            const handler = current[id];
            const message = reason || "Disconnected before confirmation";
            finishAction(handler.actionKey, message);
            handler.failure?.(message);
        }
    }

    Timer {
        interval: 500
        repeat: true
        running: root.deadlineCount > 0
        onTriggered: {
            const now = Date.now();
            const expired = [];
            for (const id in root.handlers) {
                if (now >= root.handlers[id].deadline)
                    expired.push(id);
            }
            for (const id of expired) {
                const handler = root.drop(id);
                if (!handler)
                    continue;
                root.finishAction(handler.actionKey, "Request timed out");
                handler.failure?.("Request timed out");
            }
        }
    }

    Connections {
        target: HermesConnection
        function onMessage(text) { root.handleFrame(text); }
        function onDropped() { root.abortAll("Disconnected before confirmation"); }
    }
}
