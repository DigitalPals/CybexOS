const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { shellDir, load } = require("./shell.cjs");
const T = load("Typography.js");
const H = load("SettingsHelpers.js");
const M = load("ShellMetrics.js");
const read = file => fs.readFileSync(path.join(shellDir, file), "utf8");

test("Omarchy reference scale and usage roles stay distinct", () => {
    const s = T.resolve(12);
    assert.equal(s.clock, 52);
    assert.deepEqual([s.caption, s.bodySmall, s.body, s.subtitle, s.title,
        s.heading, s.display, s.displayLarge], [10, 11, 12, 13, 14, 16, 24, 28]);
    for (const role of ["bar", "control", "navigation", "primary"])
        assert.equal(s[role], 12, role);
    for (const role of ["secondary", "tooltip"]) assert.equal(s[role], 11, role);
    for (const role of ["section", "metadata"]) assert.equal(s[role], 10, role);
    for (const role of ["notification", "osd"]) assert.equal(s[role], 14, role);
});

test("native and compatibility adapters use the same resolver, without a second type scale", () => {
    const native = read("Common/Theme.qml"), plugin = read("Commons/Style.qml");
    assert.match(native, /Typography\.resolve\(fontBaseSize\)/);
    assert.match(plugin, /Typography\.resolve\(fontBaseSize, fontOverrides\)/);
    for (const name of Object.keys(T.SCALE))
        assert.match(plugin, new RegExp(`property int ${name}: root\\.typography\\.${name}`));
    assert.doesNotMatch(plugin, /fontToken\("(?:caption|body|title|heading|display)/);
    assert.doesNotMatch(native, /property int font\w+: scaled\(/);
});

test("type scaling follows accessibility and UI scale but not spacing density", () => {
    for (const shellFontSize of [10, 12, 14, 24])
        for (const shellScale of [75, 100, 150, 200])
            for (const textScale of ["default", "large", "larger"]) {
                const p = { ...H.defaults(), shellFontSize, shellScale, textScale };
                const base = M.calculate(p).fontBase;
                const expected = T.resolve(base);
                for (const interfaceDensity of ["compact", "default", "comfortable"])
                    assert.deepEqual(T.resolve(M.calculate({ ...p, interfaceDensity }).fontBase), expected);
                assert.equal(expected.bar, base);
                assert.equal(expected.title, Math.max(1, Math.round(base * 1.167)));
                assert.equal(expected.secondary, Math.max(1, Math.round(base * 0.917)));
            }
});

test("plugin token overrides propagate to roles and preserve icon fallback behavior", () => {
    const s = T.resolve(12, { body: 17, "body-small": 15, title: 20 });
    assert.equal(s.bar, 17);
    assert.equal(s.control, 17);
    assert.equal(s.notification, 20);
    assert.equal(s.iconSmall, 15);
    assert.equal(s.icon, 20);
    assert.equal(T.resolve(12, { "icon-small": 9, "body-small": 15 }).iconSmall, 9);
    for (const invalid of [-1, 0, NaN, Infinity, "invalid"])
        assert.equal(T.resolve(12, { body: invalid }).body, 12);
    assert.equal(T.resolve(12, { body: 0.1 }).body, 1);
});

function qmlFiles(dir = shellDir) {
    return fs.readdirSync(dir, { withFileTypes: true }).flatMap(entry => {
        const file = path.join(dir, entry.name);
        return entry.isDirectory() ? qmlFiles(file) : file.endsWith(".qml") ? [file] : [];
    });
}

test("views cannot introduce pixel literals, point sizes, or ambiguous legacy text tokens", () => {
    for (const file of qmlFiles()) {
        const source = fs.readFileSync(file, "utf8"), name = path.relative(shellDir, file);
        assert.doesNotMatch(source, /\b(?:pixelSize|pointSize)\s*:\s*\d/, name);
        assert.doesNotMatch(source, /font\.pointSize\s*:/, name);
        assert.doesNotMatch(source, /font\.pixelSize:\s*Theme\.scaled\(/, name);
        assert.doesNotMatch(source, /font\.pixelSize:\s*Theme\.font(?:Micro|Tiny|Caption|Secondary|Body|Heading|Prominent|Display|Hero)\b/, name);
        // These two exceptions size icon glyphs, never copy.
        if (!["Bar/HermesChip.qml", "Ui/MultiSelect.qml"].includes(name))
            assert.doesNotMatch(source, /font\.pixelSize:[^\n]*(?:\s[+*\/-]\s)/, name);
    }
});

test("bar labels, navigation, controls and notification surfaces use their assigned roles", () => {
    for (const file of qmlFiles(path.join(shellDir, "Bar"))) {
        const source = fs.readFileSync(file, "utf8");
        for (const match of source.matchAll(/font\.pixelSize: Theme\.typography\.(\w+)/g))
            assert.equal(match[1], path.basename(file) === "BarTooltip.qml" ? "tooltip" : "bar", file);
    }
    assert.match(read("Settings/SettingsView.qml"), /font\.pixelSize: Theme\.typography\.navigation/);
    assert.match(read("Popovers/Drawer/DrawerTabs.qml"), /font\.pixelSize: Theme\.typography\.navigation/);
    for (const file of ["NotificationToasts.qml", "Popovers/NotifsPopover.qml", "Popovers/Drawer/DrawerNotifications.qml"])
        for (const key of ["header", "body"])
            assert.match(read(file), new RegExp(`${key}: Theme\\.typography\\.notification`), file);
    for (const file of qmlFiles()) {
        const source = fs.readFileSync(file, "utf8");
        for (const match of source.matchAll(/\b(?:TextInput|TextEdit|Controls\.TextField)\s*\{(?:(?!font\.pixelSize:)[\s\S]){0,2500}font\.pixelSize:\s*Theme\.typography\.(\w+)/g)) {
            // The launcher query has the same prominence as its result labels.
            if (path.relative(shellDir, file) === "LauncherView.qml")
                assert.equal(match[1], "heading", `${file}: launcher query`);
            else
                assert.ok(["control", "title"].includes(match[1]), `${file}: input uses ${match[1]}`);
        }
    }
});
