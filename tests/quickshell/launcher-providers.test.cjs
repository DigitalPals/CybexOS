const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { load, shellDir } = require("./shell.cjs");

const P = load("LauncherProviders.js");

test("provider registry preserves every launcher mode and adds palette providers", () => {
    assert.deepEqual(P.PROVIDERS.map(provider => provider.id), [
        "files", "command", "calculator", "web", "windows",
        "clipboard", "emoji", "actions", "apps"
    ]);
    assert.equal(P.providerFor("firefox").id, "apps");
    assert.equal(P.providerFor("/notes").id, "files");
    assert.equal(P.providerFor(";deploy token").id, "clipboard");
    assert.equal(P.providerFor(":rocket").id, "emoji");
    assert.equal(P.providerFor("!wallpaper").id, "actions");
    assert.equal(P.prefixedProviderFor("firefox"), null);
    assert.equal(P.prefixedProviderFor(":rocket").id, "emoji");
    assert.deepEqual(P.TAB_IDS, ["apps", "emoji", "clipboard", "actions"]);
    assert.equal(P.providerById("emoji").enter, "paste");
    assert.equal(P.termFor(";  deploy token  "), "deploy token");
    assert.equal(new Set(P.PROVIDERS.map(provider => provider.prefix)).size,
        P.PROVIDERS.length, "prefixes must be unique, including the default");
});

test("clearing a prefix restores the selected tab provider", () => {
    const selectedTab = "clipboard";

    assert.equal(P.prefixedProviderFor(":rocket").id, "emoji");
    assert.equal(P.prefixedProviderFor(""), null);
    assert.equal(P.providerById(selectedTab).id, "clipboard");
});

test("app scoring keeps an empty directory alphabetical and adds usage later", () => {
    const app = {
        id: "org.mozilla.firefox.desktop",
        name: "Firefox",
        genericName: "Web Browser",
        keywords: ["internet", "browser"]
    };

    assert.equal(P.appScore(app, "", 9000), 1);
    assert.equal(P.appScore(app, "fire", 12), 8012);
    assert.equal(P.appScore(app, "browser", 12), 6012);
    assert.equal(P.appScore(app, "internet", 12), 6012);
    assert.equal(P.appScore(app, "terminal", 12), -1);
});

test("clipboard rows retain the opaque cliphist entry and recognize images", () => {
    const rows = P.clipboardRows([
        "41\tsecond text",
        "42\t[[ binary data 1920x1080 png ]]",
        "43\tdeploy token"
    ], "", 8);

    assert.equal(rows.length, 3);
    assert.equal(rows[0].raw, "41\tsecond text");
    assert.equal(rows[1].image, true);
    assert.equal(rows[1].title, "Clipboard image");
    assert.deepEqual(P.clipboardRows(rows.map(row => row.raw), "deploy", 8)
        .map(row => row.raw), ["43\tdeploy token"]);
});

test("emoji parser accepts only fully-qualified entries and searches names", () => {
    const source = [
        "1F600 ; fully-qualified # 😀 E1.0 grinning face",
        "1F3F3 FE0F 200D 1F308 ; fully-qualified # 🏳️‍🌈 E4.0 rainbow flag",
        "263A ; unqualified # ☺ E0.6 smiling face"
    ].join("\n");
    const entries = P.parseEmojiData(source);

    assert.deepEqual(entries, [
        { emoji: "😀", name: "grinning face" },
        { emoji: "🏳️‍🌈", name: "rainbow flag" }
    ]);
    assert.deepEqual(P.emojiRows(entries, "rainbow", 8)
        .map(row => row.value), ["🏳️‍🌈"]);
    assert.match(P.emojiRows(entries, "rainbow", 8)[0].subtitle,
        /Enter to paste/);
});

