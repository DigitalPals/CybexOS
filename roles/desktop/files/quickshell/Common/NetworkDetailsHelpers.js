// Pure helpers for the live metrics in Common/NetworkDetails.qml: kernel byte
// counters read through FileView, and the lines of long-lived `ping -O`
// processes. Device, route and scan parsing stays in NetworkHelpers.js and
// scripts/network-tool.py.

// Same interface grammar as network-tool.py; it keeps a name from escaping
// /sys/class/net.
var INTERFACE_RE = /^[A-Za-z0-9_.:@+-]{1,64}$/;

function counterPath(interfaceName, counter) {
    var name = String(interfaceName || "");
    if (!INTERFACE_RE.test(name) || name === "." || name === "..")
        return "";
    if (counter !== "rx_bytes" && counter !== "tx_bytes")
        return "";
    return "/sys/class/net/" + name + "/statistics/" + counter;
}

function parseCounter(text) {
    var value = String(text === null || text === undefined ? "" : text).trim();
    if (!/^[0-9]+$/.test(value))
        return null;
    var number = Number(value);
    return Number.isFinite(number) ? number : null;
}

// The shape NetworkHelpers.calculateRates expects for one reading.
function counterSample(interfaceName, rxText, txText, timestampMs) {
    return {
        interface: String(interfaceName || ""),
        rxBytes: parseCounter(rxText),
        txBytes: parseCounter(txText),
        timestamp: Number(timestampMs)
    };
}

// The snapshot's device with the live counters when they describe it. The
// device's own rxBytes/txBytes are only as fresh as the last snapshot, which
// no longer runs at the 1.5 second cadence. Returns the same object when
// there is nothing newer, so a binding on it does not churn.
function withCounters(device, interfaceName, sample) {
    if (!device || !sample || sample.interface === ""
            || sample.interface !== String(interfaceName || "")
            || sample.rxBytes === null || sample.txBytes === null)
        return device;
    var merged = {};
    for (var key in device) {
        if (Object.prototype.hasOwnProperty.call(device, key))
            merged[key] = device[key];
    }
    merged.rxBytes = sample.rxBytes;
    merged.txBytes = sample.txBytes;
    return merged;
}

var PING_LOST_RE = /^no answer yet for icmp_seq=([0-9]+)/;
var PING_REPLY_RE = /\bicmp_seq=([0-9]+)\b.*\btime[=<]([0-9]+(?:\.[0-9]+)?)\s*ms/;

// One line of `ping -n -O` output under LC_ALL=C. With -O every probe
// produces exactly one line: its reply, or "no answer yet" when the next
// probe goes out first. Returns { seq, ms } with ms null for a lost probe,
// or null for anything else (the banner, errors, statistics).
function parsePingLine(line) {
    var text = String(line || "");
    var lost = PING_LOST_RE.exec(text);
    if (lost)
        return { seq: Number(lost[1]), ms: null };
    var reply = PING_REPLY_RE.exec(text);
    if (reply)
        return { seq: Number(reply[1]), ms: Number(reply[2]) };
    return null;
}

// icmp_seq is 16 bits on the wire and wraps after 65535.
function seqAfter(seq, lastSeq) {
    if (lastSeq < 0)
        return true;
    var delta = (seq - lastSeq + 65536) % 65536;
    return delta > 0 && delta < 32768;
}

// The sample `line` adds after `lastSeq` (-1 before the first), or null. A
// reply for a probe already counted lost, or a duplicate, adds nothing: the
// old one-shot probe also counted a reply slower than its timeout as lost.
function pingSample(lastSeq, line) {
    var parsed = parsePingLine(line);
    if (!parsed || !seqAfter(parsed.seq, Number(lastSeq)))
        return null;
    return parsed;
}

// Probes a pinger has been silent for since `lastSampleAt`, allowing one
// interval of jitter: 0 until two full intervals have passed.
function missedProbes(lastSampleAt, now, intervalMs) {
    var interval = Number(intervalMs);
    var elapsed = Number(now) - Number(lastSampleAt);
    if (!(interval > 0) || !Number.isFinite(elapsed))
        return 0;
    return Math.max(0, Math.floor(elapsed / interval) - 1);
}

// A numeric IPv4/IPv6 address, which is all NetworkManager reports as a
// gateway; anything else (a hostname, an option-like string, a scoped
// link-local address) is not pinged. Returns the address or "".
var PING_TARGET_RE = /^[0-9A-Fa-f:][0-9A-Fa-f:.]{1,44}$/;

function pingTarget(value) {
    var address = String(value === null || value === undefined ? "" : value);
    return PING_TARGET_RE.test(address) ? address : "";
}

// argv for one long-lived pinger, or null when `target` is not an address.
// LC_ALL=C keeps iputils' translated messages out of the parser.
function pingCommand(target, intervalMs) {
    var address = pingTarget(target);
    if (address === "")
        return null;
    var seconds = Math.max(0.2, Number(intervalMs) / 1000 || 1);
    return ["env", "LC_ALL=C", "ping", "-n", "-O", "-i", String(seconds), "--", address];
}

var exported = {
    counterPath: counterPath,
    parseCounter: parseCounter,
    counterSample: counterSample,
    withCounters: withCounters,
    parsePingLine: parsePingLine,
    seqAfter: seqAfter,
    pingSample: pingSample,
    missedProbes: missedProbes,
    pingTarget: pingTarget,
    pingCommand: pingCommand
};

if (typeof module !== "undefined" && module.exports)
    module.exports = exported;
