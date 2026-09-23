const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { shellDir } = require("./shell.cjs");

const assetsDir = path.join(shellDir, "assets");
const brands = [
    "claude", "fedora", "gemini", "github", "grok", "kimi", "openai",
    "slack", "t3", "tailscale", "whatsapp", "youtube"
];
const whiteVariants = brands.filter(name => name !== "t3");

function read(relative) {
    return fs.readFileSync(path.join(shellDir, relative), "utf8");
}

function codeFiles(dir = shellDir) {
    return fs.readdirSync(dir, { withFileTypes: true }).flatMap(entry => {
        const file = path.join(dir, entry.name);
        if (entry.isDirectory())
            return ["assets", "scripts"].includes(entry.name) ? [] : codeFiles(file);
        return /\.(?:qml|js)$/.test(entry.name) ? [file] : [];
    });
}

function withoutPaint(svg) {
    return svg.replace(/(fill|stroke)="#[0-9a-f]{6}"/gi, '$1="#paint"').trim();
}

test("the brand registry owns canonical and geometry-matched hover SVGs", () => {
    const registry = read("Common/BrandIcons.qml");
    const highlightRegistry = registry.slice(registry.indexOf("highlightFiles"),
        registry.indexOf("readonly property var labels"));
    const assets = fs.readdirSync(assetsDir)
        .filter(name => name.endsWith(".svg"))
        .sort();

    assert.deepEqual(assets, [
        ...brands.map(name => `${name}.svg`),
        ...whiteVariants.map(name => `${name}-white.svg`)
    ].sort());
    for (const name of brands) {
        assert.match(registry, new RegExp(`\\b${name}: "${name}\\.svg"`),
            `${name} must resolve through BrandIcons`);
        const hoverFile = name === "t3" ? "t3.svg" : `${name}-white.svg`;
        assert.match(highlightRegistry,
            new RegExp(`\\b${name}: "${hoverFile.replace(".", "\\.")}"`),
            `${name} must resolve a source-painted hover mark`);

        const canonical = fs.readFileSync(path.join(assetsDir, `${name}.svg`), "utf8");
        const hover = fs.readFileSync(path.join(assetsDir, hoverFile), "utf8");
        assert.equal(withoutPaint(hover), withoutPaint(canonical),
            `${hoverFile} must change paint without changing geometry`);
        assert.match(hover, /#ffffff/i,
            `${hoverFile} must provide the bright menubar paint`);
    }
});

test("product marks render through BrandIcon rather than ad-hoc asset paths", () => {
    const registry = path.join(shellDir, "Common/BrandIcons.qml");
    for (const file of codeFiles()) {
        if (file === registry || file.endsWith("/Common/TablerIcons.qml"))
            continue;
        const source = fs.readFileSync(file, "utf8");
        assert.doesNotMatch(source, /\/assets\/|\.svg["']/,
            `${path.relative(shellDir, file)} bypasses BrandIcons`);
    }

    const icon = read("Common/BrandIcon.qml");
    assert.match(icon, /property bool normalizeTintSource:\s*false/);
    assert.match(icon,
        /source:\s*root\.normalizeTintSource\s*\?\s*BrandIcons\.highlightSource\(root\.name\)\s*:\s*BrandIcons\.source\(root\.name\)/,
        "flat contextual tinting must start from geometry-matched white paint");
    assert.match(icon, /source:\s*BrandIcons\.highlightSource\(root\.name\)/);
    assert.match(icon, /property bool colorized:\s*false/);
    assert.match(icon, /property real tintAmount:\s*colorized \? 1 : 0/);
    assert.match(icon, /property bool highlighted:\s*false/);
    assert.match(icon, /property real highlightAmount:\s*highlighted \? 1 : 0/);
    assert.match(icon, /Behavior on tintAmount/,
        "contextual brand tints must fade like interface icon colours");
    assert.match(icon, /Behavior on highlightAmount/,
        "source-painted hover marks must cross-fade like other bar glyphs");
    assert.match(icon, /colorization:\s*root\.tintAmount/);
    assert.match(icon, /colorizationColor:\s*root\.tint/);
    assert.match(icon, /opacity:\s*1 - root\.highlightAmount/);
    assert.match(icon, /opacity:\s*root\.highlightAmount/);
    assert.match(icon, /Accessible\.ignored:\s*true/);

    const notifs = read("Common/Notifs.qml");
    assert.equal((notifs.match(/BrandIcons\.has\(/g) || []).length, 2,
        "notification-supplied and derived brands must both cross the allow-list");

    const desktopTasks = fs.readFileSync(path.resolve(shellDir,
        "../../../desktop/tasks/main.yml"), "utf8");
    for (const name of whiteVariants)
        assert.doesNotMatch(desktopTasks, new RegExp(`- assets/${name}-white\\.svg`),
            `${name}'s active hover SVG must survive deployment cleanup`);
});

test("Quickshell no longer carries a parallel Nerd Font icon path", () => {
    const sources = codeFiles().map(file => fs.readFileSync(file, "utf8")).join("\n");
    // The default text face includes Nerd Font glyphs; icons still use Sym/BrandIcon.
    assert.doesNotMatch(sources, /fontNerd|/);
});

test("every bundled product mark records pinned provenance and licensing", () => {
    const provenance = read("assets/README.md");
    const licenses = read("assets/THIRD_PARTY_LICENSES.md");

    for (const name of brands)
        assert.match(provenance, new RegExp(`\\b${name}\\.svg\\b`));
    for (const revision of [
        "4a79bb55697c85b8bc9f3caa22be747e0277ad4f",
        "5a0fe38e97784d94279ce4eb1bf85f9a91bf027e",
        "a3a8cbd60539b4af4de8f96c892dbd07a2b6c041",
        "e7ee4e88ac5b43a1acf2ab39157b63c80e8093f2"
    ])
        assert.match(provenance, new RegExp(revision));
    assert.match(licenses, /CC0 1\.0 Universal/);
    assert.match(licenses, /CC BY-SA 4\.0/);
    assert.match(licenses, /Fedora®/);
    assert.equal((licenses.match(/MIT License/g) || []).length, 3);
});
