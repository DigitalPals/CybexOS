// Pure Fusebox presentation helpers, shared by QML and Node fixtures. The
// account, quota and request rules mirror Fusebox's own dashboard (ui/app.js)
// so the widget and the dashboard always say the same thing.

// Sessions lead: a coding session is idle between requests most of the time,
// so requests in progress sit at 0 even while work is under way.
var METRICS = [
    { value: "sessions", label: "Recent sessions" },
    { value: "serving", label: "Requests in progress" },
    { value: "rpm", label: "Requests per minute" },
    { value: "faults", label: "Faults" }
];

// How quota meters read, as Fusebox's own Used / Remaining switch.
var QUOTA_DISPLAYS = [
    { value: "used", label: "Used" },
    { value: "remaining", label: "Remaining" }
];

var PROVIDER_NAMES = {
    claude: "Claude", codex: "Codex", gemini: "Gemini", vertex: "Vertex AI",
    antigravity: "Antigravity", kimi: "Kimi", xai: "Grok", meta: "Meta",
    devin: "Devin", "openai-compat": "Compatible"
};

// Bundled identity marks (BrandIcons) for the providers that have one.
var PROVIDER_MARKS = { claude: "claude", codex: "openai", gemini: "gemini", vertex: "gemini",
    antigravity: "gemini", xai: "grok", kimi: "kimi" };

var MINUTE = 60000;
var HOUR = 60 * MINUTE;
var DAY = 24 * HOUR;

function providerName(a) {
    if (!a)
        return "";
    if (a.provider === "openai-compat")
        return a.group || "Compatible";
    if (a.kind === "api-key" && a.provider === "xai")
        return "xAI";
    if (a.kind === "api-key" && a.provider === "codex")
        return "OpenAI";
    return PROVIDER_NAMES[a.provider] || a.provider;
}

function providerMark(provider) {
    return PROVIDER_MARKS[provider] || "";
}

function planName(a) {
    if (!a || !a.plan)
        return "";
    var text = String(a.plan).replace(/[_-]+/g, " ");
    return text.charAt(0).toUpperCase() + text.slice(1);
}

// "2h 14m", "3d 7h", "45m", "<1m": the dashboard's countdowns, at most two units.
function span(ms) {
    var s = Math.max(0, Math.floor(ms / 1000));
    if (s < 60)
        return "<1m";
    if (s < 3600)
        return Math.floor(s / 60) + "m";
    if (s < 86400)
        return Math.floor(s / 3600) + "h " + Math.floor(s % 3600 / 60) + "m";
    return Math.floor(s / 86400) + "d " + Math.floor(s % 86400 / 3600) + "h";
}

function pad(n) {
    return n < 10 ? "0" + n : String(n);
}

var WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];

// A wall-clock time, with the weekday once it is more than a day away.
function when(at, now) {
    var d = new Date(at);
    var time = pad(d.getHours()) + ":" + pad(d.getMinutes());
    return at - now >= DAY ? WEEKDAYS[d.getDay()] + " " + time : time;
}

function ago(ms) {
    if (!(ms >= 0) || ms < 5000)
        return "just now";
    if (ms < MINUTE)
        return Math.floor(ms / 1000) + " s ago";
    if (ms < HOUR)
        return Math.floor(ms / MINUTE) + " min ago";
    if (ms < DAY)
        return Math.floor(ms / HOUR) + " h ago";
    return Math.floor(ms / DAY) + " d ago";
}

function number(n) {
    if (!(n >= 0))
        return "0";
    if (n < 1000)
        return String(Math.round(n));
    if (n < 1e6)
        return (n / 1000).toFixed(n < 10000 ? 1 : 0) + "k";
    if (n < 1e9)
        return (n / 1e6).toFixed(n < 1e7 ? 1 : 0) + "M";
    return (n / 1e9).toFixed(1) + "B";
}

function seconds(ms) {
    if (ms === null || ms === undefined || !(ms >= 0))
        return "—";
    return ms < 1000 ? Math.round(ms) + " ms" : (ms / 1000).toFixed(ms < 10000 ? 1 : 0) + " s";
}

// Whole percentages; the ends never round onto 0% or 100% unless they are.
function percent(value) {
    var rounded = Math.round(value);
    if (value > 0 && rounded === 0)
        return "<1%";
    if (value < 100 && rounded === 100)
        return ">99%";
    return rounded + "%";
}

