// The shell's reading of `cybex doctor --json` (docs/system-check.md): the
// report is checked here, so a malformed or newer one is refused rather than
// half-shown.
var IDS = ["graphics", "drivers", "firmware-files", "services", "audio", "secure-boot",
    "firmware-updates", "storage", "battery", "time", "desktop"];
var STATES = ["ok", "suggestion", "problem", "info", "unknown"];
// What needs the person, most important first.
var RANK = {problem: 0, suggestion: 1};

function object(value) { return value !== null && typeof value === "object" && !Array.isArray(value); }

// The report, or null when it is not one this shell can read.
function parse(text) {
    let value;
    try { value = typeof text === "string" ? JSON.parse(text) : text; } catch (_) { return null; }
    if (!object(value) || value.version !== 1 || !Array.isArray(value.checks)
            || !["ok", "suggestion", "problem"].includes(value.overall))
        return null;
    const checks = value.checks.filter(check => object(check) && IDS.includes(check.id) && STATES.includes(check.state));
    if (checks.length !== value.checks.length)
        return null;
    return {overall: value.overall, checkedAt: typeof value.checkedAt === "string" ? value.checkedAt : "",
        checks: checks.map(check => ({id: check.id, state: check.state,
            summary: typeof check.summary === "string" ? check.summary : ""}))};
}

// The checks that need the person: problems, then suggestions, each in the
// report's order.
function attention(report) {
    if (!report)
        return [];
    return report.checks.filter(check => check.state in RANK)
        .map((check, index) => ({check: check, index: index}))
        .sort((a, b) => RANK[a.check.state] - RANK[b.check.state] || a.index - b.index)
        .map(entry => entry.check);
}

if (typeof module !== "undefined" && module.exports)
    module.exports = {IDS, STATES, parse, attention};
