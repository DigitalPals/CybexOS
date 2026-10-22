// Pure parsing and formatting helpers for Common/SysInfo.qml. Keep this file
// free of Qt APIs so kernel/file fixtures can exercise the exact runtime logic
// under Node as well as QML.

function decodeOsReleaseValue(raw) {
    if (typeof raw !== "string")
        return null;
    var value = raw.trim();
    if (value === "")
        return "";

    var quote = value[0];
    var quoted = quote === "\"" || quote === "'";
    if (quoted) {
        if (value.length < 2 || value[value.length - 1] !== quote)
            return null;
        value = value.slice(1, -1);
        // Single-quoted os-release values are literal. Double-quoted and
        // unquoted values use a backslash to preserve the following byte.
        if (quote === "'")
            return value;
    }

    var decoded = "";
    for (var i = 0; i < value.length; i++) {
        if (value[i] !== "\\") {
            decoded += value[i];
            continue;
        }
        if (i + 1 >= value.length)
            return null;
        decoded += value[++i];
    }
    return decoded;
}

function parseOsRelease(text) {
    var fields = {};
    if (typeof text === "string") {
        var lines = text.split("\n");
        for (var i = 0; i < lines.length; i++) {
            var line = lines[i].trim();
            if (line === "" || line[0] === "#")
                continue;
            var match = line.match(/^([A-Z][A-Z0-9_]*)=(.*)$/);
            if (!match)
                continue;
            var value = decodeOsReleaseValue(match[2]);
            if (value !== null)
                fields[match[1]] = value;
        }
    }
    return {
        id: fields.ID || "",
        name: fields.NAME || "",
        version: fields.VERSION_ID || fields.VERSION || "",
        variant: fields.VARIANT || ""
    };
}

// Linux reports guest and guest_nice after steal, but those counters are
// already included in user and nice. Aggregate only the first eight fields so
// virtualized CPU time is not counted twice.
function parseCpuStat(text) {
    if (typeof text !== "string")
        return null;
    var line = text.split("\n")[0].trim();
    var parts = line.split(/\s+/);
    if (parts[0] !== "cpu" || parts.length < 5)
        return null;

    var counters = [];
    for (var i = 1; i <= 8; i++) {
        var raw = i < parts.length ? parts[i] : "0";
        if (!/^\d+$/.test(raw))
            return null;
        var counter = Number(raw);
        if (!Number.isFinite(counter) || counter < 0)
            return null;
        counters.push(counter);
    }

    var total = counters.reduce(function (sum, counter) {
        return sum + counter;
    }, 0);
    return {
        total: total,
        idle: counters[3] + counters[4]
    };
}

function cpuUsage(previous, current) {
    if (!previous || !current)
        return null;
    var totalDelta = current.total - previous.total;
    var idleDelta = current.idle - previous.idle;
    if (!Number.isFinite(totalDelta) || !Number.isFinite(idleDelta)
            || totalDelta <= 0 || idleDelta < 0 || idleDelta > totalDelta)
        return null;
    return Math.max(0, Math.min(100,
        (totalDelta - idleDelta) / totalDelta * 100));
}

function parseCpuModel(text) {
    if (typeof text !== "string")
        return "";
    var match = text.match(/^model name\s*:\s*(.+)$/m);
    return match ? match[1].trim().replace(/\s+/g, " ") : "";
}

function parseMemInfo(text) {
    var fields = {};
    if (typeof text === "string") {
        var lines = text.split("\n");
        for (var i = 0; i < lines.length; i++) {
            var match = lines[i].match(/^([A-Za-z_()]+):\s+(\d+)\s+(\S+)\s*$/);
            if (!match)
                continue;
            fields[match[1]] = {
                value: Number(match[2]),
                unit: match[3]
            };
        }
    }

    function kib(name) {
        var field = fields[name];
        if (!field || field.unit !== "kB" || !Number.isFinite(field.value))
            return null;
        return field.value * 1024;
    }

    var memTotal = kib("MemTotal");
    var memAvailable = kib("MemAvailable");
    var memKnown = memTotal !== null && memTotal > 0
        && memAvailable !== null && memAvailable >= 0
        && memAvailable <= memTotal;
    var memUsed = memKnown ? memTotal - memAvailable : 0;

    var swapTotal = kib("SwapTotal");
    var swapFree = kib("SwapFree");
    var swapKnown = swapTotal !== null && swapTotal >= 0
        && swapFree !== null && swapFree >= 0 && swapFree <= swapTotal;
    var swapUsed = swapKnown ? swapTotal - swapFree : 0;

    return {
        memKnown: memKnown,
        memTotalBytes: memKnown ? memTotal : 0,
        memUsedBytes: memUsed,
        memUsage: memKnown ? memUsed / memTotal * 100 : 0,
        swapKnown: swapKnown,
        swapTotalBytes: swapKnown ? swapTotal : 0,
        swapUsedBytes: swapUsed,
        swapUsage: swapKnown && swapTotal > 0 ? swapUsed / swapTotal * 100 : 0
    };
}

