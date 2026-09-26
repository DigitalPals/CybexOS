const test = require("node:test");
const assert = require("node:assert/strict");
const H = require("../../roles/desktop/files/quickshell/Common/RemoteServerHelpers.js");
const S = require("../../roles/desktop/files/quickshell/Common/SettingsHelpers.js");

function sample() {
    return { version: 1, boot: "a", uptime: 1200, cpu: 25, perCore: [20, 30], load: [1, 2, 3],
        meta: { hostname: "beast", os: "Linux", defaultInterface: "eth0" },
        memory: { total: 16 * 1024 ** 3, available: 12 * 1024 ** 3, used: 4 * 1024 ** 3 },
        storage: [{ mount: "/", total: 1000, free: 400, percent: 60 }],
        temperatures: [{ name: "CPU", celsius: 54 }],
        network: [{ name: "eth0", addresses: ["10.10.0.7"], rx: 1024, tx: 2048 },
            { name: "docker0", addresses: ["172.17.0.1"], rx: 999999, tx: 999999 }] };
}
test("remote widget migrates as disabled and preserves user options", () => {
    const old = S.defaults();
    old.mods.right = old.mods.right.filter(m => m.id !== "remote");
    delete old.modOpts.remote;
    const migrated = S.merge(old);
    assert.equal(migrated.mods.right.find(m => m.id === "remote").on, false);
    assert.equal(migrated.modOpts.remote.host, "");
    assert.equal(migrated.modOpts.remote.metric, "cpu");
    const normalized = S.normalizeModOpts({ remote: { host: " john@10.10.0.7 ", label: "The Beast",
        metric: "diskFree", mount: "/data", interface: "eth0", pollSecs: 999 } }).remote;
    assert.equal(normalized.host, "john@10.10.0.7");
    assert.equal(normalized.metric, "diskFree");
    assert.equal(normalized.mount, "/data");
    assert.equal(normalized.pollSecs, 60);
    assert.equal(S.normalizeModOpts({ remote: { metric: "bogus" } }).remote.metric, "cpu");
});
test("every menu metric produces the intended unit and missing readings stay unknown", () => {
    const s = sample();
    const options = { mount: "/", interface: "eth0" };
    const expected = { cpu: "25%", load: "1.00", memory: "25%", memoryUsed: "4.0 GiB",
        memoryFree: "12.0 GiB", disk: "60%", diskFree: "400 B", rx: "↓ 1.0 KiB/s",
        tx: "↑ 2.0 KiB/s", temperature: "54°C" };
    for (const { value } of H.METRICS) {
        assert.equal(H.metric(s, { ...options, metric: value }), expected[value]);
        assert.equal(H.metric(null, { ...options, metric: value }), "—");
    }
    assert.equal(H.metric(s, { metric: "disk", mount: "/missing" }), "—");
    assert.equal(H.metric({ ...s, cpu: null }, { metric: "cpu" }), "—");
    assert.equal(H.temperature({ ...s, temperatures: [] }), null);
});
test("network automatic uses the default route and explicit missing interfaces stay missing", () => {
    const s = sample();
    assert.equal(H.network(s, "").name, "eth0");
    assert.equal(H.network(s, "docker0").name, "docker0");
    assert.equal(H.network(s, "missing"), null);
    delete s.meta.defaultInterface;
    assert.equal(H.network(s, "").name, "docker0");
});
test("malformed data is rejected while unavailable first-sample counters are valid", () => {
    const s = sample();
    assert.equal(H.validSample(s), true);
    s.cpu = null; s.perCore = [null]; s.network[0].rx = null;
    assert.equal(H.validSample(s), true);
    for (const value of [null, {}, { ...s, version: 2 }, { ...s, cpu: Infinity },
        { ...s, network: [{}] }, { ...s, storage: [{}] }, { ...s, load: [] }])
        assert.equal(H.validSample(value), false);
});
test("history is bounded and reboot or long disconnection starts a new series", () => {
    const s = sample();
    let history = [];
    for (let at = 0; at <= 700000; at += 2000) history = H.historyAppend(history, s, at);
    assert.equal(history.length, 300);
    assert.ok(history.every(p => 700000 - p.at < 600000));
    assert.equal(H.historyAppend(history, { ...s, boot: "b" }, 702000).length, 1);
    assert.equal(H.historyAppend(history, s, 900000).length, 1);
    assert.equal(history[0].network[0].name, "eth0");
});
test("readings warn at their thresholds and load is judged per logical CPU", () => {
    assert.equal(H.level(null), "unknown");
    assert.equal(H.level(84), "ok");
    assert.equal(H.level(85), "warn");
    assert.equal(H.level(95), "critical");
    assert.equal(H.level(74, "celsius"), "ok");
    assert.equal(H.level(75, "celsius"), "warn");
    assert.equal(H.level(90, "celsius"), "critical");
    const s = sample();
    s.meta.cores = 1;
    assert.equal(H.metricLevel(s, { metric: "load" }), "critical");
    s.meta.cores = 2;
    assert.equal(H.metricLevel(s, { metric: "load" }), "ok");
    assert.equal(H.metricLevel(s, { metric: "cpu" }), "ok");
    assert.equal(H.metricLevel(s, { metric: "diskFree", mount: "/" }), "ok");
    assert.equal(H.metricLevel(s, { metric: "rx" }), "ok");
    assert.equal(H.metricLevel(null, { metric: "cpu" }), "unknown");
});
test("the dashboard opens on the reading the menubar shows", () => {
    const views = H.VIEWS.map(v => v.value);
    for (const { value } of H.METRICS)
        assert.ok(views.includes(H.viewFor(value)), value);
    assert.equal(H.viewFor("memoryFree"), "memory");
    assert.equal(H.viewFor("diskFree"), "storage");
    assert.equal(H.viewFor("temperature"), "temperature");
    assert.equal(H.viewFor("rx"), "cpu");
});
test("chart windows grow with history and rate scales use whole binary steps", () => {
    assert.equal(H.chartSpan(0), 120000);
    assert.equal(H.chartSpan(121000), 180000);
    assert.equal(H.chartSpan(3600000), 600000);
    assert.equal(H.chartCeiling(null), 1024);
    assert.equal(H.chartCeiling(530000), 1048576);
    assert.equal(H.chartCeiling(1048576), 1048576);
    assert.deepEqual(H.summary([{ value: 10 }, { value: null }, { value: 30 }]),
        { average: 20, peak: 30, low: 10 });
    assert.equal(H.summary([{ value: null }]), null);
});
test("filesystems collapse bind mounts, drop firmware stores and lead with the selection", () => {
    const s = sample();
    s.storage = [
        { device: "tank/ROOT", type: "zfs", mount: "/", total: 10, free: 5, percent: 50 },
        { device: "efivarfs", type: "efivarfs", mount: "/sys/firmware/efi/efivars", total: 1, free: 0, percent: 78 },
        { device: "/dev/loop0", type: "btrfs", mount: "/var/lib/incus/devices/a/config.mount", total: 4, free: 1, percent: 79 },
        { device: "/dev/loop0", type: "btrfs", mount: "/var/lib/incus/pool", total: 4, free: 1, percent: 79 }
    ];
    assert.deepEqual(H.storageRows(s, "/").map(d => d.mount), ["/", "/var/lib/incus/pool"]);
    assert.deepEqual(H.storageRows(s, "/var/lib/incus/devices/a/config.mount").map(d => d.mount),
        ["/var/lib/incus/devices/a/config.mount", "/"]);
    assert.deepEqual(H.storageRows(null, "/"), []);
});
test("repeated sensor names identify their chip and sort hottest first", () => {
    const s = sample();
    s.temperatures = [{ name: "nvme · Composite", celsius: 30 }, { name: "k10temp · Tctl", celsius: 58 },
        { name: "nvme · Composite", celsius: 27 }];
    assert.deepEqual(H.sensorRows(s).map(t => t.name),
        ["k10temp · Tctl", "nvme 1 · Composite", "nvme 2 · Composite"]);
});
test("interfaces list the default route, then addressed, then busy links", () => {
    const s = sample();
    s.network.push({ name: "veth0", addresses: [], rx: 5000000, tx: 0 });
    assert.deepEqual(H.interfaceRows(s).map(n => n.name), ["eth0", "docker0", "veth0"]);
});
test("relative ages and compact rates stay short", () => {
    assert.equal(H.ago(2000), "just now");
    assert.equal(H.ago(42000), "42s ago");
    assert.equal(H.ago(125000), "2 min ago");
    assert.equal(H.ago(7200000), "2 h ago");
    assert.equal(H.ago(null), "");
    assert.equal(H.compactRate(900), "900 B/s");
    assert.equal(H.compactRate(425984), "416 K/s");
    assert.equal(H.compactRate(1300000), "1.2 M/s");
    assert.equal(H.compactRate(null), "—");
});
test("history keeps the hottest reading for the temperature chart", () => {
    const [point] = H.historyAppend([], sample(), 1000);
    assert.equal(point.temperature, 54);
    assert.equal(point.cpu, 25);
});
