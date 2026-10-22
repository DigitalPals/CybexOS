// Pure normalization and projection helpers for the Hermes menubar client.
// Keep this file free of Qt APIs: bridge payloads are deliberately normalized
// here so both QML and Node tests exercise the same compatibility boundary.

var WORKING_STATES = ["working", "running", "thinking", "generating", "busy"];
var ATTENTION_STATES = ["approval", "clarify", "input", "sudo", "secret", "waiting"];
var TERMINAL_TOOL_STATES = ["completed", "complete", "done", "failed", "error",
    "cancelled", "canceled", "interrupted"];

function object(value) {
    return value && typeof value === "object" && !Array.isArray(value) ? value : {};
}

function array(value) {
    return Array.isArray(value) ? value : [];
}

function string(value, fallback) {
    if (typeof value === "string")
        return value;
    if (typeof value === "number" || typeof value === "boolean")
        return String(value);
    return fallback || "";
}

function firstString() {
    for (var i = 0; i < arguments.length; i++) {
        var value = string(arguments[i], "").trim();
        if (value !== "")
            return value;
    }
    return "";
}

function number(value, fallback) {
    return typeof value === "number" && isFinite(value) ? value : fallback;
}

function bool(value, fallback) {
    return typeof value === "boolean" ? value : fallback;
}

function compactState(value) {
    return string(value, "idle").trim().toLowerCase().replace(/[._ -]+/g, "-");
}

function canonicalStatus(value) {
    var state = compactState(value);
    if (WORKING_STATES.indexOf(state) >= 0 || state.indexOf("tool-") === 0)
        return "working";
    if (ATTENTION_STATES.indexOf(state) >= 0 || state.indexOf("needs-") === 0)
        return "attention";
    if (["failed", "failure", "error", "crashed"].indexOf(state) >= 0)
        return "error";
    if (["complete", "completed", "done", "finished", "success"].indexOf(state) >= 0)
        return "done";
    if (["offline", "disconnected", "unavailable"].indexOf(state) >= 0)
        return "offline";
    if (["queued", "pending"].indexOf(state) >= 0)
        return "queued";
    return "idle";
}

function normalizeConversation(raw, index) {
    var value = object(raw);
    var session = object(value.session);
    var id = firstString(value.sessionId, value.session_id, value.id,
        session.sessionId, session.session_id, session.id,
        "conversation-" + number(index, 0));
    var statusValue = firstString(value.status, value.state, value.activityState,
        session.status, session.state, "idle");
    if (value.attention || session.attention)
        statusValue = "attention";
    else if (value.isStreaming === true || value.is_streaming === true
            || firstString(value.activeStreamId, value.active_stream_id,
                session.activeStreamId, session.active_stream_id) !== "")
        statusValue = "working";
    var status = canonicalStatus(statusValue);
    var unread = Math.max(0, Math.floor(number(value.unread,
        number(value.unreadCount, value.hasUnread === true ? 1 : 0))));
    var updatedAt = firstString(value.updatedAt, value.lastActivityAt,
        value.updated_at, value.last_message_at, session.updatedAt,
        session.updated_at, value.createdAt, value.created_at);
    return {
        id: id,
        sessionId: id,
        title: firstString(value.title, value.name, session.title,
            "Untitled chat"),
        profile: firstString(value.profile, value.profileName, session.profile),
        model: firstString(value.model, value.modelName, session.model),
        modelProvider: firstString(value.modelProvider, value.model_provider,
            value.provider, session.modelProvider, session.model_provider,
            session.provider),
        workspace: firstString(value.workspace, value.cwd, session.workspace),
        source: firstString(value.sourceLabel, value.source_label,
            value.sessionSource, value.session_source, value.sourceTag,
            value.source_tag),
        readOnly: bool(value.readOnly, bool(value.read_only,
            bool(session.readOnly, bool(session.read_only, false)))),
        messageCount: Math.max(0, Math.floor(number(value.messageCount,
            number(value.message_count, number(session.messageCount,
                number(session.message_count, 0)))))),
        status: status,
        rawStatus: statusValue,
        statusText: firstString(value.statusText, value.activity, value.detail,
            session.statusText, status === "working" ? "Hermes is working…"
                : status === "attention" ? "Hermes needs you" : "Ready"),
        unread: unread,
        requestCount: Math.max(0, Math.floor(number(value.requestCount,
            number(value.pendingRequests, status === "attention" ? 1 : 0)))),
        updatedAt: updatedAt,
        // Numeric sort key, parsed once here instead of inside the comparator.
        updatedAtMs: parseTime(updatedAt),
        createdAt: firstString(value.createdAt, value.created_at,
            session.createdAt, session.created_at),
        error: firstString(value.error, value.lastError, session.error)
    };
}

// Shallow equality over a normalized conversation's scalar fields. Status
// broadcasts often repeat the current state; callers skip the reassign (and
// the list re-sort every binding would observe) when nothing changed.
function sameConversation(a, b) {
    if (!a || !b)
        return false;
    var keys = Object.keys(a);
    if (keys.length !== Object.keys(b).length)
        return false;
    for (var i = 0; i < keys.length; i++) {
        if (a[keys[i]] !== b[keys[i]])
            return false;
    }
    return true;
}

