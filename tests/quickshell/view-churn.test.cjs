// View-layer churn: rows that survive a list change keep their delegates,
// hidden views stop animating and polling, and nothing redraws faster than
// what it displays can change. Source contracts for QML wiring that has no
// Node surface.
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { shellDir } = require("./shell.cjs");

function read(relative) {
    return fs.readFileSync(path.join(shellDir, relative), "utf8");
}

test("drawer Bluetooth rows survive discovery churn", () => {
    const drawer = read("Popovers/Drawer/DrawerBluetooth.qml");

    // A fixed section model; an array literal holding the live lists was a
    // new model on every BlueZ add, rename or expiry.
    assert.match(drawer, /model:\s*\["connected", "paired", "nearby"\]/);
    assert.doesNotMatch(drawer, /devices:\s*root\.\w+Devices,\s*show:/);
    assert.match(drawer, /required property string modelData\s*\n\s*readonly property var devices:/);
    // Rows are diffed by device identity.
    assert.match(drawer, /model:\s*ScriptModel \{\s*values:\s*section\.devices\s*\}/);
    assert.doesNotMatch(drawer, /section\.modelData\.devices/);
});

test("drawer Sound rows survive streams coming and going", () => {
    const drawer = read("Popovers/Drawer/DrawerSound.qml");

    assert.match(drawer, /model:\s*ScriptModel \{\s*values:\s*root\.visibleSinks\s*\}/);
    assert.match(drawer, /model:\s*ScriptModel \{\s*values:\s*root\.readyStreams\s*\}/);
    assert.doesNotMatch(drawer, /model:\s*root\.(?:visibleSinks|readyStreams)\b/,
        "a fresh node array as the model rebuilds every row, a dragged slider included");
});

