// Pure presentation helpers for the dedicated battery view. UPower remains
// the source of truth in QML; this module only gives its telemetry stable,
// testable text and turns the one-shot sysfs cycle read into one value.
// Keep this file free of Qt APIs so the same edge cases run under Node.

var MISSING = "—";

function finiteNumber(value) {
    if (value === undefined || value === null || typeof value === "boolean")
        return NaN;
    if (typeof value === "string" && value.trim() === "")
        return NaN;
    var number = Number(value);
    return isFinite(number) ? number : NaN;
}

// Capacity cannot meaningfully be zero. A fixed decimal keeps this column
// from changing width as the backend settles on its final floating value.
function formatWh(value) {
    var number = finiteNumber(value);
    return number > 0 ? number.toFixed(1) + " Wh" : MISSING;
}

// UPower signs changeRate by direction. This panel labels direction with its
// state text, so the telemetry value is deliberately magnitude-only. Zero is
// useful at full charge and must remain distinct from a missing reading.
function formatW(value) {
    var number = finiteNumber(value);
    return isFinite(number) ? Math.abs(number).toFixed(1) + " W" : MISSING;
}

function pad2(value) {
    return value < 10 ? "0" + value : String(value);
}

function formatDuration(seconds) {
    var number = finiteNumber(seconds);
    if (!(number > 0))
        return MISSING;
    var totalMinutes = Math.max(1, Math.round(number / 60));
    var hours = Math.floor(totalMinutes / 60);
    var minutes = totalMinutes % 60;
    return hours > 0 ? hours + " h " + pad2(minutes) + " min"
        : totalMinutes + " min";
}

// The process emits one line per lexically sorted BAT*/cycle_count file.
// Preserve malformed positions as an em dash: on a two-pack machine, one bad
// counter must not make the other pack look like the only battery installed.
function parseCycleCounts(output) {
    if (typeof output !== "string")
        return MISSING;

    var lines = output.replace(/\r/g, "").split("\n");
    while (lines.length > 0 && lines[lines.length - 1] === "")
        lines.pop();
    if (lines.length === 0)
        return MISSING;

    return lines.map(function (line) {
        var value = line.trim();
        if (!/^\d+$/.test(value))
            return MISSING;
        return String(parseInt(value, 10));
    }).join(" · ");
}

function parseBoolean(value) {
    return value === "true" ? true : value === "false" ? false : null;
}

function parseThreshold(value) {
    if (value === "-1")
        return null;
    if (!/^\d+$/.test(value))
        return undefined;
    var number = parseInt(value, 10);
    return number <= 100 ? number : undefined;
}

// scripts/battery-health prints one tab-separated row per physical system
// battery. Treat the entire snapshot as invalid if even one row is malformed:
// a partially parsed multi-pack laptop must not look safely configurable.
function parseChargeThresholdStatus(output) {
    if (typeof output !== "string")
        return null;

    var trimmed = output.trim();
    if (trimmed === "") {
        return {
            batteryCount: 0,
            supportedCount: 0,
            supported: false,
            enabled: false,
            mixed: false,
            batteries: []
        };
    }

    var batteries = [];
    var lines = trimmed.replace(/\r/g, "").split("\n");
    for (var i = 0; i < lines.length; i++) {
        var fields = lines[i].split("\t");
        if (fields.length !== 7 || fields[0] !== "battery"
                || !/^\/org\/freedesktop\/UPower\/devices\/[A-Za-z0-9_]+$/.test(fields[1]))
            return null;

        var supported = parseBoolean(fields[2]);
        var enabled = parseBoolean(fields[3]);
        var start = parseThreshold(fields[4]);
        var end = parseThreshold(fields[5]);
        var settings = /^\d+$/.test(fields[6]) ? parseInt(fields[6], 10) : NaN;
        if (supported === null || enabled === null || start === undefined
                || end === undefined || !isFinite(settings))
            return null;

        batteries.push({
            path: fields[1],
            supported: supported,
            enabled: enabled,
            start: start,
            end: end,
            settings: settings
        });
    }

    var supportedBatteries = batteries.filter(function (battery) {
        return battery.supported;
    });
    var enabledCount = supportedBatteries.filter(function (battery) {
        return battery.enabled;
    }).length;

    return {
        batteryCount: batteries.length,
        supportedCount: supportedBatteries.length,
        // The UI describes a laptop-wide policy, so every system pack must
        // implement it. Peripheral batteries never enter this snapshot.
        supported: batteries.length > 0
            && supportedBatteries.length === batteries.length,
        enabled: supportedBatteries.length > 0
            && enabledCount === supportedBatteries.length,
        mixed: enabledCount > 0 && enabledCount < supportedBatteries.length,
        batteries: batteries
    };
}

function formatChargeLimit(status) {
    if (!status || !status.supported || !Array.isArray(status.batteries))
        return MISSING;

    var limits = [];
    var firmwareLimit = false;
    for (var i = 0; i < status.batteries.length; i++) {
        var battery = status.batteries[i];
        firmwareLimit = firmwareLimit || (battery.settings & 4) !== 0;
        var label = "";
        if (battery.end !== null) {
            label = battery.start !== null && battery.start < battery.end
                ? battery.start + "–" + battery.end + "%"
                : battery.end + "%";
        }
        if (label !== "" && limits.indexOf(label) === -1)
            limits.push(label);
    }

    if (limits.length === 1) {
        return limits[0].indexOf("–") !== -1
            ? "Charge between " + limits[0]
            : "Charge to " + limits[0];
    }
    if (limits.length > 1)
        return "Battery limits " + limits.join(" · ");
    return firmwareLimit ? "Use the firmware charge limit"
        : "Use the system charge limit";
}

var exported = {
    MISSING: MISSING,
    formatWh: formatWh,
    formatW: formatW,
    formatDuration: formatDuration,
    parseCycleCounts: parseCycleCounts,
    parseChargeThresholdStatus: parseChargeThresholdStatus,
    formatChargeLimit: formatChargeLimit
};

if (typeof module !== "undefined" && module.exports)
    module.exports = exported;