function conversationPriority(conversation) {
    switch (conversation && conversation.status) {
    case "attention": return 0;
    case "error": return 1;
    case "working": return 2;
    case "queued": return 3;
    case "done": return 4;
    default: return 5;
    }
}

function parseTime(value) {
    if (typeof value === "number" && isFinite(value))
        return value < 100000000000 ? value * 1000 : value;
    var parsed = typeof value === "string"
        ? (/^\d+(?:\.\d+)?$/.test(value.trim())
            ? Number(value) * (Number(value) < 100000000000 ? 1000 : 1)
            : Date.parse(value)) : NaN;
    return isNaN(parsed) ? 0 : parsed;
}

function sortTime(conversation) {
    return typeof conversation.updatedAtMs === "number"
        ? conversation.updatedAtMs : parseTime(conversation.updatedAt);
}

function sortedConversations(values) {
    return array(values).slice().sort(function(a, b) {
        var priority = conversationPriority(a) - conversationPriority(b);
        if (priority !== 0)
            return priority;
        var time = sortTime(b) - sortTime(a);
        if (time !== 0)
            return time;
        return string(a.title).localeCompare(string(b.title));
    });
}

function extractText(content, depth) {
    var level = number(depth, 0);
    if (level > 5)
        return "";
    if (typeof content === "string")
        return content;
    if (typeof content === "number" || typeof content === "boolean")
        return String(content);
    if (Array.isArray(content)) {
        return content.map(function(part) {
            return extractText(part, level + 1);
        }).filter(function(part) { return part.trim() !== ""; }).join("\n");
    }
    if (!content || typeof content !== "object")
        return "";

    var type = compactState(content.type);
    if (["tool-use", "tool-result", "function-call", "function-result"]
            .indexOf(type) >= 0)
        return "";
    if (["image", "image-url", "input-image"].indexOf(type) >= 0)
        return "[Image attachment]";
    if (["file", "input-file", "attachment"].indexOf(type) >= 0) {
        var name = firstString(content.filename, content.file_name, content.name);
        return name !== "" ? "[File attachment: " + name + "]"
            : "[File attachment]";
    }
    var keys = ["text", "content", "value", "input_text", "output_text"];
    for (var i = 0; i < keys.length; i++) {
        if (content[keys[i]] === undefined)
            continue;
        var text = extractText(content[keys[i]], level + 1);
        if (text.trim() !== "")
            return text;
    }
    return "";
}

function normalizeRole(value) {
    var role = compactState(value);
    if (["human", "me", "you"].indexOf(role) >= 0)
        return "user";
    if (["agent", "hermes", "model"].indexOf(role) >= 0)
        return "assistant";
    if (["tool", "system"].indexOf(role) >= 0)
        return role;
    if (role === "user" || role === "assistant")
        return role;
    return "metadata";
}

function normalizeAttachments(value) {
    return array(value).slice(0, 20).map(function(raw) {
        var item = object(raw);
        var source = firstString(item.name, item.filename, item.path,
            typeof raw === "string" ? raw : "attachment");
        var pieces = source.replace(/\\/g, "/").split("/");
        var name = pieces[pieces.length - 1] || "attachment";
        var mime = firstString(item.mime, item.mimeType, item.mime_type);
        return {
            name: name.slice(0, 200),
            mime: mime.slice(0, 160),
            size: Math.max(0, Math.floor(number(item.size, 0))),
            isImage: bool(item.isImage, bool(item.is_image,
                mime.indexOf("image/") === 0))
        };
    });
}

function normalizeMessage(raw, index) {
    var value = object(raw);
    var nested = object(value.message);
    if (Object.keys(nested).length > 0)
        value = Object.assign({}, nested, value);
    var text = extractText(value.text !== undefined ? value.text
        : value.content !== undefined ? value.content
            : value.delta !== undefined ? value.delta : value.message);
    var id = firstString(value.id, value.messageId, value.message_id,
        value.turnId, value.turn_id, value.itemId, value.item_id,
        "message-" + number(index, 0));
    return {
        id: id,
        role: normalizeRole(value.role || value.author || value.sender),
        text: text,
        createdAt: firstString(value.createdAt, value.created_at,
            value.timestamp, value.time),
        updatedAt: firstString(value.updatedAt, value.updated_at,
            value.timestamp, value.time),
        streaming: bool(value.streaming, bool(value.partial, false)),
        pending: bool(value.pending, false),
        error: firstString(value.error),
        model: firstString(value.model, value.modelName),
        attachments: normalizeAttachments(value.attachments),
        parentId: firstString(value.parentId, value.parent_id,
            value.parentMessageId, value.parent_message_id),
        order: number(value.order, number(value.timelineOrder,
            number(value.sourceIndex, number(index, 0) * 1000))),
        sourceIndex: number(value.sourceIndex, number(value.source_index,
            number(index, 0)))
    };
}

