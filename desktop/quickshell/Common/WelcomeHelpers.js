// Welcome progress and the optional checklist are independent of preferences.
// Connect comes first: the sign-ins it offers make the steps after it easier.
var STEPS = ["hello", "connect", "wallpaper", "style", "shortcuts", "finish"];
// The steps between Hello and Ready, which the top bar numbers.
var MIDDLE = ["connect", "wallpaper", "style", "shortcuts"];
var ITEMS = ["webapps", "assistant", "fingerprint", "security", "backup", "accounts"];
function object(value) { return value !== null && typeof value === "object" && !Array.isArray(value); }
function initial(version) {
    return {v: 1, status: "new", step: "hello", seen: [], checklist: {},
        version: String(version || ""), notified: false};
}
function validate(value) {
    if (!object(value) || value.v !== 1 || !["new", "open", "completed", "dismissed"].includes(value.status)
            || !STEPS.includes(value.step) || !Array.isArray(value.seen)
            || value.seen.some(id => !STEPS.includes(id)) || new Set(value.seen).size !== value.seen.length
            || !object(value.checklist) || Object.keys(value.checklist).some(id => !ITEMS.includes(id)
                || value.checklist[id] !== "later")
            || typeof value.version !== "string" || value.version.length > 128
            || (value.notified !== undefined && typeof value.notified !== "boolean"))
        return false;
    // Refuse a newer document rather than silently dropping its fields.
    return Object.keys(value).every(key => ["v", "status", "step", "seen", "checklist", "version", "notified"].includes(key));
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
// The steps this computer shows: Connect only when it has something to
// connect (1Password installed, or the assistant).
function steps(connect) {
    return connect ? STEPS.slice() : STEPS.filter(id => id !== "connect");
}
// Where Continue (+1) or Back (-1) goes from `step` among `route`. A step
// the route leaves out moves on to its neighbour in the full order.
function neighbour(route, step, delta) {
    const index = route.indexOf(step);
    if (index >= 0) return route[Math.max(0, Math.min(route.length - 1, index + delta))];
    // A step the route leaves out sits between the route's steps around it.
    const before = route.filter(id => STEPS.indexOf(id) < STEPS.indexOf(step)).length;
    return route[Math.max(0, Math.min(route.length - 1, delta > 0 ? before : before - 1))];
}
function checklist(facts, later) {
    // Web apps are choices, not a task with a correct answer. The security
    // backend can read registrations, but cannot cheaply detect a FIDO reader.
    // The assistant has its own step, Connect.
    const rows = [{id: "webapps", page: "applications", done: null}];
    if (facts.reader) rows.push({id: "fingerprint", page: "security", done: !!facts.fingerprint});
    rows.push({id: "security", page: "security", done: null});
    rows.push({id: "backup", page: "backup", done: facts.backupKnown ? !!facts.backup : null});
    rows.push({id: "accounts", page: "accounts", done: facts.accountsKnown ? !!facts.accounts : null});
    return rows.map(row => Object.assign({}, row, {later: later[row.id] === "later"}));
}
// The window a Hyprland openwindow event names: "ADDRESS,WORKSPACE,CLASS,TITLE".
// The title may hold commas; the class cannot.
function openedWindow(data) {
    const fields = String(data || "").split(",");
    return fields.length >= 3 ? {address: fields[0], windowClass: fields[2]} : null;
}
// The GECOS full name, or "" when the account has none.
function fullName(passwd) {
    const fields = String(passwd || "").trim().split(":");
    return fields.length >= 5 ? fields[4].split(",")[0].trim() : "";
}
function firstName(passwd, username) {
    const fields = String(passwd || "").trim().split(":");
    const name = fields.length >= 5 ? fields[4].split(",")[0].trim() : "";
    return (name || String(username || "")).split(/\s+/)[0];
}
if (typeof module !== "undefined" && module.exports)
    module.exports = {STEPS, MIDDLE, ITEMS, initial, validate, parse, serialize, visit, resume, steps, neighbour, checklist,
        openedWindow, fullName, firstName};
