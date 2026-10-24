// The NerdOS Assistant's shell side (docs/assistant.md): placement, the box's
// side, agent choice, and the wiring between the shortcut, the service, the
// bar, the compositor and the installation feature. The service has its own
// tests in tests/nixos/test_assistant.py.
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { shellDir, load } = require("./shell.cjs");

const A = load("AssistantHelpers.js");
const root = path.resolve(shellDir, "../..");
const read = relative => fs.readFileSync(path.join(shellDir, relative), "utf8");
const repo = relative => fs.readFileSync(path.join(root, relative), "utf8");

test("the character starts in the top-right corner below the bar and stays on its output", () => {
    const output = { width: 1920, height: 1080 };
    assert.deepEqual(A.placement({ x: -1, y: -1 }, output, 60, 36),
        { x: 1920 - 60 - 24, y: 36 + 24 });
    assert.deepEqual(A.placement({ x: 300, y: 200 }, output, 60, 36), { x: 300, y: 200 });
    // A place saved on a larger display is pulled back inside this one.
    assert.deepEqual(A.placement({ x: 3000, y: 2000 }, output, 60, 36), { x: 1860, y: 1020 });
    assert.deepEqual(A.placement({ x: 10.6, y: 0 }, output, 60, 0), { x: 11, y: 0 });
});

test("the box opens below unless below is cramped and above is roomier", () => {
    const output = { width: 1920, height: 1080 };
    const below = A.dockPlacement({ x: 900, y: 100 }, 60, output, 360, 36);
    assert.equal(below.above, false);
    assert.equal(below.anchorY, 100 + 60 + A.GAP);
    assert.equal(below.room, 1080 - (100 + 60 + A.GAP) - A.EDGE);
    assert.equal(below.x, 900 + 30 - 180, "centred under the character");

    const near = A.dockPlacement({ x: 900, y: 900 }, 60, output, 360, 36);
    assert.equal(near.above, true);
    assert.equal(near.anchorY, 900 - A.GAP);
    assert.equal(near.room, 900 - A.GAP - 36);

    // Cramped both ways: the roomier side wins, which is below here.
    const short = { width: 800, height: 420 };
    const middle = A.dockPlacement({ x: 300, y: 120 }, 60, short, 360, 36);
    assert.equal(middle.above, false, "below has 218 px, above only 74");

    // Clamped to the output with its margin, and never wider than it.
    assert.equal(A.dockPlacement({ x: 0, y: 100 }, 60, output, 360, 0).x, A.EDGE);
    assert.equal(A.dockPlacement({ x: 1860, y: 100 }, 60, output, 360, 0).x, 1920 - 360 - A.EDGE);
    assert.equal(A.dockPlacement({ x: 100, y: 100 }, 60, { width: 300, height: 900 }, 360, 0).width,
        300 - A.EDGE * 2);
});

test("a drag that ends past the edge finds the display under the pointer", () => {
    const outputs = [{ x: 0, y: 0, width: 1920, height: 1080 }, { x: 1920, y: -200, width: 2560, height: 1440 }];
    assert.equal(A.outputAt(outputs, 100, 100), 0);
    assert.equal(A.outputAt(outputs, 2000, -100), 1);
    assert.equal(A.outputAt(outputs, 1919, 1079), 0);
    assert.equal(A.outputAt(outputs, 1920, 1300), -1, "between displays is no display");
    assert.equal(A.dragged(4, -4), false, "a press that wobbles is still a click");
    assert.equal(A.dragged(5, 0), true);
});

test("automatic follows the nerd agent default, then whichever is installed", () => {
    const both = { claude: { available: true }, codex: { available: true } };
    const codexOnly = { claude: { available: false }, codex: { available: true } };
    assert.equal(A.resolveAgent("auto", both, "codex"), "codex");
    assert.equal(A.resolveAgent("auto", both, "opencode"), "claude");
    assert.equal(A.resolveAgent("auto", codexOnly, "claude"), "codex",
        "a default that is not installed gives way to one that is");
    assert.equal(A.resolveAgent("auto", {}, ""), "claude");
    assert.equal(A.resolveAgent("codex", {}, "claude"), "codex",
        "an explicit choice stands, so the service can say it is missing");
    assert.equal(A.nextAgent("claude", both), "codex");
    assert.equal(A.nextAgent("codex", both), "claude");
    assert.equal(A.nextAgent("claude", codexOnly), "codex");
    assert.equal(A.nextAgent("codex", {}), "codex");
    assert.equal(A.anyAgent({ claude: { available: false } }), false);
    assert.equal(A.resolveAgent("auto", {claude: {available: true, auth: "required"},
        codex: {available: true, auth: "ready"}}, "claude"), "codex");
    assert.equal(A.modelFor("claude", "sonnet", "gpt-5.6-sol"), "sonnet");
    assert.equal(A.modelFor("codex", "sonnet", "default"), "");
});

