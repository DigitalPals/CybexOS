const test = require("node:test");
const assert = require("node:assert/strict");
const { load } = require("./shell.cjs");

const H = load("SysInfoHelpers.js");

test("os-release parsing handles quoted values and escapes", () => {
    const parsed = H.parseOsRelease(String.raw`
# fixture comment
NAME="CybexOS \"Blue\" Linux"
VERSION_ID="44"
VARIANT='Workstation Edition'
ID=cybexos
PRETTY_NAME="ignored aggregate"
`);
    assert.deepEqual(parsed, {
        id: "cybexos",
        name: 'CybexOS "Blue" Linux',
        version: "44",
        variant: "Workstation Edition",
    });
});

test("os-release parsing ignores malformed assignments and falls back to VERSION", () => {
    assert.deepEqual(H.parseOsRelease(
        "NAME=CybexOS\\ Linux\nVERSION='Rawhide'\nBROKEN=\"open\nnot-a-key\n"), {
        id: "",
        name: "CybexOS Linux",
        version: "Rawhide",
        variant: "",
    });
    assert.deepEqual(H.parseOsRelease(undefined), {
        id: "", name: "", version: "", variant: "",
    });
});

test("aggregate CPU parsing excludes already-accounted guest counters", () => {
    const previous = H.parseCpuStat(
        "cpu  100 0 50 100 0 10 10 0 500 200\ncpu0 0 0 0 0\n");
    const current = H.parseCpuStat(
        "cpu  140 5 70 125 0 15 15 0 900 600\n");

    assert.deepEqual(previous, { total: 270, idle: 100 });
    assert.deepEqual(current, { total: 370, idle: 125 });
    assert.equal(H.cpuUsage(previous, current), 75);
});

test("CPU deltas reject malformed, reset, and non-moving counters", () => {
    assert.equal(H.parseCpuStat("intr 1 2 3"), null);
    assert.equal(H.parseCpuStat("cpu 1 nope 3 4"), null);
    assert.equal(H.cpuUsage(null, { total: 2, idle: 1 }), null);
    assert.equal(H.cpuUsage({ total: 5, idle: 2 }, { total: 5, idle: 2 }), null);
    assert.equal(H.cpuUsage({ total: 50, idle: 20 }, { total: 40, idle: 10 }), null);
});

test("CPU model parsing takes the first normalized model name", () => {
    assert.equal(H.parseCpuModel(
        "processor : 0\nmodel name : Intel(R)   Core(TM) Ultra\nprocessor : 1\nmodel name : other\n"),
    "Intel(R) Core(TM) Ultra");
    assert.equal(H.parseCpuModel("processor : 0\n"), "");
});

test("MemAvailable and swap counters become byte totals and usage", () => {
    const memory = H.parseMemInfo([
        "MemTotal:       16777216 kB",
        "MemAvailable:    6291456 kB",
        "SwapTotal:       2097152 kB",
        "SwapFree:         524288 kB",
    ].join("\n"));

    assert.equal(memory.memKnown, true);
    assert.equal(memory.memTotalBytes, 16 * 1024 ** 3);
    assert.equal(memory.memUsedBytes, 10 * 1024 ** 3);
    assert.equal(memory.memUsage, 62.5);
    assert.equal(memory.swapKnown, true);
    assert.equal(memory.swapTotalBytes, 2 * 1024 ** 3);
    assert.equal(memory.swapUsedBytes, 1.5 * 1024 ** 3);
    assert.equal(memory.swapUsage, 75);
});

test("a zero-swap system is known and distinct from missing swap data", () => {
    const none = H.parseMemInfo([
        "MemTotal: 1024 kB",
        "MemAvailable: 512 kB",
        "SwapTotal: 0 kB",
        "SwapFree: 0 kB",
    ].join("\n"));
    assert.equal(none.swapKnown, true);
    assert.equal(none.swapTotalBytes, 0);
    assert.equal(none.swapUsage, 0);

    const malformed = H.parseMemInfo(
        "MemTotal: 1024 kB\nSwapTotal: 0 kB\n");
    assert.equal(malformed.memKnown, false);
    assert.equal(malformed.swapKnown, false);
    assert.equal(malformed.memTotalBytes, 0);
});

test("df parsing validates the C-locale header, root target, and values", () => {
    const disk = H.parseDf([
        "Type     1B-blocks        Used        Avail Use% Mounted on",
        "btrfs 509315383296 57712041984 449654628352  12% /",
        "",
    ].join("\n"));
    assert.deepEqual(disk, {
        type: "btrfs",
        totalBytes: 509315383296,
        usedBytes: 57712041984,
        availableBytes: 449654628352,
        usage: 12,
    });

    for (const malformed of [
        "",
        "Type Size Used Avail Use% Mounted on\nbtrfs 100 20 80 20% /\n",
        "Type 1B-blocks Used Avail Use% Mounted on\nbtrfs 100 xx 80 20% /\n",
        "Type 1B-blocks Used Avail Use% Mounted on\nbtrfs 100 20 80 101% /\n",
        "Type 1B-blocks Used Avail Use% Mounted on\nbtrfs 100 20 80 20% /home\n",
    ])
        assert.equal(H.parseDf(malformed), null);
});

test("IEC formatting changes units exactly at binary boundaries", () => {
    assert.equal(H.formatIecBytes(0), "0 B");
    assert.equal(H.formatIecBytes(1023), "1023 B");
    assert.equal(H.formatIecBytes(1024), "1 KiB");
    assert.equal(H.formatIecBytes(1536), "1.5 KiB");
    assert.equal(H.formatIecBytes(1024 ** 2), "1 MiB");
    assert.equal(H.formatIecBytes(12.25 * 1024 ** 3), "12.3 GiB");
    assert.equal(H.formatIecBytes(-1), "Unavailable");
    assert.equal(H.formatIecBytes(undefined), "Unavailable");
});

test("uptime parsing and formatting stay compact at minute boundaries", () => {
    assert.equal(H.parseUptime("90061.42 12345.67\n"), 90061);
    assert.equal(H.parseUptime("unavailable"), null);
    assert.equal(H.formatUptime(0), "0m");
    assert.equal(H.formatUptime(59), "0m");
    assert.equal(H.formatUptime(60), "1m");
    assert.equal(H.formatUptime(3600), "1h");
    assert.equal(H.formatUptime(3660), "1h 1m");
    assert.equal(H.formatUptime(90060), "1d 1h 1m");
    assert.equal(H.formatUptime(-1), "Unavailable");
});
