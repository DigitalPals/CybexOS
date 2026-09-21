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

// Only a complete zero -> positive transition after a known baseline is news.
// A failed first attempt must not turn the first successful snapshot into a
// notification for updates that may have been pending before login.
function shouldNotify(complete, hasBaseline, previousTotal, nextTotal, enabled) {
    return !!complete && !!hasBaseline && previousTotal === 0
        && nextTotal > 0 && !!enabled;
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
    shouldNotify: shouldNotify,
    dnfSection: dnfSection,
    dnfTableRow: dnfTableRow,
    parseDnfRunLine: parseDnfRunLine,
    rowMatchesToken: rowMatchesToken,
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
