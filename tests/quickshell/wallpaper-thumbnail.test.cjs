const test = require("node:test");
const assert = require("node:assert/strict");
const childProcess = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { shellDir } = require("./shell.cjs");
const { fileURLToPath } = require("node:url");

const helper = path.join(shellDir, "scripts/wallpaper-thumbnail.py");

// A stand-in `magick` that records its argv and copies the first existing
// file argument (the source) to the last argument (the output).
function fakeMagick(t) {
    const temporary = fs.mkdtempSync(path.join(os.tmpdir(), "qs-thumb-test-"));
    t.after(() => fs.rmSync(temporary, { recursive: true, force: true }));

    const bin = path.join(temporary, "bin");
    const count = path.join(temporary, "magick-count");
    fs.mkdirSync(bin);
    fs.writeFileSync(path.join(bin, "magick"), `#!/bin/sh
printf '%s\\n' "$*" >> "$MAGICK_COUNT"
source=
for output do
    if [ -z "$source" ] && [ -f "$output" ]; then source=$output; fi
done
cp "$source" "$output"
`);
    fs.chmodSync(path.join(bin, "magick"), 0o755);

    const env = {
        ...process.env,
        PATH: `${bin}:${process.env.PATH}`,
        XDG_CACHE_HOME: path.join(temporary, "cache"),
        MAGICK_COUNT: count,
    };
    const spawn = args => childProcess.spawnSync("python3", [helper, ...args], {
        encoding: "utf8",
        env,
    });
    const calls = () => fs.existsSync(count)
        ? fs.readFileSync(count, "utf8").trim().split("\n") : [];
    return { temporary, env, spawn, calls };
}

test("wallpaper thumbnails persist, hit the cache, and revise changed sources", t => {
    const { temporary, spawn, calls } = fakeMagick(t);
    const source = path.join(temporary, "wall paper.png");
    fs.writeFileSync(source, "first image");
    const run = () => {
        const result = spawn([source]);
        assert.equal(result.status, 0, result.stderr);
        return result.stdout.trim();
    };

    const first = run();
    const second = run();
    assert.equal(second, first);
    assert.equal(calls().length, 1,
        "an unchanged source must not invoke ImageMagick again");
    assert.ok(fs.existsSync(fileURLToPath(new URL(first))));

    fs.writeFileSync(source, "changed image with a different size");
    const changed = run();
    assert.notEqual(changed, first, "the URL revision must invalidate Qt's image cache");
    assert.equal(calls().length, 2);
});

test("one helper run answers every source in order, one line each", t => {
    const { temporary, spawn } = fakeMagick(t);
    const first = path.join(temporary, "a.jpg");
    const second = path.join(temporary, "b.jpg");
    fs.writeFileSync(first, "a");
    fs.writeFileSync(second, "bb");

    const result = spawn([first, path.join(temporary, "missing.jpg"), second]);
    assert.equal(result.status, 1, "a failed source is reported through the status");
    const lines = result.stdout.split("\n");
    assert.equal(lines.pop(), "");
    assert.equal(lines.length, 3);
    assert.match(lines[0], /^file:/);
    assert.equal(lines[1], "-", "a failure is a visible marker, never a blank line");
    assert.match(lines[2], /^file:/);
    assert.notEqual(lines[0], lines[2]);
    assert.match(result.stderr, /missing\.jpg/);
    assert.equal(spawn([]).status, 2);
});

test("ImageMagick decodes at preview size, bounded in time and memory", t => {
    const { temporary, spawn, calls } = fakeMagick(t);
    const source = path.join(temporary, "wall.jpg");
    fs.writeFileSync(source, "jpeg");
    assert.equal(spawn([source]).status, 0);
    const argv = calls()[0];
    assert.ok(argv.indexOf("-define jpeg:size=") !== -1
        && argv.indexOf("-define jpeg:size=") < argv.indexOf(source),
        "the size hint must precede the input to reach the decoder");
    assert.match(argv, /-limit memory 256MiB/);
    const script = fs.readFileSync(helper, "utf8");
    assert.match(script, /timeout=MAGICK_TIMEOUT/);
});

test("thumbnail sets from an older cache version are pruned", t => {
    const { temporary, env, spawn } = fakeMagick(t);
    const root = path.join(env.XDG_CACHE_HOME, "quickshell", "wallpaper-thumbnails");
    const stale = path.join(root, "v1-old");
    fs.mkdirSync(stale, { recursive: true });
    fs.writeFileSync(path.join(stale, "x.jpg"), "old");
    const source = path.join(temporary, "wall.png");
    fs.writeFileSync(source, "png");

    assert.equal(spawn([source]).status, 0);
    assert.equal(fs.existsSync(stale), false);
    assert.equal(fs.readdirSync(root).length, 1, "only the current version remains");
});

test("the wallpaper grid requests cached previews instead of full images", () => {
    const page = fs.readFileSync(path.join(shellDir, "Settings/WallpaperPage.qml"), "utf8");
    const wallpaper = fs.readFileSync(path.join(shellDir, "Common/Wallpaper.qml"), "utf8");

    assert.match(page, /Wallpaper\.requestThumbnail\(imagePath\)/);
    assert.match(page, /source:\s*cell\.thumbnailSource/);
    assert.match(wallpaper, /wallpaper-thumbnail\.py/);
    assert.match(wallpaper, /property var thumbnailPaths/);
    assert.match(wallpaper, /stdout:\s*SplitParser/,
        "previews settle line by line as the batch helper answers");
    assert.match(wallpaper,
        /onRunningChanged:\s*\{\s*if \(!running && root\.activeThumbnailBatch\.length > 0\)\s*root\.finishThumbnailBatch\(\)/,
        "a helper that never started must still release its batch");
    assert.doesNotMatch(wallpaper, /onExited/,
        "exited() never arrives when python3 cannot start");
});