test("the Sound tab samples the mic meter and releases a muted source", () => {
    const drawer = read("Popovers/Drawer/DrawerSound.qml");
    const monitor = drawer.match(/PwNodePeakMonitor \{[\s\S]*?\n    \}/)?.[0] ?? "";

    assert.match(monitor, /enabled:\s*root\.visible && !!Audio\.source && !Audio\.sourceMuted/,
        "a muted source must not hold a capture stream open");
    // The peak arrives at the PipeWire buffer rate; the meter reads a ~15 Hz
    // sample of it, in whole pixels.
    assert.match(drawer,
        /Timer \{\s*interval:\s*66\s*repeat:\s*true\s*running:\s*inputPeak\.enabled\s*onTriggered:\s*root\.micPeak = Format\.clamp01\(inputPeak\.peak\)/);
    assert.match(drawer, /if \(!running\)\s*root\.micPeak = 0;/);
    assert.match(drawer, /width:\s*Math\.round\(parent\.width \* root\.micPeak\)/);
    assert.equal((drawer.match(/inputPeak\.peak/g) ?? []).length, 1,
        "only the sampling timer may read the live peak");
});

test("spinners stop while their view is hidden", () => {
    // PopoutHost keeps an outgoing panel alive, invisible, until the popout
    // closes; an ungated spinner kept rendering behind the incoming one.
    const sites = {
        "Popovers/T3ThreadPage.qml": /running:\s*root\.working && workingGlyph\.visible/,
        "Popovers/HermesToolCard.qml": /running:\s*root\.running && statusGlyph\.visible/,
        "Ui/Button.qml": /running:\s*root\.iconSpinning && iconLabel\.visible/,
        "Ui/MultiSelect.qml": /running:\s*root\.loadingOptions && refreshButton\.visible/,
        "Popovers/WifiPopover.qml": /running:\s*row\.working && signalGlyph\.visible/
    };
    for (const [file, pattern] of Object.entries(sites))
        assert.match(read(file), pattern, file);
    const updates = read("Popovers/UpdatesPopover.qml");
    assert.match(updates, /running:\s*root\.spinning && headerMark\.visible/);
    assert.match(updates, /&& stepMark\.visible && !Theme\.reducedMotion/);
    // A stopped value source keeps its angle; the marks that replace the arc
    // must not inherit the tilt.
    for (const [file, id] of [["Popovers/UpdatesPopover.qml", "headerMark"],
            ["Popovers/UpdatesPopover.qml", "stepMark"],
            ["Popovers/HermesToolCard.qml", "statusGlyph"],
            ["Popovers/WifiPopover.qml", "signalGlyph"]])
        assert.match(read(file),
            new RegExp(`onRunningChanged: if \\(!running\\) ${id}\\.rotation = 0`), `${file} ${id}`);
});

test("roving keyboard pickers move focus before they commit", () => {
    // activeFocusOnTab follows the selection. Committing first asked Qt to
    // clear it on the item that still held focus, which it refuses ("Cannot
    // set activeFocusOnTab to false once item is the active focus item"),
    // leaving a stale second tab stop behind.
    const order = (source, focus, commit, label) => {
        const at = source.indexOf(focus);
        assert.ok(at > 0, `${label}: focus call not found`);
        const next = source.indexOf(commit, at);
        assert.ok(next > at, `${label}: the commit must follow the focus move`);
        assert.ok(next - at < 160, `${label}: the commit must be the focus move's own`);
    };
    order(read("Settings/PillRow.qml"),
        "pillRepeater.itemAt(next).forceActiveFocus();",
        "root.picked(root.model[next].value);", "PillRow");
    const appearance = read("Settings/AppearancePage.qml");
    order(appearance, "swatchRepeater.itemAt(next).forceActiveFocus();",
        "page.pickAccent(page.accentChoices[next]);", "accent swatches");
    order(read("Settings/BarBackgroundGroup.qml"), "barColorRepeater.itemAt(next).forceActiveFocus();",
        "barColorRow.commit(Settings.barColorChoices[next].id);", "bar colours");
    order(read("Settings/CornerPickerRow.qml"),
        "cornerRepeater.itemAt(root.corners.indexOf(target)).forceActiveFocus();",
        "root.pick(target);", "corner picker");
    const view = read("Settings/SettingsView.qml");
    const select = view.slice(view.indexOf("function selectVisible("),
        view.indexOf("function selectOffset("));
    order(select, "item.forceActiveFocus();", "Settings.page = navItems[clamped].id;",
        "settings rail keys");
    assert.match(view,
        /onClicked:\s*\{\s*navItem\.forceActiveFocus\(\);\s*Settings\.page = navItem\.modelData\.id;/,
        "settings rail clicks");

    const tabs = read("Popovers/Drawer/DrawerTabs.qml");
    const activate = tabs.slice(tabs.indexOf("function activateTab("));
    order(activate, "if (target) target.forceActiveFocus();",
        "Popouts.openPanel(name, \"right\");", "drawer tabs");
    const wallpaper = read("Settings/WallpaperPage.qml");
    order(wallpaper.slice(wallpaper.indexOf("function focusThumbnail(")),
        "target.forceActiveFocus();", "wallGrid.currentIndex = clamped;", "wallpaper grid");
    const folders = read("Settings/FolderDialog.qml");
    order(folders.slice(folders.indexOf("function focusFolder(")),
        "target.forceActiveFocus();", "folderList.currentIndex = clamped;", "folder list keys");
    assert.match(folders,
        /onClicked:\s*\{\s*folderRow\.forceActiveFocus\(\);\s*root\.selectedPath = folderRow\.path;\s*folderList\.currentIndex = folderRow\.index;/,
        "folder list clicks");
    const battery = read("Popovers/BatteryPopover.qml");
    order(battery.slice(battery.indexOf("function pickProfile(")),
        "segment.forceActiveFocus();",
        "PowerProfiles.profile = profileRepeater.model[index].profile;", "power profiles");
});

test("open views tick no faster than what they display", () => {
    // Reminder countdowns wake when the soonest label changes: about once a
    // minute, every second only inside a reminder's final minute, and never
    // while the panel is hidden.
    const reminders = read("Popovers/ReminderPopover.qml");
    assert.doesNotMatch(reminders, /SystemClock|precision:/);
    assert.match(reminders, /Countdown\.soonestChangeMs\(/);
    assert.match(reminders,
        /function scheduleTick\(\) \{\s*tick\.stop\(\);\s*nowMs = Date\.now\(\);\s*if \(!visible\)\s*return;/);
    assert.match(reminders, /onVisibleChanged:\s*scheduleTick\(\)/);
    assert.match(reminders, /function onRecordsChanged\(\) \{\s*root\.scheduleTick\(\);/);
    assert.match(reminders, /id:\s*tick\s*onTriggered:\s*root\.scheduleTick\(\)/);
    assert.match(reminders, /Countdown\.remainingLabel\(Number\(due\) \* 1000 - nowMs\)/);

    // The Region & formats page's clock caption is HH:mm.
    const system = read("Settings/RegionPage.qml");
    assert.match(system,
        /SystemClock \{\s*id:\s*clock\s*precision:\s*SystemClock\.Minutes\s*enabled:\s*page\.visible/);
    assert.match(system, /Qt\.formatDateTime\(clock\.date, Settings\.clock24 \? "HH:mm" : "h:mm AP"\)/);
    assert.doesNotMatch(system, /interval:\s*1000/);
});
