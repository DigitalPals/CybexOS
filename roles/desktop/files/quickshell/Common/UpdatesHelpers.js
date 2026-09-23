// Pure parsing and transition rules for Common/Updates.qml. Keeping these free
// of Qt APIs makes the parts fed by command output executable under Node.

function dnfNames(body) {
    var names = [];
    String(body || "").split("\n").forEach(function (line) {
        // Section headings carry no columns and continuation lines are
        // indented. A package row begins with name.arch, followed by its
        // version and repository.
        var match = line.match(/^([A-Za-z0-9][^\s]*)\.[a-z0-9_]+\s+\S+\s+\S/);
        if (match)
            names.push(match[1]);
    });
    return names;
}

function flatpakNames(body) {
    return String(body || "").split("\n")
        .map(function (line) { return line.trim(); })
        .filter(function (line) { return line !== ""; });
}

// Count devices, not alternative releases for the same device.
function firmwareNames(body) {
    const data = JSON.parse(body);
    if (!data || !Array.isArray(data.Devices))
        throw new Error("missing firmware device list");
    return data.Devices.filter(device => Array.isArray(device.Releases)
        && device.Releases.length > 0).map(device =>
        typeof device.Name === "string" ? device.Name : "Firmware device");
}

// The sources one check covers, as { dnf, flatpak, firmware, project }.
var CHECK_SOURCES = ["dnf", "flatpak", "firmware", "project"];

function allParts() {
    var parts = {};
    CHECK_SOURCES.forEach(function (source) {
        parts[source] = true;
    });
    return parts;
}

// A retry repeats only the sources whose last attempt failed ({ source:
// error text }, "" for one that answered). Rerunning dnf, a Flathub round
// trip and fwupd because one of them is unreachable is what turned a single
// blocked remote into five complete checks per poll.
function failedParts(errors) {
    var parts = {};
    CHECK_SOURCES.forEach(function (source) {
        parts[source] = !!errors && typeof errors[source] === "string"
            && errors[source] !== "";
    });
    return parts;
}

// Only a zero -> positive transition of the published total is news, and only
// a source that answered before can make it: each source's first answer of a
// session is its baseline, since those updates may have been pending before
// login. Tracking that per source is what lets dnf keep notifying while a
// blocked Flathub or a masked fwupd never answers at all. `sources` lists
// what this check answered: [{ baseline, count }], baseline meaning the
// source had answered in an earlier check.
function shouldNotify(previousTotal, nextTotal, sources, enabled) {
    if (!enabled || previousTotal !== 0 || !(nextTotal > 0))
        return false;
    return (Array.isArray(sources) ? sources : []).some(function (source) {
        return !!source && !!source.baseline && source.count > 0;
    });
}

// The notification body: what is pending, never an error from a source that
// did not answer (the menubar summary leads with those).
function pendingSummary(dnfCount, flatpakCount, firmwareCount, projectAvailable,
        projectVersion) {
    var parts = [];
    if (dnfCount > 0)
        parts.push("dnf " + dnfCount);
    if (flatpakCount > 0)
        parts.push("flatpak " + flatpakCount);
    if (firmwareCount > 0)
        parts.push("firmware " + firmwareCount);
    if (projectAvailable)
        parts.push("CybexOS " + projectVersion);
    return parts.join(" · ");
}

// ---- native run parsing ----------------------------------------------------
// The in-shell upgrade streams the same non-TTY dnf5 output the update
// script's dashboard greps. Two sources, two jobs: the resolved transaction
// TABLE ("Upgrading:" sections) carries every package's full name and
// version and is the only place they appear untruncated — dnf5 clips the
// bracketed progress lines to a fixed column — so the table builds the feed,
// and the bracketed lines only advance progress and mark table rows done.

// Table section headings, and the feed verb each one's rows become.
var DNF_TABLE_SECTIONS = {
    "Upgrading": "up",
    "Installing": "add",
    "Installing dependencies": "add",
    "Installing weak dependencies": "add",
    "Installing group/module packages": "add",
    "Reinstalling": "up",
    "Downgrading": "down",
    "Removing": "del",
    "Removing dependent packages": "del",
    "Removing unused dependencies": "del"
};

// A table section heading, e.g. "Upgrading:" -> "up". Null otherwise.
function dnfSection(line) {
    var match = String(line || "").match(/^([A-Za-z][A-Za-z /-]*):\s*$/);
    if (!match)
        return null;
    return DNF_TABLE_SECTIONS.hasOwnProperty(match[1])
        ? DNF_TABLE_SECTIONS[match[1]] : null;
}

