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

// The kernel a pending transaction would bring, as "7.2.7" — the one package
// name worth saying out loud, because it means a restart. check-update lists
// "kernel-core.x86_64  7.2.7-200.fc44  updates".
function dnfKernelVersion(body) {
    var version = "";
    String(body || "").split("\n").some(function (line) {
        var match = line.match(/^kernel(?:-core)?\.[a-z0-9_]+\s+(?:[0-9]+:)?([^\s-]+)/);
        if (match)
            version = match[1];
        return !!match;
    });
    return version;
}

// `dnf advisory list --security --updates --json`: one row per package an
// advisory touches. What matters is whether there are any, and whether one of
// them is serious enough to say so.
function securityAdvisories(body) {
    var rows = JSON.parse(body);
    if (!Array.isArray(rows))
        throw new Error("expected an advisory list");
    var names = [];
    var severe = false;
    rows.forEach(function (row) {
        if (!row || typeof row.name !== "string")
            return;
        if (names.indexOf(row.name) === -1)
            names.push(row.name);
        if (/^(critical|important)$/i.test(String(row.severity || "")))
            severe = true;
    });
    return { count: names.length, severe: severe };
}

// The System row's one line: only what changes what a person does next.
function systemDetail(kernelVersion, securityCount, securitySevere) {
    var parts = [];
    if (kernelVersion)
        parts.push("New kernel " + kernelVersion);
    if (securityCount > 0)
        parts.push(securitySevere ? "Important security fixes" : "Security fixes");
    return parts.join(" · ");
}

// fwupd names Secure Boot key databases after their certificates ("KEK CA",
// "Windows UEFI CA", "UEFI dbx"); nobody recognises those.
function firmwareDisplayName(name) {
    var text = String(name || "").trim();
    if (/^UEFI dbx$/i.test(text))
        return "Secure Boot database";
    if (/^(KEK CA|UEFI CA|Windows UEFI CA|Option ROM UEFI CA)$/i.test(text))
        return "Secure Boot certificates";
    if (/^UEFI Device Firmware$/i.test(text))
        return "Device firmware";
    if (/^System Firmware$/i.test(text))
        return "System firmware";
    return text !== "" ? text : "Firmware";
}

// One device per pending upgrade, from `fwupdmgr get-updates --json`. Counts
// devices, not alternative releases for the same device.
function firmwareDevices(body) {
    const data = JSON.parse(body);
    if (!data || !Array.isArray(data.Devices))
        throw new Error("missing firmware device list");
    return data.Devices.filter(device => Array.isArray(device.Releases)
        && device.Releases.length > 0).map(device => {
        const flags = Array.isArray(device.Flags) ? device.Flags : [];
        const release = device.Releases[0] || {};
        return {
            id: typeof device.DeviceId === "string" ? device.DeviceId : "",
            name: firmwareDisplayName(device.Name),
            from: typeof device.Version === "string" ? device.Version : "",
            to: typeof release.Version === "string" ? release.Version : "",
            needsReboot: flags.indexOf("needs-reboot") !== -1
                || flags.indexOf("needs-shutdown") !== -1,
            requireAc: flags.indexOf("require-ac") !== -1
        };
    });
}

