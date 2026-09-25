const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { shellDir, load, isVendored } = require("./shell.cjs");

const F = load("Format.js");

// The three m:ss builders Format.mmss replaced, transcribed from the code it
// took over: the media seek labels, the usage poll countdown in the popover,
// and the same countdown restated in the System settings page. mmss has to
// agree with all three over the range each of them could actually see.
const MEDIA = s => {
    if (!s || s < 0) return "0:00";
    return `${Math.floor(s / 60)}:${String(Math.floor(s % 60)).padStart(2, "0")}`;
};
const USAGE = s => `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
const SYSTEM = s => Math.floor(s / 60) + ":" + String(s % 60).padStart(2, "0");

function read(rel) {
    return fs.readFileSync(path.join(shellDir, rel), "utf8");
}

function qmlAndJs() {
    const out = [];
    const walk = dir => {
        for (const e of fs.readdirSync(path.join(shellDir, dir), { withFileTypes: true })) {
            const rel = dir === "." ? e.name : path.join(dir, e.name);
            if (e.isDirectory() && !["tests", "assets", "scripts"].includes(e.name)
                    && !isVendored(rel))
                walk(rel);
            else if (/\.(qml|js)$/.test(e.name))
                out.push(rel);
        }
    };
    walk(".");
    return out;
}

test("the unit constants are seconds, and the MS_ ones milliseconds", () => {
    assert.deepEqual([F.MINUTE, F.HOUR, F.DAY], [60, 3600, 86400]);
    assert.deepEqual([F.MS_SECOND, F.MS_MINUTE, F.MS_HOUR, F.MS_DAY],
        [1000, 60000, 3600000, 86400000]);
});

test("clamp01 and pad2 do the obvious thing", () => {
    assert.deepEqual([-1, -0.001, 0, 0.5, 1, 1.001, 42].map(F.clamp01),
        [0, 0, 0, 0.5, 1, 1, 1]);
    assert.deepEqual([0, 5, 9, 10, 99, 100].map(F.pad2),
        ["00", "05", "09", "10", "99", "100"]);
});

test("mmss agrees with all three implementations it replaced", () => {
    // Usage.nextPollSecs is a clamped `int`, and a media position is a
    // non-negative real, so whole seconds from zero is the domain all three
    // shared. Below that they disagreed with each other, not with mmss.
    for (let s = 0; s <= 4000; s++) {
        const got = F.mmss(s);
        assert.equal(got, MEDIA(s), `media(${s})`);
        assert.equal(got, USAGE(s), `usage(${s})`);
        assert.equal(got, SYSTEM(s), `system(${s})`);
    }
    assert.equal(F.mmss(7325), "122:05");
});

test("mmss reads junk as zero rather than as a stray minus sign", () => {
    // The old usage/system copies rendered "-1:-30" and "0:12.7" here; only
    // the media copy guarded. This is the behaviour that changed, and it
    // changed on inputs none of the three call sites can produce.
    for (const bad of [-1, -30, null, undefined, NaN, Infinity, "x"])
        assert.equal(F.mmss(bad), "0:00", `mmss(${String(bad)})`);
    assert.equal(F.mmss(12.7), "0:12");
});

test("the idioms Format replaced do not come back", () => {
    const exempt = {
        "Common/Format.js": "defines them",
        // A .js cannot import another .js the way a QML file can without
        // introducing a second module mechanism for one constant.
        "Common/T3CodeHelpers.js": "pure helper module, no QML import available",
        "Common/GitHubHelpers.js": "pure helper module, no QML import available",
        "Settings/LocalTime.js": "pure helper module, no QML import available"
    };
    for (const rel of qmlAndJs()) {
        if (rel in exempt) continue;
        const source = read(rel);
        assert.doesNotMatch(source, /Math\.max\(0, Math\.min\(1,/,
            `${rel} open-codes clamp01`);
        assert.doesNotMatch(source, /\b(3600000|86400000)\b/,
            `${rel} open-codes a millisecond constant`);
    }
});