// Normalized fields of an incremental message event, restricted to those the
// payload actually carries. Merging a full normalizeMessage() result would
// overwrite an existing row's createdAt, model, attachments, parentId and
// sourceIndex with empty defaults on every streamed delta.
function messagePatch(raw, message) {
    var value = object(raw);
    var nested = object(value.message);
    if (Object.keys(nested).length > 0)
        value = Object.assign({}, nested, value);
    function has() {
        for (var i = 0; i < arguments.length; i++) {
            var candidate = value[arguments[i]];
            if (candidate !== undefined && candidate !== null)
                return true;
        }
        return false;
    }
    var patch = { id: message.id };
    if (has("role", "author", "sender"))
        patch.role = message.role;
    if (has("text", "content", "delta", "message"))
        patch.text = message.text;
    if (has("createdAt", "created_at", "timestamp", "time"))
        patch.createdAt = message.createdAt;
    if (has("updatedAt", "updated_at", "timestamp", "time"))
        patch.updatedAt = message.updatedAt;
    if (has("streaming", "partial"))
        patch.streaming = message.streaming;
    if (has("pending"))
        patch.pending = message.pending;
    if (has("error"))
        patch.error = message.error;
    if (has("model", "modelName"))
        patch.model = message.model;
    if (Array.isArray(value.attachments))
        patch.attachments = message.attachments;
    if (has("parentId", "parent_id", "parentMessageId", "parent_message_id"))
        patch.parentId = message.parentId;
    if (typeof value.order === "number" || typeof value.timelineOrder === "number"
            || typeof value.sourceIndex === "number")
        patch.order = message.order;
    if (typeof value.sourceIndex === "number"
            || typeof value.source_index === "number")
        patch.sourceIndex = message.sourceIndex;
    return patch;
}

// True once `text` has more than `limit` lines. Scans with indexOf and stops
// early instead of allocating a split() array for every streamed update.
function exceedsLineCount(text, limit) {
    var value = string(text);
    var max = number(limit, 0);
    var lines = 1;
    var at = value.indexOf("\n");
    while (at >= 0) {
        if (++lines > max)
            return true;
        at = value.indexOf("\n", at + 1);
    }
    return lines > max;
}

// Minimal keyed edit script turning the `current` keys into the `desired`
// keys, for updating a ListModel in place. Rows whose key survives are kept
// (so their delegates, focus and per-row state survive); only new rows are
// inserted and only vanished or displaced rows removed. Ops apply in order:
// {op: "remove", at, count}, {op: "insert", at, index}, {op: "keep", at, index},
// where `index` addresses `desired`.
function listSyncOps(current, desired) {
    var model = array(current).slice();
    var wanted = array(desired);
    var ops = [];
    var row = 0;
    for (var i = 0; i < wanted.length; i++) {
        var key = wanted[i];
        if (row < model.length && model[row] === key) {
            ops.push({ op: "keep", at: row, index: i });
            row++;
            continue;
        }
        var later = model.indexOf(key, row + 1);
        if (later > row) {
            ops.push({ op: "remove", at: row, count: later - row });
            model.splice(row, later - row);
            ops.push({ op: "keep", at: row, index: i });
        } else {
            ops.push({ op: "insert", at: row, index: i });
            model.splice(row, 0, key);
        }
        row++;
    }
    if (model.length > row)
        ops.push({ op: "remove", at: row, count: model.length - row });
    return ops;
}

function renderableMessage(message) {
    if (!message || ["user", "assistant", "system"].indexOf(message.role) < 0)
        return false;
    return string(message.text).trim() !== "" || message.streaming === true
        || message.pending === true || string(message.error).trim() !== ""
        || array(message.attachments).length > 0;
}

function messageList(value) {
    if (Array.isArray(value))
        return value;
    var data = object(value);
    if (Array.isArray(data.messages))
        return data.messages;
    if (Array.isArray(data.items))
        return data.items;
    if (Array.isArray(data.history))
        return data.history;
    return [];
}

function normalizeMessages(value) {
    return messageList(value).map(function(message, index) {
        return normalizeMessage(message, index);
    }).filter(renderableMessage);
}

function upsertById(values, item) {
    var next = array(values).slice();
    var at = next.findIndex(function(current) { return current.id === item.id; });
    if (at < 0)
        next.push(item);
    else
        next[at] = Object.assign({}, next[at], item);
    return next;
}

function applyMessageEvent(values, type, payload) {
    var event = compactState(type);
    if (["message-snapshot", "message-list", "session-history", "history"].indexOf(event) >= 0)
        return normalizeMessages(payload);
    var current = array(values);
    var message = normalizeMessage(payload, current.length);
    var delta = event === "message-delta" || event === "assistant-delta"
        || event === "stream-delta";
    var streaming = delta || event === "message-start" || event === "assistant-start"
        ? true : event === "message-complete" || event === "message-completed"
            || event === "assistant-complete" ? false : null;
    var at = current.findIndex(function(item) { return item.id === message.id; });
    if (at < 0) {
        if (streaming !== null)
            message.streaming = streaming;
        return current.concat([message]);
    }
    // An existing row takes only the fields this event actually carries.
    var next = current.slice();
    var previous = next[at];
    var patch = messagePatch(payload, message);
    if (delta)
        patch.text = string(previous.text) + string(message.text);
    if (streaming !== null)
        patch.streaming = streaming;
    next[at] = Object.assign({}, previous, patch);
    return next;
}

