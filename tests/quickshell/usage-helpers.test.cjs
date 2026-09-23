const test = require("node:test");
const assert = require("node:assert/strict");
const { load } = require("./shell.cjs");

const H = load("UsageHelpers.js");

test("direct usage shows only detected CLI logins", () => {
    assert.deepEqual(H.providerKeys("direct", {}), []);
    assert.deepEqual(H.providerKeys("direct", null), []);
    assert.deepEqual(H.providerKeys("direct", {
        claude: { status: "error", kind: "nocreds" },
        codex: { status: "ok", source: "codex-oauth", windows: [] },
        kimi: { status: "error", kind: "nocreds" },
        xai: { status: "error", kind: "config" }
    }), ["codex"]);
});

test("detected direct logins keep their tabs through usage failures", () => {
    for (const kind of ["expired", "rate", "refresh", "wait", "network", "parse"]) {
        assert.deepEqual(H.providerKeys("direct", {
            kimi: { status: "error", kind },
            claude: { status: "ok", stale: true, staleKind: kind },
            codex: { status: "error", kind }
        }), ["claude", "codex", "kimi"]);
    }
});

test("direct usage drops removed logins even with cached readings", () => {
    assert.deepEqual(H.providerKeys("direct", {
        claude: { status: "ok", stale: true, staleKind: "nocreds" },
        codex: { status: "error", kind: "nocreds" },
        kimi: { status: "ok", source: "cliproxy" },
        xai: { status: "ok", stale: true, staleKind: "config" }
    }), []);
    const keys = H.providerKeys("direct", { codex: { status: "ok" } });
    assert.equal(H.selectedProvider(keys, "claude"), "codex");
});

test("CLIProxy usage follows its managed provider inventory", () => {
    const data = {
        xai: { status: "ok", source: "cliproxy", windows: [] },
        kimi: { status: "error", kind: "nocreds" },
        codex: { status: "ok", source: "cliproxy", windows: [] },
        claude: {
            status: "error", kind: "expired", source: "cliproxy",
            accountCount: 2
        }
    };

    assert.deepEqual(H.providerKeys("cliproxy", data),
        ["claude", "codex", "xai"],
        "managed providers stay in stable UI order while absent Kimi is omitted");
    assert.deepEqual(H.providerKeys("cliproxy", {}), []);
});

test("an authoritative CLIProxy inventory miss removes stale cached usage", () => {
    const data = {
        kimi: {
            status: "ok", source: "cliproxy", stale: true,
            staleKind: "nocreds", windows: [{ used: 20 }]
        }
    };

    assert.deepEqual(H.providerKeys("cliproxy", data), []);
});

test("selection moves to the first provider when the proxy inventory changes", () => {
    assert.equal(H.selectedProvider(["codex", "xai"], "kimi"), "codex");
    assert.equal(H.selectedProvider(["codex", "xai"], "xai"), "xai");
    assert.equal(H.selectedProvider([], "kimi"), "kimi");
});


test("Sub2API discovers Gemini and managed failures without adding direct CLI tabs", () => {
    assert.deepEqual(H.providerKeys("sub2api", {
        claude: { source: "sub2api", status: "ok" },
        codex: { source: "sub2api", status: "error", kind: "config" },
        gemini: { source: "sub2api", status: "ok" },
        xai: { source: "sub2api", staleKind: "nocreds" },
        kimi: { source: "cliproxy", status: "ok" }
    }), ["claude", "codex", "gemini"]);
    assert.deepEqual(H.providerKeys("sub2api", {}), []);
    assert.deepEqual(H.providerKeys("direct", {}), []);
});


test("Claude overview includes Fable from another account without changing the pool score", () => {
    const reading = { status: "ok", windows: [{ label: "Weekly limit", used: 34 }],
        accounts: [
            { status: "ok", label: "Account A", windows: [
                { label: "Fable weekly limit", used: 51, windowSecs: 604800, resetsAt: 2000000000 }
            ] },
            { status: "error", label: "Failed", windows: [
                { label: "Fable weekly limit", used: 0 }
            ] }
        ] };
    const original = JSON.stringify(reading);
    assert.deepEqual(H.additionalFableWindows(reading), [
        { label: "Fable weekly limit · Account A", used: 51,
          windowSecs: 604800, resetsAt: 2000000000 }
    ]);
    assert.equal(JSON.stringify(reading), original);
    reading.windows.push({ label: "Weekly (Fable)", used: 20 });
    assert.deepEqual(H.additionalFableWindows(reading), [], "do not duplicate a primary Fable window");
    assert.deepEqual(H.additionalFableWindows(null), []);
    assert.deepEqual(H.additionalFableWindows({ status: "error" }), []);
});