// One package row inside a table section:
//   " firefox    x86_64 0:154.0-3.fc44  updates  287.1 MiB"
// Exactly one leading space; the "   replacing …" continuations sit deeper
// and are the outgoing versions, not packages of their own. `evr` keeps the
// epoch for matching against progress lines; `version` drops it for people.
function dnfTableRow(line) {
    var text = String(line || "");
    var match = text.match(/^ (\S+) +(\S+) +(\S+) +\S/);
    if (!match || /^ {2,}/.test(text))
        return null;
    return {
        name: match[1],
        arch: match[2],
        evr: match[3],
        version: match[3].replace(/^[0-9]+:/, "")
    };
}

// The running phase's package verbs. Cleanup of a replaced version prints as
// "Removing old-evr…" here; it never matches a table row (the table carries
// the incoming evr), so it advances progress without touching the feed.
var DNF_RUN_VERBS = {
    "Upgrading": "up",
    "Installing": "add",
    "Reinstalling": "up",
    "Downgrading": "down",
    "Removing": "del",
    "Erasing": "del",
    "Cleanup": "del"
};

// One bracketed progress line, download or running phase:
//   "[10/28] less-0:704-4.fc44.x86_64  100% | 2.2 MiB/s | …"
//   "[11/58] Upgrading less-0:704-4.fc 100% | 29.5 MiB/s | …"
// Null off-format. `token` is dnf's (column-clipped) package text when the
// body names one through a verb; empty for Verify/Prepare/download lines.
function parseDnfRunLine(line) {
    var match = String(line || "").replace(/\r/g, "")
        .match(/^\[ *([0-9]+)\/ *([0-9]+)\] +(.*)$/);
    if (!match)
        return null;
    var out = {
        cur: parseInt(match[1], 10),
        total: parseInt(match[2], 10),
        verb: "",
        token: ""
    };
    var action = match[3].match(/^([A-Za-z]+) +(\S+)/);
    if (action && DNF_RUN_VERBS.hasOwnProperty(action[1])) {
        out.verb = DNF_RUN_VERBS[action[1]];
        out.token = action[2];
    }
    return out;
}

// Does dnf's clipped progress token name this table row? The full identity
// is "name-evr"; the token is that string cut anywhere (possibly extending
// into ".arch"), so containment must hold in whichever direction is longer.
// "less-0:704…" never matches the "less-color-0:704…" row and vice versa.
function rowMatchesToken(name, evr, token) {
    if (typeof token !== "string" || token === "")
        return false;
    var key = name + "-" + evr;
    return token.length >= key.length
        ? token.slice(0, key.length + 1) === key + "."
            || token === key
        : key.slice(0, token.length) === token;
}

// Pending feed rows indexed by package name ({name: [{index, evr}, …]}), so a
// progress line costs a handful of lookups instead of a scan of the whole
// transcript. The candidates are every prefix of the token that ends before a
// "-": one of them is the package name unless dnf clipped the token inside the
// name itself, and only then does the lookup fall back to a scan. A token
// whose name is pending but whose evr is not (cleanup of the outgoing
// version) matches nothing, as before. Returns the feed index taken, or -1.
function addPendingRow(pending, name, evr, index) {
    if (!pending.hasOwnProperty(name))
        pending[name] = [];
    pending[name].push({ index: index, evr: evr });
}

function takeFromRows(pending, name, token) {
    var rows = pending[name];
    for (var j = 0; j < rows.length; j++) {
        if (rowMatchesToken(name, rows[j].evr, token)) {
            var index = rows[j].index;
            rows.splice(j, 1);
            if (rows.length === 0)
                delete pending[name];
            return index;
        }
    }
    return -1;
}

function takePendingRow(pending, token) {
    if (typeof token !== "string" || token === "")
        return -1;
    var named = false;
    for (var at = token.indexOf("-"); at > 0; at = token.indexOf("-", at + 1)) {
        var name = token.slice(0, at);
        if (!pending.hasOwnProperty(name))
            continue;
        named = true;
        var index = takeFromRows(pending, name, token);
        if (index !== -1)
            return index;
    }
    if (named)
        return -1;
    var best = -1;
    var bestName = "";
    for (var key in pending) {
        if (!pending.hasOwnProperty(key))
            continue;
        var rows = pending[key];
        for (var k = 0; k < rows.length; k++) {
            if ((best === -1 || rows[k].index < best)
                    && rowMatchesToken(key, rows[k].evr, token)) {
                best = rows[k].index;
                bestName = key;
            }
        }
    }
    if (best === -1)
        return -1;
    var list = pending[bestName];
    for (var m = 0; m < list.length; m++) {
        if (list[m].index === best) {
            list.splice(m, 1);
            break;
        }
    }
    if (list.length === 0)
        delete pending[bestName];
    return best;
}