function normalizeTool(raw, index) {
    var value = object(raw);
    var call = object(value.tool);
    if (Object.keys(call).length > 0)
        value = Object.assign({}, call, value);
    var status = compactState(value.status || value.state || "running");
    var fn = object(value.function);
    var input = toolDetail(value.input !== undefined ? value.input
        : value.args !== undefined ? value.args
            : value.arguments !== undefined ? value.arguments : fn.arguments);
    var output = toolDetail(value.output !== undefined ? value.output
        : value.result !== undefined ? value.result
            : value.snippet !== undefined ? value.snippet
                : value.preview !== undefined ? value.preview : "");
    var error = firstString(value.error, value.errorMessage, value.error_message);
    var explicitTerminal = typeof value.terminal === "boolean" ? value.terminal : null;
    return {
        id: firstString(value.id, value.toolCallId, value.tool_call_id,
            value.callId, value.call_id,
            "tool-" + number(index, 0)),
        name: firstString(value.name, value.toolName, value.tool_name,
            fn.name, typeof value.function === "string" ? value.function : "", "Tool"),
        label: firstString(value.label, value.title, value.description),
        status: status,
        detail: firstString(value.detail, value.summary, value.command, value.path,
            output),
        input: input,
        output: output,
        startedAt: firstString(value.startedAt, value.started_at,
            value.createdAt, value.created_at, value.timestamp),
        completedAt: firstString(value.completedAt, value.completed_at,
            value.updatedAt, value.updated_at),
        error: error,
        order: number(value.order, number(value.timelineOrder,
            number(value.sourceIndex, number(index, 0) * 1000 + 100))),
        sourceIndex: number(value.sourceIndex, number(value.source_index, -1)),
        historical: value.historical === true,
        terminal: explicitTerminal !== null ? explicitTerminal
            : TERMINAL_TOOL_STATES.indexOf(status) >= 0
    };
}

function toolDetail(value) {
    var parsed = value;
    if (typeof value === "string") {
        var candidate = value.trim();
        if (candidate !== "" && (candidate[0] === "{" || candidate[0] === "[")) {
            try { parsed = JSON.parse(candidate); } catch (_error) {}
        }
    }
    var text = "";
    if (parsed && typeof parsed === "object") {
        if (!Array.isArray(parsed)) {
            var preferred = firstString(parsed.summary, parsed.message,
                parsed.result, parsed.output, parsed.error);
            if (preferred !== "")
                text = preferred;
        }
        if (text === "") {
            try { text = JSON.stringify(parsed, null, 2); }
            catch (_error) { text = String(parsed); }
        }
    } else if (parsed !== undefined && parsed !== null) {
        text = String(parsed);
    }
    return text.length > 4096 ? text.slice(0, 4095) + "…" : text;
}

function historicalTools(value) {
    var rawMessages = messageList(value);
    var data = object(value);
    var results = {};
    rawMessages.forEach(function(raw, index) {
        var message = object(raw);
        var role = normalizeRole(message.role || message.author || message.sender);
        if (role === "tool") {
            var resultId = firstString(message.tool_call_id, message.toolCallId,
                message.tool_use_id, message.call_id, message.id);
            if (resultId !== "")
                results[resultId] = {
                    output: toolDetail(message.content !== undefined
                        ? message.content : message.result),
                    failed: message.is_error === true || firstString(message.error) !== "",
                    order: number(message.order, index * 1000 + 900)
                };
        }
        array(message.content).forEach(function(part) {
            var block = object(part);
            if (compactState(block.type) !== "tool-result")
                return;
            var resultId = firstString(block.tool_use_id, block.tool_call_id);
            if (resultId !== "")
                results[resultId] = {
                    output: toolDetail(block.content !== undefined
                        ? block.content : block.result),
                    failed: block.is_error === true || firstString(block.error) !== "",
                    order: index * 1000 + 900
                };
        });
    });

    var tools = [];
    var seen = {};
    function addCall(raw, messageIndex, callIndex) {
        var call = object(raw);
        var fn = object(call.function);
        var id = firstString(call.tool_call_id, call.toolCallId, call.tool_use_id,
            call.tid, call.call_id, call.id,
            "history-tool-" + messageIndex + "-" + callIndex);
        if (seen[id])
            return;
        seen[id] = true;
        var result = object(results[id]);
        tools.push(normalizeTool({
            id: id,
            name: firstString(call.name, call.tool_name, fn.name, "Tool"),
            args: call.args !== undefined ? call.args
                : call.input !== undefined ? call.input
                    : call.arguments !== undefined ? call.arguments : fn.arguments,
            output: firstString(call.snippet, call.preview, call.result,
                call.output, result.output),
            status: result.failed || call.is_error === true || firstString(call.error) !== ""
                ? "error" : call.done === false ? "interrupted" : "completed",
            error: firstString(call.error),
            order: number(call.order, messageIndex * 1000 + 100 + callIndex),
            sourceIndex: messageIndex,
            historical: true,
            terminal: true
        }, tools.length));
    }

    rawMessages.forEach(function(raw, messageIndex) {
        var message = object(raw);
        var calls = array(message.tool_calls).concat(array(message._partial_tool_calls));
        array(message.content).forEach(function(part) {
            if (compactState(object(part).type) === "tool-use")
                calls.push(part);
        });
        calls.forEach(function(call, callIndex) {
            addCall(call, messageIndex, callIndex);
        });
    });
    array(data.tool_calls).forEach(function(call, index) {
        var sourceIndex = number(object(call).assistant_msg_idx, rawMessages.length + index);
        addCall(call, sourceIndex, index);
    });
    return tools;
}