function parseDf(text) {
    if (typeof text !== "string")
        return null;
    var lines = text.split("\n").map(function (line) {
        return line.trim();
    }).filter(function (line) {
        return line !== "";
    });
    if (lines.length !== 2
            || !/^Type\s+1B-blocks\s+Used\s+Avail\s+Use%\s+Mounted on$/.test(lines[0]))
        return null;

    var match = lines[1].match(/^(\S+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)%\s+(\S+)$/);
    if (!match || match[6] !== "/")
        return null;
    var total = Number(match[2]);
    var used = Number(match[3]);
    var available = Number(match[4]);
    var usage = Number(match[5]);
    if (![total, used, available, usage].every(Number.isFinite)
            || total <= 0 || used < 0 || used > total
            || available < 0 || available > total
            || usage < 0 || usage > 100)
        return null;

    return {
        type: match[1],
        totalBytes: total,
        usedBytes: used,
        availableBytes: available,
        usage: usage
    };
}

function parseUptime(text) {
    if (typeof text !== "string")
        return null;
    var match = text.trim().match(/^(\d+(?:\.\d+)?)\s+/);
    if (!match)
        return null;
    var seconds = Number(match[1]);
    return Number.isFinite(seconds) && seconds >= 0 ? Math.floor(seconds) : null;
}

function formatIecBytes(bytes) {
    var value = Number(bytes);
    if (!Number.isFinite(value) || value < 0)
        return "Unavailable";
    var units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB", "EiB"];
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
        value /= 1024;
        unit++;
    }
    if (unit === 0)
        return Math.round(value) + " B";
    var rounded = value.toFixed(1).replace(/\.0$/, "");
    return rounded + " " + units[unit];
}

function formatUptime(seconds) {
    var value = Number(seconds);
    if (!Number.isFinite(value) || value < 0)
        return "Unavailable";
    var minutes = Math.floor(value / 60);
    var days = Math.floor(minutes / (24 * 60));
    var hours = Math.floor(minutes / 60) % 24;
    var mins = minutes % 60;
    var parts = [];
    if (days > 0)
        parts.push(days + "d");
    if (hours > 0)
        parts.push(hours + "h");
    if (mins > 0 || parts.length === 0)
        parts.push(mins + "m");
    return parts.join(" ");
}

// Delay to the next moment a whole-minute countdown to `untilMs` changes
// its label (a multiple of a minute before the deadline), or to the deadline
// itself. A small margin puts the tick just past the boundary; the caller
// recomputes from the clock, so an early firing only costs one short tick.
function countdownTickMs(untilMs, nowMs) {
    var remaining = Number(untilMs) - Number(nowMs);
    if (!isFinite(remaining))
        return 60000;
    if (remaining <= 0)
        return 1;
    var step = remaining % 60000;
    return (step === 0 ? 60000 : step) + 50;
}

var exported = {
    decodeOsReleaseValue: decodeOsReleaseValue,
    parseOsRelease: parseOsRelease,
    parseCpuStat: parseCpuStat,
    cpuUsage: cpuUsage,
    parseCpuModel: parseCpuModel,
    parseMemInfo: parseMemInfo,
    parseDf: parseDf,
    parseUptime: parseUptime,
    formatIecBytes: formatIecBytes,
    formatUptime: formatUptime,
    countdownTickMs: countdownTickMs
};

if (typeof module !== "undefined" && module.exports)
    module.exports = exported;