// After a run the counts are rechecked once. A second, delayed check is only
// worth its network traffic when that recount failed, or when a successful
// run still reports pending packages for a backend it just upgraded (the
// package database or remote metadata was still settling).
function postRunRetryNeeded(complete, runState, dnfCount, flatpakCount,
        includedFlatpak) {
    if (!complete)
        return true;
    if (runState !== "done")
        return false;
    return dnfCount > 0 || (!!includedFlatpak && flatpakCount > 0);
}

// Connectivity can flap; an online edge is not a reason to repeat a
// complete check that is only a few minutes old.
function checkIsFresh(lastChecked, now, maxAgeMs) {
    return lastChecked > 0 && now - lastChecked >= 0
        && now - lastChecked < maxAgeMs;
}

// dnf's answer depends on its repository metadata and the installed set. This
// is their signature, from `find … -printf '%p %s %T@\n'` over every
// repository's repomd.xml, the repo files and the rpm database: sorted, so
// directory order cannot matter, and "" when the listing does not include
// the rpm database, because then it cannot vouch for what is installed.
function dnfSignature(text) {
    var lines = String(text || "").split("\n")
        .map(function (line) { return line.trim(); })
        .filter(function (line) { return line !== ""; });
    var hasRpmdb = lines.some(function (line) {
        return /\/rpmdb\.sqlite /.test(line);
    });
    return hasRpmdb ? lines.sort().join("\n") : "";
}

// However quiet the signature, a real dnf read still happens this often, so
// an input it does not cover (dnf.conf, say) is picked up within hours.
var DNF_ANSWER_MAX_AGE_MS = 6 * 3600 * 1000;

function dnfAnswerReusable(signature, cachedSignature, cachedAt, now) {
    return typeof signature === "string" && signature !== ""
        && signature === cachedSignature
        && checkIsFresh(cachedAt, now, DNF_ANSWER_MAX_AGE_MS);
}

// Application ids read as their most distinctive segment: org.signal.Signal
// is "Signal", but com.spotify.Client must not become "Client".
var FLATPAK_GENERIC_TAILS = ["client", "app", "desktop"];

function flatpakRefName(id) {
    var parts = String(id || "").split(".").filter(function (part) {
        return part !== "";
    });
    if (parts.length === 0)
        return String(id || "");
    var pick = parts[parts.length - 1];
    if (parts.length > 1
            && FLATPAK_GENERIC_TAILS.indexOf(pick.toLowerCase()) !== -1)
        pick = parts[parts.length - 2];
    return pick.charAt(0).toUpperCase() + pick.slice(1);
}

// One line of `flatpak update --noninteractive` output. "planned" rows are
// the numbered transaction table (their count is the app total); "op" rows
// are the work actually happening.
function parseFlatpakRunLine(line) {
    var text = String(line || "").replace(/\r/g, "");
    var op = text.match(/^(Updating|Installing|Uninstalling) +(app|runtime)\/([^\/\s]+)/);
    if (op) {
        return {
            kind: "op",
            verb: op[1] === "Updating" ? "up"
                : op[1] === "Installing" ? "add" : "del",
            runtime: op[2] === "runtime",
            name: flatpakRefName(op[3])
        };
    }
    var planned = text.match(/^ *([0-9]+)\.[ \t]/);
    if (planned)
        return { kind: "planned", n: parseInt(planned[1], 10) };
    return null;
}

// Combined chip percentage across both package streams; -1 until either
// stream has a real denominator, which the chip renders as indeterminate.
function runPercent(dnfCur, dnfTotal, fpCur, fpTotal) {
    var total = Math.max(0, dnfTotal || 0) + Math.max(0, fpTotal || 0);
    if (total <= 0)
        return -1;
    var cur = Math.min(dnfCur || 0, dnfTotal || 0)
        + Math.min(fpCur || 0, fpTotal || 0);
    return Math.max(0, Math.min(100, Math.round(cur * 100 / total)));
}

// The version worth a reboot hint, short enough to say out loud: the first
// kernel the transaction installed, as "7.1.9" rather than the full NEVRA.
function kernelHint(name, verb, version) {
    if (name !== "kernel" && name !== "kernel-core")
        return "";
    if (verb !== "add" && verb !== "up")
        return "";
    return String(version || "").split("-")[0];
}

var REBOOT_RECOMMENDATIONS = [
    "pending", "checking", "recommended", "not-needed", "unavailable"
];

