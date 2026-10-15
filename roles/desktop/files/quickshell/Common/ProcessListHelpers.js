// Pure parsing and ranking for the drawer's Top processes list
// (Common/ProcessList.qml). `scripts/processes list` prints the first line
// of /proc/stat and then, per process, an ownership flag followed by that
// process's own /proc/<pid>/stat line. Two such snapshots give each process's
// share of the machine's CPU time between them. Keep this file free of Qt
// APIs; tests/quickshell/process-list-helpers.test.cjs exercises it.

var MODES = ["cpu", "memory"];
var DEFAULT_LIMIT = 6;
// PF_KTHREAD in /proc/<pid>/stat's flags field.
var KTHREAD_FLAG = 0x00200000;

// Ending one of these takes the session, the shell or the lock screen with
// it. They stay listed — they can be what is busy — without an End action.
var PROTECTED_NAMES = ["systemd", "Hyprland", "Xwayland", "qs", "quickshell",
    "dbus-broker", "dbus-broker-lau", "dbus-daemon", "hyprlock", "sddm"];

function counter(value) {
    return /^\d+$/.test(String(value)) ? Number(value) : NaN;
}

// "<pid> (<comm>) <state> <ppid> …". The command name may itself contain
// spaces and parentheses, so it runs to the *last* ")". Field numbers below
// are proc(5)'s: state is 3, so field n is after[n - 3].
function parseStatLine(line) {
    var text = String(line || "");
    var open = text.indexOf("(");
    var close = text.lastIndexOf(")");
    if (open <= 0 || close <= open)
        return null;
    var pid = counter(text.slice(0, open).trim());
    var after = text.slice(close + 1).trim().split(/\s+/);
    if (!isFinite(pid) || pid <= 0 || after.length < 22)
        return null;
    var ppid = counter(after[1]);
    var flags = counter(after[6]);
    var utime = counter(after[11]);
    var stime = counter(after[12]);
    var start = counter(after[19]);
    var rss = /^-?\d+$/.test(after[21]) ? Math.max(0, Number(after[21])) : NaN;
    if (![ppid, flags, utime, stime, start, rss].every(isFinite))
        return null;
    return {
        pid: pid,
        name: text.slice(open + 1, close),
        state: after[0],
        ppid: ppid,
        kernel: (flags & KTHREAD_FLAG) !== 0 || pid === 2 || ppid === 2,
        ticks: utime + stime,
        start: start,
        rssPages: rss
    };
}

// The aggregate jiffies of /proc/stat's "cpu" line: the first eight counters
// (guest time is already inside user), as SysInfoHelpers.parseCpuStat sums.
function parseCpuTotal(line) {
    var parts = String(line || "").trim().split(/\s+/);
    if (parts[0] !== "cpu" || parts.length < 5)
        return NaN;
    var total = 0;
    for (var i = 1; i <= 8; i++) {
        var value = i < parts.length ? counter(parts[i]) : 0;
        if (!isFinite(value))
            return NaN;
        total += value;
    }
    return total;
}

// One snapshot: { total, processes: [{ pid, name, own, ticks, start, rssPages, state }] }.
// Kernel threads and zombies are left out: neither has anything to end, and
// a zombie holds no CPU or memory.
function parseSnapshot(text) {
    var total = NaN;
    var processes = [];
    String(text || "").split("\n").forEach(function(raw) {
        var line = raw.trim();
        if (line === "")
            return;
        if (/^cpu\s/.test(line)) {
            total = parseCpuTotal(line);
            return;
        }
        var marker = line.match(/^([01])\s+(.*)$/);
        if (!marker)
            return;
        var entry = parseStatLine(marker[2]);
        if (entry === null || entry.kernel || entry.state === "Z" || entry.state === "X")
            return;
        entry.own = marker[1] === "1";
        processes.push(entry);
    });
    return { total: isFinite(total) ? total : null, processes: processes };
}

// Rows for display from the current snapshot, with each process's CPU share
// since `previous` as a percentage of the whole machine (the same scale as
// the CPU meter above the list). A process new since the previous snapshot,
// or one whose pid was reused (its start time differs), has no share yet:
// cpu is null.
function rows(previous, current, pageSize) {
    var page = Number(pageSize) > 0 ? Number(pageSize) : 4096;
    var earlier = {};
    if (previous && Array.isArray(previous.processes))
        previous.processes.forEach(function(entry) { earlier[entry.pid] = entry; });
    var elapsed = previous && current && previous.total !== null && current.total !== null
        ? current.total - previous.total : 0;
    return (current && Array.isArray(current.processes) ? current.processes : []).map(function(entry) {
        var before = earlier[entry.pid];
        var cpu = null;
        if (elapsed > 0 && before && before.start === entry.start)
            cpu = Math.max(0, Math.min(100, (entry.ticks - before.ticks) / elapsed * 100));
        return {
            pid: entry.pid,
            name: entry.name,
            own: !!entry.own,
            start: entry.start,
            cpu: cpu,
            memory: entry.rssPages * page
        };
    });
}

// The top `limit` rows by CPU share or by resident memory. Ties fall back to
// the other measure and then the pid, so the order does not flicker between
// equal readings.
function rank(list, mode, limit) {
    var byMemory = mode === "memory";
    var max = Math.max(0, Math.floor(Number(limit) || DEFAULT_LIMIT));
    function cpuOf(row) { return row.cpu === null || row.cpu === undefined ? -1 : row.cpu; }
    return (Array.isArray(list) ? list.slice() : []).sort(function(a, b) {
        var primary = byMemory ? b.memory - a.memory : cpuOf(b) - cpuOf(a);
        var secondary = byMemory ? cpuOf(b) - cpuOf(a) : b.memory - a.memory;
        return primary || secondary || a.pid - b.pid;
    }).slice(0, max);
}

function formatCpu(percent) {
    if (percent === null || percent === undefined || !isFinite(percent))
        return "…";
    if (percent > 0 && percent < 0.1)
        return "<0.1%";
    return (percent < 10 ? Number(percent).toFixed(1) : String(Math.round(percent))) + "%";
}

// Whether the list offers End process for a row: only the person's own
// processes (the kill would fail for anyone else's), never pid 1 or the
// shell itself, and never one whose end would take the session with it.
function canEnd(row, selfPid) {
    if (!row || !row.own || !(row.pid > 1))
        return false;
    if (selfPid !== undefined && Number(selfPid) === row.pid)
        return false;
    return PROTECTED_NAMES.indexOf(row.name) === -1;
}

// Whether `pending` — { pid, start } of a process sent SIGTERM — is still in
// a snapshot's rows.
function stillRunning(list, pending) {
    if (!pending)
        return false;
    return (Array.isArray(list) ? list : []).some(function(row) {
        return row.pid === pending.pid && row.start === pending.start;
    });
}

var exported = {
    MODES: MODES,
    DEFAULT_LIMIT: DEFAULT_LIMIT,
    PROTECTED_NAMES: PROTECTED_NAMES,
    parseStatLine: parseStatLine,
    parseCpuTotal: parseCpuTotal,
    parseSnapshot: parseSnapshot,
    rows: rows,
    rank: rank,
    formatCpu: formatCpu,
    canEnd: canEnd,
    stillRunning: stillRunning
};

if (typeof module !== "undefined" && module.exports)
    module.exports = exported;