test("the character's mood follows the most urgent state", () => {
    const base = { connected: true };
    assert.equal(A.mood({}), "asleep");
    assert.equal(A.mood(Object.assign({}, base, { listening: true, busy: true })), "listening");
    assert.equal(A.mood(Object.assign({}, base, { waiting: true, busy: true })), "alert");
    assert.equal(A.mood(Object.assign({}, base, { busy: true, composing: true })), "thinking");
    assert.equal(A.mood(Object.assign({}, base, { transcribing: true })), "thinking");
    assert.equal(A.mood(Object.assign({}, base, { celebrating: true, failed: true })), "happy");
    assert.equal(A.mood(Object.assign({}, base, { failed: true })), "sorry");
    assert.equal(A.mood(Object.assign({}, base, { composing: true })), "attentive");
    assert.equal(A.mood(base), "idle");
    assert.ok(A.active({ status: "waiting" }) && !A.active({ status: "completed" }));
    assert.ok(A.finished({ status: "stopped" }) && !A.finished(null));
});

test("readouts: elapsed time, home-relative paths and closure changes", () => {
    assert.equal(A.elapsedLabel(8400), "8 s");
    assert.equal(A.elapsedLabel(65000), "1 min 05 s");
    assert.equal(A.elapsedLabel(12 * 60000 + 5000), "12 min");
    assert.equal(A.displayPath("/home/nerd/.config/nerdos/shell.json", "/home/nerd"), "~/.config/nerdos/shell.json");
    assert.equal(A.displayPath("/home/nerdy/x", "/home/nerd"), "/home/nerdy/x");
    const changes = A.closureChanges([
        "obsidian: ∅ → 1.9.12, +148.2 MiB",
        "electron: ∅ → 37.2.4, +201.0 MiB",
        "firefox: 140.0 → 141.0, +1.2 MiB",
        "old-tool: 2.0 → ∅, -3.1 MiB",
        "not a change line"
    ].join("\n"), 3);
    assert.deepEqual(changes.rows.map(row => [row.name, row.kind]),
        [["obsidian", "added"], ["electron", "added"], ["firefox", "changed"]]);
    assert.equal(changes.more, 1);
    assert.deepEqual(A.closureChanges("", 5), { rows: [], more: 0 });
    assert.equal(A.errorAction("auth", "codex").auth, true);
    assert.equal(A.errorAction("crashed", "claude"), null);
    assert.equal(A.copyText({ text: "Done.\n\n" }), "Done.");
});

