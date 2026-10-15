const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { spawn, spawnSync } = require("node:child_process");
const { load, shellDir } = require("./shell.cjs");

const P = load("ProcessListHelpers.js");
const helper = path.join(shellDir, "scripts", "processes");

// proc(5) stat fields after the command name: state ppid pgrp session tty
// tpgid flags minflt cminflt majflt cmajflt utime stime cutime cstime
// priority nice threads itrealvalue starttime vsize rss …
function stat(pid, name, { state = "S", ppid = 1, flags = 4194560, utime = 0, stime = 0,
    start = 1000, rss = 100 } = {}) {
    return [pid, `(${name})`, state, ppid, pid, pid, 0, -1, flags, 0, 0, 0, 0,
        utime, stime, 0, 0, 20, 0, 1, 0, start, 1234567, rss, "18446744073709551615", 1, 1].join(" ");
}

function snapshot(total, lines) {
    return [`cpu  ${total} 0 0 0 0 0 0 0 0 0`, ...lines, ""].join("\n");
}

test("stat lines parse, including names with spaces and parentheses", () => {
    const parsed = P.parseStatLine(stat(4321, "Web Content (x)", { utime: 70, stime: 30, start: 99, rss: 2560 }));
    assert.deepEqual(parsed, {
        pid: 4321, name: "Web Content (x)", state: "S", ppid: 1, kernel: false,
        ticks: 100, start: 99, rssPages: 2560
    });
    assert.equal(P.parseStatLine("garbage"), null);
    assert.equal(P.parseStatLine("12 (short) S 1 2"), null, "truncated lines are dropped");
    assert.equal(P.parseCpuTotal("cpu  10 20 30 40 50 60 70 80 90 100"), 360,
        "guest time is already inside user and is not added twice");
    assert.ok(Number.isNaN(P.parseCpuTotal("intr 1 2 3")));
});

test("kernel threads, zombies and unmarked lines stay out of a snapshot", () => {
    const parsed = P.parseSnapshot(snapshot(1000, [
        "1 " + stat(10, "firefox"),
        "0 " + stat(11, "kworker/0:1", { ppid: 2 }),
        "0 " + stat(12, "rcu_sched", { flags: 0x00200040 }),
        "1 " + stat(13, "defunct", { state: "Z" }),
        "0 " + stat(14, "sshd"),
        stat(15, "no marker"),
        "intr 1 2 3"
    ]));
    assert.equal(parsed.total, 1000);
    assert.deepEqual(parsed.processes.map(entry => [entry.pid, entry.own]), [[10, true], [14, false]]);
    assert.equal(P.parseSnapshot("").total, null);
});

test("CPU shares come from two snapshots, on the whole machine's scale", () => {
    const first = P.parseSnapshot(snapshot(1000, [
        "1 " + stat(10, "busy", { utime: 100, start: 5 }),
        "1 " + stat(11, "idle", { utime: 100, start: 6 }),
        "1 " + stat(12, "reused", { utime: 100, start: 7 })
    ]));
    const second = P.parseSnapshot(snapshot(1400, [
        "1 " + stat(10, "busy", { utime: 300, start: 5, rss: 10 }),
        "1 " + stat(11, "idle", { utime: 100, start: 6 }),
        "1 " + stat(12, "reused", { utime: 5, start: 900 }),
        "1 " + stat(13, "new", { utime: 50, start: 950 })
    ]));
    const rows = P.rows(first, second, 4096);
    const byPid = Object.fromEntries(rows.map(row => [row.pid, row]));
    assert.equal(byPid[10].cpu, 50, "200 of 400 jiffies");
    assert.equal(byPid[10].memory, 10 * 4096);
    assert.equal(byPid[11].cpu, 0);
    assert.equal(byPid[12].cpu, null, "a reused pid has no baseline");
    assert.equal(byPid[13].cpu, null, "a new process has no baseline yet");
    assert.ok(P.rows(null, second, 4096).every(row => row.cpu === null), "the first sample");
});