test("user actions require a name and argv command and cannot inject glyphs", () => {
    const parsed = P.parseActions(JSON.stringify([
        {
            id: "project",
            name: "Open project",
            subtitle: "Launch an editor",
            keywords: ["code", "work"],
            glyph: "untrusted_icon",
            command: ["code", "/tmp/project"]
        },
        { name: "Missing command" },
        { name: "String command", command: "rm -rf /" },
        { id: "project", name: "Duplicate", command: ["true"] }
    ]));

    assert.equal(parsed.error, "");
    assert.equal(parsed.actions.length, 1);
    assert.equal(parsed.actions[0].id, "user-project");
    assert.deepEqual(parsed.actions[0].command, ["code", "/tmp/project"]);
    assert.equal(parsed.actions[0].glyph, "bolt");
    assert.deepEqual(P.actionRows(parsed.actions, "work", 8)
        .map(row => row.title), ["Open project"]);
    assert.deepEqual(P.actionRows(parsed.actions, "editor", 8)
        .map(row => row.title), ["Open project"],
        "subtitles remain searchable even though the view does not draw them");
    assert.notEqual(P.parseActions("{").error, "");
    assert.notEqual(P.parseActions("{}").error, "");
});

function qmlFiles(dir) {
    return fs.readdirSync(dir, { withFileTypes: true }).flatMap(entry => {
        const full = path.join(dir, entry.name);
        if (entry.isDirectory())
            return qmlFiles(full);
        return entry.name.endsWith(".qml") ? [full] : [];
    });
}

