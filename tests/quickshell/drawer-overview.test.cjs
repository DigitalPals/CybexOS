const test = require("node:test");
const { untranslated } = require("./shell.cjs");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { shellDir } = require("./shell.cjs");

const overview = untranslated(fs.readFileSync(
    path.join(shellDir, "Popovers", "Drawer", "DrawerOverview.qml"), "utf8"));
const hero = untranslated(fs.readFileSync(
    path.join(shellDir, "Popovers", "Drawer", "DrawerSystemHero.qml"), "utf8"));
const drawer = untranslated(fs.readFileSync(
    path.join(shellDir, "Popovers", "Drawer", "DrawerPopover.qml"), "utf8"));
const power = untranslated(fs.readFileSync(
    path.join(shellDir, "Popovers", "Drawer", "DrawerPower.qml"), "utf8"));
const drawerSettings = untranslated(fs.readFileSync(
    path.join(shellDir, "Settings", "DrawerPage.qml"), "utf8"));
const sliderRow = untranslated(fs.readFileSync(
    path.join(shellDir, "Popovers", "Drawer", "DrawerSliderRow.qml"), "utf8"));
const drawerTile = untranslated(fs.readFileSync(
    path.join(shellDir, "Popovers", "Drawer", "DrawerTile.qml"), "utf8"));

test("Overview starts with one fixed system hero and owns its watcher", () => {
    const systemHero = overview.indexOf("DrawerSystemHero {");
    const media = overview.indexOf("// ---- now playing");

    assert.ok(systemHero >= 0, "Overview system hero is missing");
    assert.ok(systemHero < media, "the system hero must precede optional content");
    assert.doesNotMatch(hero, /Settings\.drawerOverview/,
        "machine identity must not acquire another visibility setting");
    assert.doesNotMatch(overview, /id:\s*statsGrid/,
        "the temporary three-card stats grid must be removed");
    assert.match(overview,
        /Claim\s*\{[\s\S]{0,180}?active:\s*root\.visible[\s\S]{0,180}?SysInfo\.acquire\(\)[\s\S]{0,180}?SysInfo\.release\(\)/,
        "Overview must own the system sampler while it is visible");
});

test("the hero presents NerdOS identity, machine details, and three wide meters", () => {
    assert.match(hero,
        /readonly property int logoSize:\s*Theme\.scaled\(56\)/);
    assert.match(hero, /BrandIcon\s*\{[\s\S]{0,120}?name:\s*"nerdos"/);
    assert.match(hero, /name:\s*"computer"/,
        "unreadable OS metadata needs a generic-computer fallback");

    for (const property of [
        "osName", "osVersion", "osVariant", "deviceVendor",
        "deviceModel", "kernelRelease", "uptimeSecs", "cpuModel", "cpuUsage",
        "cpuTemp", "memUsedBytes", "memTotalBytes", "swapUsedBytes",
        "swapTotalBytes", "rootFsUsedBytes", "rootFsTotalBytes",
        "rootFsAvailableBytes", "rootFsType",
    ])
        assert.match(hero, new RegExp(`SysInfo\\.${property}\\b`),
            `${property} is absent from the hero`);

    assert.doesNotMatch(hero, /SysInfo\.user\b/,
        "the hero must not expose the logged-in user");
    assert.doesNotMatch(hero, /SysInfo\.host\b/,
        "the hero must not expose the hostname");

    for (const label of ["CPU", "MEMORY", "DISK /"])
        assert.ok(hero.includes(`label: "${label}"`), `${label} meter is missing`);
    assert.match(hero, /BlockMeter\s*\{/);
    assert.match(hero,
        /SysInfo\.swapTotalBytes === 0\)[\s\S]{0,80}?" · No swap"/);
    assert.match(hero, /SysInfo\.memUsage >= 95[\s\S]*SysInfo\.memUsage >= 85/);
    assert.match(hero, /SysInfo\.rootFsUsage >= 90[\s\S]*SysInfo\.rootFsUsage >= 80/);
    assert.match(hero, /SysInfo\.cpuTemp >= 80[\s\S]*SysInfo\.cpuTemp >= 65/);
    assert.match(hero,
        /color:\s*severity >= 2 \? Theme\.redBgSoft[\s\S]{0,120}?"transparent"/,
        "healthy metric rows must stay flat and warning-only rows may tint");
    assert.match(hero, /status:\s*SysInfo\.cpuTempKnown/,
        "temperature belongs beside CPU utilization");
    assert.match(hero, /detail:\s*root\.memoryDetail/);
    assert.match(hero, /detail:\s*root\.diskDetail/);
});

test("unknown readings stay explicit and each metric has one accessible summary", () => {
    for (const known of ["cpuUsageKnown", "cpuTempKnown", "memKnown",
        "swapKnown", "rootFsKnown"])
        assert.match(hero, new RegExp(`SysInfo\\.${known}\\b`));
    assert.match(hero, /"Unavailable"/);
    assert.match(hero, /temperature unavailable/i);
    assert.match(hero, /Memory unavailable/);
    assert.match(hero, /Storage unavailable/);
    assert.match(hero, /Accessible\.role:\s*Accessible\.StaticText/);
    assert.match(hero, /Accessible\.name:\s*metric\.accessibleName/);
    assert.match(hero, /accessibleDescription:\s*SysInfo\.rootFsError/);
});

test("Overview sliders expose values and active toggles use a stronger fill", () => {
    assert.equal((overview.match(/showValue:\s*true/g) || []).length, 2,
        "brightness and volume should both show their current percentage");
    assert.match(sliderRow,
        /text:\s*Math\.round\(root\.value \* 100\) \+ "%"/);
    assert.match(drawerTile,
        /color:\s*on \? Theme\.accentAlpha\(0\.22\) : Theme\.chip/);
});

test("drawer caps and scrolls only its body while keeping tabs pinned", () => {
    const tabs = drawer.indexOf("DrawerTabs {");
    const viewport = drawer.indexOf("id: bodyViewport");
    assert.ok(tabs >= 0 && viewport > tabs,
        "the tab strip must remain outside and above the scrolling viewport");
    assert.match(drawer,
        /bodyHeightLimit:[\s\S]{0,180}?availableHeight[\s\S]{0,180}?drawerTabs\.height/);
    assert.match(drawer, /Flickable\s*\{[\s\S]{0,100}?id:\s*bodyFlick/);
    assert.match(drawer, /contentHeight:\s*bodyLoader\.implicitHeight/);
    assert.match(drawer, /ScrollChrome\s*\{[\s\S]{0,100}?target:\s*bodyFlick/);
    assert.match(drawer,
        /onTabChanged:[\s\S]{0,100}?bodyFlick\.contentY = 0/,
        "every tab switch must return its new body to the top");
    assert.match(drawer,
        /onActiveFocusItemChanged\(\)[\s\S]{0,180}?root\.revealFocus\(item\)/,
        "keyboard focus must be revealed inside an overflowed body");
});

test("Power no longer owns machine stats", () => {
    assert.doesNotMatch(power, /id:\s*statsGrid/);
    assert.doesNotMatch(power, /SysInfo\.(?:cpuUsage|memUsage|cpuTemp)/);
    assert.doesNotMatch(power, /SysInfo\.(?:acquire|release)\(\)/,
        "opening Power must not start the stats sampler");
});

test("Overview no longer exposes model usage", () => {
    assert.doesNotMatch(overview,
        /MODEL USAGE|DrawerUsageRows|Settings\.drawerOverview\.usage|Usage\./);
    assert.doesNotMatch(drawerSettings,
        /key:\s*"usage"\s*,\s*label:\s*"Model usage"/);
});
