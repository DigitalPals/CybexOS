const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { shellDir, load } = require("./shell.cjs");
const H = load("WallhavenHelpers.js");

const read = rel => fs.readFileSync(path.join(shellDir, rel), "utf8");

function item(id, overrides) {
    const shard = id.slice(0, 2);
    return Object.assign({
        id: id,
        purity: "sfw",
        category: "general",
        dimension_x: 3840,
        dimension_y: 2160,
        file_size: 5322122,
        file_type: "image/png",
        favorites: 98,
        path: `https://w.wallhaven.cc/full/${shard}/wallhaven-${id}.png`,
        thumbs: {
            large: `https://th.wallhaven.cc/lg/${shard}/${id}.jpg`,
            original: `https://th.wallhaven.cc/orig/${shard}/${id}.jpg`,
            small: `https://th.wallhaven.cc/small/${shard}/${id}.jpg`
        }
    }, overrides || {});
}

function reply(data, meta) {
    return JSON.stringify({ data: data, meta: Object.assign({ current_page: 1, last_page: 3, seed: null }, meta || {}) });
}

test("every search asks for safe-for-work images and never the People category", () => {
    for (const category of ["general", "anime", "both", "people", "111", undefined]) {
        for (const sort of ["popular", "trending", "latest", "random", "views", undefined]) {
            const url = new URL(H.searchUrl({ category: category, sort: sort }));
            assert.equal(url.origin + url.pathname, "https://wallhaven.cc/api/v1/search");
            assert.equal(url.searchParams.get("purity"), "100");
            assert.match(url.searchParams.get("categories"), /^[01][01]0$/);
            assert.notEqual(url.searchParams.get("categories"), "000");
            assert.equal(url.searchParams.has("apikey"), false);
        }
    }
    assert.equal(new URL(H.searchUrl({ category: "anime" })).searchParams.get("categories"), "010");
    assert.equal(new URL(H.searchUrl({ category: "both" })).searchParams.get("categories"), "110");
});

test("sort choices map to Wallhaven's sorting and only random carries a seed", () => {
    const params = options => new URL(H.searchUrl(options)).searchParams;
    assert.equal(params({ sort: "popular" }).get("sorting"), "favorites");
    assert.equal(params({ sort: "trending" }).get("sorting"), "toplist");
    assert.equal(params({ sort: "trending" }).get("topRange"), "1M");
    assert.equal(params({ sort: "latest" }).get("sorting"), "date_added");
    assert.equal(params({ sort: "random", seed: "WPvrQV" }).get("seed"), "WPvrQV");
    assert.equal(params({ sort: "latest", seed: "WPvrQV" }).has("seed"), false);
    assert.equal(params({ sort: "random", seed: "bad seed&x=1" }).has("seed"), false);
    assert.equal(params({ sort: "nonsense" }).get("sorting"), "favorites");
});

test("queries, sizes and pages are encoded and bounded", () => {
    const url = new URL(H.searchUrl({ query: "  city & night=1  ", minimum: "3840x2160",
        landscape: true, page: 3 }));
    assert.equal(url.searchParams.get("q"), "city & night=1");
    assert.equal(url.searchParams.has("night"), false);
    assert.equal(url.searchParams.get("atleast"), "3840x2160");
    assert.equal(url.searchParams.get("ratios"), "landscape");
    assert.equal(url.searchParams.get("page"), "3");
    assert.equal(new URL(H.searchUrl({ query: "x".repeat(500) })).searchParams.get("q").length, 100);
    const plain = new URL(H.searchUrl({ query: "   ", minimum: "3840x2160;rm", page: 1 })).searchParams;
    assert.equal(plain.has("q"), false);
    assert.equal(plain.has("atleast"), false);
    assert.equal(plain.has("page"), false);
    assert.equal(plain.has("ratios"), false);
});

test("the minimum size covers every display in physical pixels", () => {
    assert.equal(H.minimumFor([
        { width: 1920, height: 1200, devicePixelRatio: 1.5 },
        { width: 3840, height: 2160, devicePixelRatio: 1 }
    ]), "3840x2160");
    assert.equal(H.minimumFor([{ width: 1280, height: 800, devicePixelRatio: 2 }]), "2560x1600");
    assert.equal(H.minimumFor([{ width: 0, height: 0, devicePixelRatio: 1 }]), "");
    assert.equal(H.minimumFor([]), "");
    assert.equal(H.allLandscape([{ width: 1920, height: 1080 }, { width: 1080, height: 1920 }]), false);
    assert.equal(H.allLandscape([{ width: 1920, height: 1080 }]), true);
    assert.equal(H.allLandscape([]), false);
});