test("ranking by CPU or memory is stable on ties", () => {
    const rows = [
        { pid: 3, name: "c", cpu: 5, memory: 100 },
        { pid: 1, name: "a", cpu: 5, memory: 300 },
        { pid: 2, name: "b", cpu: null, memory: 900 },
        { pid: 4, name: "d", cpu: 40, memory: 10 }
    ];
    assert.deepEqual(P.rank(rows, "cpu", 6).map(row => row.pid), [4, 1, 3, 2]);
    assert.deepEqual(P.rank(rows, "memory", 2).map(row => row.pid), [2, 1]);
    assert.deepEqual(P.rank(rows, "cpu", 6), P.rank(rows.slice().reverse(), "cpu", 6),
        "input order does not change the result");
    assert.equal(P.DEFAULT_LIMIT, 6);
    assert.equal(P.rank(rows, "cpu").length, 4, "fewer rows than the limit: all of them");
    assert.equal(rows[0].pid, 3, "ranking does not reorder its input");
});

test("CPU readings format compactly", () => {
    assert.equal(P.formatCpu(null), "…");
    assert.equal(P.formatCpu(0), "0.0%");
    assert.equal(P.formatCpu(0.04), "<0.1%");
    assert.equal(P.formatCpu(3.456), "3.5%");
    assert.equal(P.formatCpu(42.6), "43%");
});

test("End process is offered only where it can work and cannot end the session", () => {
    assert.equal(P.canEnd({ pid: 500, name: "firefox", own: true }, 900), true);
    assert.equal(P.canEnd({ pid: 500, name: "firefox", own: false }, 900), false, "another user's");
    assert.equal(P.canEnd({ pid: 900, name: "anything", own: true }, 900), false, "the shell itself");
    assert.equal(P.canEnd({ pid: 1, name: "systemd", own: true }), false);
    for (const name of ["Hyprland", "systemd", "qs", "Xwayland", "dbus-broker", "hyprlock"])
        assert.equal(P.canEnd({ pid: 77, name, own: true }), false, name);
    assert.equal(P.canEnd(null), false);
    assert.equal(P.stillRunning([{ pid: 5, start: 9 }], { pid: 5, start: 9 }), true);
    assert.equal(P.stillRunning([{ pid: 5, start: 10 }], { pid: 5, start: 9 }), false, "pid reused");
    assert.equal(P.stillRunning([], null), false);
});

// ---- the helper script, against this machine's /proc ----------------------

const linux = fs.existsSync("/proc/self/stat");

test("the list helper reads /proc in one bash process and parses cleanly", { skip: !linux && "no /proc" }, () => {
    const source = fs.readFileSync(helper, "utf8");
    const listBody = source.slice(source.indexOf("list() {"), source.indexOf("signal() {"));
    assert.doesNotMatch(listBody, /\$\(|`|(^|[^|])\|(?!\|)\s*[a-z]/m,
        "no command substitution or pipeline in a sample");
    assert.doesNotMatch(listBody, /^\s*(cat|awk|sed|ps|grep|head|stat|getconf)\b/m,
        "a sample must not fork a process per /proc entry");
    const result = spawnSync("bash", [helper, "list"], { encoding: "utf8" });
    assert.equal(result.status, 0, result.stderr);
    const parsed = P.parseSnapshot(result.stdout);
    assert.ok(parsed.total > 0, "the aggregate cpu line comes first");
    assert.ok(parsed.processes.some(entry => entry.pid === process.pid && entry.own),
        "this test's own process is listed as owned");
    assert.ok(parsed.processes.every(entry => !entry.kernel));
    assert.ok(!/^\d+ \S+ \(kthreadd\)/m.test(result.stdout), "kernel threads are skipped in bash");
});

test("the signal helper validates, checks the start time, and signals", { skip: !linux && "no /proc" }, async () => {
    const run = args => spawnSync("bash", [helper, ...args], { encoding: "utf8" });
    assert.equal(run(["signal", "abc", "1", "TERM"]).status, 2);
    assert.equal(run(["signal", "1", "1", "HUP"]).status, 2, "only TERM and KILL");
    assert.equal(run(["bogus"]).status, 2);
    assert.equal(run(["signal", "999999999", "1", "TERM"]).status, 3, "gone");

    const child = spawn("sleep", ["30"]);
    const exited = new Promise(resolve => child.on("exit", (code, signal) => resolve(signal)));
    try {
        const fields = fs.readFileSync(`/proc/${child.pid}/stat`, "utf8");
        const start = fields.slice(fields.lastIndexOf(")") + 2).split(" ")[19];
        assert.equal(run(["signal", String(child.pid), String(Number(start) + 1), "TERM"]).status, 3,
            "a different start time is a different process: left alone");
        assert.equal(run(["signal", String(child.pid), start, "TERM"]).status, 0);
        assert.equal(await exited, "SIGTERM");
    } finally {
        child.kill("SIGKILL");
    }
});
