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
        at: now, boot: sample.boot, cpu: sample.cpu, memory: memoryPercent(sample), network: sample.network
    }]).slice(-300);
}
if (typeof module !== "undefined" && module.exports)
    module.exports = { METRICS, known, percent, bytes, rate, uptime, memoryPercent, disk, network,
        temperature, metric, validSample, historyAppend };