// Hyprland here reads every dispatch as Lua (`hl.dispatch(<request>)`), so a
// plain dispatcher word such as `focuswindow address:…` is a syntax error
// that fails silently from the shell's side.
test("window activation restores through the checked workspace API", () => {
    const providers = fs.readFileSync(
        path.join(shellDir, "Common/LauncherProviders.qml"), "utf8");
    assert.match(providers, /case "windows":[\s\S]*?row\.win && DesktopWorkspaces\.activate\(row\.win\.address\)/);
    const owner = fs.readFileSync(path.join(shellDir, "Common/DesktopWorkspaces.qml"), "utf8");
    assert.match(owner, /return !isLive\(address\) \? "" : ready/);
    assert.match(owner, /WindowCommands\.desktopActivate\(address\) : WindowCommands\.focusWindow\(address\)/);
    assert.match(owner, /commandProc\.command = \["hyprctl", "eval", next\.expression\]/);

    for (const file of qmlFiles(shellDir)) {
        const source = fs.readFileSync(file, "utf8");
        for (const match of source.matchAll(/Hyprland\.dispatch\(\s*(['"`])(.*)/g))
            assert.ok(match[2].startsWith("hl.dsp."),
                `${path.relative(shellDir, file)} dispatches a non-Lua request: ${match[0]}`);
    }
});

// Quickshell emits no `exited` when a binary cannot be launched, only the
// falling edge of `running`; a provider waiting for `exited` would stay
// "Searching…" forever when fd, qalc or sh is missing.
test("launcher searches settle even when their binary never starts", () => {
    const providers = fs.readFileSync(
        path.join(shellDir, "Common/LauncherProviders.qml"), "utf8");
    for (const [id, loading] of [["fileProc", "fileLoading"],
            ["calcProc", "calcLoading"], ["clipboardListProc", "clipboardLoading"]]) {
        const start = providers.indexOf(`id: ${id}`);
        assert.notEqual(start, -1, `${id} is missing`);
        const next = providers.indexOf("\n    Process {", start);
        const next2 = providers.indexOf("\n    Timer {", start);
        const end = Math.min(...[next, next2].filter(i => i !== -1), providers.length);
        const block = providers.slice(start, end);
        const falling = block.slice(block.indexOf("onRunningChanged"));
        assert.match(falling, /exitSeen \? lastExit : ProcHelpers\.NOT_STARTED/,
            `${id} must settle on the falling edge of running`);
        assert.match(falling, new RegExp(`root\\.${loading} = false`),
            `${id} must clear its loading state on the falling edge`);
        const exited = block.slice(block.indexOf("onExited"),
            block.indexOf("}", block.indexOf("onExited")));
        assert.doesNotMatch(exited, new RegExp(loading),
            `${id} must not wait for an exited signal that may never come`);
    }
});

// ---- Command palette: the curated verb catalogue ---------------------------

const BUILTIN_IDS = ["settings", "wallpaper-shuffle", "dnd-toggle", "lock", "power"];

test("the catalogue groups every action under one known verb, in verb order", () => {
    const verbs = P.VERBS.map(verb => verb.id);
    assert.deepEqual(P.VERBS.map(verb => verb.label),
        ["Install", "Remove", "Set up", "Toggle", "Update", "Capture", "System"]);
    const ids = P.BUILTIN_ACTIONS.map(action => action.id);
    assert.equal(new Set(ids).size, ids.length, "action ids must be unique");
    let previous = 0;
    for (const action of P.BUILTIN_ACTIONS) {
        const rank = verbs.indexOf(action.verb);
        assert.ok(rank !== -1, `${action.id} has an unknown verb ${action.verb}`);
        assert.ok(rank >= previous, `${action.id} is out of verb order`);
        previous = rank;
        assert.ok(action.name && action.subtitle && action.glyph, action.id);
        // Exactly one way to run: a command, a Settings page, or a built-in.
        const ways = [Array.isArray(action.command), !!action.settingsPage,
            BUILTIN_IDS.includes(action.id)].filter(Boolean).length;
        assert.equal(ways, 1, `${action.id} must have exactly one effect`);
        if (action.requires)
            assert.ok(P.FEATURE_FLAGS.includes(action.requires), action.id);
    }
    for (const id of BUILTIN_IDS)
        assert.ok(ids.includes(id), `${id} kept its id`);
});

test("the catalogue wires every cross-package command exactly as named", () => {
    const byId = Object.fromEntries(P.BUILTIN_ACTIONS.map(action => [action.id, action]));
    const commands = {
        "webapp-install": ["cybexos-webapp", "install", "--notify", "--url", "{argument}"],
        "webapp-remove": ["cybexos-webapp", "remove", "--notify", "{argument}"],
        "theme-install": ["cybex", "theme", "install", "{argument}"],
        "ai-agent-choose": ["cybex", "agent", "--window", "--pick"],
        "ai-agent-launch": ["cybex", "agent", "--window"],
        "game-mode": ["game-mode", "toggle"],
        "updates-check": ["cybexos-runtime", "ipc", "updates", "check"],
        "updates-open": ["cybexos-runtime", "ipc", "updates", "open"],
        "screenshot-region": ["screenshot", "region"],
        "screenshot-fullscreen": ["screenshot", "fullscreen"],
        "screenshot-scroll": ["screenshot", "scroll"],
        "screen-record": ["screen-record"],
        "screen-record-webcam": ["screen-record", "--webcam"],
        "color-picker": ["color-picker"],
        "screen-ocr": ["screen-ocr"],
        "backup-now": ["cybex", "backup", "now"],
        "overview": ["cybexos-runtime", "ipc", "overview", "open"],
        "report": ["cybex", "report"]
    };
    for (const [id, command] of Object.entries(commands))
        assert.deepEqual(byId[id] && byId[id].command, command, id);
    const pages = {
        "security-fingerprint": ["security", undefined],
        "security-key": ["security", undefined],
        "security-open": ["security", undefined],
        "backup-setup": ["backup", undefined],
        "recovery": ["about", "recoveryPoints"]
    };
    for (const [id, [page, key]] of Object.entries(pages)) {
        assert.equal(byId[id].settingsPage, page, id);
        assert.equal(byId[id].settingsKey, key, id);
    }
    // Every capture waits for the launcher to leave the screen.
    for (const action of P.BUILTIN_ACTIONS.filter(action => action.verb === "capture"))
        assert.equal(action.settle, true, action.id);
    // Commands resolve from the system PATH, where NixOS installs
    // the immutable wrappers; personal actions can use explicit personal paths.
    for (const action of P.BUILTIN_ACTIONS.filter(action => action.command))
        assert.match(action.command[0], /^[a-z][a-z-]+$/, action.id);
});

test("factory reset is never one launcher Enter away", () => {
    const text = JSON.stringify(P.BUILTIN_ACTIONS).toLowerCase();
    assert.doesNotMatch(text, /factory|reset|wipe|erase/);
});

test("actions for a feature the installation left out are hidden", () => {
    const ids = flags => P.availableActions(P.BUILTIN_ACTIONS, flags).map(action => action.id);
    assert.ok(ids({ developerTools: true }).includes("ai-agent-launch"));
    assert.ok(ids({ developerTools: true }).includes("ai-agent-choose"));
    assert.ok(!ids({ developerTools: false }).includes("ai-agent-launch"));
    assert.ok(!ids({}).includes("ai-agent-choose"));
    assert.ok(ids({}).includes("game-mode"), "ungated actions always show");
    const connected = [{ id: "c", requires: "connectedWidgets" }, { id: "plain" }];
    assert.deepEqual(P.availableActions(connected, { connectedWidgets: false })
        .map(action => action.id), ["plain"]);
    assert.deepEqual(P.availableActions(connected, { connectedWidgets: true })
        .map(action => action.id), ["c", "plain"]);
});

test("the Actions list shows every entry grouped by verb and tagged", () => {
    const rows = P.actionRows(P.BUILTIN_ACTIONS, "", P.BUILTIN_ACTIONS.length);
    assert.equal(rows.length, P.BUILTIN_ACTIONS.length,
        "the catalogue scrolls instead of being cut at eight rows");
    assert.deepEqual(rows.map(row => row.action.id),
        P.BUILTIN_ACTIONS.map(action => action.id));
    assert.equal(rows[0].tag, "Install");
    assert.equal(rows.at(-1).tag, "System");
    const user = P.parseActions(JSON.stringify([{ name: "Notes", command: ["true"] }])).actions;
    assert.equal(P.actionRows(user, "", 8)[0].tag, "Custom");
    // A name match outranks one found only in another entry's keywords.
    assert.equal(P.actionRows(P.BUILTIN_ACTIONS, "lock", 8)[0].action.id, "lock");
    assert.equal(P.actionRows(P.BUILTIN_ACTIONS, "web install", 8)[0].action.id,
        "webapp-install", "every word of a query may match in any order");
});

test("a typed Apps query blends at most three marked actions after the apps", () => {
    const apps = [{ providerId: "apps", kind: "app", title: "Screenshot Tool" }];
    assert.deepEqual(P.blendRows(apps, P.BUILTIN_ACTIONS, ""), apps,
        "the empty query stays the plain application directory");
    assert.deepEqual(P.blendRows(apps, P.BUILTIN_ACTIONS, "s"), apps,
        "a single character is too loose to offer actions");
    const rows = P.blendRows(apps, P.BUILTIN_ACTIONS, "screenshot");
    assert.equal(rows[0], apps[0], "apps keep their place first");
    const blended = rows.slice(1);
    assert.ok(blended.length > 0 && blended.length <= P.BLEND_LIMIT);
    for (const row of blended) {
        assert.equal(row.blended, true);
        assert.equal(row.tag, "Action");
        assert.equal(row.kind, "action");
    }
    assert.equal(blended[0].action.verb, "capture");
    // Matches must start a word of the name or keywords: a subtitle-only or
    // mid-word substring does not join the app results.
    assert.deepEqual(P.blendedActionRows(P.BUILTIN_ACTIONS, "creensho"), []);
    assert.deepEqual(P.blendedActionRows(P.BUILTIN_ACTIONS, "pixel"), [],
        "a subtitle-only match stays in the Actions tab");
    assert.deepEqual(P.blendedActionRows(P.BUILTIN_ACTIONS, "monitor")
        .map(row => row.action.id), ["screenshot-fullscreen"], "keywords count");
    assert.ok(P.blendedActionRows(P.BUILTIN_ACTIONS, "game").some(row =>
        row.action.id === "game-mode"));
});

test("argument actions validate their one value before Enter can run them", () => {
    const install = P.BUILTIN_ACTIONS.find(action => action.id === "webapp-install");
    const theme = P.BUILTIN_ACTIONS.find(action => action.id === "theme-install");
    for (const action of P.BUILTIN_ACTIONS.filter(action => action.argument || action.choices)) {
        assert.equal(action.command.filter(part => part === "{argument}").length, 1, action.id);
        assert.ok(action.name.endsWith("…"), `${action.id} reads as a prompt`);
        if (action.argument)
            for (const key of ["kind", "label", "placeholder", "hint", "submit"])
                assert.ok(action.argument[key], `${action.id}.argument.${key}`);
    }

    assert.deepEqual(P.argumentRows(install, ""), []);
    assert.equal(P.argumentEmptyText(install, ""), install.argument.hint);
    const rows = P.argumentRows(install, "app.slack.com");
    assert.equal(rows.length, 1);
    assert.equal(rows[0].kind, "argument");
    assert.equal(rows[0].value, "https://app.slack.com/", "a bare host gets https");
    assert.equal(rows[0].title, "Install web app from app.slack.com");
    for (const bad of ["ftp://example.com", "javascript:alert(1)", "https://user:pw@example.com",
        "https://exa mple.com", "https://example.com:99999", "file:///etc/passwd",
        "https://-bad.example", "https://x.com/\u0007"]) {
        assert.deepEqual(P.argumentRows(install, bad), [], bad);
        assert.notEqual(P.argumentEmptyText(install, bad), "", bad);
    }
    assert.equal(P.webUrlArgument("http://192.168.1.20:8123/lovelace").ok, true,
        "local http services are web apps too");

    for (const good of ["https://github.com/owner/theme", "git@github.com:owner/theme.git",
        "ssh://git@example.com/owner/theme"])
        assert.equal(P.argumentRows(theme, good).length, 1, good);
    for (const bad of ["https://github.com", "http://github.com/owner/theme", "--upload-pack=x",
        "ext::sh -c id", "/home/user/theme", "file:///tmp/theme",
        "https://token@github.com/owner/theme"])
        assert.deepEqual(P.argumentRows(theme, bad), [], bad);
});

test("the argument reaches the command as one argv element, never spliced", () => {
    const install = P.BUILTIN_ACTIONS.find(action => action.id === "webapp-install");
    const hostile = "https://example.com/a b;$(id)`x`";
    assert.deepEqual(P.expandCommand(install.command, "/home/alex", hostile), [
        "cybexos-webapp", "install", "--notify", "--url", hostile
    ]);
    assert.deepEqual(P.expandCommand(install.command, "/home/alex", ""), [],
        "a missing argument runs nothing");
    assert.deepEqual(P.expandCommand(["~/.local/bin/x", "~/literal", "{argument}"],
        "/home/alex/", "~/arg"), ["/home/alex/.local/bin/x", "~/literal", "~/arg"],
        "only the program is expanded; the argument is passed as typed");
    assert.deepEqual(P.expandCommand(["true", "{argument}x"], "/h", "y"),
        ["true", "{argument}x"], "only a whole element is a placeholder");
});

test("Remove web app… lists installed web apps to choose from", () => {
    const apps = P.parseWebApps(JSON.stringify([
        { id: "slack", name: "Slack", url: "https://app.slack.com/",
            icon: "/home/a/.local/share/cybexos/webapps/slack/icon.png" },
        { id: "../evil", name: "Evil", url: "https://x" },
        { id: "slack", name: "Duplicate" },
        { id: "notes", name: "Notes\nline", url: "https://n.example/", icon: "relative.png" },
        "junk"
    ]));
    assert.deepEqual(apps.map(app => app.id), ["slack", "notes"]);
    assert.equal(apps[1].name, "Notes line");
    assert.equal(apps[1].icon, "", "only absolute icon paths are drawn");
    assert.deepEqual(P.parseWebApps("not json"), []);
    const rows = P.webAppChoiceRows(apps, "", 8);
    assert.deepEqual(rows.map(row => row.title), ["Remove Notes line", "Remove Slack"]);
    assert.ok(rows.every(row => row.kind === "choice"));
    assert.deepEqual(P.webAppChoiceRows(apps, "sla", 8).map(row => row.value), ["slack"]);
    // Removing takes a second press on the same row.
    const confirming = P.webAppChoiceRows(apps, "", 8, "slack");
    const slack = confirming.find(row => row.value === "slack");
    assert.equal(slack.confirm, true);
    assert.equal(slack.title, "Press Enter again to remove Slack");
    assert.ok(rows.every(row => row.confirm === false));
});

test("launcher open targets a tab, or a prefix provider through its prefix", () => {
    assert.deepEqual(P.openTarget("clipboard"), { tab: "clipboard", query: "" });
    assert.deepEqual(P.openTarget("actions"), { tab: "actions", query: "" });
    assert.deepEqual(P.openTarget("files"), { tab: "apps", query: "/" });
    assert.deepEqual(P.openTarget("windows"), { tab: "apps", query: "$" });
    assert.deepEqual(P.openTarget("bogus"), { tab: "apps", query: "" });
    assert.deepEqual(P.openTarget(""), { tab: "apps", query: "" });
});

test("absolute desktop-entry icons load as files", () => {
    assert.equal(P.directIconUrl("/home/a/x y/icon#1.png"), "file:///home/a/x%20y/icon%231.png");
    assert.equal(P.directIconUrl("firefox"), "", "theme names go to the icon theme");
    assert.equal(P.directIconUrl("file:///a.png"), "file:///a.png");
    assert.equal(P.directIconUrl(""), "");
});

// ---- Clipboard: pins and image previews ------------------------------------

test("pinned entries come first, survive pruning and hide their history twin", () => {
    const pins = P.parsePins(JSON.stringify({ version: 1, pins: [
        { id: "0123456789abcdef", kind: "text", file: "0123456789abcdef.txt",
            preview: "deploy token", source: "43\tdeploy token" },
        { id: "fedcba9876543210", kind: "image", file: "fedcba9876543210.png",
            thumb: "fedcba9876543210-thumb.png", source: "40\t[[ binary data 2 KiB png 10x10 ]]" },
        { id: "../../etc/passwd", kind: "text", file: "x.txt" },
        { id: "aaaaaaaaaaaaaaaa", kind: "text", file: "../../etc/passwd" },
        { id: "bbbbbbbbbbbbbbbb", kind: "script", file: "bbbbbbbbbbbbbbbb.txt" }
    ] }));
    assert.deepEqual(pins.map(pin => pin.id), ["0123456789abcdef", "fedcba9876543210"]);
    assert.deepEqual(P.parsePins("{"), []);

    const lines = [
        "44\tnewest text",
        "43\tdeploy token",
        "42\t[[ binary data 1920x1080 png ]]",
        "40\t[[ binary data 2 KiB png 10x10 ]]"
    ];
    const rows = P.clipboardRows(lines, "", 8, {
        pins,
        previews: { "42\t[[ binary data 1920x1080 png ]]": "file:///run/p/abc.png" },
        pinDir: "/home/a/.local/share/cybexos/clipboard/pins"
    });
    assert.deepEqual(rows.map(row => row.title), [
        "deploy token", "Pinned image", "newest text", "Clipboard image"
    ]);
    assert.equal(rows[0].pinned, true);
    assert.equal(rows[0].pinId, "0123456789abcdef");
    assert.equal(rows[1].thumbnail,
        "file:///home/a/.local/share/cybexos/clipboard/pins/fedcba9876543210-thumb.png");
    assert.equal(rows[2].pinned, false);
    assert.equal(rows[3].thumbnail, "file:///run/p/abc.png");
    assert.equal(rows[3].raw, "42\t[[ binary data 1920x1080 png ]]");

    // A wiped history keeps the pins.
    assert.deepEqual(P.clipboardRows([], "", 8, { pins }).map(row => row.pinId),
        ["0123456789abcdef", "fedcba9876543210"]);
    // Search applies to pins as well.
    assert.deepEqual(P.clipboardRows(lines, "deploy", 8, { pins }).map(row => row.title),
        ["deploy token"]);
});

test("image previews are requested for the newest image entries only", () => {
    const lines = ["5\ttext", "4\t[[ binary data 1 KiB png 2x2 ]]", "3\tmore",
        "2\t[[ binary data 9 KiB jpeg 30x30 ]]", "1\t[[ binary data 9 KiB gif 3x3 ]]"];
    assert.deepEqual(P.clipboardPreviewTargets(lines, 2), [
        "4\t[[ binary data 1 KiB png 2x2 ]]", "2\t[[ binary data 9 KiB jpeg 30x30 ]]"
    ]);
    assert.deepEqual(P.clipboardPreviewTargets(["1\tplain"], 24), []);
});