// Machine status is durable and may predate the fields this client knows.
// Unknown or missing values are uncertainty, never an inferred negative.
function normalizedRebootRecommendation(value) {
    return REBOOT_RECOMMENDATIONS.indexOf(value) !== -1
        ? value : "unavailable";
}

function rebootLabel(recommendation, kernelVersion) {
    var state = normalizedRebootRecommendation(recommendation);
    if (state === "recommended") {
        var kernel = String(kernelVersion || "");
        return "Reboot recommended"
            + (kernel !== "" ? " · Kernel " + kernel + " installed" : "");
    }
    if (state === "not-needed")
        return "No reboot recommended";
    return "Couldn’t determine whether a reboot is recommended";
}

// The line a failure banner leads with: the last line of the tail that names
// a problem, clipped so a stack of context cannot take over the panel.
function failureHeadline(lines) {
    var list = Array.isArray(lines) ? lines : [];
    for (var i = list.length - 1; i >= 0; i--) {
        var line = String(list[i]).trim();
        if (/error|failed|cannot|unable|not authorized|no space/i.test(line))
            return line.length > 96 ? line.slice(0, 95) + "…" : line;
    }
    return "";
}

// Log directory stamp, matching the update script's `date +%Y%m%d-%H%M%S` so
// both entry points shelve their logs the same way.
function logStamp(date) {
    function pad(value) {
        return (value < 10 ? "0" : "") + value;
    }
    return "" + date.getFullYear() + pad(date.getMonth() + 1)
        + pad(date.getDate()) + "-" + pad(date.getHours())
        + pad(date.getMinutes()) + pad(date.getSeconds());
}

// A log read is a snapshot of one run at one byte offset. Process callbacks
// can arrive after the coordinator has discovered a newer durable run, so a
// successful exit alone is not enough: accepting stale bytes would mix two
// transactions and advancing the new run's offset would permanently skip its
// opening lines.
function acceptsLogRead(activeRun, activeOffset, targetRun, sourceOffset,
        targetOffset, exitSeen, exitCode) {
    return !!exitSeen && exitCode === 0 && targetRun !== ""
        && targetRun === activeRun && sourceOffset === activeOffset
        && targetOffset > sourceOffset;
}

// A status subprocess can outlive the UI action that launched it. In
// particular, retrying a terminal run must not let the prior run's last status
// replace the response from `start`. The caller increments its generation for
// every local start/dismiss boundary and suppresses polling while start owns
// discovery of the durable run id.
function acceptsStatusResponse(activeGeneration, requestGeneration,
        startPending, exitSeen, exitCode) {
    return !startPending && !!exitSeen && exitCode === 0
        && requestGeneration === activeGeneration;
}

// Older release updaters only expose curl's status line. Keep the affected
// source and the likely remedy visible instead of a bare HTTP error.
function projectCheckError(message) {
    if (/curl:.*(?:error:|returned error:) 403/.test(message))
        return "CybexOS: GitHub refused the release check (HTTP 403). Its API may be rate limited; try again later.";
    if (/curl:.*(?:error:|returned error:) 404/.test(message))
        return "CybexOS: GitHub found no published release (HTTP 404), or the repository is inaccessible.";
    return "CybexOS: " + message;
}

var exported = {
    firmwareNames: firmwareNames,
    projectCheckError: projectCheckError,
    dnfNames: dnfNames,
    flatpakNames: flatpakNames,
    CHECK_SOURCES: CHECK_SOURCES,
    allParts: allParts,
    failedParts: failedParts,
    shouldNotify: shouldNotify,
    pendingSummary: pendingSummary,
    dnfSection: dnfSection,
    dnfTableRow: dnfTableRow,
    parseDnfRunLine: parseDnfRunLine,
    rowMatchesToken: rowMatchesToken,
    addPendingRow: addPendingRow,
    takePendingRow: takePendingRow,
    postRunRetryNeeded: postRunRetryNeeded,
    checkIsFresh: checkIsFresh,
    dnfSignature: dnfSignature,
    DNF_ANSWER_MAX_AGE_MS: DNF_ANSWER_MAX_AGE_MS,
    dnfAnswerReusable: dnfAnswerReusable,
    flatpakRefName: flatpakRefName,
    parseFlatpakRunLine: parseFlatpakRunLine,
    runPercent: runPercent,
    kernelHint: kernelHint,
    normalizedRebootRecommendation: normalizedRebootRecommendation,
    rebootLabel: rebootLabel,
    failureHeadline: failureHeadline,
    logStamp: logStamp,
    acceptsLogRead: acceptsLogRead,
    acceptsStatusResponse: acceptsStatusResponse
};

if (typeof module !== "undefined" && module.exports)
    module.exports = exported;