test("Super+I is one in-process shortcut: a tap types, a hold talks", () => {
    const shell = read("shell.qml");
    assert.match(shell, /GlobalShortcut \{\s*appid: "quickshell"\s*name: "assistantTalk"[\s\S]*?onPressed: Assistant\.shortcutPressed\(\)\s*onReleased: Assistant\.shortcutReleased\(\)/);
    const bindings = repo("desktop/hypr/bindings.lua");
    assert.match(bindings, /if features\.assistant then\s*bind\(mainMod \.\. " \+ I", hl\.dsp\.global\("quickshell:assistantTalk"\),\s*\{ description = "Shell: Assistant" \}\)/);
    assert.match(repo("desktop/hypr/features.lua"), /assistant = os\.getenv\("NERDOS_ASSISTANT"\) ~= "0"/);
    const assistant = read("Common/Assistant.qml");
    assert.match(assistant, /interval: AssistantHelpers\.HOLD_MS/);
    assert.match(assistant, /function shortcutReleased\(\) \{\s*if \(holdTimer\.running\) \{\s*holdTimer\.stop\(\);[\s\S]*?toggleComposer\(\);/,
        "a release before the hold time is a tap");
    assert.match(assistant, /if \(shortcutHolding && listening && !voiceLatched\)\s*stopListening\(true\);/,
        "releasing a hold sends what was said");
    assert.ok(A.HOLD_MS >= 200 && A.HOLD_MS <= 400);
});

test("the shell is a client: the service owns turns and the shell reconciles with hello", () => {
    const assistant = read("Common/Assistant.qml");
    assert.match(assistant, /readonly property string socketPath: runtimeDir \+ "\/assistant\.sock"/);
    assert.match(assistant, /Socket \{\s*id: socket\s*path: root\.socketPath\s*parser: SplitParser/);
    assert.match(assistant, /onConnectionStateChanged: \{\s*root\.helloed = false;/);
    assert.match(assistant, /case "turn\.updated":\s*adopt\(params\.turn\);/);
    assert.match(assistant, /case "turn\.delta":/);
    assert.doesNotMatch(assistant, /Process \{[^}]*"claude"|"codex", "app-server"/,
        "the shell never runs an agent itself");
    // Voice: Voxtype writes the transcript to a file instead of typing it.
    assert.match(assistant, /record start --file="\$2"/);
    assert.match(assistant, /property: "assistantWatching"\s*value: root\.available/);
    // Screen context: hidden for the capture, one output, into the service's directory.
    assert.match(assistant, /exec grim -o "\$2" -l 6 "\$3"/);
    assert.match(assistant, /readonly property string scratchDir: runtimeDir \+ "\/assistant"/);
    assert.match(assistant, /if \(!Settings\.assistantScreenContext \|\| capturing/,
        "no screenshot unless screen context was switched on");
});

test("the overlay takes input only on the character and the box, and the keyboard only when asked", () => {
    const window = read("AssistantWindow.qml");
    assert.match(window, /WlrLayershell\.namespace: "qs-assistant"/);
    assert.match(window, /WlrLayershell\.layer: WlrLayer\.Overlay/);
    assert.match(window, /mask: Region \{\s*item: character\s*Region \{\s*item: dockMask/);
    assert.match(window, /keyboardFocus: !root\.dockShown \? WlrKeyboardFocus\.None\s*: root\.keyboardWanted && !grab\.active \? WlrKeyboardFocus\.Exclusive\s*: WlrKeyboardFocus\.OnDemand/);
    assert.match(window, /readonly property bool keyboardWanted: Assistant\.focusRequested/);
    assert.match(window, /HyprlandFocusGrab \{\s*id: grab/);
    assert.match(window, /Assistant\.openComposer\(false\)/, "hovering opens the box without the keyboard");
    assert.match(window, /opacity: Assistant\.capturing \? 0 : 1/);
    assert.match(read("shell.qml"), /LazyLoader \{\s*active: Assistant\.shown\s*AssistantWindow \{\}/);
    const look = repo("desktop/hypr/looknfeel.lua");
    const blur = look.match(/name = "quickshell-blur",[\s\S]*?namespace = \[\[([^\]]+)\]\]/);
    assert.doesNotMatch(blur[1], /assistant/, "a full-output surface must not be blurred");
});

test("the menubar button toggles the character on its own display and shows activity", () => {
    const module = read("Bar/Modules/Assistant.qml");
    assert.match(module, /moduleId: "assistant"/);
    assert.match(module, /onClicked: Assistant\.toggleShown\(root\.host \? root\.host\.outputName : ""\)/);
    assert.match(read("Bar/Bar.qml"), /case "assistant": return Settings\.assistantConfigured;/);
    assert.match(read("Bar/Bar.qml"), /assistant: "Modules\/Assistant\.qml"/);
    assert.ok(load("PanelRegistryData.js").PANEL_LESS_MODULES.includes("assistant"));
    assert.equal(load("WidgetCatalog.js").WIDGETS.assistant.glyph, "assistant");
});

test("the approval card never answers for the person", () => {
    const card = read("Assistant/AssistantApproval.qml");
    for (const decision of ["allow", "always", "deny"])
        assert.match(card, new RegExp(`Assistant\\.respond\\(root\\.approval\\.id, "${decision}"\\)`));
    assert.doesNotMatch(card, /Component\.onCompleted|Timer \{/, "no card answers itself");
    // A staged change is applied by the updater's own reviewed request.
    assert.match(read("Assistant/AssistantReply.qml"), /onTriggered: Updates\.apply\(\)/);
    assert.match(read("Assistant/AssistantReply.qml"),
        /Updates\.deployment\.transaction === turn\.staged/);
});

test("the installation feature carries the service, the agents and the menubar", () => {
    const options = repo("nix/modules/default.nix");
    assert.match(options, /assistant = mkOption \{ type = types\.bool; default = true; \};/);
    const desktop = repo("nix/modules/desktop.nix");
    assert.match(desktop, /NERDOS_ASSISTANT = if cfg\.features\.assistant then "1" else "0";/);
    assert.match(desktop, /systemd\.user\.services\.nerdos-assistant = lib\.mkIf cfg\.features\.assistant \{/);
    assert.match(desktop, /ExecStart = "\$\{assistant\}\/bin\/nerdos-assistant serve";/);
    assert.match(desktop, /path = \[ config\.system\.path \];\s*serviceConfig = \{\s*ExecStart = "\$\{assistant\}/);
    const applications = repo("nix/modules/applications.nix");
    assert.match(applications, /lib\.optionals \(cfg\.features\.proprietary && \(cfg\.features\.developer \|\| cfg\.features\.assistant\)\) \[ claude-code \]/,
        "Claude Code is unfree: it still needs the proprietary feature");
    assert.match(applications, /lib\.optionals cfg\.features\.assistant \[ assistant codex \]/);
    assert.match(repo("installer/nerdos-install"), /\('assistant', 'NerdOS Assistant'\)/);
    assert.match(repo("lifecycle/nerdos/cli.py"), /for name in \('agent', 'assistant', 'backup', 'report'\):/);
    assert.match(read("Common/Settings.qml"), /readonly property bool assistantConfigured:\s*Quickshell\.env\("NERDOS_ASSISTANT"\) !== "0"/);
});
