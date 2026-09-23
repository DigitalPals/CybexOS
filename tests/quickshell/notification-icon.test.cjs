const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { fileURLToPath } = require("node:url");
const { spawnSync } = require("node:child_process");
const { shellDir } = require("./shell.cjs");

const helper = path.join(shellDir, "scripts", "notification-icon.py");

function fixture() {
    const base = fs.mkdtempSync(path.join(os.tmpdir(), "notif-icon-test-"));
    const profile = path.join(base, "browser", "Default");
    const cache = path.join(base, "cache");
    fs.mkdirSync(profile, { recursive: true });
    const database = path.join(profile, "Favicons");
    const setup = spawnSync("python3", ["-c", String.raw`
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.executescript("""
CREATE TABLE icon_mapping(id INTEGER PRIMARY KEY, page_url TEXT, icon_id INTEGER);
CREATE TABLE favicon_bitmaps(id INTEGER PRIMARY KEY, icon_id INTEGER,
    last_updated INTEGER, image_data BLOB, width INTEGER, height INTEGER);
INSERT INTO icon_mapping VALUES (1, 'https://news.example.com/story', 10);
INSERT INTO icon_mapping VALUES (2, 'https://news.example.com/other', 11);
INSERT INTO icon_mapping VALUES (3, 'https://news.example.com.evil.test/', 12);
INSERT INTO favicon_bitmaps VALUES (1, 10, 100, X'736D616C6C', 16, 16);
INSERT INTO favicon_bitmaps VALUES (2, 11, 200, X'6C61726765', 64, 64);
INSERT INTO favicon_bitmaps VALUES (3, 12, 300, X'77726F6E67', 128, 128);
""")
db.commit()
`, database], { encoding: "utf8" });
    assert.equal(setup.status, 0, setup.stderr);
    return { base, browser: path.join(base, "browser"), cache };
}

function run(origin, env) {
    return spawnSync("python3", [helper, origin], {
        encoding: "utf8",
        env: {
            ...process.env,
            XDG_CACHE_HOME: env.cache,
            QUICKSHELL_NOTIFICATION_ICON_CONFIG_ROOTS: env.browser,
        },
    });
}

test("the resolver writes the largest exact-origin browser favicon to cache", t => {
    const env = fixture();
    t.after(() => fs.rmSync(env.base, { recursive: true, force: true }));

    const result = run("news.example.com", env);
    assert.equal(result.status, 0, result.stderr);
    const output = result.stdout.trim();
    assert.match(output, /^file:\/\//);
    assert.equal(fs.readFileSync(fileURLToPath(output)).toString(), "large");
});

test("the origin's root page mapping is answered before the prefix scan", t => {
    const env = fixture();
    t.after(() => fs.rmSync(env.base, { recursive: true, force: true }));
    const setup = spawnSync("python3", ["-c", String.raw`
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.executescript("""
INSERT INTO icon_mapping VALUES (4, 'https://news.example.com/', 13);
INSERT INTO favicon_bitmaps VALUES (4, 13, 400, X'726F6F74', 32, 32);
""")
db.commit()
`, path.join(env.browser, "Default", "Favicons")], { encoding: "utf8" });
    assert.equal(setup.status, 0, setup.stderr);

    const result = run("news.example.com", env);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(fs.readFileSync(fileURLToPath(result.stdout.trim())).toString(), "root");
});

test("an uncached valid origin falls back to its own conventional favicon", t => {
    const env = fixture();
    t.after(() => fs.rmSync(env.base, { recursive: true, force: true }));

    const result = run("other.example", env);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout.trim(), "https://other.example/favicon.ico");
});

test("invalid or injection-shaped origins are rejected before SQLite lookup", t => {
    const env = fixture();
    t.after(() => fs.rmSync(env.base, { recursive: true, force: true }));

    for (const origin of ["News.Example.com", "example.com/%", "example.com' OR 1=1"]) {
        const result = run(origin, env);
        assert.equal(result.status, 2, origin);
        assert.equal(result.stdout, "", origin);
    }
});