function maskEmails(text) {
    return String(text || "").replace(/[^\s@<>()"',;:]+@[^\s@<>()"',;:]+\.[a-z]{2,}/gi, "••••••@••••••");
}

// Account labels are usually emails. Hidden, an account reads as its provider
// and its place among that provider's accounts, which stays put across refreshes.
function accountName(a, accounts, hide) {
    if (!a)
        return "";
    if (!hide)
        return a.label;
    var peers = (accounts || []).filter(function(x) {
        return x.provider === a.provider && x.kind === a.kind;
    }).map(function(x) { return x.id; }).sort();
    var index = peers.indexOf(a.id);
    var name = providerName(a) + (a.kind === "api-key" ? " key" : "");
    return peers.length > 1 && index >= 0 ? name + " " + (index + 1) : name;
}

// A usage window that is still current, or null.
function quota(w, now) {
    if (!w || typeof w.used !== "number" || !isFinite(w.used))
        return null;
    if (w.resetsAt && !(w.resetsAt > now))
        return null;
    var used = Math.max(0, Math.min(100, w.used));
    return { used: used, level: used >= 95 ? "critical" : used >= 75 ? "warn" : "ok" };
}

// The share a meter fills and prints: what is used, or what is left. Its level
// always measures used, as Fusebox's meters do in Remaining mode, so a nearly
// spent window stays red however it is read.
function quotaShare(reading, display) {
    if (!reading)
        return null;
    return display === "remaining" ? 100 - reading.used : reading.used;
}

function quotaWord(display) {
    return display === "remaining" ? "left" : "used";
}

function isHours(name) {
    return /^\d+h$/.test(name);
}

// The 5-hour (short) or weekly window the dashboard's meters show.
function windowOf(a, short, now) {
    var best = null;
    ((a && a.windows) || []).forEach(function(w) {
        if (w.model || !quota(w, now) || isHours(w.name) !== short)
            return;
        if (!best || w.used > best.used)
            best = w;
    });
    return best;
}

function windowLabel(w, short) {
    if (short)
        return w ? w.name.toUpperCase() : "5H";
    return w && w.name === "day" ? "DAY" : "WK";
}

function windowTitle(w) {
    if (!w)
        return "";
    if (isHours(w.name))
        return w.name.replace("h", "") + "-hour";
    return w.name === "day" ? "Daily" : "Weekly";
}

var SIGNIN_ERROR = /invalid_grant|refresh token|sign in again|re-?authenticat|unauthori[sz]ed|\b401\b|token (?:has )?expired|expired token|revoked/i;

function inFlight(a, load) {
    var entry = a && load ? load[a.id] : null;
    return entry ? entry.inFlight : 0;
}

function sessions(a, load) {
    var entry = a && load ? load[a.id] : null;
    return entry ? entry.sessions : 0;
}

// The dashboard's acctState(): disabled, then the latest pause, then an error.
// A ready account carrying requests reads Serving.
function accountState(a, load, now) {
    if (a.disabled)
        return { cls: "disabled", level: "idle", word: "Off" };
    var latest = null;
    (a.cooldowns || []).forEach(function(c) {
        if (c.until > now && (!latest || c.until > latest.until))
            latest = c;
    });
    if (latest)
        return { cls: "cooling", level: "warn", word: "Cooling " + span(latest.until - now),
            until: latest.until, model: latest.model, kind: latest.kind };
    if (a.lastError) {
        var signin = a.kind !== "api-key" && SIGNIN_ERROR.test(a.lastError);
        return { cls: "error", level: "critical", word: signin ? "Sign-in expired" : "Error", signin: signin };
    }
    var n = inFlight(a, load);
    return n > 0 ? { cls: "serving", level: "ok", word: "Serving " + n }
        : { cls: "ready", level: "ok", word: "Ready" };
}

// The word beside an account's dot. A healthy account reads as its recent
// sessions, or Ready when it has none; requests without a session still show
// as Serving. An account that is off, cooling or in error reads as just that.
function statusText(state, sessionCount, inFlightCount) {
    if (state.cls !== "ready" && state.cls !== "serving")
        return state.word;
    if (sessionCount > 0)
        return sessionCount + (sessionCount === 1 ? " session" : " sessions");
    return inFlightCount > 0 ? "Serving " + inFlightCount : "Ready";
}

// Subscriptions first, then keys; each provider's accounts in a stable order.
function groupAccounts(accounts) {
    var order = { oauth: 0, "service-account": 1, "api-key": 2 };
    return (accounts || []).slice().sort(function(x, y) {
        return (order[x.kind] - order[y.kind]) || providerName(x).localeCompare(providerName(y))
            || (x.id < y.id ? -1 : x.id > y.id ? 1 : 0);
    });
}

// ---- requests and load -----------------------------------------------------

function outcome(r) {
    return r.status === 499 ? "cancelled" : r.status >= 400 ? "failed" : "ok";
}

function trimSeries(series, now) {
    var cutoff = Math.floor(now / MINUTE) - 59;
    return (series || []).filter(function(b) { return b.minute >= cutoff; });
}

// Counts one finished request into its minute, as the dashboard's onRequest().
function applyRequest(series, r, now) {
    var minute = Math.floor(r.at / MINUTE);
    var next = trimSeries(series, now).map(function(b) { return b; });
    if (minute < Math.floor(now / MINUTE) - 59)
        return next;
    var index = next.findIndex(function(b) { return b.minute === minute; });
    var bucket = index >= 0 ? Object.assign({}, next[index])
        : { minute: minute, requests: 0, failed: 0, cancelled: 0, input_tokens: 0, output_tokens: 0, cache_tokens: 0 };
    bucket.requests += 1;
    var result = outcome(r);
    if (result !== "ok")
        bucket[result] += 1;
    bucket.input_tokens += r.input || 0;
    bucket.output_tokens += r.output || 0;
    bucket.cache_tokens += r.cached || 0;
    if (index >= 0)
        next[index] = bucket;
    else
        next.push(bucket);
    return next.sort(function(x, y) { return x.minute - y.minute; });
}

// Sixty bars, oldest first, with empty minutes filled in.
function bars(series, now) {
    var current = Math.floor(now / MINUTE);
    var byMinute = {};
    (series || []).forEach(function(b) { byMinute[b.minute] = b; });
    var out = [];
    for (var m = current - 59; m <= current; m++) {
        var b = byMinute[m];
        out.push({ minute: m, requests: b ? b.requests : 0, failed: b ? b.failed : 0, current: m === current });
    }
    return out;
}

function median(values) {
    if (!values.length)
        return null;
    var sorted = values.slice().sort(function(x, y) { return x - y; });
    var mid = Math.floor(sorted.length / 2);
    return sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
}

// The figures: recent sessions (Fusebox's per-account count of sessions seen in
// the last five minutes; each session is pinned to one account), requests in
// progress, the last full minute, failures in the hour and the typical time to
// first token of recent successful requests.
function figures(series, requests, active, now, load) {
    var current = Math.floor(now / MINUTE);
    var lastMinute = (series || []).find(function(b) { return b.minute === current - 1; });
    var failed = (series || []).reduce(function(sum, b) {
        return b.minute > current - 60 ? sum + (b.failed || 0) : sum;
    }, 0);
    var ttfts = (requests || []).filter(function(r) {
        return r.ttft !== null && r.ttft !== undefined && outcome(r) === "ok";
    }).slice(0, 20).map(function(r) { return r.ttft; });
    var recent = Object.keys(load || {}).reduce(function(sum, id) { return sum + (load[id].sessions || 0); }, 0);
    return { sessions: recent, serving: active || 0, rpm: lastMinute ? lastMinute.requests : 0, failed: failed,
        ttft: median(ttfts) };
}

// ---- faults ----------------------------------------------------------------

function faultLevel(faults) {
    if ((faults || []).some(function(f) { return f.level === "err"; }))
        return "critical";
    return faults && faults.length ? "warn" : "ok";
}

// "Back at 16:40, in 1h 12m" while a fault should clear by itself.
function faultTiming(f, now) {
    if (!f || !f.until || f.until <= now)
        return "";
    return "Back at " + when(f.until, now) + ", in " + span(f.until - now);
}

// Faults that just appeared and are worth a notification. Rate limits come and
// go too often, as in Fusebox's own push notifications.
function newFaults(previousKeys, faults) {
    var seen = {};
    (previousKeys || []).forEach(function(key) { seen[key] = true; });
    return (faults || []).filter(function(f) {
        return !seen[f.key] && f.kind !== "rate_limit";
    });
}

function barValue(metric, figuresValue, faults) {
    if (metric === "faults")
        return String((faults || []).length);
    if (metric === "rpm")
        return String(figuresValue ? figuresValue.rpm : 0);
    if (metric === "serving")
        return String(figuresValue ? figuresValue.serving : 0);
    return String(figuresValue ? figuresValue.sessions : 0);
}

// The dashboard address for one of its hash routes.
function dashboardUrl(base, path) {
    var root = String(base || "").replace(/\/+$/, "");
    if (!/^https?:\/\//i.test(root))
        return "";
    return root + "/" + (/^#\//.test(path || "") ? path : "");
}

if (typeof module !== "undefined" && module.exports)
    module.exports = { METRICS, QUOTA_DISPLAYS, quotaShare, quotaWord, providerName, providerMark,
        planName, span, when, ago, number, seconds, percent, maskEmails, accountName, quota, windowOf,
        windowLabel, windowTitle, inFlight, sessions, accountState, statusText, groupAccounts, outcome, trimSeries,
        applyRequest, bars, median, figures, faultLevel, faultTiming, newFaults, barValue, dashboardUrl };
