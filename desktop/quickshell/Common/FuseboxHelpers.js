// Pure Fusebox presentation helpers, shared by QML and Node fixtures. The
// account, quota and request rules mirror Fusebox's own dashboard (ui/app.js)
// so the widget and the dashboard always say the same thing.

// Sessions lead: a coding session is idle between requests most of the time,
// so requests in progress sit at 0 even while work is under way.
var METRICS = [
    { value: "sessions", label: "Recent sessions" },
    { value: "serving", label: "Requests in progress" },
    { value: "rpm", label: "Requests per minute" },
    { value: "faults", label: "Faults" },
    { value: "clients", label: "Connected clients" }
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

// ChatGPT's plan says only "pro"; the subscription names the tier, as the dashboard reads it.
var CODEX_PLAN_NAMES = { chatgptprolite: "Pro 100", chatgptpro: "Pro 200", chatgptpromax: "Pro 500" };

function planName(a) {
    if (!a)
        return "";
    if (a.provider === "codex" && CODEX_PLAN_NAMES.hasOwnProperty(a.subscriptionPlan || ""))
        return CODEX_PLAN_NAMES[a.subscriptionPlan];
    if (!a.plan)
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

// ---- pace ----------------------------------------------------------------------
// The dashboard's pace rules: where even use would be by now, how fast the window
// is going, and when it runs out if that is before it resets.

function windowLength(w) {
    var hours = /^(\d+)h$/.exec(w && w.name || "");
    if (hours)
        return Number(hours[1]) * HOUR;
    return w && w.name === "day" ? DAY : w && w.name === "week" ? 7 * DAY : null;
}

// How far through its window we are, 0 to 1, when the window says when it resets.
function windowElapsed(w, now) {
    var length = windowLength(w);
    if (!length || !w.resetsAt)
        return null;
    var left = w.resetsAt - now;
    return left >= 0 && left <= length ? 1 - left / length : null;
}

// Where even pace puts the meter's fill now, in the meter's own direction.
function paceMark(w, now, display) {
    var t = windowElapsed(w, now);
    return t === null ? null : display === "remaining" ? 1 - t : t;
}

// Percent of the window used per hour so far, once a little of it has passed.
function burnRate(w, now) {
    var reading = quota(w, now);
    var t = windowElapsed(w, now);
    if (!reading || t === null || t < 0.02)
        return null;
    return reading.used / (t * windowLength(w) / HOUR);
}

// When the window runs out at the pace so far, if that is before it resets. Early
// in a window, or with little used, the pace is too unsettled to say.
function runsOutAt(w, now) {
    var reading = quota(w, now);
    var t = windowElapsed(w, now);
    if (!reading || reading.used >= 100 || t === null || t < 0.25 || reading.used < 20)
        return null;
    var at = now + (100 - reading.used) / (reading.used / (t * windowLength(w)));
    return at < w.resetsAt ? at : null;
}

// "0.4% an hour"; a window barely in use says nothing rather than "0.0%".
function rateText(rate) {
    if (rate === null || rate < 0.05)
        return "";
    return (rate < 1 ? rate.toFixed(1) : String(Math.round(rate))) + "% an hour";
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

// ---- combined weekly limits ------------------------------------------------------
// The overview's combined meter: each provider with two or more subscriptions, its
// accounts' average weekly use and where even pace puts it. When every reporting
// account's plan has a price, accounts count by it, as Fusebox weighs them: the 5x
// and 20x in Max's names are for the 5-hour window, and weekly limits track price.

var PLAN_PRICE = { claude: { pro: 1, max_5x: 5, max_20x: 10 } };

function planWeight(a) {
    var prices = PLAN_PRICE[a.provider];
    return prices && prices.hasOwnProperty(a.plan || "") ? prices[a.plan] : null;
}

// Subscriptions that report limits; API keys have none.
function metered(a) {
    return (a.kind === "oauth" && (a.provider === "claude" || a.provider === "codex"))
        || (a.windows || []).some(function(w) { return !w.model; });
}

function planCounts(list) {
    var counts = {};
    list.forEach(function(a) {
        var name = planName(a);
        if (name)
            counts[name] = (counts[name] || 0) + 1;
    });
    return Object.keys(counts).map(function(name) { return [name, counts[name]]; })
        .sort(function(x, y) { return y[1] - x[1] || x[0].localeCompare(y[0]); });
}

// A window that renewed counts as unused and at the start of its week; disabled
// accounts and accounts without a weekly reading are left out.
function weeklyPools(accounts, now) {
    var byProvider = {};
    var order = [];
    groupAccounts(accounts).forEach(function(a) {
        if (a.disabled || !metered(a))
            return;
        if (!byProvider[a.provider]) {
            byProvider[a.provider] = [];
            order.push(a.provider);
        }
        byProvider[a.provider].push(a);
    });
    var pools = [];
    order.forEach(function(provider) {
        var list = byProvider[provider];
        if (list.length < 2)
            return;
        var weeks = [];
        list.forEach(function(a) {
            var w = (a.windows || []).find(function(x) { return x.name === "week" && !x.model; });
            if (w)
                weeks.push([a, w]);
        });
        if (!weeks.length)
            return;
        var priced = weeks.every(function(pair) { return planWeight(pair[0]) !== null; });
        var weight = 0, used = 0, elapsed = 0, paced = true;
        weeks.forEach(function(pair) {
            var k = priced ? planWeight(pair[0]) : 1;
            weight += k;
            var reading = quota(pair[1], now);
            if (!reading)
                return;
            var t = windowElapsed(pair[1], now);
            if (t === null)
                t = reading.used === 0 ? 0 : null;
            used += k * reading.used;
            if (t === null)
                paced = false;
            else
                elapsed += k * t;
        });
        pools.push({ provider: provider, account: list[0], accounts: list.length, reported: weeks.length,
            used: used / weight, pace: paced ? elapsed / weight : null, priced: priced, plans: planCounts(list) });
    });
    return pools;
}

// Accounts by provider, subscriptions before keys, in the dashboard's order. A
// group names its plan when every account shares it, so rows needn't repeat it.
function accountGroups(accounts) {
    var groups = [];
    var byKey = {};
    groupAccounts(accounts).forEach(function(a) {
        var keys = a.kind === "api-key";
        var key = providerName(a) + (keys ? "|key" : "|sub");
        if (!byKey.hasOwnProperty(key)) {
            byKey[key] = { key: key, provider: a.provider, name: providerName(a), keys: keys, accounts: [] };
            groups.push(byKey[key]);
        }
        byKey[key].accounts.push(a);
    });
    groups.forEach(function(g) {
        var n = g.accounts.length;
        var plans = planCounts(g.accounts);
        var known = plans.reduce(function(sum, entry) { return sum + entry[1]; }, 0);
        g.uniformPlan = !g.keys && plans.length === 1 && known === n;
        g.summary = g.keys ? n + (n === 1 ? " key" : " keys")
            : g.uniformPlan ? (n === 1 ? plans[0][0] : n + " × " + plans[0][0])
            : plans.length && known === n ? plans.map(function(entry) { return entry[1] + " " + entry[0]; }).join(", ")
            : n + (n === 1 ? " account" : " accounts");
    });
    return groups;
}

// How far the combined use is from even pace, in points of the week.
function poolGap(p) {
    if (p.pace === null)
        return null;
    var d = Math.round(p.used - p.pace * 100);
    if (!d)
        return { text: "On pace", level: "ok" };
    var n = Math.abs(d);
    return { text: n + (n === 1 ? " point " : " points ") + (d < 0 ? "under" : "over") + " pace",
        level: d > 0 ? "warn" : "ok" };
}

function poolBasis(pools) {
    var priced = pools.some(function(p) { return p.priced; });
    var equal = pools.some(function(p) { return !p.priced; });
    return priced && !equal ? "weighted by plan price" : priced ? "partly weighted by plan price" : "weighted equally";
}

// ---- who used a window ----------------------------------------------------------
// Fusebox splits each rise in a window's reported use over the requests that
// finished since the previous one, by list price: an estimate in points.

var HIDDEN = "••••••";

function shareKey(w) {
    return w.model ? w.name + " · " + w.model : w.name;
}

function currentShare(a, w) {
    if (!a || !w || !a.attribution)
        return null;
    var key = shareKey(w);
    return a.attribution.current.find(function(s) { return s.key === key; }) || null;
}

// Named clients go with the other labels when hidden; programs ("Claude Code") stay.
function clientName(id, label, hide) {
    id = String(id || "");
    if (!id)
        return label || "Other requests";
    if (id.indexOf("app:") === 0)
        return label || id.slice(4);
    return hide ? HIDDEN : label || id;
}

// The four largest clients, the rest together, then use from outside Fusebox and
// from before it looked.
function shareRows(s, hide) {
    if (!s)
        return [];
    var clients = (s.clients || []).filter(function(c) { return c.points > 0; });
    var rows = clients.slice(0, 4).map(function(c) {
        return { name: clientName(c.id, c.label, hide), points: c.points, other: false };
    });
    var rest = clients.slice(4);
    if (rest.length)
        rows.push({ name: rest.length + (rest.length === 1 ? " more client" : " more clients"), other: true,
            points: rest.reduce(function(sum, c) { return sum + c.points; }, 0) });
    if (s.outside > 0)
        rows.push({ name: "Outside Fusebox", points: s.outside, other: true });
    if (s.before > 0)
        rows.push({ name: "Before Fusebox looked", points: s.before, other: true });
    return rows;
}

// "week opus" for a window limited to one model.
function windowName(name, model) {
    return model && String(name).indexOf(model) === -1 ? name + " " + model : String(name || "");
}

// What a session used of the account's current windows: "4% of week · 11% of 5h".
function sessionQuota(a, s) {
    var used = s && s.quota ? s.quota : {};
    var shares = a && a.attribution ? a.attribution.current : [];
    var order = shares.map(function(x) { return x.key; });
    return Object.keys(used).filter(function(k) { return used[k] > 0; })
        .sort(function(x, y) {
            var i = order.indexOf(x), j = order.indexOf(y);
            return (i < 0 ? order.length : i) - (j < 0 ? order.length : j);
        })
        .map(function(k) {
            var match = shares.find(function(x) { return x.key === k; });
            return percent(used[k]) + " of " + (match ? windowName(match.name, match.model) : k.replace(" · ", " "));
        }).join(" · ");
}

// ---- where requests come from -----------------------------------------------------

function viaText(src, hide, compact) {
    if (!src)
        return "";
    if (src.via === "forwarded")
        return !src.login ? "via reverse proxy" : compact ? "via Tailscale" : "via Tailscale · " + (hide ? HIDDEN : src.login);
    if (src.via === "proxy_protocol")
        return "via TCP forwarder";
    if (src.via === "unknown")
        return "address unknown";
    return /^(127\.|::1$)/.test(src.ip || "") ? "this machine" : "direct";
}

// "100.64.0.3 · via Tailscale · me@github"; the address and login are hidden with
// the account emails. Compact leaves the login to the Clients list.
function sourceText(src, hide, compact) {
    if (!src)
        return "";
    return (hide ? HIDDEN : src.ip) + " · " + viaText(src, hide, compact);
}

// Where a session or request came from, in one line: its key and its address.
function originText(item, hide) {
    var parts = [];
    if (item && item.keyLabel)
        parts.push(hide ? "key " + HIDDEN : item.keyLabel);
    if (item && item.source)
        parts.push(sourceText(item.source, hide, true));
    return parts.join(" · ");
}

// Pinned sessions worth a row: those with recent requests to name them by. The
// rest are counted, as their details have left the request log.
function namedSessions(detail) {
    return (detail && !detail.error ? detail.sessions : []).filter(function(s) { return s.client || s.model; });
}

// ---- clients and budgets ----------------------------------------------------------

// Named clients with a daily token or monthly spending limit, and how far through
// each they are. Levels as the quota meters: amber from 75%, red from 95%.
function budgets(view, hide) {
    var out = [];
    ((view && view.named) || []).forEach(function(c) {
        var name = hide ? HIDDEN : c.label || c.id;
        if (c.tokensPerDay)
            out.push(budget(c.id + ":tokens", name, c.tokensToday / c.tokensPerDay,
                number(c.tokensToday) + " of " + number(c.tokensPerDay) + " tokens today"));
        if (c.usdPerMonth)
            out.push(budget(c.id + ":usd", name, c.usdMonth / c.usdPerMonth,
                "$" + c.usdMonth.toFixed(2) + " of $" + money(c.usdPerMonth) + " this month"));
    });
    return out;
}

function budget(key, name, share, text) {
    var used = share > 0 ? Math.min(1, share) : 0;
    return { key: key, name: name, share: used, text: text, level: used >= 0.95 ? "critical" : used >= 0.75 ? "warn" : "ok" };
}

function money(n) {
    return n % 1 === 0 ? String(n) : n.toFixed(2);
}

// One row per connected key and address; busy ones first, then the most recent.
function connectedRows(view, hide) {
    return ((view && view.connected) || []).slice().sort(function(x, y) {
        var busy = (y.inFlight + y.sockets > 0) - (x.inFlight + x.sockets > 0);
        return busy || (y.last || 0) - (x.last || 0);
    }).map(function(c) {
        return { key: (c.id || c.label) + "|" + c.ip, name: clientName(c.id, c.label, hide && c.id !== ""
            && c.id.indexOf("app:") !== 0), where: sourceText(c, hide, true), full: sourceText(c, hide),
            busy: c.inFlight + c.sockets > 0,
            inFlight: c.inFlight, sockets: c.sockets, last: c.last };
    });
}

function connectedState(row, now) {
    if (row.inFlight > 0)
        return row.inFlight + (row.inFlight === 1 ? " request" : " requests");
    if (row.sockets > 0)
        return row.sockets === 1 ? "socket open" : row.sockets + " sockets open";
    return row.last ? ago(now - row.last) : "";
}

// ---- priority -----------------------------------------------------------------------
// Which accounts take new sessions first: the dashboard's First, Normal and Last.

var PRIORITIES = [
    { value: 10, label: "First" },
    { value: 0, label: "Normal" },
    { value: -10, label: "Last" }
];

function priorityChoice(priority) {
    return priority > 0 ? 10 : priority < 0 ? -10 : 0;
}

// Read after "New sessions": when this account takes them.
function priorityHelp(priority) {
    var p = priorityChoice(priority);
    return p > 0 ? "Before Normal and Last accounts" : p < 0 ? "Only when no other account can"
        : "By the routing strategy";
}

// ---- account details ---------------------------------------------------------

var DEVICE_CODE_PROVIDERS = ["kimi", "xai", "meta"];

function authName(a) {
    if (a.kind === "service-account")
        return "Service account";
    if (a.kind === "api-key")
        return "API key";
    return DEVICE_CODE_PROVIDERS.indexOf(a.provider) !== -1 ? "Device code" : "OAuth";
}

// "Claude · OAuth · last used 20 s ago", as the dashboard's account line.
function accountSubtitle(a, now) {
    return [providerName(a), authName(a), a.lastUsed ? "last used " + ago(now - a.lastUsed) : "not used yet"]
        .join(" · ");
}

// The expanded account's figures: requests and failures since Fusebox started,
// coding sessions pinned to it, and how long its sign-in stays valid.
function accountFacts(a, detail, now) {
    var facts = [
        { label: "Requests", value: number(a.requests) },
        { label: "Failed", value: number(a.failures), level: a.failures > 0 ? "critical" : "ok" },
        { label: "Pinned", value: detail && !detail.error ? String(detail.sessions.length) : "–" }
    ];
    if (a.kind === "oauth" && a.expiresAt)
        facts.push(a.expiresAt > now ? { label: "Token", value: span(a.expiresAt - now) }
            : { label: "Token", value: "Expired", level: "critical" });
    return facts;
}

// The meters' two windows in an account's details: when each resets ("resets
// 12:10 · in 57m"), is back when used up, or runs out early at this pace, and
// which clients used it.
function windowDetails(a, now, hide) {
    var out = [];
    [true, false].forEach(function(short) {
        var w = windowOf(a, short, now);
        if (!w)
            return;
        var out_ = runsOutAt(w, now);
        var spent = w.used >= 100;
        var timing = out_ !== null ? "runs out " + when(out_, now) + " · in " + span(out_ - now)
            : w.resetsAt ? (spent ? "back " : "resets ") + when(w.resetsAt, now) + " · in " + span(w.resetsAt - now)
            : "";
        var share = currentShare(a, w);
        out.push({ title: windowTitle(w), timing: timing, level: out_ !== null || spent ? "warn" : "ok",
            rate: rateText(burnRate(w, now)), rows: shareRows(share, hide), meterLevel: quota(w, now).level,
            byTokens: !!share && share.byTokens > 0 });
    });
    return out;
}

var PAUSE_WORDS = { quota: "usage limit used up", rate_limit: "rate limited", checking: "checking its limits" };

// One line per paused model, newest pause last: "claude-opus · rate limited · back in 4m".
function pauseText(a, now) {
    return (a.cooldowns || []).filter(function(c) { return c.until > now; })
        .sort(function(x, y) { return x.until - y.until; })
        .map(function(c) {
            return (c.model === "*" ? "Every model" : c.model) + " · "
                + (PAUSE_WORDS[c.kind] || c.kind.replace(/_/g, " ")) + " · back in " + span(c.until - now);
        }).join("\n");
}

// ---- banked resets -------------------------------------------------------------
// The rules of Fusebox's own reset dialog: spending needs fresh status, an
// eligible inventory, a confirmation (quote) and no unresolved earlier spend.

var RESET_FRESH_MS = 5 * MINUTE;
// Fusebox's confirmation lasts two minutes from the status read; expire it a
// little sooner here so a quote the server would refuse is never offered.
var QUOTE_MS = 110 * 1000;
var MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

function resetsSupported(a, enabled) {
    return !!enabled && !!a && a.kind === "oauth" && (a.provider === "claude" || a.provider === "codex");
}

function resetUnresolved(view) {
    var op = view && view.operation;
    return !!op && (op.status === "pending" || op.status === "unknown");
}

// A usable grant that has expired or not started yet means the status is out of date.
function grantTimingChanged(view, now) {
    var grants = view && view.inventory ? view.inventory.grants : [];
    return grants.some(function(g) {
        return g.usable && ((g.expiresAt && g.expiresAt <= now) || (g.startsAt && g.startsAt > now));
    });
}

// Why "Use 1 reset" can't open a confirmation now, or "" when it can.
function resetBlock(view, a, now) {
    if (!view)
        return "Checking reset status…";
    if (a.disabled)
        return "Turn this account on to use a reset.";
    if (view.error)
        return view.error;
    if (resetUnresolved(view))
        return "A reset may have been used. New resets are blocked until it's resolved.";
    if (!(view.checkedAt > now - RESET_FRESH_MS) || grantTimingChanged(view, now))
        return "Refresh to check availability.";
    var inv = view.inventory;
    if (!inv || !inv.eligible)
        return (inv && inv.reason) || "No reset can be used right now.";
    return view.quote ? "" : "Refresh to check availability.";
}

function usableGrants(view) {
    return (view && view.inventory ? view.inventory.grants : []).filter(function(g) { return g.usable; });
}

// Claude can retry an unresolved spend with its saved IDs for ten minutes; Codex
// can only have its outcome recorded.
function retryAllowed(view, a, now) {
    return a.provider === "claude" && !!view && view.retryable && resetUnresolved(view)
        && view.operation.retryUntil > now;
}

function dateText(at, now) {
    if (Math.abs(at - now) < DAY)
        return when(at, now);
    var d = new Date(at);
    return MONTHS[d.getMonth()] + " " + d.getDate();
}

function grantDetail(g, now) {
    return (g.expiresAt ? "Expires " + dateText(g.expiresAt, now) : "No expiry reported")
        + " · Clears " + (g.clears.length ? g.clears.join(", ") : "provider limits");
}

// "1:42" left to confirm; 0 or less means the confirmation has lapsed.
function quoteLeft(startedAt, now) {
    return startedAt + QUOTE_MS - now;
}

function countdown(ms) {
    var s = Math.max(0, Math.ceil(ms / 1000));
    return Math.floor(s / 60) + ":" + pad(s % 60);
}

function resetCountText(n) {
    return n + (n === 1 ? " banked reset" : " banked resets");
}

// "Oct 22, 13:00", or just the time within a day.
function stamp(at, now) {
    return Math.abs(at - now) < DAY ? when(at, now) : dateText(at, now) + ", " + when(at, at);
}

// What Fusebox does about the soonest-expiring banked reset by itself.
function bankedPlanText(plan, now) {
    if (!plan)
        return "";
    if (!plan.auto)
        return "The next one expires " + stamp(plan.expiresAt, now) + ". Automatic redemption is off.";
    var text = plan.due ? "Fusebox is about to use one by itself."
        : "Fusebox uses one by itself at 95% weekly use, or " + (plan.redeemAt ? "at " + stamp(plan.redeemAt, now)
            + ", an hour" : "an hour") + " before it expires.";
    return plan.prioritized ? text + " Until then, this account takes new work first." : text;
}

// How a settled spend reads: used is good news, the rest is information.
function operationTone(op) {
    if (!op)
        return "info";
    if (op.status === "applied" || op.status === "reconciled_used")
        return "ok";
    return op.status === "pending" || op.status === "unknown" ? "warn" : "info";
}

// ---- requests and load -----------------------------------------------------

// What a request came from: the program when its User-Agent named one, else the
// API format it spoke, named as Fusebox's dashboard names them.
var CLIENT_FORMATS = { openai: "OpenAI", responses: "Responses", claude: "Anthropic", gemini: "Gemini" };

function clientLabel(r) {
    return r.clientApp || CLIENT_FORMATS[r.client] || r.client || "Client";
}

// Transport and retries worth a tag, as the dashboard's route column marks them.
function requestTags(r) {
    var tags = [];
    var kind = { ws: "ws", images: "image", video: "video" }[r.transport];
    if (kind)
        tags.push(kind);
    if (r.attempts > 1)
        tags.push(r.attempts + " tries");
    return tags;
}

// "3.6 s · 333k in · 290 out": time to first token, then tokens with the
// cached context counted in. Partial usage is a lower bound; missing is left out.
function requestMetrics(r) {
    var parts = [];
    if (r.ttft !== null && r.ttft !== undefined)
        parts.push(seconds(r.ttft));
    if (r.usage !== "missing") {
        var bound = r.usage === "partial" ? "≥" : "";
        parts.push(bound + number((r.input || 0) + (r.cached || 0)) + " in · " + bound + number(r.output || 0) + " out");
    }
    return parts.join(" · ");
}

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
// first token of recent successful requests, and the keys and addresses connected now.
function figures(series, requests, active, now, load, clients) {
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
        ttft: median(ttfts), clients: clients && clients.connected ? clients.connected.length : 0 };
}

// ---- faults ----------------------------------------------------------------

// Faults the menubar badge and count include. Pace warnings are listed but left
// out, as in Fusebox's own badge: they can hold for days and ask for no action.
function badgeFaults(faults) {
    return (faults || []).filter(function(f) { return f.badge !== false; });
}

function faultLevel(faults) {
    var counted = badgeFaults(faults);
    if (counted.some(function(f) { return f.level === "err"; }))
        return "critical";
    return counted.length ? "warn" : "ok";
}

// The glyph for each kind of fault.
function faultGlyph(f) {
    if (f.kind === "pace")
        return "speed";
    if (f.kind === "storage")
        return "server";
    return f.level === "err" ? "error" : "warning";
}

// ---- dismissed faults ------------------------------------------------------------
// A dismissed fault stays hidden while it lasts. One whose expected end changes
// is a new incident and shows again; one that clears is forgotten, so it shows
// the next time it trips. Clearing means unseen for a grace period, so a Fusebox
// restart, which briefly drops quota faults, doesn't bring dismissals back.

var DISMISS_GRACE_MS = 15 * MINUTE;
var MAX_DISMISSED = 200;

function faultSignature(f) {
    return f.key + "|" + (f.until || 0);
}

function isDismissed(dismissed, f) {
    var entry = dismissed ? dismissed[f.key] : null;
    return !!entry && entry.signature === faultSignature(f);
}

function visibleFaults(faults, dismissed) {
    return (faults || []).filter(function(f) { return !isDismissed(dismissed, f); });
}

function dismissFault(dismissed, f, now) {
    var next = Object.assign({}, dismissed || {});
    next[f.key] = { signature: faultSignature(f), seenAt: now };
    return next;
}

// Dismissals as read from disk: valid entries only, and no time limit yet. The
// shell may have been off for days; the first fault update decides what stays.
function loadDismissed(raw) {
    var next = {};
    Object.keys(raw && typeof raw === "object" ? raw : {}).slice(0, MAX_DISMISSED).forEach(function(key) {
        var entry = raw[key];
        if (entry && typeof entry.signature === "string" && typeof entry.seenAt === "number")
            next[key] = { signature: entry.signature, seenAt: entry.seenAt };
    });
    return next;
}

// Keeps dismissals of faults that are still there (or only briefly gone), drops
// those that cleared or changed, and ignores anything malformed from disk.
function pruneDismissed(dismissed, faults, now) {
    var present = {};
    (faults || []).forEach(function(f) { present[f.key] = f; });
    var next = {};
    Object.keys(dismissed || {}).slice(0, MAX_DISMISSED).forEach(function(key) {
        var entry = dismissed[key];
        if (!entry || typeof entry.signature !== "string" || typeof entry.seenAt !== "number")
            return;
        if (present[key]) {
            if (entry.signature === faultSignature(present[key]))
                next[key] = { signature: entry.signature, seenAt: now };
        } else if (entry.seenAt > now - DISMISS_GRACE_MS) {
            next[key] = entry;
        }
    });
    return next;
}

// "Back at 16:40, in 1h 12m" while a fault should clear by itself. A pace
// warning's time is when its window renews.
function faultTiming(f, now) {
    if (!f || !f.until || f.until <= now)
        return "";
    return (f.kind === "pace" ? "Renews " : "Back at ") + when(f.until, now) + ", in " + span(f.until - now);
}

// Faults that just appeared and are worth a notification. Rate limits come and
// go too often, as in Fusebox's own push notifications, and pace warnings are
// for the dashboard, not a notification.
function newFaults(previousKeys, faults) {
    var seen = {};
    (previousKeys || []).forEach(function(key) { seen[key] = true; });
    return badgeFaults(faults).filter(function(f) {
        return !seen[f.key] && f.kind !== "rate_limit";
    });
}

function barValue(metric, figuresValue, faults) {
    if (metric === "faults")
        return String(badgeFaults(faults).length);
    if (metric === "clients")
        return String(figuresValue ? figuresValue.clients : 0);
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
        windowLabel, windowTitle, windowElapsed, paceMark, burnRate, runsOutAt, rateText, inFlight, sessions,
        accountState, statusText, groupAccounts, metered, weeklyPools, accountGroups, poolGap, poolBasis, HIDDEN,
        shareKey, currentShare, clientName, shareRows, windowDetails, windowName, sessionQuota, viaText,
        sourceText, originText, namedSessions, budgets, connectedRows, connectedState, PRIORITIES, priorityChoice, priorityHelp,
        authName, accountSubtitle, accountFacts, pauseText, resetsSupported, resetUnresolved,
        grantTimingChanged, resetBlock, usableGrants, retryAllowed, dateText, grantDetail, quoteLeft,
        countdown, resetCountText, stamp, bankedPlanText, operationTone, QUOTE_MS, clientLabel, requestTags,
        requestMetrics, outcome, trimSeries, applyRequest, bars, median, figures, badgeFaults, faultLevel, faultGlyph,
        faultSignature, isDismissed, visibleFaults, dismissFault, loadDismissed, pruneDismissed, DISMISS_GRACE_MS,
        faultTiming, newFaults, barValue, dashboardUrl };
