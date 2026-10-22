// Pure Notes state and Markdown-editing helpers shared by QML and Node tests.
// Keep this file free of Qt APIs so malformed-file handling and editor
// transformations can be verified without constructing the shell.

var VERSION = 2;
var LEGACY_VERSION = 1;
var MAX_TITLE_LENGTH = 50;
var UNTITLED_TITLE = "Untitled note";
var ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/;
var RECORD_KEYS = ["id", "title", "body", "createdAt", "updatedAt"];
var LEGACY_RECORD_KEYS = ["id", "body", "createdAt", "updatedAt"];
var MINUTE_MS = 60000;
var HOUR_MS = 60 * MINUTE_MS;
var DAY_MS = 24 * HOUR_MS;
var TITLE_EFFORTS = {
    codex: ["none", "low", "medium", "high", "xhigh", "max"],
    claude: ["low", "medium", "high", "xhigh", "max"]
};

function isObject(value) {
    return value !== null && typeof value === "object" && !Array.isArray(value);
}

function hasOnlyKeys(value, keys) {
    var actual = Object.keys(value).sort();
    var expected = keys.slice().sort();
    return actual.length === expected.length && actual.every(function(key, index) {
        return key === expected[index];
    });
}

function isBlank(body) {
    return typeof body !== "string" || body.trim() === "";
}

function normalizeTitle(value) {
    if (typeof value !== "string")
        return "";
    var compact = value.replace(/[\u0000-\u001f\u007f]/g, " ")
        .replace(/\s+/g, " ").trim();
    var title = "";
    var characters = 0;
    for (var i = 0; i < compact.length && characters < MAX_TITLE_LENGTH; i++) {
        var first = compact.charCodeAt(i);
        title += compact.charAt(i);
        if (first >= 0xd800 && first <= 0xdbff && i + 1 < compact.length) {
            var second = compact.charCodeAt(i + 1);
            if (second >= 0xdc00 && second <= 0xdfff) {
                title += compact.charAt(++i);
            }
        }
        characters++;
    }
    return title.trim();
}

function shouldAutoGenerateTitle(title, provider) {
    return normalizeTitle(title) === ""
        && (provider === "codex" || provider === "claude");
}

function titleLength(value) {
    var count = 0;
    for (var i = 0; i < value.length; i++, count++) {
        var first = value.charCodeAt(i);
        if (first >= 0xd800 && first <= 0xdbff && i + 1 < value.length) {
            var second = value.charCodeAt(i + 1);
            if (second >= 0xdc00 && second <= 0xdfff)
                i++;
        }
    }
    return count;
}