function normalizeHistory(value) {
    var data = object(value);
    var explicit = array(data.tools).concat(array(data.toolActivity));
    var projected = explicit.length > 0
        ? explicit.map(function(tool, index) { return normalizeTool(tool, index); })
        : historicalTools(value);
    return {
        messages: normalizeMessages(value),
        tools: projected,
        history: object(data.history),
        sessionState: object(data.sessionState || data.session_state)
    };
}

function transcriptItems(messages, tools) {
    var result = [];
    array(messages).forEach(function(message, index) {
        result.push({
            id: "message:" + firstString(message.id, String(index)),
            kind: "message",
            message: message,
            tool: {},
            order: number(message.order, index * 1000)
        });
    });
    array(tools).forEach(function(tool, index) {
        result.push({
            id: "tool:" + firstString(tool.id, String(index)),
            kind: "tool",
            message: {},
            tool: tool,
            order: number(tool.order, (messages.length + index) * 1000 + 100)
        });
    });
    return result.sort(function(a, b) {
        if (a.order !== b.order)
            return a.order - b.order;
        if (a.kind !== b.kind)
            return a.kind === "message" ? -1 : 1;
        return a.id.localeCompare(b.id);
    });
}

function emptySessionState() {
    return {
        reasoning: "",
        reasoningActive: false,
        warning: "",
        goalState: "",
        goalMessage: "",
        todos: [],
        todoSummary: {},
        context: {},
        usage: {},
        pendingSteer: "",
        background: "",
        updatedAt: ""
    };
}

function scalarProjection(raw, keys) {
    var value = object(raw);
    var result = {};
    keys.forEach(function(key) {
        var candidate = value[key];
        if (typeof candidate === "string" || typeof candidate === "number"
                || typeof candidate === "boolean")
            result[key] = candidate;
    });
    return result;
}

function normalizeTodos(value) {
    return array(value).slice(0, 100).map(function(raw, index) {
        var todo = object(raw);
        return {
            id: firstString(todo.id, todo.todo_id, "todo-" + index),
            content: firstString(todo.content, todo.text, todo.title,
                "Untitled task").slice(0, 1000),
            status: compactState(todo.status || todo.state || "pending")
        };
    });
}

function mergeSessionState(current, raw) {
    var next = Object.assign(emptySessionState(), object(current));
    var value = object(raw);
    if (Array.isArray(value.todos))
        next.todos = normalizeTodos(value.todos);
    if (value.todoSummary && typeof value.todoSummary === "object")
        next.todoSummary = scalarProjection(value.todoSummary,
            ["total", "pending", "in_progress", "completed", "cancelled"]);
    if (value.todo_summary && typeof value.todo_summary === "object")
        next.todoSummary = scalarProjection(value.todo_summary,
            ["total", "pending", "in_progress", "completed", "cancelled"]);
    if (value.context && typeof value.context === "object")
        next.context = Object.assign({}, next.context, scalarProjection(value.context,
            ["contextLength", "thresholdTokens", "lastPromptTokens",
             "postCompressionTokens", "context_length", "threshold_tokens",
             "last_prompt_tokens", "post_compression_context_tokens_estimate"]));
    if (value.usage && typeof value.usage === "object")
        next.usage = Object.assign({}, next.usage, scalarProjection(value.usage,
            ["input_tokens", "output_tokens", "total_tokens", "cached_tokens",
             "cache_read_tokens", "tokens_per_second", "tps", "tool_calls",
             "elapsed_seconds", "last_prompt_tokens", "context_length",
             "threshold_tokens"]));
    var pending = firstString(value.pendingSteer, value.pending_steer);
    if (pending !== "")
        next.pendingSteer = pending.slice(0, 2000);
    next.updatedAt = firstString(value.updatedAt, value.updated_at, next.updatedAt);
    return next;
}

