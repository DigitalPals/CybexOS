const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { shellDir, load } = require("./shell.cjs");

function read(rel) {
    return fs.readFileSync(path.join(shellDir, rel), "utf8");
}

test("the launcher is warm before the first shortcut press", () => {
    const window = read("LauncherWindow.qml");

    assert.match(window, /LauncherView\s*\{/);
    assert.match(window, /width:\s*launcherView\.implicitWidth/);
    assert.match(window, /height:\s*launcherView\.implicitHeight/);
    assert.doesNotMatch(window, /\bLoader\s*\{|launcherLoader/,
        "constructing LauncherView on demand adds cold-start latency");
});

test("opening claims focus immediately and preserves the first typed key", () => {
    const window = read("LauncherWindow.qml");
    const view = read("LauncherView.qml");

    assert.match(window,
        /keyboardFocus:\s*Launcher\.open\s*\?\s*WlrKeyboardFocus\.Exclusive/);
    assert.match(window, /focus:\s*Launcher\.open/);
    assert.match(window, /!launcherView\.inputActiveFocus/);
    assert.match(window, /launcherView\.handleEarlyKey\(event\)/);

    assert.match(view, /function prepareOpen\(\): void/);
    assert.match(view, /search\.text = "";\s*selected = 0;\s*focusInput\(\);/s);
    assert.match(view, /Qt\.callLater\(\(\) => \{\s*if \(Launcher\.open\)\s*root\.focusInput\(\);/s);
    assert.match(view, /function handleEarlyKey\(event\): bool/);
    assert.match(view, /search\.insert\(search\.cursorPosition, event\.text\)/);
    assert.match(view, /focus:\s*Launcher\.open/);
});

test("Enter activates the selected first result without waiting for animation", () => {
    const view = read("LauncherView.qml");

    assert.match(view, /property int selected:\s*0/);
    assert.match(view,
        /event\.key === Qt\.Key_Return \|\| event\.key === Qt\.Key_Enter\) \{\s*activate\(rows\[selected\]\);/s);
    assert.doesNotMatch(view, /\bentered\b|enterTimer|enterDelay|PauseAnimation/,
        "result-row staging must not make the selected app look unavailable");
});

test("the empty app directory is alphabetical", () => {
    const view = read("LauncherView.qml");
    const providers = read("Common/LauncherProviders.qml");
    const helpers = load("LauncherProviders.js");
    const app = { id: "z.desktop", name: "Zulu", genericName: "", keywords: [] };

    assert.equal(helpers.appScore(app, "", 9000), 1,
        "an empty query must give every app the same score");
    assert.match(providers,
        /ProviderHelpers\.appScore\(app, root\.term,[\s\S]*Launcher\.usageBoost\(app\)\)/);
    assert.match(providers,
        /\.sort\(\(a, b\) => b\.score - a\.score[\s\S]*a\.title\.localeCompare\(b\.title\)\)/);
    assert.match(view, /readonly property var rows:\s*LauncherProviders\.rows/);
});

test("the app directory keeps every match in a fixed scrolling viewport", () => {
    const view = read("LauncherView.qml");
    const providers = read("Common/LauncherProviders.qml");
    const appRows = providers.slice(providers.indexOf("readonly property var appRows"),
        providers.indexOf("readonly property var windowRows"));
    const results = view.slice(view.indexOf("// ---- Results"),
        view.indexOf("// ---- Empty state"));

    assert.doesNotMatch(appRows, /slice\(0, root\.maxResults\)/,
        "the provider must not discard apps below the first viewport");
    assert.match(results,
        /height:\s*Math\.min\(Math\.min\(root\.maxResults, root\.rows\.length\) \* root\.rowHeight,/);
    assert.match(results, /interactive:\s*contentHeight > height/);
    assert.match(results, /boundsBehavior:\s*Flickable\.StopAtBounds/);
    assert.match(results, /ScrollChrome\s*\{[\s\S]*target:\s*resultList/);
    assert.match(view,
        /resultList\.positionViewAtIndex\(selected, ListView\.Contain\)/,
        "keyboard navigation must reveal selections beyond the first viewport");
});

test("the view is provider-driven and owns no search subprocesses", () => {
    const view = read("LauncherView.qml");
    const providers = read("Common/LauncherProviders.qml");

    assert.match(view, /readonly property var provider:\s*LauncherProviders\.activeProvider/);
    assert.match(view, /LauncherProviders\.query = query/);
    assert.match(view, /LauncherProviders\.activate\(row\)/);
    assert.match(view, /LauncherProviders\.emptyText/);
    assert.doesNotMatch(view, /LauncherProviders\.footerLeft/);
    assert.doesNotMatch(providers, /\bfooterLeft\b|\bappTotal\b/,
        "the removed footer must not leave provider summary work behind");
    assert.doesNotMatch(view, /\bProcess\s*\{|\bTimer\s*\{|switch \(row\.kind\)/,
        "providers, not the presentation, own asynchronous work and activation");

    for (const process of ["fileProc", "calcProc", "clipboardListProc"])
        assert.match(providers, new RegExp(`id:\\s*${process}`));
});

test("clipboard refreshes are generation-safe and password-aware", () => {
    const providers = read("Common/LauncherProviders.qml");
    const store = fs.readFileSync(path.resolve(__dirname,
        "../../assets/scripts/clipboard-history-store"), "utf8");

    assert.doesNotMatch(providers,
        /function refreshClipboard\(\)[\s\S]{0,180}clipboardListProc\.running = false/,
        "refreshing must not overlap a cancelled process with its replacement");
    assert.match(providers,
        /clipboardListProc\.generation = clipboardRefreshGeneration/);
    assert.match(providers,
        /if \(generation !== root\.clipboardRefreshGeneration\)[\s\S]*clipboardRefreshRestart\.restart\(\)/);
    assert.match(providers, /clipboard-history-store/);
    assert.match(store, /passwordmanagerhint\|x-kde-secret\|keepassxc\|concealed/i);
    assert.match(store, /cliphist -max-items 500 store/,
        "the continuously running history must retain a bounded number of entries");
});

test("the launcher uses the compact single-line geometry", () => {
    const view = read("LauncherView.qml");
    const window = read("LauncherWindow.qml");
    const providers = read("Common/LauncherProviders.qml");
    const resultSection = view.slice(view.indexOf("// ---- Results"),
        view.indexOf("// ---- Empty state"));

    assert.match(view, /implicitWidth:\s*Theme\.fitWidth\(Theme\.scaled\(460, Theme\.contentScale\)/);
    for (const [name, value] of Object.entries({
        tabHeight: 34,
        searchHeight: 44,
        rowHeight: 42,
        resultIconSize: 28
    }))
        assert.match(view, new RegExp(`property int ${name}: Theme\\.scaled\\(${value}\\)`));
    assert.match(providers, /property int maxResults:\s*8\b/);
    assert.match(view,
        /fullHeight:\s*padding \* 2 \+ tabHeight \+ searchHeight\s*\+ maxResults \* rowHeight \+ spacing \* 2/);
    assert.match(window,
        /\(root\.outputHeight - launcherView\.fullHeight\) \/ 2/);

    assert.match(resultSection, /height:\s*root\.rowHeight/);
    assert.match(resultSection,
        /width:\s*root\.resultIconSize\s*\n\s*height:\s*root\.resultIconSize/);
    assert.doesNotMatch(resultSection,
        /\bColumn\s*\{|modelData\.subtitle|enterGlyph|Behavior on color|ColorAnimation/,
        "result delegates must be single-line and move the highlight immediately");
    assert.match(resultSection, /animateColor:\s*false/,
        "launcher result glyphs must change color with the highlight, without lag");
    assert.doesNotMatch(view, /\bHDivider\s*\{|\bfooterLeft\b|id:\s*hints\b|esc close/,
        "the compact view has no divider, footer, counts, or shortcut hints");
});

test("the launcher defaults to Apps and exposes the discoverable provider tabs", () => {
    const view = read("LauncherView.qml");
    const providers = read("Common/LauncherProviders.qml");

    assert.match(providers, /property string selectedProviderId:\s*"apps"/);
    assert.match(providers,
        /activeProvider:\s*prefixActive\s*\?\s*prefixedProvider\s*:\s*ProviderHelpers\.providerById\(selectedProviderId\)/s);
    assert.match(view, /readonly property var tabs:\s*LauncherProviders\.tabProviders/);
    assert.match(view,
        /apps:\s*"Apps",\s*emoji:\s*"Emoji",\s*clipboard:\s*"History",\s*actions:\s*"Actions"/s);
    assert.match(view,
        /function prepareOpen\(\): void \{\s*LauncherProviders\.selectedProviderId = "apps";/s);
    assert.match(view,
        /function selectTab\(providerId\): void \{\s*LauncherProviders\.selectedProviderId = providerId;\s*search\.text = "";/s);
    assert.match(view, /Qt\.ControlModifier[\s\S]*Qt\.Key_Tab[\s\S]*cycleTab/);
    assert.match(view,
        /Qt\.Key_Left\) \{\s*cycleTab\(-1\);[\s\S]*Qt\.Key_Right\) \{\s*cycleTab\(1\);/);
    assert.doesNotMatch(view,
        /Qt\.NoModifier[\s\S]{0,80}Qt\.Key_(?:Left|Right)/,
        "arrow tab navigation must tolerate compositor keyboard flags");
    assert.match(view, /Accessible\.role:\s*Accessible\.PageTab/);
});

test("the launcher's layer surface is the card's envelope, not the output", () => {
    const window = read("LauncherWindow.qml");

    // The compositor blurs every pixel of the layer surface: a full-output
    // overlay blurred ~8 MP on a 4K output each frame for a 460 px card.
    const anchors = window.match(/anchors \{([^}]*)\}/)?.[1] ?? "";
    assert.match(anchors, /top: true/);
    assert.match(anchors, /left: true/);
    assert.doesNotMatch(anchors, /right|bottom/,
        "anchoring opposite edges stretches the surface across the output");
    assert.match(window, /exclusionMode:\s*ExclusionMode\.Ignore/,
        "margins must count from the output edge, not from the bar's zone");
    assert.match(window, /implicitWidth:\s*launcherView\.implicitWidth/);
    // A fixed envelope: the surface must not follow the card's animated
    // height, or every result-count change reconfigures and reblurs it.
    assert.match(window, /implicitHeight:\s*root\.travel \+ launcherView\.fullHeight/);
    assert.match(window, /top:\s*root\.cardTop - root\.travel/);
    assert.match(window,
        /left:\s*Math\.round\(\(root\.outputWidth - launcherView\.implicitWidth\) \/ 2\)/);
    assert.match(window, /y:\s*root\.travel/);
    // The view's envelope comes from the output: the window is sized from the
    // view, so reading the window back would shrink the card on every pass.
    assert.match(window, /outputWidth:\s*root\.screen \? root\.screen\.width : 0/);
    assert.match(window, /availableWidth:\s*root\.outputWidth > 0/);
    assert.match(window, /availableHeight:\s*root\.outputHeight > 0/);
    assert.doesNotMatch(window, /root\.(?:width|height)\b/);
    // Outside clicks now land on other surfaces; the focus grab closes.
    assert.match(window, /HyprlandFocusGrab \{[\s\S]*?onCleared:\s*Launcher\.close\(\)/);
});

test("a closed launcher stops feeding its query to the providers", () => {
    const view = read("LauncherView.qml");
    const window = read("LauncherWindow.qml");
    const providers = read("Common/LauncherProviders.qml");

    // A `$` query binds every toplevel's title and focus, and the History tab
    // re-reads cliphist on each copy; neither is on screen once closed.
    assert.match(view,
        /function resetForClose\(\): void \{\s*LauncherProviders\.selectedProviderId = "apps";\s*search\.text = "";/s);
    assert.match(window,
        /onVisibleChanged:\s*\{\s*if \(!visible\)\s*launcherView\.resetForClose\(\);/s,
        "the reset waits for the fade-out to unmap the window");
    // The emoji paste lands after the fade; it must not depend on the query.
    const paste = providers.match(/id:\s*pasteTimer[\s\S]*?\n    \}/)?.[0] ?? "";
    assert.ok(paste !== "");
    assert.doesNotMatch(paste, /\b(?:query|term|rows|activeProvider\w*)\b/);
});

test("result navigation wraps, pages by six, and Escape clears before closing", () => {
    const view = read("LauncherView.qml");
    const window = read("LauncherWindow.qml");

    assert.match(view,
        /Qt\.Key_Down \|\| event\.key === Qt\.Key_Tab\) \{\s*wrapSelection\(1\);/s);
    assert.match(view, /Qt\.Key_Up\) \{\s*wrapSelection\(-1\);/s);
    assert.match(view, /Qt\.Key_PageDown\) \{\s*pageSelection\(6\);/s);
    assert.match(view, /Qt\.Key_PageUp\) \{\s*pageSelection\(-6\);/s);
    assert.match(view,
        /Qt\.Key_Escape\) \{\s*if \(query !== ""\) \{\s*search\.text = "";\s*selected = 0;\s*\} else \{\s*Launcher\.close\(\);/s);
    assert.doesNotMatch(window, /Keys\.onEscapePressed:\s*Launcher\.close\(\)/,
        "the early-focus path must preserve two-stage Escape behavior");
});

test("clipboard, emoji, and action providers have installed data sources", () => {
    const providers = read("Common/LauncherProviders.qml");
    const packages = fs.readFileSync(path.resolve(shellDir,
        "../../../apps/defaults/main.yml"), "utf8");
    const actions = JSON.parse(read("launcher-actions.json"));

    assert.match(providers,
        /wl-paste --type text --watch [\s\S]{0,100}?clipboard-history-store/);
    assert.match(providers,
        /wl-paste --type image --watch [\s\S]{0,100}?clipboard-history-store/);
    assert.match(providers, /\/usr\/share\/unicode\/emoji\/emoji-test\.txt/);
    assert.match(providers, /watchChanges:\s*true/);
    assert.match(packages, /^\s+- cliphist$/m);
    assert.match(packages, /^\s+- unicode-emoji$/m);
    assert.ok(Array.isArray(actions));
    assert.deepEqual(actions.map(action => action.id), [
        "ai-agent-launch", "ai-agent-choose"
    ]);
    assert.deepEqual(actions[0].command,
        ["cybex", "agent", "--window"]);
    assert.deepEqual(actions[1].command,
        ["cybex", "agent", "--window", "--pick"]);
});

test("emoji activation pastes into the previously active window", () => {
    const providers = read("Common/LauncherProviders.qml");
    const activate = providers.slice(providers.indexOf("function activate(row)"));
    const emojiActivation = activate.slice(activate.indexOf('case "emoji":'),
        activate.indexOf('case "actions":'));

    assert.match(emojiActivation, /root\.pasteText\(row\.value\)/);
    assert.match(providers,
        /function pasteText\(value\): void \{[\s\S]*Quickshell\.clipboardText = text;[\s\S]*Launcher\.close\(\);[\s\S]*pasteTimer\.restart\(\);/);
    assert.match(providers,
        /id:\s*pasteTimer[\s\S]*Theme\.launcherFadeOutDuration[\s\S]*!Launcher\.open[\s\S]*"wtype", "-M", "shift", "-k", "Insert", "-m", "shift"/,
        "pasting must wait until the launcher has returned keyboard focus");
});

test("Super+Space uses Hyprland's in-process global shortcut", () => {
    const shell = read("shell.qml");
    const bindings = fs.readFileSync(path.resolve(shellDir, "../bindings.lua"), "utf8");

    assert.match(shell, /GlobalShortcut\s*\{/);
    assert.match(shell, /appid:\s*"quickshell"/);
    assert.match(shell, /name:\s*"launcherToggle"/);
    assert.match(shell, /onPressed:\s*Launcher\.toggle\(\)/);
    assert.match(bindings,
        /mainMod \.\. " \+ SPACE", hl\.dsp\.global\("quickshell:launcherToggle"\)/);
    assert.doesNotMatch(bindings, /qs ipc call launcher toggle/);
});

test("the default AI agent is discoverable from the launcher and shortcut sheet", () => {
    const bindings = fs.readFileSync(path.resolve(shellDir, "../bindings.lua"), "utf8");

    // The sheet is drawn from the binding's own description.
    assert.match(bindings,
        /mainMod \.\. " \+ CTRL \+ SHIFT \+ A", hl\.dsp\.exec_cmd\([^)]*cybex agent --window"\),\s*\{ description = "Apps: AI agent" \}/);
});

test("launcher-only motion stays brief and cannot gate input", () => {
    const theme = read("Common/Theme.qml");
    const window = read("LauncherWindow.qml");

    for (const [token, value] of Object.entries({
        launcherOpenDuration: 180,
        launcherCloseDuration: 120,
        launcherFadeInDuration: 110,
        launcherFadeOutDuration: 80,
        launcherResizeDuration: 140,
        launcherTravel: 8
    })) {
        assert.match(theme, new RegExp(
            `property (?:int|real) ${token}: reducedMotion \\? 0 : ${value}\\b`));
        assert.match(window, new RegExp(`Theme\\.${token}`));
    }
    assert.match(theme, /launcherInitialScale:\s*reducedMotion \? 1 : 0\.985/);
    assert.match(window, /Theme\.launcherInitialScale/);
});

// The enlarged icon must reserve its actual width, including in compact density.
test("launcher labels follow the scaled icon instead of a fixed text offset", () => {
    const view = read("LauncherView.qml");
    assert.match(view, /x: resultIcon\.x \+ resultIcon\.width \+ Theme\.scaled\(10\)/);
    assert.doesNotMatch(view, /font\.pixelSize: \d+/);
});