// "System firmware · Secure Boot certificates", each name once.
function firmwareLabel(devices) {
    var names = [];
    (Array.isArray(devices) ? devices : []).forEach(function (device) {
        var name = firmwareDisplayName(device && device.name);
        if (names.indexOf(name) === -1)
            names.push(name);
    });
    return names.join(" · ");
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

// The notification body and the overview line: what is pending, by the names
// the panel's rows use, never an error from a source that did not answer.
function pendingSummary(dnfCount, flatpakCount, firmwareCount, projectAvailable,
        projectVersion) {
    var parts = [];
    if (dnfCount > 0)
        parts.push("System " + dnfCount);
    if (flatpakCount > 0)
        parts.push("Apps " + flatpakCount);
    if (firmwareCount > 0)
        parts.push("Firmware " + firmwareCount);
    if (projectAvailable)
        parts.push("CybexOS " + projectVersion);
    return parts.join(" · ");
}

// Which sources could not be checked, as one sentence. The raw reasons stay
// in the panel's details; the header only needs to say what is unknown.
var SOURCE_NOUNS = {
    dnf: "system updates",
    flatpak: "apps",
    firmware: "firmware",
    project: "CybexOS releases"
};

function checkErrorLabel(errors) {
    var failed = [];
    CHECK_SOURCES.forEach(function (source) {
        if (errors && typeof errors[source] === "string" && errors[source] !== "")
            failed.push(SOURCE_NOUNS[source]);
    });
    if (failed.length === 0)
        return "";
    if (failed.length >= 3)
        return "Couldn’t check for updates";
    var last = failed.pop();
    return "Couldn’t check " + (failed.length > 0
        ? failed.join(", ") + " or " + last : last);
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

// One percentage for the whole run — the chip, the header and the drawer all
// show this number. -1 until any stream has made measurable progress, which
// the chip renders as indeterminate.
//
// Each stream contributes its own fraction, weighted by how much work it
// holds. dnf counts its downloads and then restarts the counter for the
// install, so the two passes are mapped onto one 0–1 range rather than
// letting the chip run to 100% twice. A firmware device is worth several
// packages: writing flash is slow, and it should not flash by as a sliver.
var DNF_DOWNLOAD_SHARE = 0.3;
var FIRMWARE_DEVICE_WEIGHT = 8;

function clampFraction(value) {
    var number = Number(value) || 0;
    return number < 0 ? 0 : number > 1 ? 1 : number;
}

function dnfFraction(state) {
    if (state.dnfDone)
        return 1;
    if (!(state.dnfTotal > 0))
        return 0;
    var pass = clampFraction(state.dnfCur / state.dnfTotal);
    return state.dnfPhase === "installing"
        ? DNF_DOWNLOAD_SHARE + (1 - DNF_DOWNLOAD_SHARE) * pass
        : state.dnfPhase === "downloading" ? DNF_DOWNLOAD_SHARE * pass : 0;
}

function runProgress(state) {
    var s = state || {};
    var parts = [];
    if (s.dnfIncluded !== false)
        parts.push({ weight: Math.max(1, s.dnfTotal || 0, s.dnfPlanned || 0),
            fraction: dnfFraction(s) });
    if (s.fpIncluded)
        parts.push({ weight: Math.max(1, s.fpTotal || 0, s.fpPlanned || 0),
            fraction: s.fpDone ? 1 : s.fpTotal > 0 ? clampFraction(s.fpCur / s.fpTotal) : 0 });
    if (s.fwIncluded) {
        var devices = Math.max(1, s.fwTotal || 0, s.fwPlanned || 0);
        parts.push({ weight: devices * FIRMWARE_DEVICE_WEIGHT,
            fraction: s.fwDone ? 1 : clampFraction(((s.fwCur || 0)
                + clampFraction(s.fwFraction)) / devices) });
    }
    var weight = 0;
    var done = 0;
    parts.forEach(function (part) {
        weight += part.weight;
        done += part.weight * part.fraction;
    });
    if (weight <= 0 || done <= 0)
        return -1;
    // Floor, so 100% means finished; the epsilon absorbs 0.65 * 100 = 64.99….
    return Math.max(0, Math.min(100, Math.floor(done * 100 / weight + 1e-9)));
}

// ---- firmware run ----------------------------------------------------------
// The worker's firmware phase streams one JSON event per line (see
// assets/scripts/cybexos-firmware-update). Anything else is ignored.
function parseFirmwareEvent(line) {
    var text = String(line || "").trim();
    if (text === "" || text.charAt(0) !== "{")
        return null;
    try {
        var event = JSON.parse(text);
        return event && typeof event.event === "string" ? event : null;
    } catch (error) {
        return null;
    }
}

// fwupd's status names (Fwupd.status_to_string) as the row says them.
var FIRMWARE_STATUS_WORDS = {
    "downloading": "Downloading",
    "decompressing": "Preparing",
    "loading": "Preparing",
    "scheduling": "Scheduling",
    "device-read": "Reading",
    "device-erase": "Installing",
    "device-write": "Installing",
    "device-verify": "Verifying",
    "device-restart": "Restarting device",
    "device-busy": "Waiting for the device",
    "waiting-for-auth": "Waiting for authorization",
    "waiting-for-user": "Waiting for you",
    "shutdown": "Finishing"
};

// fwupd restarts its percentage for every stage of one device, so each stage
// owns a slice of that device's bar: the download a fifth, the write most of
// it, verification the end. A status it does not name holds the bar still.
var FIRMWARE_STAGES = {
    "downloading": [0, 0.2],
    "decompressing": [0.2, 0],
    "loading": [0.2, 0],
    "scheduling": [0.2, 0],
    "device-read": [0.2, 0],
    "device-erase": [0.2, 0.1],
    "device-write": [0.3, 0.6],
    "device-verify": [0.9, 0.1],
    "device-restart": [0.9, 0],
    "shutdown": [0.9, 0]
};

function firmwareDeviceFraction(status, percent) {
    if (!FIRMWARE_STAGES.hasOwnProperty(status))
        return 0;
    var stage = FIRMWARE_STAGES[status];
    return stage[0] + stage[1] * clampFraction((Number(percent) || 0) / 100);
}

function firmwareStatusLabel(status, percent) {
    var word = FIRMWARE_STATUS_WORDS.hasOwnProperty(status)
        ? FIRMWARE_STATUS_WORDS[status] : "Starting";
    var withPercent = status === "downloading" || status === "device-write"
        || status === "device-erase" || status === "device-verify";
    return word + (withPercent && percent > 0 ? " · " + Math.round(percent) + "%" : "");
}

// What the header says while the worker runs, from its published phase and
// the package streams' own milestones.
function runPhaseLabel(state) {
    var s = state || {};
    if (s.cancelPending)
        return "Cancelling after this step…";
    switch (s.phase) {
    case "snapshot":
        return "Creating a restore point…";
    case "packages":
        if (!s.dnfDone)
            return s.dnfPhase === "installing" ? "Installing system updates…"
                : s.dnfPhase === "downloading" ? "Downloading system updates…"
                : "Preparing system updates…";
        return s.fpIncluded && !s.fpDone ? "Updating apps…" : "Finishing packages…";
    case "firmware":
        return s.fwStatus === "waiting-for-user" ? "Waiting for you…"
            : "Updating " + (s.fwName ? s.fwName : "firmware") + "…";
    case "tests":
    case "migration":
    case "ansible":
    case "activation":
        return "Applying CybexOS…";
    case "reboot-check":
        return "Finishing up…";
    default:
        return "Starting…";
    }
}

// ---- failure, in words ------------------------------------------------------
// The header of a failed run says what happened and what it means, in one
// sentence. dnf's own words stay one tap away in the details.
var FAILURE_RULES = [
    [/No space left|not enough (free )?(disk )?space|Disk requirements|need .* more space/i,
        "There isn’t enough free disk space."],
    [/not authori[sz]ed|Interactive authentication required|Authentication (failed|required)|Access denied|polkit/i,
        "Authorization was cancelled."],
    [/Could not resolve host|Cannot download|Failed to download|Curl error|Network is unreachable|Cannot load repo|timed out|Timeout was reached/i,
        "Couldn’t reach the update servers. Check your connection."],
    [/GPG|OpenPGP|public key|signature (check|verification)|key import/i,
        "A package signing key couldn’t be verified."],
    [/Problem:|conflicts with|nothing provides|cannot install both|broken dependencies|Transaction test error|Transaction check error/i,
        "Some updates conflict with installed packages. Try again later."],
    [/waiting for (process|lock)|another .* is running|lock.*held|already running/i,
        "Another update is already running."]
];

function friendlyFailure(lines, message, exitCode, phase, notStarted) {
    if (phase === "snapshot") {
        // The snapshot helper refuses while the system runs from a temporary
        // recovery boot or waits for a restored root; say which.
        var reason = (Array.isArray(lines) ? lines : []).concat([String(message || "")])
            .join("\n");
        if (/temporary recovery boot/i.test(reason))
            return "This session runs from a recovery point. Restore it or restart normally before updating.";
        if (/waiting for a restart/i.test(reason))
            return "A restored recovery point is waiting for a restart. Restart before updating.";
        return "Couldn’t create a restore point, so nothing was changed.";
    }
    if (exitCode === notStarted)
        return "The updater couldn’t be started.";
    if (exitCode === 126 || exitCode === 127)
        return "Authorization was cancelled.";
    var text = (Array.isArray(lines) ? lines : []).concat([String(message || "")])
        .join("\n");
    for (var i = 0; i < FAILURE_RULES.length; i++) {
        if (FAILURE_RULES[i][0].test(text))
            return FAILURE_RULES[i][1];
    }
    return phase === "ansible" || phase === "tests" || phase === "migration"
        || phase === "activation"
        ? "CybexOS couldn’t be applied." : "The system update stopped unexpectedly.";
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
    if (state === "recommended")
        return "Restart to finish updating";
    if (state === "not-needed")
        return "No restart needed";
    return "Couldn’t tell whether a restart is needed";
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

// The updater's own reasons arrive as "update: <reason>"; older release
// updaters only expose curl's status line. Keep the affected source and the
// likely remedy visible instead of a bare HTTP error.
function projectCheckError(message) {
    message = String(message).replace(/^update:\s*/, "");
    if (/curl:.*(?:error:|returned error:) 403/.test(message))
        return "CybexOS: GitHub refused the release check (HTTP 403). Its API may be rate limited; try again later.";
    if (/curl:.*(?:error:|returned error:) 404/.test(message))
        return "CybexOS: GitHub found no published release (HTTP 404), or the repository is inaccessible.";
    return "CybexOS: " + message;
}

// Why the CybexOS release step cannot run while packages still can: the
// start record carries it when the step was skipped and the package run went
// ahead; `--check --json` carries it beside a release this machine cannot
// verify yet (gh missing or too old). "" when there is none.
function projectErrorOf(record) {
    if (!record || typeof record.projectError !== "string")
        return "";
    return record.projectError.trim();
}

// A neutral release-check answer from `--check --json`: "no-release" while
// the channel has nothing published yet. Not an error, so it never feeds
// projectError; anything else (including older updaters) is "".
function projectStatusOf(record) {
    var known = ["no-release", "desktop-channel-ready", "desktop-channel-disabled", "desktop-channel-invalid"];
    return record && known.indexOf(record.status) >= 0 ? record.status : "";
}

function projectStatusLabel(status) {
    if (status === "desktop-channel-disabled")
        return "CybexOS desktop updates are not configured";
    if (status === "desktop-channel-invalid")
        return "CybexOS desktop update channel needs repair";
    if (status === "desktop-channel-ready")
        return "CybexOS desktop updates arrive with system packages";
    return status === "no-release" ? "No CybexOS release published yet" : "";
}

function projectSkippedLabel(reason, finished) {
    if (reason === "")
        return "";
    return (finished ? "" : "System update started · ") + "CybexOS skipped: " + reason;
}

// The worker defers a cancellation to its next stopping point. Firmware that
// is being written cannot be stopped either. Once Ansible has started there
// is none: the apply and activation run to completion so
// installed files and the active release stay coherent, and the reboot check
// comes after the last one. A worker from before deferred cancellation
// refuses a stop during its package transaction outright.
var UNCANCELLABLE_PHASES = ["firmware", "ansible", "activation", "reboot-check"];

function cancelAllowed(phase, deferredCancel) {
    if (UNCANCELLABLE_PHASES.indexOf(phase) !== -1)
        return false;
    return phase !== "packages" || deferredCancel === true;
}

// A release apply that stopped after Ansible began leaves newer managed files
// under the previous release (`mixedState` in the run record).
function mixedStateAdvice(mixedState) {
    if (mixedState !== true)
        return "";
    return "Some newer CybexOS files are installed under the previous release. "
        + "Run `cybex update` again once the cause is fixed, or "
        + "~/.local/share/cybexos/current/install to restore the previous release's files.";
}

var exported = {
    dnfKernelVersion: dnfKernelVersion,
    securityAdvisories: securityAdvisories,
    systemDetail: systemDetail,
    firmwareDisplayName: firmwareDisplayName,
    firmwareDevices: firmwareDevices,
    firmwareLabel: firmwareLabel,
    checkErrorLabel: checkErrorLabel,
    projectCheckError: projectCheckError,
    projectErrorOf: projectErrorOf,
    projectStatusOf: projectStatusOf,
    projectStatusLabel: projectStatusLabel,
    projectSkippedLabel: projectSkippedLabel,
    UNCANCELLABLE_PHASES: UNCANCELLABLE_PHASES,
    cancelAllowed: cancelAllowed,
    mixedStateAdvice: mixedStateAdvice,
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
    runProgress: runProgress,
    dnfFraction: dnfFraction,
    parseFirmwareEvent: parseFirmwareEvent,
    firmwareStatusLabel: firmwareStatusLabel,
    firmwareDeviceFraction: firmwareDeviceFraction,
    runPhaseLabel: runPhaseLabel,
    friendlyFailure: friendlyFailure,
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
