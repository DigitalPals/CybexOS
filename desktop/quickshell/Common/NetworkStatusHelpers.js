// Pure parsing for Common/NetworkStatus.qml. `nmcli --get-values STATE`
// deliberately uses NetworkManager's overall state: unlike the state of one
// device, it only says "connected" when the machine has global connectivity.

function onlineState(text) {
    if (typeof text !== "string")
        return null;

    var state = text.trim().toLowerCase();
    if (state === "connected" || state === "connected (global)")
        return true;

    var offline = [
        "unknown",
        "asleep",
        "disconnected",
        "disconnecting",
        "connecting",
        "connected (local only)",
        "connected (site only)"
    ];
    return offline.indexOf(state) !== -1 ? false : null;
}

// One slow or failed `nmcli general status` says more about nmcli than about
// the network. Flipping `online` off and back on for it restarts every
// consumer's online work (a full update check, a weather refetch), so a known
// state survives until this many failures in a row.
var FAILURES_BEFORE_UNKNOWN = 2;

// Whether the previous state should outlive this failed read. `failures`
// counts consecutive failures including the current one.
function holdsKnownState(known, failures) {
    return known === true && failures < FAILURES_BEFORE_UNKNOWN;
}

// `nmcli monitor` restart pacing. NetworkManager restarting is the normal
// reason the monitor ends, and it should reattach quickly; a monitor that
// cannot start at all (nmcli missing, D-Bus refused) must not respawn every
// five seconds forever. A run lasting HEALTHY_RUN_MS resets the backoff.
var MONITOR_RESTART_MIN_MS = 5000;
var MONITOR_RESTART_MAX_MS = 60000;
var MONITOR_HEALTHY_RUN_MS = 60000;

// Consecutive short runs after a run that has just ended, `ranMs` long.
function monitorShortRuns(previousShortRuns, ranMs) {
    var previous = Math.max(0, Math.floor(Number(previousShortRuns) || 0));
    var ran = Number(ranMs);
    return isFinite(ran) && ran >= MONITOR_HEALTHY_RUN_MS ? 1 : previous + 1;
}

// 5 s, 10 s, 20 s, 40 s, then 60 s for as long as the runs stay short.
function monitorRestartDelay(shortRuns) {
    var runs = Math.max(1, Math.floor(Number(shortRuns) || 0));
    return Math.min(MONITOR_RESTART_MAX_MS,
        MONITOR_RESTART_MIN_MS * Math.pow(2, Math.min(runs - 1, 16)));
}

var exported = {
    onlineState: onlineState,
    FAILURES_BEFORE_UNKNOWN: FAILURES_BEFORE_UNKNOWN,
    holdsKnownState: holdsKnownState,
    MONITOR_RESTART_MIN_MS: MONITOR_RESTART_MIN_MS,
    MONITOR_RESTART_MAX_MS: MONITOR_RESTART_MAX_MS,
    MONITOR_HEALTHY_RUN_MS: MONITOR_HEALTHY_RUN_MS,
    monitorShortRuns: monitorShortRuns,
    monitorRestartDelay: monitorRestartDelay
};

if (typeof module !== "undefined" && module.exports)
    module.exports = exported;
