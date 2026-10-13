// Pure presentation/validation helpers, also exercised by Node fixtures.
var METRICS = [
    { value: "cpu", label: "CPU utilization" },
    { value: "load", label: "Load average" },
    { value: "memory", label: "Memory used (%)" },
    { value: "memoryUsed", label: "Memory used" },
    { value: "memoryFree", label: "Memory available" },
    { value: "disk", label: "Storage used (%)" },
    { value: "diskFree", label: "Storage free" },
    { value: "rx", label: "Network download" },
    { value: "tx", label: "Network upload" },
    { value: "temperature", label: "Temperature (hottest sensor)" }
];

// The dashboard's reading tiles, in order. Each also selects the history
// shown beneath them; storage shows its filesystems instead of a chart.
var VIEWS = [
    { value: "cpu", label: "CPU" },
    { value: "memory", label: "Memory" },
    { value: "storage", label: "Storage" },
    { value: "temperature", label: "Temp" }
];
// Warning and critical thresholds. Load is judged per logical CPU.
var LIMITS = { percent: [85, 95], celsius: [75, 90] };

function known(value) { return typeof value === "number" && isFinite(value); }
function percent(value) { return known(value) ? Math.round(value) + "%" : "—"; }
function bytes(value) {
    if (!known(value)) return "—";
    var units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"];
    var index = 0;
    while (value >= 1024 && index < units.length - 1) { value /= 1024; index++; }
    return value.toFixed(index > 0 && value < 100 ? 1 : 0) + " " + units[index];
}
function rate(value) { return known(value) ? bytes(value) + "/s" : "—"; }
function compactRate(value) {
    if (!known(value)) return "—";
    var units = ["B", "K", "M", "G", "T"];
    var index = 0;
    while (value >= 1000 && index < units.length - 1) { value /= 1024; index++; }
    return (index > 0 && value < 10 ? value.toFixed(1) : Math.round(value)) + " " + units[index] + "/s";
}
function ago(ms) {
    if (!known(ms) || ms < 0) return "";
    var seconds = Math.floor(ms / 1000);
    if (seconds < 5) return "just now";
    if (seconds < 60) return seconds + "s ago";
    var minutes = Math.floor(seconds / 60);
    if (minutes < 60) return minutes + " min ago";
    var hours = Math.floor(minutes / 60);
    return hours < 24 ? hours + " h ago" : Math.floor(hours / 24) + " d ago";
}
function uptime(seconds) {
    if (!known(seconds)) return "—";
    var hours = Math.floor(seconds / 3600);
    return hours >= 24 ? Math.floor(hours / 24) + "d " + hours % 24 + "h" : hours + "h " + Math.floor(seconds / 60) % 60 + "m";
}
function memoryPercent(sample) {
    var m = sample && sample.memory;
    return m && m.total > 0 && known(m.used) ? 100 * m.used / m.total : null;
}
function disk(sample, mount) {
    return sample ? sample.storage.find(function(d) { return d.mount === mount; }) || null : null;
}
function network(sample, name) {
    if (!sample) return null;
    // Prefer the default route, avoiding double counting bridges/bonds and
    // their members. Fall back to an addressed interface if no route exists.
    if (name) return sample.network.find(function(n) { return n.name === name; }) || null;
    var primary = sample.network.find(function(n) { return n.name === sample.meta.defaultInterface; });
    if (primary) return primary;
    return sample.network.slice().sort(function(a, b) {
        var address = Number(b.addresses.length > 0) - Number(a.addresses.length > 0);
        return address || (b.rx || 0) + (b.tx || 0) - (a.rx || 0) - (a.tx || 0);
    })[0] || null;
}
function temperature(sample) {
    var values = sample ? sample.temperatures.map(function(t) { return t.celsius; }).filter(known) : [];
    return values.length ? Math.max.apply(null, values) : null;
}
function level(value, kind) {
    if (!known(value)) return "unknown";
    var limits = LIMITS[kind] || LIMITS.percent;
    return value >= limits[1] ? "critical" : value >= limits[0] ? "warn" : "ok";
}
// The level of whatever the menubar shows, so the chip can warn in place.
function metricLevel(sample, options) {
    if (!sample) return "unknown";
    var storage = disk(sample, options.mount);
    switch (options.metric) {
    case "load": return sample.meta.cores > 0 ? level(100 * sample.load[0] / sample.meta.cores) : "unknown";
    case "memory": case "memoryUsed": case "memoryFree": return level(memoryPercent(sample));
    case "disk": case "diskFree": return level(storage ? storage.percent : null);
    case "temperature": return level(temperature(sample), "celsius");
    case "rx": case "tx": return "ok";
    default: return level(sample.cpu);
    }
}
// Open the dashboard on the reading the menubar summarises.
function viewFor(metric) {
    switch (metric) {
    case "memory": case "memoryUsed": case "memoryFree": return "memory";
    case "disk": case "diskFree": return "storage";
    case "temperature": return "temperature";
    default: return "cpu";
    }
}
function summary(points) {
    var values = points.map(function(p) { return p.value; }).filter(known);
    if (!values.length) return null;
    var total = values.reduce(function(sum, v) { return sum + v; }, 0);
    return { average: total / values.length, peak: Math.max.apply(null, values),
        low: Math.min.apply(null, values) };
}
// The window a history chart shows: the whole minutes collected so far,
// between two and ten, so a young history is not a sliver at the right edge.
function chartSpan(elapsed) {
    var minutes = Math.ceil((known(elapsed) && elapsed > 0 ? elapsed : 0) / 60000);
    return Math.max(2, Math.min(10, minutes)) * 60000;
}
// A rate chart's top edge: the next power of two above the peak, so the
// scale reads in whole binary units and only moves when traffic really does.
function chartCeiling(peak) {
    if (!known(peak) || peak <= 1024) return 1024;
    return Math.pow(2, Math.ceil(Math.log(peak) / Math.LN2 - 1e-9));
}
// Firmware variable stores are not storage anyone manages.
var PSEUDO_FILESYSTEMS = ["efivarfs"];
// One row per filesystem: bind mounts of one device (container config mounts,
// for example) collapse into its shortest mount path unless one of them is
// the selected mount. The selected filesystem leads, then the fullest.
function storageRows(sample, mount) {
    if (!sample) return [];
    var rows = [];
    var byDevice = {};
    sample.storage.forEach(function(d) {
        if (PSEUDO_FILESYSTEMS.indexOf(d.type) >= 0 && d.mount !== mount) return;
        var key = d.device ? d.type + ":" + d.device + ":" + d.total : null;
        var index = key !== null && Object.prototype.hasOwnProperty.call(byDevice, key) ? byDevice[key] : -1;
        if (index < 0) {
            if (key !== null) byDevice[key] = rows.length;
            rows.push(d);
        } else if (rows[index].mount !== mount
                && (d.mount === mount || d.mount.length < rows[index].mount.length)) {
            rows[index] = d;
        }
    });
    return rows.sort(function(a, b) {
        return Number(b.mount === mount) - Number(a.mount === mount) || b.percent - a.percent
            || (a.mount < b.mount ? -1 : a.mount > b.mount ? 1 : 0);
    });
}
// Hottest first. Identical chip/label pairs (one per NVMe drive) number their
// chip in reported order, so each row names one sensor: "nvme 2 · Composite".
function sensorRows(sample) {
    if (!sample) return [];
    var seen = {};
    var totals = {};
    sample.temperatures.forEach(function(t) { totals[t.name] = (totals[t.name] || 0) + 1; });
    return sample.temperatures.map(function(t) {
        seen[t.name] = (seen[t.name] || 0) + 1;
        var split = t.name.indexOf(" · ");
        var name = totals[t.name] < 2 ? t.name : split < 0 ? t.name + " " + seen[t.name]
            : t.name.slice(0, split) + " " + seen[t.name] + t.name.slice(split);
        return { name: name, celsius: t.celsius };
    }).sort(function(a, b) { return b.celsius - a.celsius; });
}
// Interfaces worth choosing from: the default route, then addressed ones, then
// the busiest. Unaddressed idle links (veth/tap members) stay at the end.
function interfaceRows(sample) {
    if (!sample) return [];
    var primary = sample.meta.defaultInterface;
    return sample.network.slice().sort(function(a, b) {
        return Number(b.name === primary) - Number(a.name === primary)
            || Number(b.addresses.length > 0) - Number(a.addresses.length > 0)
            || (b.rx || 0) + (b.tx || 0) - (a.rx || 0) - (a.tx || 0)
            || (a.name < b.name ? -1 : a.name > b.name ? 1 : 0);
    });
}
function metric(sample, options) {
    if (!sample) return "—";
    var storage = disk(sample, options.mount);
    var net = network(sample, options.interface);
    switch (options.metric) {
    case "load": return sample.load[0].toFixed(2);
    case "memory": return percent(memoryPercent(sample));
    case "memoryUsed": return bytes(sample.memory.used);
    case "memoryFree": return bytes(sample.memory.available);
    case "disk": return percent(storage ? storage.percent : null);
    case "diskFree": return bytes(storage ? storage.free : null);
    case "rx": return "↓ " + rate(net ? net.rx : null);
    case "tx": return "↑ " + rate(net ? net.tx : null);
    case "temperature": return known(temperature(sample)) ? Math.round(temperature(sample)) + "°C" : "—";
    default: return percent(sample.cpu);
    }
}
function validSample(s) {
    return !!s && s.version === 1 && typeof s.boot === "string"
        && known(s.uptime) && (s.cpu === null || known(s.cpu))
        && s.meta && typeof s.meta.hostname === "string" && typeof s.meta.os === "string"
        && Array.isArray(s.load) && s.load.length === 3 && s.load.every(known)
        && s.memory && known(s.memory.total) && (s.memory.used === null || known(s.memory.used))
        && (s.memory.available === null || known(s.memory.available))
        && Array.isArray(s.perCore) && s.perCore.every(function(c) { return c === null || known(c); })
        && Array.isArray(s.storage) && s.storage.every(function(d) {
            return typeof d.mount === "string" && known(d.total) && known(d.free) && known(d.percent);
        })
        && Array.isArray(s.network) && s.network.every(function(n) {
            return typeof n.name === "string" && Array.isArray(n.addresses)
                && (n.rx === null || known(n.rx)) && (n.tx === null || known(n.tx));
        })
        && Array.isArray(s.temperatures) && s.temperatures.every(function(t) {
            return typeof t.name === "string" && known(t.celsius);
        });
}
function historyAppend(history, sample, now) {
    var previous = history.length ? history[history.length - 1] : null;
    var next = previous && (previous.boot !== sample.boot || now - previous.at > 90000) ? [] : history;
    // Bound both time and memory. Each point keeps interface rates separately,
    // so changing the selected interface doesn't relabel somebody else's graph.
    return next.filter(function(p) { return now - p.at < 600000; }).concat([{
        at: now, boot: sample.boot, cpu: sample.cpu, memory: memoryPercent(sample),
        temperature: temperature(sample), network: sample.network
    }]).slice(-300);
}
if (typeof module !== "undefined" && module.exports)
    module.exports = { METRICS, VIEWS, LIMITS, known, percent, bytes, rate, compactRate, ago, uptime,
        memoryPercent, disk, network, temperature, level, metricLevel, viewFor, summary, chartSpan, chartCeiling,
        storageRows, sensorRows, interfaceRows, metric, validSample, historyAppend };
