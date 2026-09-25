const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { shellDir } = require("./shell.cjs");

// The System pages of the 2026-09 Settings redesign — Online accounts,
// Plugins and About — rebuilt on labeled rows whose values and actions end
// on the page's control edge. These hold the intent of that pass: explicit
// empty states, status as hint text, one switch per plugin with the rest
// in a menu, green for healthy, and times people read.

function read(relative) {
    return fs.readFileSync(path.join(shellDir, relative), "utf8");
}

const LocalTime = require(path.join(shellDir, "Settings/LocalTime.js"));

test("timestamps parse the same from Python, recovery ids and plain ISO", () => {
    // quickshell-deploy-health writes Python's isoformat(): six fractional
    // digits and a numeric offset.
    assert.equal(LocalTime.parse("2026-09-24T17:16:48.655239+00:00"), Date.UTC(2026, 8, 24, 17, 16, 48, 655));
    assert.equal(LocalTime.parse("2026-09-24T19:16:48+02:00"), Date.UTC(2026, 8, 24, 17, 16, 48));
    assert.equal(LocalTime.parse("2026-09-24T12:16:48-0500"), Date.UTC(2026, 8, 24, 17, 16, 48));
    assert.equal(LocalTime.parse("20260924T171648Z"), Date.UTC(2026, 8, 24, 17, 16, 48));
    assert.equal(LocalTime.parse("2026-09-24T17:16"), new Date(2026, 8, 24, 17, 16).getTime(),
        "no zone means local time");
    for (const junk of ["", "junk", "2026-13-01T00:00Z", null, undefined, 42])
        assert.ok(Number.isNaN(LocalTime.parse(junk)), String(junk));
});

test("a timestamp reads as today, yesterday, a weekday or a date", () => {
    const now = new Date(2026, 8, 24, 20, 30).getTime();
    const at = (d, h, m, y = 2026, mo = 8) => new Date(y, mo, d, h, m).getTime();
    assert.equal(LocalTime.label(at(24, 19, 16), now, true), "Today at 19:16");
    assert.equal(LocalTime.label(at(24, 19, 16), now, false), "Today at 7:16 PM");
    assert.equal(LocalTime.label(at(23, 8, 2), now, true), "Yesterday at 08:02");
    assert.equal(LocalTime.label(at(23, 0, 5), now, false), "Yesterday at 12:05 AM");
    assert.equal(LocalTime.label(at(20, 21, 40), now, true), "Sunday at 21:40");
    assert.equal(LocalTime.label(at(12, 8, 2), now, true), "12 Sep at 08:02");
    assert.equal(LocalTime.label(at(12, 8, 2, 2025), now, true), "12 Sep 2025");
    // Calendar days, not 24-hour spans: 23:59 yesterday is still yesterday
    // at 00:01 today.
    assert.equal(LocalTime.label(at(23, 23, 59), at(24, 0, 1), true), "Yesterday at 23:59");
    assert.equal(LocalTime.fromText("junk", now, true, "junk"), "junk");
    assert.equal(LocalTime.label(Number.NaN, now, true), "");
});

