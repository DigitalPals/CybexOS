pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "HermesHelpers.js" as Helpers

// Native projection of the remote Hermes WebUI session list. An empty
// selectedConversationId is the deliberate, non-persisted "New chat" state;
// the first send creates a WebUI session and then selects it.
Singleton {
    id: root

    property var conversations: []
    property string selectedConversationId: ""
    // Transcripts are mutated in place (a streamed token must not reassign the
    // map every binding observes). transcriptChanged(id) is the notification;
    // transcriptRevision lets a binding opt in when it really needs to.
    property var messagesByConversation: ({})
    property int transcriptRevision: 0
    // Most recently selected conversations, newest first. Only these keep a
    // transcript in memory once they settle; others reload on selection.
    property var transcriptLru: []
    readonly property int retainedTranscripts: 3
    property var toolsByConversation: ({})
    property var sessionStateByConversation: ({})
    property var historyByConversation: ({})
    property var requestsByConversation: ({})
    property var errorsByConversation: ({})
    property var dismissedErrorSequencesByConversation: ({})
    property var loadingByConversation: ({})
    property var drafts: ({})
    property var streamIdsByConversation: ({})
    property int streamSequence: 0
    property int errorSequence: 0
    property bool ready: false
    property bool loading: false
    property string error: ""
    property bool panelVisible: false
    property bool stateLoaded: false
    property bool listInFlight: false
    property bool listQueued: false

    readonly property var newConversation: ({
        id: "",
        sessionId: "",
        title: "New chat",
        profile: "",
        model: "",
        modelProvider: "",
        workspace: "",
        source: "webui",
        readOnly: false,
        messageCount: 0,
        status: "idle",
        statusText: "Start a new conversation",
        unread: 0,
        requestCount: 0,
        updatedAt: "",
        createdAt: "",
        error: ""
    })
    readonly property bool isNewChat: selectedConversationId === ""
    readonly property var selectedConversation: isNewChat
        ? newConversation : conversationById(selectedConversationId)
    readonly property var selectedMessages: transcriptRevision >= 0
        ? messagesFor(selectedConversationId) : []
    readonly property var selectedTools: toolsFor(selectedConversationId)
    readonly property var selectedSessionState: sessionStateFor(selectedConversationId)
    readonly property var selectedHistory: historyFor(selectedConversationId)
    readonly property var selectedRequests: requestsFor(selectedConversationId)
    readonly property var selectedErrorRecord:
        errorRecordFor(selectedConversationId)
    readonly property string selectedError: errorFor(selectedConversationId)
    readonly property bool selectedErrorRetryable: selectedError !== ""
        && selectedErrorRecord.retry !== ""
    readonly property bool selectedLoading:
        loadingByConversation[selectedConversationId] === true
    readonly property var counts: Helpers.counts(conversations)
    readonly property int workingCount: counts.working
    readonly property int attentionCount: counts.attention
    readonly property int errorCount: counts.errors
    readonly property int doneCount: counts.done
    readonly property int unreadCount: counts.unread

    signal selectionReady(string conversationId)
    signal transcriptChanged(string conversationId)

    function copyMap(source, key, value) {
        const next = Object.assign({}, source);
        if (value === undefined)
            delete next[key];
        else
            next[key] = value;
        return next;
    }

    function conversationById(conversationId) {
        if (typeof conversationId !== "string" || conversationId === "")
            return null;
        return conversations.find(conversation => conversation.id === conversationId)
            ?? null;
    }

    function conversationIdForPayload(payload) {
        return Helpers.sessionId(payload);
    }

    function messagesFor(conversationId) {
        const value = messagesByConversation[conversationId];
        return Array.isArray(value) ? value : [];
    }

    function storeMessages(conversationId, value) {
        if (value === undefined)
            delete messagesByConversation[conversationId];
        else
            messagesByConversation[conversationId] = value;
        transcriptRevision++;
    }

    function touchTranscript(conversationId) {
        if (conversationId === "")
            return;
        const index = transcriptLru.indexOf(conversationId);
        if (index >= 0)
            transcriptLru.splice(index, 1);
        transcriptLru.unshift(conversationId);
        if (transcriptLru.length > retainedTranscripts)
            transcriptLru.length = retainedTranscripts;
        evictTranscripts();
    }

    // Drop settled transcripts of conversations that are neither selected nor
    // recently viewed. A live stream keeps its rows until it completes, and
    // selecting an evicted conversation reloads its history as before.
    function evictTranscripts() {
        let evicted = false;
        let tools = toolsByConversation;
        let history = historyByConversation;
        for (const conversationId of Object.keys(messagesByConversation)) {
            if (conversationId === selectedConversationId
                    || transcriptLru.indexOf(conversationId) >= 0
                    || messagesFor(conversationId).some(item => item.streaming === true))
                continue;
            delete messagesByConversation[conversationId];
            tools = copyMap(tools, conversationId, undefined);
            history = copyMap(history, conversationId, undefined);
            evicted = true;
        }
        if (!evicted)
            return;
        toolsByConversation = tools;
        historyByConversation = history;
        transcriptRevision++;
    }

    function toolsFor(conversationId) {
        const value = toolsByConversation[conversationId];
        return Array.isArray(value) ? value : [];
    }

    function sessionStateFor(conversationId) {
        const value = sessionStateByConversation[conversationId];
        return value && typeof value === "object"
            ? value : Helpers.emptySessionState();
    }

    function historyFor(conversationId) {
        const value = historyByConversation[conversationId];
        return value && typeof value === "object" ? value : ({
            hasMore: false,
            offset: 0,
            loadingEarlier: false,
            atCapacity: false
        });
    }

    function updateSessionState(conversationId, type, payload) {
        sessionStateByConversation = copyMap(sessionStateByConversation,
            conversationId, Helpers.applySessionState(
                sessionStateFor(conversationId), type, payload));
    }

    function timelinePayload(conversationId, raw, kind) {
        const value = Helpers.object(raw);
        const id = Helpers.firstString(value.id, value.messageId,
            value.message_id, value.toolCallId, value.tool_call_id,
            value.callId, value.call_id);
        const source = kind === "tool" ? toolsFor(conversationId)
            : messagesFor(conversationId);
        const current = id !== "" ? source.find(item => item.id === id) : null;
        return Object.assign({}, value, {
            order: typeof value.order === "number" ? value.order
                : current && typeof current.order === "number" ? current.order
                    : Date.now() * 1000 + (++streamSequence)
        });
    }

    function requestsFor(conversationId) {
        const value = requestsByConversation[conversationId];
        return Array.isArray(value) ? value : [];
    }

    function draft(conversationId) {
        return typeof drafts[conversationId] === "string"
            ? drafts[conversationId] : "";
    }

    function setDraft(conversationId, value) {
        const text = typeof value === "string" ? value : "";
        if (draft(conversationId) === text)
            return;
        drafts = copyMap(drafts, conversationId, text === "" ? undefined : text);
        // Typing updates the draft per keystroke; the state file is written
        // once the burst settles, and flushed when the panel closes.
        persistTimer.restart();
    }

    function flushDrafts() {
        if (persistTimer.running)
            persist();
    }

    function moveDraft(fromId, toId) {
        const text = draft(fromId);
        if (text !== "")
            drafts = copyMap(drafts, toId, text);
        drafts = copyMap(drafts, fromId, undefined);
        persist();
    }

    function setLoading(conversationId, value) {
        loadingByConversation = copyMap(loadingByConversation, conversationId,
            value === true ? true : undefined);
    }

    function errorRecordFor(conversationId) {
        const value = errorsByConversation[conversationId];
        return value && typeof value === "object" ? value : ({
            message: "",
            sequence: 0,
            retry: ""
        });
    }

    function errorFor(conversationId) {
        const record = errorRecordFor(conversationId);
        const dismissed = dismissedErrorSequencesByConversation[conversationId];
        return record.message !== "" && dismissed !== record.sequence
            ? record.message : "";
    }

    // Each occurrence gets a new sequence, even when its copy is identical.
    // Dismissing one failure therefore remains stable across selection changes
    // without swallowing a later failure from a new request or event.
    function setError(conversationId, value, retry) {
        const message = typeof value === "string" ? value.trim() : "";
        if (message === "") {
            errorsByConversation = copyMap(errorsByConversation,
                conversationId, undefined);
            return;
        }
        errorsByConversation = copyMap(errorsByConversation, conversationId, {
            message: message,
            sequence: ++errorSequence,
            retry: retry === "refresh" || retry === "load-earlier" ? retry : ""
        });
    }

    function dismissError(conversationId) {
        const record = errorRecordFor(conversationId);
        if (record.message === "" || errorFor(conversationId) === "")
            return false;
        dismissedErrorSequencesByConversation = copyMap(
            dismissedErrorSequencesByConversation, conversationId,
            record.sequence);
        return true;
    }

    function retryError(conversationId) {
        const record = errorRecordFor(conversationId);
        if (errorFor(conversationId) === "")
            return false;
        if (record.retry === "refresh")
            return refreshConversation(conversationId);
        if (record.retry === "load-earlier")
            return loadEarlier(conversationId);
        return false;
    }

    function normalizedConversations(value) {
        const source = Array.isArray(value) ? value
            : value && Array.isArray(value.conversations) ? value.conversations
                : value && Array.isArray(value.sessions) ? value.sessions
                    : value && Array.isArray(value.items) ? value.items : [];
        return source.map((conversation, index) =>
            Helpers.normalizeConversation(conversation, index));
    }

    function setConversations(value) {
        const incoming = normalizedConversations(value);
        const merged = incoming.map(conversation => {
            const current = conversationById(conversation.id);
            if (!current)
                return conversation;
            const patch = Object.assign({}, conversation);
            if (conversation.status === "idle" && current.status !== "idle"
                    && current.status !== "done") {
                patch.status = current.status;
                patch.statusText = current.statusText;
            }
            if (conversation.unread === 0 && current.unread > 0)
                patch.unread = current.unread;
            return Helpers.sameConversation(current, patch) ? current : patch;
        });
        const sorted = Helpers.sortedConversations(merged);
        if (sorted.length !== conversations.length
                || sorted.some((conversation, index) =>
                    conversation !== conversations[index]))
            conversations = sorted;
        ready = true;
        loading = false;
        error = "";
        if (selectedConversationId !== ""
                && !conversationById(selectedConversationId))
            selectConversation("", false);
    }

    function upsertConversation(raw) {
        const conversation = Helpers.normalizeConversation(raw,
            conversations.length);
        if (conversation.id === "")
            return null;
        const current = conversationById(conversation.id);
        const merged = current ? Object.assign({}, current, conversation)
            : conversation;
        if (current && Helpers.sameConversation(current, merged))
            return current;
        conversations = Helpers.sortedConversations(
            conversations.filter(item => item.id !== merged.id).concat([merged]));
        return merged;
    }

    function updateConversation(conversationId, patch) {
        const current = conversationById(conversationId);
        if (!current)
            return;
        const updated = Helpers.normalizeConversation(Object.assign({}, current,
            patch, { id: conversationId, sessionId: conversationId }), 0);
        // Repeated status broadcasts are common; an identical row must not
        // re-sort and reassign the list every conversation binding observes.
        if (Helpers.sameConversation(current, updated))
            return;
        conversations = Helpers.sortedConversations(conversations.map(conversation =>
            conversation.id === conversationId ? updated : conversation));
    }

    function removeConversationLocal(conversationId) {
        conversations = conversations.filter(conversation =>
            conversation.id !== conversationId);
        storeMessages(conversationId, undefined);
        const lruIndex = transcriptLru.indexOf(conversationId);
        if (lruIndex >= 0)
            transcriptLru.splice(lruIndex, 1);
        HermesRpc.forgetConversation(conversationId);
        toolsByConversation = copyMap(toolsByConversation,
            conversationId, undefined);
        sessionStateByConversation = copyMap(sessionStateByConversation,
            conversationId, undefined);
        historyByConversation = copyMap(historyByConversation,
            conversationId, undefined);
        requestsByConversation = copyMap(requestsByConversation,
            conversationId, undefined);
        errorsByConversation = copyMap(errorsByConversation,
            conversationId, undefined);
        dismissedErrorSequencesByConversation = copyMap(
            dismissedErrorSequencesByConversation, conversationId, undefined);
        drafts = copyMap(drafts, conversationId, undefined);
        streamIdsByConversation = copyMap(streamIdsByConversation,
            conversationId, undefined);
        if (selectedConversationId === conversationId)
            selectConversation("", false);
        persist();
    }

    function markRead(conversationId) {
        const conversation = conversationById(conversationId);
        if (!conversation || conversation.unread === 0)
            return;
        updateConversation(conversationId, { unread: 0 });
    }

    function selectConversation(conversationId, forceRefresh) {
        if (conversationId === "") {
            selectedConversationId = "";
            setError("", "");
            HermesRpc.notify("conversations.select", { sessionId: "" });
            selectionReady("");
            return true;
        }
        const conversation = conversationById(conversationId);
        if (!conversation)
            return false;
        const changed = selectedConversationId !== conversationId;
        selectedConversationId = conversationId;
        touchTranscript(conversationId);
        HermesRpc.notify("conversations.select", { sessionId: conversationId });
        if (panelVisible)
            markRead(conversationId);
        if (changed || forceRefresh === true
                || messagesFor(conversationId).length === 0)
            refreshConversation(conversationId);
        selectionReady(conversationId);
        return true;
    }

    function mergeHistory(conversationId, value, modeOverride) {
        const normalized = Helpers.normalizeHistory(value);
        const history = normalized.history;
        const mode = modeOverride || Helpers.firstString(history.mode, "replace");
        const existingMessages = messagesFor(conversationId);
        let snapshot = normalized.messages.slice();
        if (mode === "prepend") {
            for (const current of existingMessages) {
                const at = snapshot.findIndex(item => item.id === current.id);
                if (at < 0)
                    snapshot.push(current);
                else if (current.streaming === true)
                    snapshot[at] = current;
            }
        } else {
            for (const live of existingMessages) {
                const at = snapshot.findIndex(item => item.id === live.id);
                if (at < 0 && live.streaming === true)
                    snapshot.push(live);
                else if (at >= 0 && live.streaming === true)
                    snapshot[at] = live;
            }
        }
        snapshot.sort((a, b) => (a.order ?? 0) - (b.order ?? 0));
        const overflowed = snapshot.length > 250;
        if (overflowed)
            snapshot = snapshot.slice(snapshot.length - 250);
        const atCapacity = snapshot.length >= 250 && history.hasMore === true;

        const existingTools = toolsFor(conversationId);
        let tools = normalized.tools.slice();
        for (const current of existingTools) {
            const at = tools.findIndex(item => item.id === current.id);
            if (at < 0 && (mode === "prepend" || !current.terminal))
                tools.push(current);
            else if (at >= 0 && !current.terminal)
                tools[at] = current;
        }
        tools.sort((a, b) => (a.order ?? 0) - (b.order ?? 0));
        if (snapshot.length > 0) {
            const floor = snapshot[0].order ?? 0;
            tools = tools.filter(tool => (tool.order ?? 0) >= floor);
        }
        if (tools.length > 250)
            tools = tools.slice(tools.length - 250);

        storeMessages(conversationId, snapshot);
        toolsByConversation = copyMap(toolsByConversation,
            conversationId, tools);
        sessionStateByConversation = copyMap(sessionStateByConversation,
            conversationId, Helpers.mergeSessionState(
                sessionStateFor(conversationId), normalized.sessionState));
        historyByConversation = copyMap(historyByConversation,
            conversationId, {
                hasMore: history.hasMore === true && !atCapacity,
                offset: Math.max(0, Number(history.offset) || 0),
                loadingEarlier: false,
                atCapacity: atCapacity,
                messageCount: Math.max(0, Number(history.messageCount) || 0),
                limit: Math.max(1, Number(history.limit) || 80)
            });
        transcriptChanged(conversationId);
    }

    function refreshConversation(conversationId) {
        const conversation = conversationById(conversationId);
        if (!conversation || HermesConnection.state !== "connected")
            return false;
        setLoading(conversationId, true);
        setError(conversationId, "");
        let pending = 2;
        const finish = () => {
            pending--;
            if (pending <= 0)
                root.setLoading(conversationId, false);
        };
        const loadStatus = () => HermesRpc.request("session.status", {
            sessionId: conversationId
        }, result => {
            root.applyStatus(conversationId, result);
            finish();
        }, reason => {
            if (root.messagesFor(conversationId).length === 0)
                root.setError(conversationId, reason, "refresh");
            finish();
        }, { fallback: "Could not load Hermes status" });
        HermesRpc.request("session.history", {
            sessionId: conversationId,
            limit: 80
        }, result => {
            root.mergeHistory(conversationId, result);
            finish();
            loadStatus();
        }, reason => {
            root.setError(conversationId, reason, "refresh");
            finish();
            loadStatus();
        }, { timeoutMs: 30000, fallback: "Could not load Hermes history" });
        return true;
    }

    function loadEarlier(conversationId) {
        const conversation = conversationById(conversationId);
        const state = historyFor(conversationId);
        if (!conversation || state.loadingEarlier === true || state.hasMore !== true
                || messagesFor(conversationId).length >= 250)
            return false;
        setError(conversationId, "");
        historyByConversation = copyMap(historyByConversation, conversationId,
            Object.assign({}, state, { loadingEarlier: true }));
        HermesRpc.request("session.history", {
            sessionId: conversationId,
            before: Math.max(0, Number(state.offset) || 0),
            limit: 80
        }, result => {
            root.mergeHistory(conversationId, result, "prepend");
        }, reason => {
            root.historyByConversation = root.copyMap(root.historyByConversation,
                conversationId, Object.assign({}, root.historyFor(conversationId), {
                    loadingEarlier: false
                }));
            root.setError(conversationId, reason, "load-earlier");
        }, { timeoutMs: 30000, fallback: "Could not load earlier Hermes history" });
        return true;
    }

    // Connect, remote sign-in and gateway events can each ask for the list in
    // the same turn. Requests coalesce into one per event-loop turn, and at
    // most one runs at a time: a request made meanwhile queues exactly one
    // follow-up, so the last caller still sees a list fetched after its call.
    function refreshAll() {
        if (HermesConnection.state !== "connected")
            return;
        loading = true;
        error = "";
        Qt.callLater(root.requestConversationList);
    }

    function requestConversationList() {
        if (listInFlight) {
            listQueued = true;
            return;
        }
        if (HermesConnection.state !== "connected") {
            loading = false;
            return;
        }
        listInFlight = true;
        const settle = () => {
            root.listInFlight = false;
            if (root.listQueued) {
                root.listQueued = false;
                root.refreshAll();
            }
        };
        HermesRpc.request("conversations.list", {}, result => {
            root.setConversations(result);
            settle();
        }, reason => {
            root.loading = false;
            root.ready = true;
            root.error = reason;
            settle();
        }, { timeoutMs: 30000,
            fallback: "Could not load Hermes conversations" });
    }

    function createConversation(options, onSuccess, onFailure) {
        const createOptions = options && typeof options === "object" ? options : ({});
        const key = HermesRpc.actionKey("conversation-create", "", "");
        return HermesRpc.request("conversations.create", createOptions, result => {
            const raw = result?.conversation ?? result?.session ?? result;
            const conversation = root.upsertConversation(raw);
            if (!conversation) {
                onFailure?.("Hermes returned an invalid conversation");
                return;
            }
            root.moveDraft("", conversation.id);
            root.selectConversation(conversation.id, false);
            onSuccess?.(conversation);
        }, onFailure, { actionKey: key, timeoutMs: 30000,
            fallback: "Could not start a new conversation" });
    }

    function deleteConversation(conversationId, onSuccess, onFailure) {
        const conversation = conversationById(conversationId);
        if (!conversation)
            return "";
        if (conversation.readOnly) {
            onFailure?.("This conversation is read-only");
            return "";
        }
        const key = HermesRpc.actionKey("conversation-delete", conversationId, "");
        return HermesRpc.request("conversations.delete", {
            sessionId: conversationId
        }, result => {
            root.removeConversationLocal(conversationId);
            onSuccess?.(result);
        }, onFailure, { actionKey: key,
            fallback: "Could not delete conversation" });
    }

    function applyStatus(conversationId, raw) {
        const value = Helpers.object(raw);
        const nested = Helpers.object(value.status);
        const statusValue = Helpers.firstString(value.state,
            typeof value.status === "string" ? value.status : "", nested.state,
            value.activityState);
        const status = statusValue !== "" ? Helpers.canonicalStatus(statusValue)
            : conversationById(conversationId)?.status ?? "idle";
        const statusText = Helpers.firstString(value.statusText, value.activity,
            value.detail, nested.text, nested.detail);
        const current = conversationById(conversationId);
        const patch = {
            status: status,
            rawStatus: statusValue
        };
        // Only a real transition moves the conversation in recency order; a
        // repeated "working" broadcast is not new activity.
        const timestamp = Helpers.firstString(value.updatedAt, value.timestamp);
        if (timestamp !== "")
            patch.updatedAt = timestamp;
        else if (!current || current.status !== status
                || (statusText !== "" && current.statusText !== statusText))
            patch.updatedAt = new Date().toISOString();
        if (statusText !== "")
            patch.statusText = statusText;
        if (value.error !== undefined)
            patch.error = Helpers.firstString(value.error);
        updateConversation(conversationId, patch);
    }

    function ensureConversationForPayload(value) {
        const conversationId = conversationIdForPayload(value);
        if (conversationId === "" || conversationById(conversationId))
            return conversationId;
        const raw = value.conversation ?? value.session ?? {
            sessionId: conversationId,
            title: Helpers.firstString(value.title, "Untitled chat")
        };
        return upsertConversation(Object.assign({}, raw, {
            sessionId: conversationId
        }))?.id ?? "";
    }

    function applyEvent(type, payload) {
        const event = Helpers.eventType(type);
        const value = Helpers.object(payload);
        if (event === "conversations-list" || event === "conversations-snapshot"
                || event === "sessions-list" || event === "sessions-snapshot") {
            setConversations(payload);
            return;
        }
        if (event === "conversation-created") {
            upsertConversation(value.conversation ?? value.session ?? value);
            return;
        }
        if (event === "conversation-updated") {
            const raw = value.conversation ?? value.session ?? value;
            const id = Helpers.firstString(raw.sessionId, raw.session_id, raw.id,
                Helpers.sessionId(value));
            if (conversationById(id))
                updateConversation(id, raw);
            else
                upsertConversation(raw);
            return;
        }
        if (event === "conversation-deleted") {
            removeConversationLocal(Helpers.firstString(value.sessionId,
                value.session_id, value.id));
            return;
        }

        const conversationId = ensureConversationForPayload(value);
        if (conversationId === "")
            return;

        if (event === "message-snapshot" || event === "message-page"
                || event === "session-history") {
            mergeHistory(conversationId, payload,
                event === "message-page" ? "prepend" : "replace");
            return;
        }
        if (event === "session-status" || event === "session-activity"
                || event === "session-info" || event === "session-usage"
                || event === "session-reasoning" || event === "session-warning"
                || event === "session-context" || event === "session-goal"
                || event === "session-todos" || event === "session-pending-steer"
                || event === "session-background" || event === "status"
                || event === "activity") {
            updateSessionState(conversationId, event, value);
            if (event === "session-status" || event === "session-activity"
                    || event === "session-info" || event === "status"
                    || event === "activity")
                applyStatus(conversationId, value);
            transcriptChanged(conversationId);
            return;
        }
        if (event === "session-error" || event === "error") {
            const reason = Helpers.firstString(value.error, value.message,
                "Hermes session failed");
            setError(conversationId, reason);
            updateConversation(conversationId, { status: "error", error: reason,
                updatedAt: new Date().toISOString() });
            return;
        }
        if (event.indexOf("message-") === 0 || event.indexOf("assistant-") === 0
                || event.indexOf("stream-") === 0 || event === "session-history") {
            let messagePayload = value;
            const streamingEvent = event === "message-start"
                || event === "assistant-start" || event === "message-delta"
                || event === "assistant-delta" || event === "stream-delta"
                || event === "message-complete" || event === "message-completed"
                || event === "assistant-complete";
            if (streamingEvent) {
                let streamId = streamIdsByConversation[conversationId] ?? "";
                if (event.indexOf("start") >= 0 || streamId === "") {
                    const live = messagesFor(conversationId).slice().reverse()
                        .find(item => item.streaming === true
                            && item.role === "assistant");
                    streamId = live?.id ?? "stream-" + conversationId + "-"
                        + String(++streamSequence);
                    streamIdsByConversation = copyMap(streamIdsByConversation,
                        conversationId, streamId);
                }
                messagePayload = Object.assign({}, value, {
                    id: Helpers.firstString(value.id, value.messageId,
                        value.message_id, streamId),
                    role: Helpers.firstString(value.role, "assistant")
                });
            }
            messagePayload = timelinePayload(conversationId, messagePayload, "message");
            let next = Helpers.applyMessageEvent(messagesFor(conversationId),
                event, messagePayload);
            if (event === "message-start" || event === "assistant-start")
                updateSessionState(conversationId, "turn-start", value);
            if (event === "message-complete" || event === "message-completed"
                    || event === "assistant-complete")
                updateSessionState(conversationId, "turn-complete", value);
            if (event === "message-complete" || event === "message-completed"
                    || event === "assistant-complete")
                streamIdsByConversation = copyMap(streamIdsByConversation,
                    conversationId, undefined);
            if (next.length > 250)
                next = next.slice(next.length - 250);
            storeMessages(conversationId, next);
            if ((event.indexOf("complete") >= 0 || event === "message-created")
                    && (!panelVisible
                        || selectedConversationId !== conversationId)) {
                const conversation = conversationById(conversationId);
                updateConversation(conversationId, {
                    unread: (conversation?.unread ?? 0) + 1
                });
            }
            transcriptChanged(conversationId);
            if (event.indexOf("complete") >= 0)
                evictTranscripts();
            return;
        }
        if (event.indexOf("tool-") === 0) {
            const toolPayload = timelinePayload(conversationId, value, "tool");
            let nextTools = Helpers.applyToolEvent(toolsFor(conversationId),
                event, toolPayload);
            if (nextTools.length > 30)
                nextTools = nextTools.slice(nextTools.length - 30);
            toolsByConversation = copyMap(toolsByConversation,
                conversationId, nextTools);
            const tool = nextTools.find(item => item.id
                === Helpers.normalizeTool(toolPayload, 0).id);
            const current = conversationById(conversationId);
            const toolText = tool ? tool.label || tool.name : "";
            // tool.progress repeats per chunk; only a new tool or label is news.
            if (tool && !tool.terminal && current && (current.status !== "working"
                    || current.statusText !== toolText))
                updateConversation(conversationId, { status: "working",
                    statusText: toolText,
                    updatedAt: new Date().toISOString() });
            transcriptChanged(conversationId);
            return;
        }
        const requestEvent = event.indexOf("request-") === 0
            || event.indexOf("approval-") === 0 || event.indexOf("clarify-") === 0
            || event.indexOf("sudo-") === 0 || event.indexOf("secret-") === 0;
        if (requestEvent) {
            const requestPayload = Object.assign({}, value);
            if (event.indexOf("approval-") === 0 || event === "request-approval")
                requestPayload.kind = "approval";
            if (event.indexOf("clarify-") === 0 || event === "request-clarify")
                requestPayload.kind = "clarify";
            if (event.indexOf("sudo-") === 0 || event === "request-sudo")
                requestPayload.kind = "sudo";
            if (event.indexOf("secret-") === 0 || event === "request-secret")
                requestPayload.kind = "secret";
            const nextRequests = Helpers.applyRequestEvent(
                requestsFor(conversationId), event, requestPayload);
            requestsByConversation = copyMap(requestsByConversation,
                conversationId, nextRequests);
            updateConversation(conversationId, {
                requestCount: nextRequests.length,
                status: nextRequests.length > 0 ? "attention" : "working",
                statusText: nextRequests.length > 0
                    ? "Hermes needs you" : "Working…",
                updatedAt: new Date().toISOString()
            });
        }
    }

    function persist() {
        persistTimer.stop();
        if (!stateLoaded)
            return;
        // qmllint disable unqualified
        persisted.drafts = root.drafts;
        // qmllint enable unqualified
        stateFile.writeAdapter();
    }

    onPanelVisibleChanged: {
        if (panelVisible && selectedConversationId !== "")
            markRead(selectedConversationId);
        if (!panelVisible)
            flushDrafts();
    }

    Component.onDestruction: flushDrafts()

    Timer {
        id: persistTimer
        interval: 750
        onTriggered: root.persist()
    }

    FileView {
        id: stateFile
        path: (Quickshell.env("XDG_STATE_HOME")
            || Quickshell.env("HOME") + "/.local/state")
            + "/hermes-menubar/client.json"
        printErrors: false
        blockLoading: true
        onLoaded: {
            // qmllint disable unqualified
            root.drafts = persisted.drafts && typeof persisted.drafts === "object"
                ? persisted.drafts : ({});
            // qmllint enable unqualified
            root.stateLoaded = true;
            root.selectedConversationId = "";
        }
        onLoadFailed: error => {
            if (error !== FileViewError.FileNotFound)
                console.warn("hermes: could not read client state");
            root.stateLoaded = true;
            root.selectedConversationId = "";
        }

        JsonAdapter {
            id: persisted
            property var drafts: ({})
        }
    }
}