// Take the first line that contains prose after common Markdown decorations
// are removed. This is deliberately local and deterministic, and is only used
// to migrate schema-v1 notes. New drafts keep their title separate from their
// body and use the generic untitled label until the user types or generates one.
function fallbackTitle(body) {
    var lines = typeof body === "string" ? body.split(/\r?\n/) : [];
    for (var i = 0; i < lines.length; i++) {
        var line = lines[i].trim();
        if (line === "" || /^(?:```|~~~)/.test(line)
                || /^(?:-{3,}|\*{3,}|_{3,})$/.test(line))
            continue;
        line = line.replace(/^(?:>\s*)+/, "")
            .replace(/^#{1,6}\s*/, "")
            .replace(/^(?:[-*+] |[0-9]+[.)] )/, "")
            .replace(/^\[[ xX]\]\s*/, "")
            .replace(/!\[([^\]]*)\]\([^)]*\)/g, "$1")
            .replace(/\[([^\]]+)\]\([^)]*\)/g, "$1")
            .replace(/<[^>]+>/g, "")
            .replace(/\\([\\`*{}\[\]()#+.!_>~-])/g, "$1")
            .replace(/[`*_~]/g, "");
        var title = normalizeTitle(line);
        if (title !== "")
            return title;
    }
    return UNTITLED_TITLE;
}

function validTitle(title) {
    return typeof title === "string" && title !== ""
        && titleLength(title) <= MAX_TITLE_LENGTH && normalizeTitle(title) === title;
}

function validId(id) {
    return typeof id === "string" && ID_PATTERN.test(id);
}

function validTimestamp(value) {
    return typeof value === "number" && isFinite(value) && value >= 0
        && Math.floor(value) === value && value <= 9007199254740991;
}

// Compact enough for the trailing edge of an overview row. Future values are
// treated as clock skew rather than exposing a negative age; malformed inputs
// stay empty so a damaged value can never render "NaNy" in the shell.
function relativeTimeLabel(updatedAt, nowMs) {
    if (!validTimestamp(updatedAt) || !validTimestamp(nowMs))
        return "";
    var age = Math.max(0, nowMs - updatedAt);
    if (age < MINUTE_MS)
        return "now";
    if (age < HOUR_MS)
        return Math.floor(age / MINUTE_MS) + "m";
    if (age < DAY_MS)
        return Math.floor(age / HOUR_MS) + "h";
    if (age < 30 * DAY_MS)
        return Math.floor(age / DAY_MS) + "d";
    if (age < 365 * DAY_MS)
        return Math.floor(age / (30 * DAY_MS)) + "mo";
    return Math.floor(age / (365 * DAY_MS)) + "y";
}

function validRecord(record) {
    return isObject(record) && hasOnlyKeys(record, RECORD_KEYS)
        && validId(record.id) && validTitle(record.title)
        && typeof record.body === "string"
        && !isBlank(record.body) && validTimestamp(record.createdAt)
        && validTimestamp(record.updatedAt) && record.updatedAt >= record.createdAt;
}

function validLegacyRecord(record) {
    return isObject(record) && hasOnlyKeys(record, LEGACY_RECORD_KEYS)
        && validId(record.id) && typeof record.body === "string"
        && !isBlank(record.body) && validTimestamp(record.createdAt)
        && validTimestamp(record.updatedAt) && record.updatedAt >= record.createdAt;
}

function copyRecord(record) {
    return {
        id: record.id,
        title: record.title,
        body: record.body,
        createdAt: record.createdAt,
        updatedAt: record.updatedAt
    };
}

// Newest edits lead. The remaining comparisons make equal timestamps stable
// across input order too, which keeps serialization deterministic.
function compareRecords(left, right) {
    if (left.updatedAt !== right.updatedAt)
        return right.updatedAt - left.updatedAt;
    if (left.createdAt !== right.createdAt)
        return right.createdAt - left.createdAt;
    return left.id < right.id ? -1 : left.id > right.id ? 1 : 0;
}

function sortRecords(records) {
    return (Array.isArray(records) ? records : []).map(copyRecord).sort(compareRecords);
}

function validateRecords(records, legacy) {
    if (!Array.isArray(records))
        return { ok: false, reason: "notes is not an array" };
    var seen = Object.create(null);
    for (var i = 0; i < records.length; i++) {
        if (!(legacy ? validLegacyRecord(records[i]) : validRecord(records[i])))
            return { ok: false, reason: "invalid note at index " + i };
        if (Object.prototype.hasOwnProperty.call(seen, records[i].id))
            return { ok: false, reason: "duplicate note id" };
        seen[records[i].id] = true;
    }
    return { ok: true, reason: "" };
}

// Strict parsing is deliberate. Silently dropping one damaged record and
// later saving the survivors would destroy the only copy of that note. A
// future version or any malformed shape therefore blocks all mutations until
// the user repairs or moves the file.
function parseState(text) {
    if (typeof text !== "string" || text.trim() === "")
        return { status: "corrupt", value: null, records: [],
            error: "Empty Notes state" };
    var parsed;
    try {
        parsed = JSON.parse(text);
    } catch (error) {
        return { status: "corrupt", value: null, records: [], error: "Invalid JSON" };
    }
    if (!isObject(parsed) || !hasOnlyKeys(parsed, ["v", "notes"])
            || (parsed.v !== VERSION && parsed.v !== LEGACY_VERSION)) {
        return { status: "corrupt", value: null, records: [],
            error: "Unsupported Notes state" };
    }
    var migrated = parsed.v === LEGACY_VERSION;
    var checked = validateRecords(parsed.notes, migrated);
    if (!checked.ok)
        return { status: "corrupt", value: null, records: [], error: checked.reason };
    var source = migrated ? parsed.notes.map(function(record) {
        return {
            id: record.id,
            title: fallbackTitle(record.body),
            body: record.body,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt
        };
    }) : parsed.notes;
    var records = sortRecords(source);
    return {
        status: "ok",
        value: { v: VERSION, notes: records },
        records: records,
        error: "",
        migrated: migrated
    };
}

// Fixed root and record key order plus a total record ordering make the same
// logical state serialize to the same bytes every time.
function serializeState(records) {
    var checked = validateRecords(records);
    if (!checked.ok)
        throw new Error(checked.reason);
    var ordered = {
        v: VERSION,
        notes: sortRecords(records).map(copyRecord)
    };
    return JSON.stringify(ordered, null, 2) + "\n";
}

function findRecord(records, id) {
    var list = Array.isArray(records) ? records : [];
    for (var i = 0; i < list.length; i++) {
        if (list[i].id === id)
            return list[i];
    }
    return null;
}

function addRecord(records, body, id, now, title) {
    var list = Array.isArray(records) ? records : [];
    if (isBlank(body) || !validId(id) || !validTimestamp(now)
            || findRecord(list, id) !== null)
        return { changed: false, records: sortRecords(list), record: null };
    var normalizedTitle = normalizeTitle(title);
    var record = {
        id: id,
        title: normalizedTitle === "" ? UNTITLED_TITLE : normalizedTitle,
        body: body,
        createdAt: now,
        updatedAt: now
    };
    return {
        changed: true,
        records: sortRecords(list.concat([record])),
        record: copyRecord(record)
    };
}

function updateRecord(records, id, body, now) {
    var list = Array.isArray(records) ? records : [];
    if (isBlank(body))
        return removeRecord(list, id);
    if (!validTimestamp(now))
        return { changed: false, records: sortRecords(list), record: null };
    var found = findRecord(list, id);
    if (!found || found.body === body)
        return { changed: false, records: sortRecords(list), record: found };
    var updated = null;
    var next = list.map(function(record) {
        if (record.id !== id)
            return copyRecord(record);
        updated = {
            id: record.id,
            title: record.title,
            body: body,
            createdAt: record.createdAt,
            updatedAt: Math.max(now, record.updatedAt)
        };
        return updated;
    });
    return { changed: true, records: sortRecords(next), record: copyRecord(updated) };
}

// Manual title changes participate in the note's edit ordering. An empty
// title is represented by the generic untitled label rather than copying any
// part of the note body into the title field.
function updateTitleRecord(records, id, title, now) {
    var list = Array.isArray(records) ? records : [];
    if (!validTimestamp(now))
        return { changed: false, records: sortRecords(list), record: null };
    var found = findRecord(list, id);
    if (!found)
        return { changed: false, records: sortRecords(list), record: null };
    var normalized = normalizeTitle(title);
    if (normalized === "")
        normalized = UNTITLED_TITLE;
    if (normalized === found.title)
        return { changed: false, records: sortRecords(list), record: found };
    var updated = null;
    var next = list.map(function(record) {
        if (record.id !== id)
            return copyRecord(record);
        updated = {
            id: record.id,
            title: normalized,
            body: record.body,
            createdAt: record.createdAt,
            updatedAt: Math.max(now, record.updatedAt)
        };
        return updated;
    });
    return { changed: true, records: sortRecords(next), record: copyRecord(updated) };
}

// Model results are metadata: applying one must not make an otherwise
// untouched note look newly edited or disturb its list position.
function applyGeneratedTitle(records, id, title) {
    var list = Array.isArray(records) ? records : [];
    var found = findRecord(list, id);
    var normalized = normalizeTitle(title);
    if (!found || normalized === "" || normalized === found.title)
        return { changed: false, records: sortRecords(list), record: found };
    var updated = null;
    var next = list.map(function(record) {
        if (record.id !== id)
            return copyRecord(record);
        updated = {
            id: record.id,
            title: normalized,
            body: record.body,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt
        };
        return updated;
    });
    return { changed: true, records: sortRecords(next), record: copyRecord(updated) };
}

function captureTitleRequest(record, provider, model, effort) {
    if (!validRecord(record) || ["codex", "claude"].indexOf(provider) === -1
            || typeof model !== "string" || model.trim() === ""
            || TITLE_EFFORTS[provider].indexOf(effort) === -1)
        return null;
    return {
        id: record.id,
        title: record.title,
        body: record.body,
        provider: provider,
        model: model,
        effort: effort
    };
}

function titleRequestCurrent(records, request, provider, model, effort) {
    if (!request || request.provider !== provider || request.model !== model
            || request.effort !== effort)
        return false;
    var record = findRecord(records, request.id);
    return record !== null && record.title === request.title
        && record.body === request.body;
}

function removeRecord(records, id) {
    var list = Array.isArray(records) ? records : [];
    var deleted = findRecord(list, id);
    if (!deleted)
        return { changed: false, records: sortRecords(list), deleted: null };
    return {
        changed: true,
        records: sortRecords(list.filter(function(record) { return record.id !== id; })),
        deleted: copyRecord(deleted)
    };
}

function restoreDeleted(records, deleted) {
    var list = Array.isArray(records) ? records : [];
    if (!validRecord(deleted) || findRecord(list, deleted.id) !== null)
        return { changed: false, records: sortRecords(list), record: null };
    return {
        changed: true,
        records: sortRecords(list.concat([copyRecord(deleted)])),
        record: copyRecord(deleted)
    };
}

// The editor's leave-focus rule in pure form: a blank existing note is a
// deletion, while a blank never-materialized draft remains a no-op.
function commitDraft(records, id, body, now, newId) {
    if (isBlank(body)) {
        if (!id)
            return { changed: false, records: sortRecords(records), deleted: null,
                record: null };
        return removeRecord(records, id);
    }
    return id ? updateRecord(records, id, body, now)
        : addRecord(records, body, newId, now);
}

function normalizedSelection(text, start, end) {
    var length = text.length;
    var first = Math.max(0, Math.min(length, Number(start) || 0));
    var last = Math.max(0, Math.min(length, Number(end) || 0));
    if (first > last) {
        var held = first;
        first = last;
        last = held;
    }
    return { start: first, end: last };
}

function inlineMarkers(text, start, end, open, close) {
    var source = String(text == null ? "" : text);
    var selection = normalizedSelection(source, start, end);
    var selected = source.slice(selection.start, selection.end);
    var replacement = open + selected + close;
    var next = source.slice(0, selection.start) + replacement
        + source.slice(selection.end);
    var innerStart = selection.start + open.length;
    var innerEnd = innerStart + selected.length;
    return {
        text: next,
        selectionStart: innerStart,
        selectionEnd: innerEnd,
        cursorPosition: innerEnd
    };
}

function linkMarkers(text, start, end) {
    var source = String(text == null ? "" : text);
    var selection = normalizedSelection(source, start, end);
    var selected = source.slice(selection.start, selection.end);
    var label = selected === "" ? "link text" : selected;
    var destination = "https://";
    var replacement = "[" + label + "](" + destination + ")";
    var next = source.slice(0, selection.start) + replacement
        + source.slice(selection.end);
    var selectStart = selected === "" ? selection.start + 1
        : selection.start + label.length + 3;
    var selectEnd = selectStart + (selected === "" ? label.length : destination.length);
    return {
        text: next,
        selectionStart: selectStart,
        selectionEnd: selectEnd,
        cursorPosition: selectEnd
    };
}

function listPrefix(line) {
    var match = /^(?:[-*+] \[[ xX]\] |[-*+] |[0-9]+[.)] )/.exec(line);
    return match ? match[0] : "";
}

function toggleLines(text, start, end, kind) {
    var source = String(text == null ? "" : text);
    var selection = normalizedSelection(source, start, end);
    var lineStart = source.lastIndexOf("\n", selection.start - 1) + 1;
    var probeEnd = selection.end > selection.start
            && source.charAt(selection.end - 1) === "\n"
        ? selection.end - 1 : selection.end;
    var newline = source.indexOf("\n", probeEnd);
    var lineEnd = newline === -1 ? source.length : newline;
    var lines = source.slice(lineStart, lineEnd).split("\n");
    var checklist = kind === "checklist";
    var allActive = lines.every(function(line) {
        return checklist ? /^- \[[ xX]\] /.test(line)
            : /^- (?!\[[ xX]\] )/.test(line);
    });
    var desired = checklist ? "- [ ] " : "- ";
    var transformed = lines.map(function(line) {
        var existing = listPrefix(line);
        if (allActive)
            return line.slice(existing.length);
        return desired + line.slice(existing.length);
    }).join("\n");
    var next = source.slice(0, lineStart) + transformed + source.slice(lineEnd);
    if (selection.start !== selection.end) {
        return {
            text: next,
            selectionStart: lineStart,
            selectionEnd: lineStart + transformed.length,
            cursorPosition: lineStart + transformed.length
        };
    }
    var firstExisting = listPrefix(lines[0]);
    var delta = allActive ? -firstExisting.length : desired.length - firstExisting.length;
    var cursor = Math.max(lineStart, selection.start + delta);
    return { text: next, selectionStart: cursor, selectionEnd: cursor,
        cursorPosition: cursor };
}

function transformMarkdown(text, start, end, action) {
    if (action === "bold")
        return inlineMarkers(text, start, end, "**", "**");
    if (action === "italic")
        return inlineMarkers(text, start, end, "_", "_");
    if (action === "code")
        return inlineMarkers(text, start, end, "`", "`");
    if (action === "link")
        return linkMarkers(text, start, end);
    if (action === "bullet" || action === "checklist")
        return toggleLines(text, start, end, action);
    var source = String(text == null ? "" : text);
    var selection = normalizedSelection(source, start, end);
    return { text: source, selectionStart: selection.start,
        selectionEnd: selection.end, cursorPosition: selection.end };
}

function escapeHtml(value) {
    return String(value == null ? "" : value)
        .replace(/&/g, "&amp;")
        .replace(/</g, "&lt;")
        .replace(/>/g, "&gt;");
}

function escapeHtmlAttribute(value) {
    return escapeHtml(value).replace(/"/g, "&quot;").replace(/'/g, "&#39;");
}

// MarkdownText otherwise uses Qt's literal blue for anchors. Styling the
// rendered copy never touches the raw body retained in Notes.records.
function styleMarkdownLinks(markdown, linkColor) {
    var source = String(markdown == null ? "" : markdown);
    var color = String(linkColor == null ? "" : linkColor).trim();
    if (!/^#[0-9a-f]{6}$/i.test(color))
        color = "#ffffff";
    var pattern = /(^|[^!\\])\[([^\]\n]+)\]\((<[^>\n]+>|[^)\s]+)(?:\s+(?:"[^"\n]*"|'[^'\n]*'))?\)/g;
    return source.replace(pattern, function(match, prefix, label, destination) {
        if (destination.charAt(0) === "<"
                && destination.charAt(destination.length - 1) === ">")
            destination = destination.slice(1, -1);
        return prefix + "<a href=\"" + escapeHtmlAttribute(destination)
            + "\"><font color=\"" + color + "\">"
            + escapeHtml(label) + "</font></a>";
    });
}

var exported = {
    VERSION: VERSION,
    LEGACY_VERSION: LEGACY_VERSION,
    MAX_TITLE_LENGTH: MAX_TITLE_LENGTH,
    UNTITLED_TITLE: UNTITLED_TITLE,
    isBlank: isBlank,
    normalizeTitle: normalizeTitle,
    shouldAutoGenerateTitle: shouldAutoGenerateTitle,
    fallbackTitle: fallbackTitle,
    validTitle: validTitle,
    validId: validId,
    validTimestamp: validTimestamp,
    relativeTimeLabel: relativeTimeLabel,
    validRecord: validRecord,
    compareRecords: compareRecords,
    sortRecords: sortRecords,
    validateRecords: validateRecords,
    parseState: parseState,
    serializeState: serializeState,
    findRecord: findRecord,
    addRecord: addRecord,
    updateRecord: updateRecord,
    updateTitleRecord: updateTitleRecord,
    applyGeneratedTitle: applyGeneratedTitle,
    captureTitleRequest: captureTitleRequest,
    titleRequestCurrent: titleRequestCurrent,
    removeRecord: removeRecord,
    restoreDeleted: restoreDeleted,
    commitDraft: commitDraft,
    inlineMarkers: inlineMarkers,
    linkMarkers: linkMarkers,
    toggleLines: toggleLines,
    transformMarkdown: transformMarkdown,
    styleMarkdownLinks: styleMarkdownLinks
};

if (typeof module !== "undefined" && module.exports)
    module.exports = exported;