function applySessionState(current, type, payload) {
    var next = mergeSessionState(current, {});
    var value = object(payload);
    var event = compactState(type);
    var kind = compactState(value.kind || event);

    if (event === "turn-start" || event === "message-start"
            || event === "assistant-start") {
        next.reasoning = "";
        next.reasoningActive = true;
        next.warning = "";
        next.pendingSteer = "";
    }
    if (event === "turn-complete" || event === "message-complete"
            || event === "message-completed" || event === "assistant-complete")
        next.reasoningActive = false;

    if (kind === "reasoning" || event === "session-reasoning") {
        var reasoning = typeof value.reasoning === "string" ? value.reasoning
            : typeof value.text === "string" ? value.text
                : typeof value.delta === "string" ? value.delta : "";
        if (reasoning !== "") {
            var combined = value.replace === true ? reasoning
                : string(next.reasoning) + reasoning;
            next.reasoning = combined.length > 12000
                ? combined.slice(combined.length - 12000) : combined;
        }
        next.reasoningActive = value.active !== false;
    } else if (kind === "warning" || event === "session-warning") {
        next.warning = firstString(value.message, value.warning, value.detail,
            "Hermes reported a warning").slice(0, 1000);
    } else if (kind === "goal" || kind === "goal-continue"
            || event === "session-goal") {
        next.goalState = compactState(value.state || value.status
            || (kind === "goal-continue" ? "continuing" : "active"));
        next.goalMessage = firstString(value.message, value.text,
            value.continuation_prompt, object(value.decision).message).slice(0, 2000);
    } else if (kind === "todo-state" || kind === "todos"
            || event === "session-todos") {
        next.todos = normalizeTodos(value.todos);
        next.todoSummary = scalarProjection(value.summary,
            ["total", "pending", "in_progress", "completed", "cancelled"]);
    } else if (kind === "context-status" || kind === "context"
            || event === "session-context") {
        var context = Object.assign({}, object(value.context), value);
        next.context = Object.assign({}, next.context, scalarProjection(context,
            ["contextLength", "thresholdTokens", "lastPromptTokens",
             "postCompressionTokens", "context_length", "threshold_tokens",
             "last_prompt_tokens", "post_compression_context_tokens_estimate"]));
        if (value.prefill && typeof value.prefill === "object")
            next.context.prefill = scalarProjection(value.prefill,
                ["enabled", "message_count", "token_estimate", "source"]);
    } else if (kind === "usage" || kind === "metering"
            || event === "session-usage") {
        var usage = Object.assign({}, object(value.usage), value);
        next.usage = Object.assign({}, next.usage, scalarProjection(usage,
            ["input_tokens", "output_tokens", "total_tokens", "cached_tokens",
             "cache_read_tokens", "tokens_per_second", "tps", "tool_calls",
             "elapsed_seconds", "last_prompt_tokens", "context_length",
             "threshold_tokens"]));
    } else if (kind === "pending-steer-leftover"
            || event === "session-pending-steer") {
        next.pendingSteer = firstString(value.text, value.message).slice(0, 2000);
    } else if (kind === "bg-task-complete" || kind === "process-complete"
            || event === "session-background") {
        next.background = firstString(value.message, value.title,
            value.process_name, "Background task completed").slice(0, 1000);
    }
    next.updatedAt = firstString(value.updatedAt, value.updated_at,
        value.timestamp, value.ts, new Date().toISOString());
    return next;
}

function applyToolEvent(values, type, payload) {
    var next = array(values);
    var tool = normalizeTool(payload, next.length);
    var event = compactState(type);
    if (event.indexOf("completed") >= 0 || event.indexOf("complete") >= 0) {
        tool.status = "completed";
        tool.terminal = true;
    } else if (event.indexOf("failed") >= 0 || event.indexOf("error") >= 0) {
        tool.status = "error";
        tool.terminal = true;
    } else if (event.indexOf("cancel") >= 0 || event.indexOf("interrupt") >= 0) {
        tool.status = "interrupted";
        tool.terminal = true;
    }
    return upsertById(next, tool);
}

function normalizeOptions(value) {
    return array(value).map(function(option, index) {
        if (typeof option === "string")
            return { id: option, label: option, description: "", value: option };
        var raw = object(option);
        var label = firstString(raw.label, raw.title, raw.value, raw.id,
            "Option " + (index + 1));
        return {
            id: firstString(raw.id, raw.value, label),
            label: label,
            description: firstString(raw.description, raw.detail),
            value: raw.value !== undefined ? raw.value : firstString(raw.id, label)
        };
    });
}

function normalizeRequestKind(value) {
    var kind = compactState(value);
    if (kind.indexOf("clarif") >= 0 || kind === "input" || kind === "question")
        return "clarify";
    if (kind.indexOf("sudo") >= 0 || kind.indexOf("elevat") >= 0)
        return "sudo";
    if (kind.indexOf("secret") >= 0 || kind.indexOf("credential") >= 0)
        return "secret";
    return "approval";
}

