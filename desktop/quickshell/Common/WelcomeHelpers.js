// The guide records observations, never success inferred from a button press.
// Keep transient practice sequences out of the document: after a restart a
// half-finished window/workspace exercise starts with a fresh baseline.
var STEPS = ["hello", "wallpaper", "style", "keys", "shortcuts", "finish"];
var TASKS = ["launcher", "terminal", "workspace", "overview", "shortcuts"];
var ITEMS = ["webapps", "assistant", "fingerprint", "security", "backup", "accounts"];
function object(value) { return value !== null && typeof value === "object" && !Array.isArray(value); }
function initial(version) {
    return {v: 1, status: "new", step: "hello", seen: [], practice: {}, checklist: {},
        version: String(version || ""), notified: false};
}
function validate(value) {
    if (!object(value) || value.v !== 1 || !["new", "open", "completed", "dismissed"].includes(value.status)
            || !STEPS.includes(value.step) || !Array.isArray(value.seen)
            || value.seen.some(id => !STEPS.includes(id)) || new Set(value.seen).size !== value.seen.length
            || !object(value.practice) || Object.keys(value.practice).some(id => !TASKS.includes(id)
                || typeof value.practice[id] !== "boolean")
            || !object(value.checklist) || Object.keys(value.checklist).some(id => !ITEMS.includes(id)
                || value.checklist[id] !== "later")
            || typeof value.version !== "string" || value.version.length > 128
            || (value.notified !== undefined && typeof value.notified !== "boolean"))
        return false;
    // Refuse a newer document rather than silently dropping its fields.
    return Object.keys(value).every(key => ["v", "status", "step", "seen", "practice", "checklist", "version", "notified"].includes(key));
}
function parse(text, version) {
    if (String(text).length > 65536) return {error: "invalid"};
    try {
        const value = JSON.parse(text);
        return validate(value) ? {value: Object.assign({notified: false}, value), error: ""} : {error: "invalid"};
    } catch (_) { return {error: "invalid"}; }
}
function serialize(value) {
    if (!validate(value)) throw new Error("Invalid welcome document");
    return JSON.stringify(value, null, 2) + "\n";
}
function visit(state, step) {
    if (!STEPS.includes(step)) return state;
    return Object.assign({}, state, {status: "open", step: step,
        seen: state.seen.includes(step) ? state.seen : state.seen.concat([step])});
}
function resume(state, requested) {
    if (requested && !STEPS.includes(requested)) return null;
    return visit(state, requested || (state.status === "completed" ? "hello" : state.step));
}
function sequence(workspace, windows) {
    return {start: workspace, away: false, baseline: (windows || []).slice(), candidates: []};
}
function reduce(practice, tracker, event) {
    const done = Object.assign({}, practice);
    const next = Object.assign({}, tracker);
    if (["launcher", "overview", "shortcuts"].includes(event.type) && event.open === true)
        done[event.type] = true;
    if (event.type === "workspace" && tracker.start !== null && event.id !== null) {
        next.away = tracker.away || event.id !== tracker.start;
        if (tracker.away && event.id === tracker.start) done.workspace = true;
    }
    if (event.type === "windows") {
        const ids = Array.isArray(event.ids) ? event.ids : [];
        if (tracker.candidates.some(id => !ids.includes(id))) done.terminal = true;
        next.candidates = tracker.candidates.filter(id => ids.includes(id)).concat(
            ids.filter(id => !tracker.baseline.includes(id) && !tracker.candidates.includes(id)));
    }
    return {practice: done, tracker: next};
}
function checklist(facts, later) {
    // Web apps are choices, not a task with a correct answer. The security
    // backend can read registrations, but cannot cheaply detect a FIDO reader.
    const rows = [{id: "webapps", page: "applications", done: null}];
    if (facts.assistantAvailable) rows.push({id: "assistant", page: "assistant", done: !!facts.assistant});
    if (facts.reader) rows.push({id: "fingerprint", page: "security", done: !!facts.fingerprint});
    rows.push({id: "security", page: "security", done: null});
    rows.push({id: "backup", page: "backup", done: facts.backupKnown ? !!facts.backup : null});
    rows.push({id: "accounts", page: "accounts", done: facts.accountsKnown ? !!facts.accounts : null});
    return rows.map(row => Object.assign({}, row, {later: later[row.id] === "later"}));
}
function firstName(passwd, username) {
    const fields = String(passwd || "").trim().split(":");
    const name = fields.length >= 5 ? fields[4].split(",")[0].trim() : "";
    return (name || String(username || "")).split(/\s+/)[0];
}
if (typeof module !== "undefined" && module.exports)
    module.exports = {STEPS, TASKS, ITEMS, initial, validate, parse, serialize, visit, resume, sequence, reduce, checklist, firstName};