test("About reads status in the status colours and the check as a time", () => {
    const about = read("Settings/AboutPage.qml");
    assert.match(about, /: Theme\.connected/, "healthy is the green status colour");
    assert.doesNotMatch(about, /Theme\.accent\b/, "the accent is a mark, not a health verdict");
    assert.match(about, /!ShellHealth\.serviceActive \? Theme\.red/);
    assert.match(about, /ShellHealth\.issueCount > 0 \? Theme\.amber/);
    assert.match(about, /label: "Last deploy check"[\s\S]{0,200}?LocalTime\.fromText\(ShellHealth\.deploymentCheckedAt, clock\.date\.getTime\(\),\s*Settings\.clock24/);
    assert.match(about, /SystemClock \{\s*id: clock\s*precision: SystemClock\.Hours\s*enabled: page\.visible/,
        "relative dates roll over at midnight without a per-minute tick");
    assert.match(about, /label: "~\/\.config\/cybexos\/shell\.json"\s*labelMono: true/);
    assert.match(about, /hint: "Every page back to its defaults\. You can undo for 8 seconds\."/);
    assert.match(read("Settings/ValueRow.qml"), /elide: Text\.ElideMiddle/,
        "a path label keeps both of its ends");

    const recovery = read("Settings/RecoveryGroup.qml");
    assert.match(recovery, /delegate: ValueRow \{/, "each recovery point is a row");
    assert.match(recovery, /label: recoveryGroup\.whenTaken\(modelData\.id\)/);
    assert.match(recovery, /modelData\.bootable \? RecoveryHelpers\.pointTime\(modelData\.id\)/,
        "a bootable point also gives the UTC stamp the boot menu lists");
    assert.match(recovery, /label: "Recovery points"\s*value: "None yet"/);
    assert.doesNotMatch(recovery, /ResponsiveActionRow/);
});

test("Online accounts has an explicit empty state and no standing Refresh", () => {
    const accounts = read("Settings/AccountsPage.qml");
    assert.doesNotMatch(accounts, /SystemServiceStatus/);
    assert.doesNotMatch(accounts, /Add or reconnect an account/, "the bare text link is gone");
    assert.match(accounts,
        /visible: page\.service\.loaded && page\.accounts\.length === 0\s*label: "No accounts connected"[\s\S]{0,200}?text: "Add account"[\s\S]{0,60}?primary: true/);
    assert.match(accounts, /visible: page\.service\.error !== ""[\s\S]{0,200}?text: "Refresh"/,
        "Refresh appears with an error, not as a standing control");
    assert.match(accounts, /!page\.service\.loaded \? "Loading accounts…"/);
    assert.match(accounts, /label: "Use calendars"/);
    assert.match(accounts, /text: "Remove…"[\s\S]*?page\.removing = account\.info\.id/);
    assert.match(accounts, /action: "remove", id: account\.info\.id, confirmed: true/,
        "removal still takes the confirming second press");
});

test("each plugin is one row: an Enabled switch and a ⋯ menu", () => {
    const page = read("Settings/PluginsPage.qml");
    const row = read("Settings/PluginRow.qml");
    assert.doesNotMatch(page, /Configure bar widgets/, "plugin widgets are added from the Bar page's tray");
    assert.match(page, /FieldRow \{[\s\S]{0,160}?label: "Source"/);
    assert.match(page, /text: "Install"[\s\S]{0,80}?enabled: !UserPlugins\.busy && page\.source !== ""/);
    assert.match(page, /readonly property string source: PluginSource\.parse\(sourceRow\.text\)/,
        "Install takes the URL out of a pasted omarchy plugin add command");
    assert.match(page, /Plugins run as your desktop user\. Install only packages you trust\. New packages start disabled\./);
    assert.match(page, /delegate: PluginRow \{/);

    assert.match(row, /Toggle \{[\s\S]{0,500}?onToggled: value => root\.run\(\[value \? "enable" : "disable", root\.plugin\.id\]\)/);
    assert.match(row, /glyph: "more_horiz"/);
    assert.match(row, /Controls\.Menu \{[\s\S]*?popupType: Controls\.Popup\.Item/);
    for (const item of ["Update", "Preview update", "Clone as a custom copy…", "Remove…"])
        assert.ok(row.includes(`text: "${item}"`), `the ⋯ menu offers ${item}`);
    assert.match(row, /\["update", root\.plugin\.id, "--preview"\]/);
    assert.match(row, /\["clone", root\.plugin\.id, cloneRow\.text\.trim\(\)\]/);
    assert.match(row, /visible: root\.confirmRemoval[\s\S]{0,700}?root\.run\(\["remove", root\.plugin\.id\]\)/,
        "Remove asks first");
    assert.match(row, /"bar-widget": "a bar widget"/, "the hint says what a plugin adds");
    assert.match(row, /dirty: false\s*resetKeys: \[\]/);
});

test("the Omarchy plugins page links the directory and explains adding one", () => {
    const page = read("Settings/PluginsPage.qml");
    const settings = read("Common/Settings.qml");
    assert.match(settings, /id: "plugins", group: "System", label: "Omarchy plugins"/);
    assert.match(page, /directoryUrl: "https:\/\/plugins\.omarchy\.org\/"/);
    assert.match(page, /text: "Browse plugins"[\s\S]{0,160}?onTriggered: Qt\.openUrlExternally\(page\.directoryUrl\)/);
    assert.equal((page.match(/^\s*Step \{/gm) ?? []).length, 3, "three numbered steps");
    assert.match(page, /title: "Add a plugin"/);
});

test("a pasted install command installs its source", () => {
    const PluginSource = require(path.join(shellDir, "Settings/PluginSource.js"));
    const url = "https://github.com/acme/omarchy-weather.git";
    for (const text of [
        url,
        `  ${url}  `,
        `omarchy plugin add ${url}`,
        `omarchy plugin add ${url} --enable`,
        `omarchy plugin add --enable ${url}`,
        `$ omarchy plugin add "${url}"`,
        `cybex plugin add '${url}'`,
        `Omarchy Plugin Install ${url}\n# then enable it`
    ])
        assert.equal(PluginSource.parse(text), url, JSON.stringify(text));
    assert.equal(PluginSource.parse("~/Code/my plugin"), "~/Code/my plugin", "a bare path keeps its spaces");
    assert.equal(PluginSource.parse("\"/tmp/my plugin\""), "/tmp/my plugin");
    for (const empty of ["", "   ", null, undefined, "omarchy plugin add", "omarchy plugin add --enable"])
        assert.equal(PluginSource.parse(empty), "", JSON.stringify(empty));
});

test("the new System page types are registered", () => {
    const qmldir = read("Settings/qmldir");
    for (const type of ["IdleTimeline", "ValueRow", "FieldRow", "RowCluster", "PluginRow"])
        assert.match(qmldir, new RegExp(`^${type} ${type}\\.qml$`, "m"));
});
