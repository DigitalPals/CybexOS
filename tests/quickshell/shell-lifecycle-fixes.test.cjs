// Lifecycle and churn fixes across the launcher, notifications, notes,
// palette and clipboard providers. The pure halves are tested directly; the
// QML halves are pinned by source so a later edit cannot quietly restore the
// old shape.
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { shellDir, load } = require("./shell.cjs");

const Notif = load("NotifHelpers.js");
const Providers = load("LauncherProviders.js");

function read(relative) {
    return fs.readFileSync(path.join(shellDir, relative), "utf8");
}

test("a minute countdown wakes when its label changes and at the deadline", () => {
    const until = 10 * 60000;
    // 9 min 30 s left reads "10 min"; it becomes "9 min" 30 s later.
    assert.equal(Notif.countdownTickMs(until, until - 9.5 * 60000), 30000);
    // Exactly on a boundary: a full minute until the next label.
    assert.equal(Notif.countdownTickMs(until, until - 5 * 60000), 60000);
    // The last minute waits for the deadline itself.
    assert.equal(Notif.countdownTickMs(until, until - 12000), 12000);
    assert.equal(Notif.countdownTickMs(until, until), 0);
    assert.equal(Notif.countdownTickMs(until, until + 5), 0);
    assert.equal(Notif.countdownTickMs(until, until - 60001), 50,
        "an early coarse-timer wake-up must not spin");
    assert.equal(Notif.countdownTickMs(until, until - 60001, 1), 1);
});

test("Do Not Disturb no longer ticks every second", () => {
    const notifs = read("Common/Notifs.qml");
    assert.doesNotMatch(notifs, /interval:\s*1000\b/);
    assert.match(notifs, /Helpers\.countdownTickMs\(Settings\.notifDndUntilMs, dndClockMs\)/);
    assert.match(notifs, /function onNotifDndUntilMsChanged\(\)[\s\S]*?root\.scheduleDndTick\(\)/);
});

test("a replaced notification updates its toast and history entry in place", () => {
    const notifs = read("Common/Notifs.qml");
    for (const name of ["summaryChanged", "bodyChanged", "appIconChanged",
        "imageChanged", "urgencyChanged", "actionsChanged", "hintsChanged"])
        assert.match(notifs, new RegExp(`"${name}"`));
    assert.match(notifs, /notif\[name\]\.connect\(changed\)/);
    assert.match(notifs, /notif\[name\]\.disconnect\(changed\)/,
        "a closed notification must drop its replacement handlers");
    assert.match(notifs, /root\.updateEntry\(entry\.key, Object\.assign\(\s*\{ actions: notif\.actions \}, root\.describe\(root\.remoteSource\(notif\)\)\)\)/);
    assert.match(notifs, /Qt\.callLater\(refresh\)/,
        "one replacement changes many properties; rebuild once");
});

test("the drawer's hour boundary only re-slices when it moves", () => {
    const drawer = read("Popovers/Drawer/DrawerNotifications.qml");
    assert.match(drawer, /readonly property int recentCount:/);
    assert.match(drawer, /recent:\s*entries\.slice\(0, recentCount\)/);
    assert.match(drawer, /earlier:\s*entries\.slice\(recentCount\)/);
    assert.doesNotMatch(drawer, /entries\.filter\(/);
    assert.equal((drawer.match(/model:\s*ScriptModel\s*\{/g) || []).length, 2,
        "both card lists keep surviving delegates");
});

test("launcher commands run detached, with the text passed as an argument", () => {
    const launcher = read("Common/Launcher.qml");
    assert.doesNotMatch(launcher, /id:\s*commandProc|StdioCollector/);
    assert.match(launcher, /Quickshell\.execDetached\(\["sh", "-c",[\s\S]*?'sh -c "\$1"[\s\S]*?"sh", command\]\)/);
    assert.match(launcher, /notify-send "Launcher command failed"/);
});

test("the notes list is not rebuilt behind the editor and edits are debounced", () => {
    const panel = read("Popovers/NotesPopover.qml");
    assert.match(panel, /model:\s*root\.editing \? \[\] : Notes\.records/);
    assert.match(panel, /onTextChanged:\s*\{\s*if \(!noteEdit\.syncing\)\s*persistTimer\.restart\(\);/);
    const finish = panel.slice(panel.indexOf("function finishEditing("),
        panel.indexOf("function deleteEditing("));
    assert.match(finish, /persistTimer\.stop\(\);\s*persistEditor\(\);\s*const id = editingId;/,
        "a draft inside the debounce window must be committed before closing");
});

test("the palette is gated on wallpaper mode, bounded, and keyed by file", () => {
    const palette = read("Common/Palette.qml");
    assert.match(palette, /Settings\.paletteMode !== "wallpaper"/);
    assert.match(palette, /function onPaletteModeChanged\(\)/);
    assert.match(palette, /\["timeout", "20s"\]\.concat\(\["matugen"/);
    assert.match(palette, /\["stat", "-L", "-c", "%Y %s", "--", activeIdentity\]/);
    assert.match(palette, /PaletteHelpers\.readCache\(cacheStore\.text\(\), identity, stamp\)/);
    assert.match(palette, /serializeCache\(completedIdentity,\s*palette, completedStamp, cacheStore\.text\(\)\)/);
});

test("clipboard watchers restart with a bounded backoff", () => {
    assert.equal(Providers.watcherRestartDelayMs(0), 1000);
    assert.equal(Providers.watcherRestartDelayMs(1), 2000);
    assert.equal(Providers.watcherRestartDelayMs(5), 32000);
    assert.equal(Providers.watcherRestartDelayMs(6), 60000);
    assert.equal(Providers.watcherRestartDelayMs(500), 60000);
    assert.equal(Providers.watcherRestartDelayMs(-3), 1000);
    assert.equal(Providers.watcherRestartDelayMs(undefined), 1000);

    const providers = read("Common/LauncherProviders.qml");
    assert.match(providers, /component ClipboardWatcher: Process/);
    assert.match(providers, /ProviderHelpers\.watcherRestartDelayMs\(failures\)/);
    assert.equal((providers.match(/ClipboardWatcher \{\s*watch: "wl-paste --type (text|image) --watch "/g) || []).length, 2);
});

test("emoji data is read only once the Emoji provider is used", () => {
    const providers = read("Common/LauncherProviders.qml");
    assert.match(providers,
        /path:\s*root\.emojiRequested \? "\/usr\/share\/unicode\/emoji\/emoji-test\.txt" : ""/);
    assert.match(providers,
        /activeProviderId === "emoji" && !root\.emojiRequested\) \{[\s\S]*?root\.emojiLoading = true;[\s\S]*?root\.emojiRequested = true;/);
});