function normalizeQuestion(raw, index) {
    var value = object(raw);
    var id = firstString(value.id, value.qid, value.questionId,
        value.question_id, "question-" + number(index, 0));
    return {
        id: id,
        prompt: firstString(value.prompt, value.question, value.text),
        header: firstString(value.header, value.title),
        options: normalizeOptions(value.options || value.choices),
        multiSelect: bool(value.multiSelect, bool(value.multi_select, false))
    };
}

function normalizeRequest(raw, index) {
    var value = object(raw);
    var nested = object(value.request);
    if (Object.keys(nested).length > 0)
        value = Object.assign({}, nested, value);
    var kind = normalizeRequestKind(value.kind || value.type || value.requestType);
    var questions = array(value.questions).map(function(question, questionIndex) {
        return normalizeQuestion(question, questionIndex);
    });
    var firstQuestion = questions.length > 0 ? object(questions[0]) : {};
    return {
        id: firstString(value.id, value.requestId, value.request_id,
            value.callId, value.call_id,
            "request-" + number(index, 0)),
        kind: kind,
        title: firstString(value.title, value.header, firstQuestion.header,
            kind === "clarify" ? "Hermes has a question"
                : kind === "sudo" ? "Administrator access"
                    : kind === "secret" ? "Credential needed" : "Approval needed"),
        prompt: firstString(value.prompt, value.question, value.message,
            firstQuestion.prompt, value.detail),
        detail: firstString(value.detail, value.description, value.command),
        secretName: firstString(value.secretName, value.secret_name, value.env_var,
            value.name, value.key),
        options: normalizeOptions(value.options || value.choices
            || firstQuestion.options),
        multiSelect: bool(value.multiSelect, bool(value.multi_select, false)),
        questions: questions,
        createdAt: firstString(value.createdAt, value.created_at, value.timestamp),
        resolved: bool(value.resolved, false),
        error: firstString(value.error)
    };
}

function applyRequestEvent(values, type, payload) {
    var current = array(values);
    var event = compactState(type);
    var request = normalizeRequest(payload, current.length);
    if (event.indexOf("resolved") >= 0 || event.indexOf("completed") >= 0
            || event.indexOf("cancel") >= 0 || event.indexOf("expired") >= 0
            || event.indexOf("expire") >= 0)
        return current.filter(function(item) { return item.id !== request.id; });
    return upsertById(current, request);
}

function eventType(value) {
    return string(value).trim().toLowerCase().replace(/[._ ]+/g, "-");
}

function sessionId(payload) {
    var value = object(payload);
    var session = object(value.session);
    return firstString(value.sessionId, value.session_id, session.id);
}

function statusVerb(value) {
    var raw = firstString(value).trim();
    if (raw === "")
        return "working";
    raw = raw.replace(/^Hermes\s+(?:is\s+)?/i, "").replace(/\.{3}|…/g, "").trim();
    var first = raw.split(/[ ·:—-]/)[0].toLowerCase();
    if (/^[a-z][a-z0-9_-]{1,24}$/.test(first))
        return first.replace(/_/g, " ");
    return "working";
}

function activityLabel(conversation, detailMode) {
    if (!conversation)
        return "idle";
    if (conversation.status === "attention")
        return "needs you";
    if (conversation.status === "error")
        return "error";
    if (conversation.status === "queued")
        return "queued";
    if (conversation.status === "done")
        return "done";
    if (conversation.status !== "working")
        return "idle";
    if (detailMode === "full" && conversation.statusText)
        return conversation.statusText;
    if (detailMode === "none" || detailMode === "generic")
        return "working…";
    return statusVerb(conversation.statusText) + "…";
}

function counts(conversations) {
    var result = { working: 0, attention: 0, errors: 0, done: 0, unread: 0 };
    array(conversations).forEach(function(conversation) {
        if (conversation.status === "working") result.working++;
        if (conversation.status === "attention") result.attention++;
        if (conversation.status === "error") result.errors++;
        if (conversation.status === "done") result.done++;
        result.unread += Math.max(0, number(conversation.unread, 0));
    });
    return result;
}

function relativeTime(value, now) {
    var then = parseTime(value);
    var current = typeof now === "number" && isFinite(now) ? now : Date.now();
    if (then <= 0)
        return "";
    var seconds = Math.max(0, Math.floor((current - then) / 1000));
    if (seconds < 10) return "now";
    if (seconds < 60) return seconds + "s";
    var minutes = Math.floor(seconds / 60);
    if (minutes < 60) return minutes + "m";
    var hours = Math.floor(minutes / 60);
    if (hours < 24) return hours + "h";
    var days = Math.floor(hours / 24);
    return days < 14 ? days + "d" : new Date(then).toLocaleDateString();
}

