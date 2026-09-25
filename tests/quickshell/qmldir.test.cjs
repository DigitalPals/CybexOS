const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { shellDir, VENDORED_DIRS, isVendored } = require("./shell.cjs");

// Every directory holding QML types, discovered rather than listed. A
// directory carrying a qmldir is no longer implicitly scanned by the
// engine, so an unlisted type fails at runtime as "X is not a type" —
// which is why this check exists at all.
//
// Derived on purpose: this list used to be hardcoded, and when Bar/Modules/
// was added it escaped every assertion below until someone noticed. A new
// directory of types now joins the check by existing. Vendored directories
// are the exception: they ship without a qmldir, exactly as upstream does, and
// resolve sibling types through the engine's implicit directory import.
function typeDirs() {
    const out = [];
    const walk = (rel) => {
        const abs = path.join(shellDir, rel);
        const entries = fs.readdirSync(abs, { withFileTypes: true });
        if (entries.some(e => e.isFile() && /^[A-Z].*\.qml$/.test(e.name)))
            out.push(rel);
        for (const e of entries) {
            const child = rel === "." ? e.name : path.join(rel, e.name);
            if (e.isDirectory() && !e.name.startsWith(".")
                    && !["tests", "assets", "scripts"].includes(e.name)
                    && !isVendored(child))
                walk(child);
        }
    };
    walk(".");
    return out;
}

const DIRS = typeDirs();

// Files that must NOT be registered as types, with the reason. A stale
// exemption is itself a failure: see the test below.
const EXEMPT = {
    "Common/T3Socket.qml":
        "imports the optional QtWebSockets package; T3Connection loads it "
        + "through a Loader by URL so a missing package degrades to "
        + "Loader.Error instead of an unresolvable type",
    "Common/HermesSocket.qml":
        "imports the optional QtWebSockets package; HermesConnection loads it "
        + "through a Loader by URL so a missing package degrades to "
        + "Loader.Error instead of an unresolvable type"
};

function read(relative) {
    return fs.readFileSync(path.join(shellDir, relative), "utf8");
}

function qmlFilesIn(dir) {
    return fs.readdirSync(path.join(shellDir, dir))
        .filter(name => name.endsWith(".qml"))
        // A QML type name must start uppercase, so a lowercase file can never
        // be one. That is exactly shell.qml, the entry point loaded by path.
        .filter(name => /^[A-Z]/.test(name));
}

// `Type File.qml` or `singleton Type File.qml`, ignoring comments.
function entriesIn(dir) {
    const out = new Map();
    for (const line of read(path.join(dir, "qmldir")).split("\n")) {
        const trimmed = line.trim();
        if (trimmed === "" || trimmed.startsWith("#"))
            continue;
        const parts = trimmed.split(/\s+/);
        const [type, file] = parts[0] === "singleton" ? [parts[1], parts[2]] : parts;
        out.set(file, type);
    }
    return out;
}

test("every directory that needs a qmldir has one", () => {
    assert.ok(DIRS.length >= 5, `only found ${DIRS.length} type directories`);
    for (const dir of DIRS)
        assert.ok(fs.existsSync(path.join(shellDir, dir, "qmldir")),
            `${dir}/qmldir is missing`);
});

test("every QML type is listed in its directory's qmldir", () => {
    for (const dir of DIRS) {
        const entries = entriesIn(dir);
        const files = qmlFilesIn(dir);
        assert.ok(files.length > 0, `${dir} has no QML types — did it move?`);
        for (const file of files) {
            const rel = dir === "." ? file : `${dir}/${file}`;
            if (EXEMPT[rel] !== undefined) {
                assert.equal(entries.has(file), false,
                    `${rel} is exempt (${EXEMPT[rel]}) but ${dir}/qmldir lists it`);
                continue;
            }
            assert.ok(entries.has(file), `${dir}/qmldir must list ${file}`);
            assert.equal(entries.get(file), file.replace(/\.qml$/, ""),
                `${dir}/qmldir registers ${file} under the wrong type name`);
        }
    }
});

test("every qmldir entry points at a file that exists", () => {
    for (const dir of DIRS) {
        for (const [file, type] of entriesIn(dir)) {
            assert.ok(fs.existsSync(path.join(shellDir, dir, file)),
                `${dir}/qmldir lists ${file}, which does not exist`);
            assert.ok(/^[A-Z]/.test(type), `${dir}/qmldir type ${type} must start uppercase`);
        }
    }
});

test("shell.qml is not registered as a type anywhere", () => {
    // It is the entry point Quickshell loads by path. Listing it would also be
    // impossible — QML type names cannot start lowercase.
    for (const dir of DIRS)
        assert.equal(entriesIn(dir).has("shell.qml"), false,
            `${dir}/qmldir must not list shell.qml`);
    assert.ok(fs.existsSync(path.join(shellDir, "shell.qml")));
});

test("every exemption still exists and still says why", () => {
    // A file that was exempt and then deleted, or exempted without a reason,
    // would otherwise quietly weaken this check.
    for (const [rel, reason] of Object.entries(EXEMPT)) {
        assert.ok(fs.existsSync(path.join(shellDir, rel)),
            `${rel} is exempted but no longer exists — drop the exemption`);
        assert.ok(reason.length > 20, `${rel} needs a real reason`);
        const dir = path.dirname(rel);
        assert.match(read(path.join(dir, "qmldir")), /^#/m,
            `${dir}/qmldir must carry a comment explaining its exemption`);
    }
});

test("T3Socket stays reachable by URL, since it is not a type", () => {
    // The exemption is only safe while this is how it loads. It moved from
    // T3Code to T3Connection when the transport was split out.
    assert.match(read("Common/T3Connection.qml"), /source:\s*"T3Socket\.qml"/);
});

test("HermesSocket stays reachable by URL, since it is not a type", () => {
    assert.match(read("Common/HermesConnection.qml"),
        /source:\s*"HermesSocket\.qml"/);
});

test("every vendored directory exists, says where it came from, and has no qmldir", () => {
    // The scans that skip these directories are only justified while they
    // stay unchanged upstream copies. A qmldir would be a local edit, and
    // would also stop the implicit import their QML relies on.
    assert.ok(VENDORED_DIRS.length > 0);
    for (const dir of VENDORED_DIRS) {
        assert.ok(fs.statSync(path.join(shellDir, dir), { throwIfNoEntry: false })
            ?.isDirectory(), `vendored ${dir}/ is gone — drop it from VENDORED_DIRS`);
        assert.ok(fs.existsSync(path.join(shellDir, dir, "README.md")),
            `vendored ${dir}/ needs a README.md recording its upstream`);
        assert.ok(!fs.existsSync(path.join(shellDir, dir, "qmldir")),
            `vendored ${dir}/ must not carry a qmldir`);
        assert.ok(isVendored(path.join(dir, "Type.qml")) && isVendored(path.join(shellDir, dir)));
    }
    assert.ok(!isVendored("Common/Settings.qml"));
    assert.ok(!DIRS.some(isVendored), "a vendored directory reached the qmldir checks");
});
