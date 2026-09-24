// Pure helpers for turning a finished child process into shell state: why a
// command failed, and the JSON shapes the shell reads back from `ip` and
// `tailscale`. Keep this file free of Qt APIs so the same logic stays
// testable under Node.
//
// The QML side of the contract (verified against a live Quickshell 0.2.1
// instance): for one run, StdioCollector.streamFinished fires for stdout and
// stderr *before* Process.exited, and Process.runningChanged(false) fires
// last — so a handler on the falling edge of `running` sees everything. When
// the binary cannot be launched at all, only that falling edge arrives:
// there is no exited() and no stream, so callers pass NOT_STARTED as the
// exit code for that case.

// No exited() was seen: the command never ran (missing binary, permissions).
var NOT_STARTED = -1;

// curl exit codes this shell can actually hit. `curl -sf` reports every
// failure through its status alone — -s silences the error text and -f turns
// an HTTP error into an empty body — so without this map a failed fetch has
// nothing to say for itself.
var CURL_EXIT = {
    5: "could not reach the proxy",
    6: "could not resolve the host",
    7: "could not connect to the host",
    22: "the server rejected the request",
    28: "the request timed out",
    35: "the TLS handshake failed",
    52: "the server sent an empty reply",
    56: "the connection broke mid-transfer",
    60: "the server certificate could not be verified"
};

// Last non-empty line of a command's stderr, clipped so one runaway
// traceback cannot take over a popover. The last line is the useful one for
// the multi-line case this shell actually has — a Python traceback ends with
// the exception — where a first-line rule would only report "Traceback
// (most recent call last):".
function lastLine(text, limit) {
    if (typeof text !== "string")
        return "";
    var lines = text.split("\n");
    for (var i = lines.length - 1; i >= 0; i--) {
        var line = lines[i].trim();
        if (line === "")
            continue;
        var max = limit === undefined ? 160 : limit;
        return line.length > max ? line.slice(0, max - 1) + "…" : line;
    }
    return "";
}

// One sentence for why `label` failed. What the command said on stderr wins;
// otherwise a caller-supplied exit-code map (CURL_EXIT) speaks for the silent
// ones, and anything left over falls back to the raw status.
function commandError(label, exitCode, stderrText, exitReasons) {
    var said = lastLine(stderrText);
    if (said !== "")
        return said;
    if (exitCode === NOT_STARTED)
        return label + " could not be started";
    var reason = exitReasons ? exitReasons[exitCode] : undefined;
    if (reason)
        return reason;
    return label + " exited with status " + exitCode;
}

function parseJson(text) {
    if (typeof text !== "string" || text.trim() === "")
        return undefined;
    try {
        return JSON.parse(text);
    } catch (e) {
        return undefined;
    }
}

// First IPv4 address in `ip -j -4 addr show <device>` output, or "" when the
// device has none yet. Replaces a `… | jq -r '.[0].addr_info[0].local'`
// pipeline, so it deliberately reads the same first address — it only skips
// entries that are not `inet`, which `-4` should have excluded anyway.
function firstIpv4(text) {
    var links = parseJson(text);
    if (!Array.isArray(links))
        return "";
    for (var i = 0; i < links.length; i++) {
        var addresses = links[i] && links[i].addr_info;
        if (!Array.isArray(addresses))
            continue;
        for (var j = 0; j < addresses.length; j++) {
            var entry = addresses[j];
            if (entry && entry.family === "inet" && typeof entry.local === "string" && entry.local !== "")
                return entry.local;
        }
    }
    return "";
}

// Peer rows for the Tailscale popover from `tailscale status --json`, online
// first then alphabetical. Returns null — never an empty list — when the text
// is not that document, so an unreadable status cannot pass for an empty
// tailnet.
function tailscalePeers(text) {
    var status = parseJson(text);
    if (!status || typeof status !== "object" || Array.isArray(status))
        return null;
    var peers = status.Peer;
    if (peers === undefined || peers === null)
        peers = {};
    if (typeof peers !== "object" || Array.isArray(peers))
        return null;
    var list = Object.keys(peers).map(function (key) {
        var peer = peers[key] || {};
        return {
            name: String(peer.DNSName || peer.HostName || "?").split(".")[0],
            online: !!peer.Online,
            ip: peer.TailscaleIPs && peer.TailscaleIPs[0] || "",
            os: peer.OS || "",
            exitOption: !!peer.ExitNodeOption,
            exit: !!peer.ExitNode
        };
    });
    list.sort(function (a, b) {
        return (b.online - a.online) || a.name.localeCompare(b.name);
    });
    return list;
}

// This machine's own entry in the same `tailscale status --json` body, so
// one run answers both "am I on the tailnet" and "who else is". Null for
// output that cannot be read, which the caller must tell apart from a
// readable status that simply says the backend is stopped — otherwise a dead
// tailscaled would render identically to a deliberate `tailscale down`.
function tailscaleSelf(text) {
    var status = parseJson(text);
    if (!status || typeof status !== "object" || Array.isArray(status))
        return null;
    var self = status.Self;
    if (self === undefined || self === null)
        self = {};
    if (typeof self !== "object" || Array.isArray(self))
        return null;
    return {
        running: status.BackendState === "Running",
        backendState: String(status.BackendState || ""),
        host: String(self.HostName || ""),
        net: String(status.MagicDNSSuffix || ""),
        ip: self.TailscaleIPs && self.TailscaleIPs[0] || "",
        exitNode: !!(status.ExitNodeStatus && status.ExitNodeStatus.Online)
    };
}

var exported = {
    NOT_STARTED: NOT_STARTED,
    CURL_EXIT: CURL_EXIT,
    lastLine: lastLine,
    commandError: commandError,
    firstIpv4: firstIpv4,
    tailscalePeers: tailscalePeers,
    tailscaleSelf: tailscaleSelf
};

if (typeof module !== "undefined" && module.exports)
    module.exports = exported;