// Accept only an HTTP(S) WebUI base. User-info is rejected because the
// password has a dedicated, masked field and must never become part of a URL
// shown in the panel, a log, or bridge state.
function remoteWebUrl(value) {
    if (typeof value !== "string")
        return "";
    var trimmed = value.trim();
    if (!/^https?:\/\//i.test(trimmed)
            || /[\s\\\u0000-\u001f\u007f]/.test(trimmed))
        return "";
    var authority = trimmed.match(/^https?:\/\/([^/?#]+)/i);
    if (!authority || authority[1].indexOf("@") >= 0)
        return "";
    return trimmed.replace(/[/?#]+$/, "");
}

// The connected identity shown to the user is deliberately only the origin.
// Paths, queries, fragments and any attempted user-info are never reflected.
function remoteOrigin(value) {
    var safe = remoteWebUrl(value);
    if (safe === "")
        return "";
    var match = safe.match(/^(https?):\/\/([^/?#]+)/i);
    return match ? match[1].toLowerCase() + "://" + match[2] : "";
}

// An explicit bridge flag wins over a URL in the payload. Failed candidate
// logins include the attempted URL with configured=false; treating that URL as
// selected would make the local/remote backend choice ambiguous.
function remoteIsConfigured(raw) {
    var value = object(raw);
    if (typeof value.configured === "boolean")
        return value.configured;
    return remoteOrigin(firstString(value.origin, value.url,
        value.webuiUrl, value.webui_url)) !== "";
}

function remoteState(value) {
    var state = compactState(value);
    if (["ready", "authenticated", "online"].indexOf(state) >= 0)
        return "connected";
    if (["session-expired", "sessionexpired", "unauthorized", "sign-in-required"]
            .indexOf(state) >= 0)
        return "expired";
    if (["loading", "signing-in", "logging-in"].indexOf(state) >= 0)
        return "connecting";
    if (["failed", "failure"].indexOf(state) >= 0)
        return "error";
    if (["connected", "connecting", "disconnected", "expired", "error"]
            .indexOf(state) >= 0)
        return state;
    return "disconnected";
}

// Remote errors cross a trust boundary. Reduce them to useful known classes
// instead of reflecting arbitrary server text (which can contain URL
// credentials or the submitted password). HTTP 302 has a specific meaning in
// Hermes WebUI: the browser session is no longer signed in.
function remoteErrorMessage(value) {
    var text = string(value, "");
    if (/cross-origin redirect/i.test(text))
        return "Remote Hermes WebUI redirect was blocked";
    if (/(?:http\s*)?302|status(?:_code)?[=: ]+302|redirect(?:ed)?\s+to\s+(?:the\s+)?(?:login|sign-in)/i.test(text))
        return "Session sign-in required";
    if (/(?:http\s*)?(?:401|403)|unauthori[sz]ed|forbidden|invalid password|credential/i.test(text))
        return "Remote sign-in was rejected";
    if (/timeout|timed out/i.test(text))
        return "Remote Hermes WebUI timed out";
    if (/certificate|\btls\b|\bssl\b/i.test(text))
        return "Remote Hermes WebUI TLS failed";
    if (/refused|unreachable|host not found|name or service|network/i.test(text))
        return "Could not reach the remote Hermes WebUI";
    return text.trim() === "" ? "" : "Remote Hermes sign-in failed";
}

// This is the single backend-selection truth table for Hermes readiness. Once
// a remote URL is configured, a local provider must never be used as evidence
// that the selected remote backend is ready.
function agentBackendReady(raw) {
    var value = object(raw);
    if (value.remoteChecked !== true)
        return false;
    if (value.remoteConfigured === true)
        return remoteState(value.remoteState) === "connected"
            && value.remoteAuthenticated === true;
    return value.localProviderReady === true;
}

var exported = {
    object: object,
    array: array,
    string: string,
    firstString: firstString,
    canonicalStatus: canonicalStatus,
    normalizeConversation: normalizeConversation,
    sameConversation: sameConversation,
    sortedConversations: sortedConversations,
    extractText: extractText,
    normalizeRole: normalizeRole,
    normalizeMessage: normalizeMessage,
    normalizeMessages: normalizeMessages,
    messagePatch: messagePatch,
    applyMessageEvent: applyMessageEvent,
    exceedsLineCount: exceedsLineCount,
    listSyncOps: listSyncOps,
    normalizeTool: normalizeTool,
    applyToolEvent: applyToolEvent,
    historicalTools: historicalTools,
    normalizeHistory: normalizeHistory,
    transcriptItems: transcriptItems,
    emptySessionState: emptySessionState,
    mergeSessionState: mergeSessionState,
    applySessionState: applySessionState,
    normalizeRequest: normalizeRequest,
    normalizeQuestion: normalizeQuestion,
    applyRequestEvent: applyRequestEvent,
    eventType: eventType,
    sessionId: sessionId,
    activityLabel: activityLabel,
    counts: counts,
    relativeTime: relativeTime,
    remoteWebUrl: remoteWebUrl,
    remoteOrigin: remoteOrigin,
    remoteIsConfigured: remoteIsConfigured,
    remoteState: remoteState,
    remoteErrorMessage: remoteErrorMessage,
    agentBackendReady: agentBackendReady
};

if (typeof module !== "undefined" && module.exports)
    module.exports = exported;