test("results keep only safe-for-work images with Wallhaven's own URLs", () => {
    const parsed = H.parseResults(reply([
        item("qroy2d"),
        item("ab12cd", { purity: "sketchy" }),
        item("ef34gh", { purity: "nsfw" }),
        item("ij56kl", { purity: undefined }),
        item("mn78op", { path: "https://evil.example/full/mn/wallhaven-mn78op.png" }),
        item("qr90st", { path: "https://w.wallhaven.cc/full/qr/wallhaven-qr90st.png?x" }),
        item("uv12wx", { file_type: "image/gif" }),
        item("yz34ab", { thumbs: { large: "https://evil.example/lg/yz/yz34ab.jpg" } }),
        item("../etc"),
        item("cd56ef", { dimension_x: 0 }),
        item("gh78ij", { file_size: "5322122" }),
        item("qroy2d"),
        item("rdwjj7", { file_type: "image/jpeg",
            path: "https://w.wallhaven.cc/full/rd/wallhaven-rdwjj7.jpg",
            thumbs: { small: "https://th.wallhaven.cc/small/rd/rdwjj7.jpg" } })
    ], { current_page: 2, last_page: 16, seed: "WPvrQV" }));

    assert.deepEqual(parsed.items.map(entry => entry.id), ["qroy2d", "rdwjj7"]);
    assert.equal(parsed.page, 2);
    assert.equal(parsed.lastPage, 16);
    assert.equal(parsed.seed, "WPvrQV");
    assert.deepEqual(parsed.items[0], {
        id: "qroy2d", width: 3840, height: 2160, size: 5322122, favorites: 98,
        category: "general",
        thumb: "https://th.wallhaven.cc/lg/qr/qroy2d.jpg",
        image: "https://w.wallhaven.cc/full/qr/wallhaven-qroy2d.png",
        page: "https://wallhaven.cc/w/qroy2d",
        fileName: "wallhaven-qroy2d.png"
    });
    assert.equal(parsed.items[1].thumb, "https://th.wallhaven.cc/small/rd/rdwjj7.jpg");
    assert.equal(parsed.items[1].fileName, "wallhaven-rdwjj7.jpg");
});

test("an error document or malformed listing is an error, an empty one is not", () => {
    assert.deepEqual(H.parseResults(reply([], { last_page: 1 })).items, []);
    for (const body of ["", "null", "[]", "<html>", '{"error":"Too Many Requests"}',
        '{"data":{}}', '{"data":[]}', '{"meta":{}}'])
        assert.throws(() => H.parseResults(body), undefined, body);
    const odd = H.parseResults(JSON.stringify({ data: [], meta: { current_page: "x", last_page: -1, seed: "a b" } }));
    assert.equal(odd.page, 1);
    assert.equal(odd.lastPage, 1);
    assert.equal(odd.seed, "");
});

test("a later page appends without repeating images already shown", () => {
    const first = [{ id: "a" }, { id: "b" }];
    const merged = H.merge(first, [{ id: "b" }, { id: "c" }]);
    assert.deepEqual(merged.map(entry => entry.id), ["a", "b", "c"]);
    assert.equal(merged[0], first[0], "existing entries keep their identity for ScriptModel");
});

test("status copy names rate limiting and offline separately", () => {
    assert.match(H.statusError(429), /Wait a minute/);
    assert.match(H.statusError(0), /connection/);
    assert.match(H.statusError(503), /HTTP 503/);
    assert.equal(H.describe({ width: 3840, height: 2160, size: 5322122 }), "3840 × 2160 · 5.3 MB");
    assert.equal(H.formatBytes(840000), "840 kB");
});

test("every download failure code the helper prints has page copy", () => {
    const script = read("scripts/wallpaper-download.py");
    const codes = new Set([...script.matchAll(/Failure\("([a-z]+)"/g)].map(match => match[1]));
    assert.ok(codes.size >= 6, "the helper's failure codes were found");
    for (const code of codes)
        assert.notEqual(H.downloadError(code), H.downloadError("unknown-code"), code);
});

test("the Online view reaches the network only once chosen", () => {
    const page = read("Settings/WallpaperPage.qml");
    const view = read("Settings/WallpaperOnlineView.qml");
    const online = read("Common/OnlineWallpapers.qml");

    assert.match(online, /property string view:\s*"library"/,
        "the page opens on the local Library");
    assert.match(page, /Loader \{[\s\S]*?active:\s*page\.online/,
        "the Online view is instantiated only while chosen");
    assert.match(view, /Component\.onCompleted:\s*OnlineWallpapers\.ensureLoaded\(\)/);
    assert.doesNotMatch(online, /Component\.onCompleted/,
        "creating the singleton must not search");
    assert.match(view, /model:\s*ScriptModel\s*\{\s*values:\s*root\.results\s*\}/,
        "a later page appends tiles instead of resetting the grid");
    assert.match(view, /onAtYEndChanged:\s*\{\s*if \(atYEnd && contentHeight > height\)\s*OnlineWallpapers\.more\(\)/,
        "a short first page must not chain requests by itself");
    assert.match(online, /wallpaper-download\.py/);
    assert.match(online,
        /onRunningChanged:\s*\{\s*if \(!running && root\.downloadItem !== null\)\s*root\.finishDownload\(\)/,
        "a helper that never started must still settle its download");
    assert.match(read("Common/qmldir"), /^singleton OnlineWallpapers OnlineWallpapers\.qml$/m);
    assert.match(read("Settings/qmldir"), /^WallpaperOnlineView WallpaperOnlineView\.qml$/m);
});
