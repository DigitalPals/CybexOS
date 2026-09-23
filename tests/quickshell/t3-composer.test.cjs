const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { shellDir } = require("./shell.cjs");

// The T3-integrated composer keeps controls in one glass shell. These pins
// prevent the round send action and access chip from regressing into tall form
// controls when the shell-wide metrics change.

const composer = fs.readFileSync(
    path.join(shellDir, "Popovers/T3Composer.qml"), "utf8");

test("T3 composer send button is a round inline action, not a form control", () => {
    const send = composer.match(
        /Rectangle\s*\{\s*id:\s*sendButton\b([\s\S]*?)\n\s*Sym\s*\{/);

    assert.ok(send, "expected to find the composer's send button");
    assert.match(send[1], /height:\s*Theme\.inlineActionHeight\b/,
        "the send button sits inside the prompt box and must stay pill-sized");
    assert.doesNotMatch(send[1], /Theme\.controlHeight\b/,
        "a form-control height fills the prompt box");
    assert.match(send[1], /width:\s*Theme\.inlineActionHeight\b/);
    assert.match(send[1], /radius:\s*width \/ 2\b/,
        "the primary composer action should keep T3's circular silhouette");
});

// The composer bar reads as a sentence about the run — brand mark, model,
// reasoning, access — not as a strip of form fields, and not as a summary
// label that has to be opened before anything can be changed.
test("the composer bar names the run in place and each part is its own menu", () => {
    const bar = composer.match(/Item\s*\{\s*id:\s*actionRow\b([\s\S]*?)\n\s{12}\}/);

    assert.ok(bar, "expected to find the composer action bar");
    assert.match(bar[1], /T3ModelPicker\s*\{\s*\n\s*id:\s*modelSelect\b/,
        "the model control opens the provider/model panel, not a flat list");
    for (const id of ["effortSelect", "accessSelect"])
        assert.match(bar[1], new RegExp(`T3InlineSelect\\s*\\{\\s*\\n\\s*id:\\s*${id}\\b`),
            `${id} must be an inline dropdown on the bar`);
    assert.match(bar[1], /id:\s*modelSelect[\s\S]*?brand:\s*root\.providerGlyph/,
        "the provider travels as the model's brand mark rather than a second control");
    assert.match(bar[1], /id:\s*accessSelect[\s\S]*?symbol:\s*settingsPresentation\.accessSymbol\(\)/);
    assert.match(composer,
        /function accessSymbol\(\)[\s\S]{0,220}?"full-access"\s*\n?\s*\?\s*"lock_open"\s*:\s*"lock"/,
        "full access is the one mode that should not be wearing a closed lock");
    assert.doesNotMatch(bar[1], /elide[\s\S]*?compactSummary\(\)/,
        "the bar shows live controls, not a read-only summary of them");
});

// New Thread grows to its content cap: opening below the composer reserves
// room in its scrolling form, while existing threads overlay their transcript.
test("new-thread bar menus reserve scroll room while thread menus open upward", () => {
    const bar = composer.match(/Item\s*\{\s*id:\s*actionRow\b([\s\S]*?)\n\s{12}\}/);
    const newPage = fs.readFileSync(
        path.join(shellDir, "Popovers/T3NewThreadPage.qml"), "utf8");

    assert.ok(bar, "expected to find the composer action bar");
    for (const id of ["modelSelect", "effortSelect", "accessSelect"])
        assert.match(bar[1], new RegExp(
            `id:\\s*${id}\\b[\\s\\S]*?openUpward:\\s*!root\\.newThread`),
        `${id} should open into newly reserved space only on New Thread`);
    assert.match(composer,
        /readonly property real barPickerReserve:[\s\S]*?modelSelect\.popupHeight[\s\S]*?effortSelect\.popupHeight[\s\S]*?accessSelect\.popupHeight/);
    assert.match(composer,
        /id:\s*barPickerSpace[\s\S]*?height:\s*root\.barPickerReserve/,
        "the floating menu must contribute its height to the composer's Column");
    assert.match(newPage,
        /onBarPickerReserveChanged:[\s\S]*?flick\.contentHeight - flick\.height/,
        "the bounded page must scroll the newly reserved menu into view");
    assert.match(newPage,
        /id:\s*viewport[\s\S]*?anchors\.bottom:\s*parent\.bottom/,
        "the form viewport must consume the drawer below its fixed header");

    const popover = fs.readFileSync(
        path.join(shellDir, "Popovers/T3CodePopover.qml"), "utf8");
    assert.doesNotMatch(newPage, /detachedOverflowHeight|detachedOverflowItem/);
    assert.doesNotMatch(popover, /detachedOverflowHeight|detachedOverflowItem/,
        "T3 no longer asks the host for a transparent tail");

    for (const host of ["Popovers/T3InlineSelect.qml", "Popovers/T3ModelPicker.qml"])
        for (const property of ["popupHeight", "popupItem"])
            assert.match(fs.readFileSync(path.join(shellDir, host), "utf8"),
                new RegExp(`readonly property (?:int|Item) ${property}:`),
                `${host} must publish the popup geometry its parent reserves`);
});

test("the New Thread project menu reserves room inside its scroll viewport", () => {
    const newPage = fs.readFileSync(
        path.join(shellDir, "Popovers/T3NewThreadPage.qml"), "utf8");
    const picker = fs.readFileSync(
        path.join(shellDir, "Popovers/T3Picker.qml"), "utf8");

    for (const property of ["popupHeight", "popupItem"])
        assert.match(picker, new RegExp(`readonly property (?:int|Item) ${property}:`),
            `the Project picker must publish its ${property}`);
    assert.match(picker,
        /readonly property real popupOffsetY:\s*menu\.triggerY/,
        "the Project picker must publish its trigger-relative popup position");
    assert.match(picker, /height:\s*root\.popupHeight/,
        "the published height and the painted menu must remain identical");
    assert.match(newPage,
        /projectPicker\.popupOffsetY \+ projectPicker\.popupHeight/,
        "scroll-space math must not treat the page-hosted menu as a picker child");
    assert.match(newPage,
        /id:\s*projectShoulder[\s\S]*?z:\s*projectPicker\.expanded \? 200 : 0/,
        "the Project menu must paint above the composer that follows it");
    assert.match(newPage,
        /readonly property real projectPickerLayoutHeight:[\s\S]*?projectPickerNeededHeight/);
    assert.match(newPage,
        /id:\s*projectPickerSpace[\s\S]*?root\.projectPickerLayoutHeight - form\.spacing/,
        "only the part extending below the normal form should grow scroll content");
    assert.match(newPage,
        /id:\s*projectPicker[\s\S]*?popupBoundsItem:\s*root/,
        "the Project menu must stay inside the page body");
    assert.doesNotMatch(newPage, /activePopupItem|detachedOverflow/);
    assert.match(newPage,
        /onExpandedChanged:[\s\S]*?root\.projectPopupBottom - flick\.height/,
        "a height-capped view must scroll just enough to reveal the menu");
});

// The bar is a fixed width the prompt above it never has to respect, so
// something has to give when the model name is long. It must not be the send
// action, which would leave the turn with no way to start or stop.
test("the composer bar yields the model name before it yields the send action", () => {
    const bar = composer.match(/Item\s*\{\s*id:\s*actionRow\b([\s\S]*?)\n\s{12}\}/);

    assert.ok(bar);
    assert.match(bar[1],
        /readonly property real inlineRoom:\s*width - sendButton\.width/);
    assert.match(bar[1],
        /readonly property real accessRoom:[\s\S]*?Math\.max\(48, selectorRoom - 48\)/);
    assert.match(bar[1],
        /readonly property real modelRoom:\s*Math\.max\(48,[\s\S]*?selectorRoom - accessRoom\)/,
        "model must consume the residual room and therefore elide before access");
    assert.match(bar[1], /id:\s*modelSelect[\s\S]*?maxWidth:\s*actionRow\.modelRoom/);
    assert.match(bar[1], /id:\s*accessSelect[\s\S]*?maxWidth:\s*actionRow\.accessRoom/);
    assert.ok(bar[1].indexOf("id: settingsButton") < bar[1].indexOf("id: sendButton"));

    const control = fs.readFileSync(path.join(shellDir, "Popovers/T3BarControl.qml"), "utf8");
    assert.match(control, /readonly property real naturalWidth:\s*trigger\.implicitWidth/);
    assert.match(control, /implicitWidth:\s*Math\.min\(maxWidth,/);
    assert.match(control, /property real minimumWidth:\s*48/);
    assert.match(control, /elide:\s*Text\.ElideRight/);
    assert.doesNotMatch(control, /implicitWidth:\s*triggerRow\.implicitWidth/,
        "measuring the laid-out Row closes a binding loop against the clamped label");

    // Three buttons that must read as one sentence cannot afford three
    // implementations that drift apart.
    for (const host of ["Popovers/T3InlineSelect.qml", "Popovers/T3ModelPicker.qml"]) {
        const source = fs.readFileSync(path.join(shellDir, host), "utf8");
        assert.match(source, /T3BarControl\s*\{\s*\n\s*id:\s*trigger\b/,
            `${host} must reuse the shared bar button`);
    }
});

test("narrow composers move reasoning into Run settings", () => {
    assert.match(composer,
        /readonly property bool narrow:\s*root\.width < 360/);
    assert.match(composer,
        /readonly property bool reasoningInDrawer:\s*narrow && reasoningDescriptor !== null/);
    assert.match(composer,
        /id:\s*reasoningPicker[\s\S]*?visible:\s*settingsPresentation\.reasoningInDrawer/);
    assert.match(composer,
        /id:\s*effortSelect[\s\S]*?visible:\s*!settingsPresentation\.narrow/);
    assert.match(composer,
        /id:\s*settingsButton[\s\S]*?visible:\s*settingsPresentation\.hasDrawer/,
        "the tune action remains available when it owns narrow reasoning");
});

test("model and option popups are hosted by and clamp to their drawer body", () => {
    for (const file of ["T3Picker.qml", "T3InlineSelect.qml", "T3ModelPicker.qml"]) {
        const source = fs.readFileSync(path.join(shellDir, "Popovers", file), "utf8");
        assert.match(source, /property Item popupBoundsItem:\s*null/);
        assert.match(source,
            /readonly property Item popupHostItem:\s*popupBoundsItem \? popupBoundsItem : root/,
            `${file} must lift the popup out of a clipped trigger subtree`);
        assert.match(source, /parent:\s*root\.popupHostItem/,
            `${file} must put popup rows in the page's pointer-delivery tree`);
        assert.match(source,
            /function updatePopupGeometry\(\)[\s\S]*?popupHostItem\.mapFromItem\(root, 0, 0\)/);
        assert.match(source,
            /expanded = true;[\s\S]*?Qt\.callLater\(updatePopupGeometry\)/,
            `${file} must refresh its portal position after New Thread scrolls`);
        assert.match(source, /popupBoundsRight/);
        assert.match(source, /popupBoundsBottom/);
        if (file === "T3Picker.qml") {
            assert.match(source,
                /triggerX:\s*Math\.max\(root\.popupBoundsLeft,[\s\S]*?root\.popupBoundsRight - width\)/);
            assert.match(source,
                /triggerY:\s*Math\.max\(root\.popupBoundsTop,[\s\S]*?root\.popupBoundsBottom - height\)/);
            assert.match(source, /x:\s*root\.popupHostOrigin\.x \+ triggerX/);
            assert.match(source, /y:\s*root\.popupHostOrigin\.y \+ triggerY/);
        } else {
            assert.match(source,
                /x:\s*root\.popupHostOrigin\.x \+ Math\.max\(root\.popupBoundsLeft,[\s\S]*?root\.popupBoundsRight - width\)/);
            assert.match(source,
                /y:\s*root\.popupHostOrigin\.y \+ Math\.max\(root\.popupBoundsTop,[\s\S]*?root\.popupBoundsBottom - height\)/);
        }
        assert.match(source,
            /const (?:menu|panel)Point = (?:menu|panel)\.mapFromItem\(item, x, y\)/,
            `${file} must hit-test the reparented popup in its own coordinates`);
        assert.match(source, /width:\s*parent \? parent\.width : 0/,
            `${file} delegates must tolerate their transient null parent`);
    }
    const bar = composer.match(/Item\s*\{\s*id:\s*actionRow\b([\s\S]*?)\n\s{12}\}/);
    assert.match(bar[1],
        /id:\s*effortSelect[\s\S]*?alignRight:\s*true/);
    assert.match(bar[1],
        /id:\s*accessSelect[\s\S]*?alignRight:\s*true/);
});

// One field, not a text box stacked on a toolbar.
test("no rule separates the composer prompt from its controls", () => {
    const shell = composer.match(/Rectangle\s*\{\s*id:\s*composerShell\b([\s\S]*?)\n\s{4}\}/);

    assert.ok(shell, "expected the composer glass shell");
    assert.doesNotMatch(shell[1], /Rectangle\s*\{\s*\n\s*width:\s*parent\.width\s*\n\s*height:\s*1\s*\n\s*color:\s*T3Theme\.border\s*\n\s*\}/,
        "a hairline under the prompt splits the one glass shell into two controls");
});

// Provider and model are one gesture on the bar. Applying them as two draft
// updates routes through the provider's *default* model, which a per-thread
// guard can reject even when the model the user asked for is allowed.
test("the composer changes provider and model as a single selection", () => {
    const drafts = fs.readFileSync(path.join(shellDir, "Common/T3Drafts.qml"), "utf8");
    const code = fs.readFileSync(path.join(shellDir, "Common/T3Code.qml"), "utf8");

    assert.match(composer,
        /function chooseSelection\(instanceId, model\)[\s\S]*?T3Code\.setNewSelection\(instanceId, model\)/);
    assert.match(composer,
        /function chooseSelection\(instanceId, model\)[\s\S]*?T3Code\.setThreadSelection\(threadId, instanceId, model\)/);
    assert.match(drafts, /function setThreadSelection\(threadId, instanceId, model\)/);
    assert.match(drafts, /function setNewSelection\(instanceId, model\)/);
    assert.match(drafts,
        /function threadModelChangeReason\(threadId, instanceId, model\)[\s\S]*?modelChangeAllowed/,
        "a cross-provider list must still respect each thread's model-change guard");
    for (const name of ["setNewSelection", "setThreadSelection", "selectionId",
            "threadPickerRows", "newPickerRows"])
        assert.match(code, new RegExp(`function ${name}\\(`),
            `T3Code must expose ${name} to the composer`);
    assert.doesNotMatch(composer, /id:\s*providerPicker\b/,
        "a separate provider picker is the second control the bar folded away");
});

test("T3 composer preserves the Ultrathink prompt cue inside the glass shell", () => {
    assert.match(composer,
        /readonly property bool ultrathink:\s*\/\\bultrathink\\b\/i\.test\(promptEdit\.text\)/);
    assert.match(composer,
        /visible:\s*root\.ultrathink[\s\S]*?color:\s*T3Theme\.accentSubtle/);
});

test("draft feedback waits for the selected-draft binding before resyncing input", () => {
    const connections = composer.match(
        /Connections\s*\{\s*target:\s*T3Code([\s\S]*?)\n\s*}/);

    assert.ok(connections, "expected composer draft connections");
    assert.match(composer,
        /id:\s*promptSyncTimer[\s\S]*?interval:\s*0[\s\S]*?onTriggered:\s*root\.syncPrompt\(\)/);
    assert.match(connections[1], /promptSyncTimer\.restart\(\)/);
    assert.doesNotMatch(connections[1], /root\.syncPrompt\(\)/,
        "a synchronous resync can read the previous draft and undo the keystroke");
});

test("the header glyph button lives in IconButton.qml, not inline copies", () => {
    for (const page of ["Popovers/T3ThreadPage.qml", "Popovers/T3NewThreadPage.qml"]) {
        const source = fs.readFileSync(path.join(shellDir, page), "utf8");
        assert.doesNotMatch(source, /component\s+(IconButton|HeaderAction)\s*:/,
            `${page} must use the shared IconButton type instead of a local copy`);
    }
});

// A running turn locks the prompt, so the round action would otherwise sit
// there disabled with nothing to send — exactly when the user wants to stop
// the turn, and exactly where they are already pointing.
test("the composer's round action becomes a stop while the turn is working", () => {
    const send = composer.match(
        /Rectangle\s*\{\s*id:\s*sendButton\b([\s\S]*?)\n\s{16}\}/);

    assert.ok(send, "expected to find the composer's send button");
    assert.match(composer, /property bool stoppable:\s*false/);
    assert.match(composer, /signal stopRequested\(\)/);
    assert.match(composer,
        /readonly property bool stopMode:\s*stoppable && !newThread/,
        "a thread that does not exist yet has no turn to interrupt");
    assert.match(send[1], /visible:\s*!root\.stopMode[\s\S]*?name:\s*root\.sending \? "more_horiz" : "arrow_upward"/);
    // The stop mark is a Rectangle, not a glyph: the icon font builds its
    // filled square by collapsing the outlined one's counter, and the seam
    // rounds back open at this size.
    assert.match(send[1],
        /Rectangle\s*\{\s*visible:\s*root\.stopMode[\s\S]*?radius:\s*2/,
        "the stop square must be drawn, not shaped from the icon font");
    assert.match(send[1], /enabled:\s*root\.stopMode\s*\n\s*\? T3Code\.canDispatch && !root\.stopping/,
        "a stop must not wait on prompt text the composer will not accept");
    assert.match(send[1], /onClicked:\s*root\.activatePrimary\(\)/);
    assert.match(send[1], /Accessible\.name:\s*root\.stopMode \? "Stop"/);
});

// Stopping is not the same act as sending, and the button says so in colour
// as well as in glyph — with a red mixed for a fill rather than for copy.
test("the working composer shows a red stop beside a live progress ring", () => {
    const bar = composer.match(/Item\s*\{\s*id:\s*actionRow\b([\s\S]*?)\n\s{12}\}/);
    const theme = fs.readFileSync(path.join(shellDir, "Common/T3Theme.qml"), "utf8");

    assert.ok(bar);
    assert.match(bar[1],
        /id:\s*sendButton[\s\S]*?color:\s*root\.stopMode\s*\n\s*\?\s*\(sendMouse\.containsMouse && sendMouse\.enabled\s*\n\s*\? T3Theme\.dangerHover : T3Theme\.danger\)/);
    assert.match(bar[1],
        /id:\s*workingIndicator[\s\S]*?visible:\s*root\.stopMode \|\| root\.sending/);
    assert.match(bar[1],
        /id:\s*workingIndicator[\s\S]*?name:\s*"progress_activity"[\s\S]*?RotationAnimation on rotation/,
        "an in-flight turn needs a moving indicator, not a static glyph");
    assert.match(theme, /readonly property color danger:\s*dark \? "#[0-9a-f]{6}" : "#[0-9a-f]{6}"/,
        "the palette's error role is a copy tint; a filled circle needs a mid-tone");
    assert.match(theme, /readonly property color dangerForeground:\s*SettingsHelpers\.ensureContrast/,
        "white on an arbitrary red is an assumption, not a contrast check");
});

// The strip is the composer's footnote: same object, docked to its top edge,
// narrower than the shell so the shell reads as the thing in front.
test("task progress docks to the composer instead of floating above the transcript", () => {
    const page = fs.readFileSync(path.join(shellDir, "Popovers/T3ThreadPage.qml"), "utf8");
    const dock = page.match(/Item\s*\{\s*id:\s*composerDock\b([\s\S]*?)\n\s{4}\}/);

    assert.ok(dock, "expected the strip and the composer to share one wrapper");
    assert.ok(dock[1].indexOf("id: taskProgressCard") < dock[1].indexOf("id: composer\n"),
        "the strip must paint before the composer that covers its bottom");
    assert.match(dock[1], /id:\s*composer\b[\s\S]*?anchors\.top:\s*taskProgressCard\.bottom/,
        "the page Column's spacing would open a gap between the two");
    assert.match(dock[1], /id:\s*taskProgressCard[\s\S]*?clip:\s*true/);
    assert.match(dock[1],
        /id:\s*taskProgressStrip[\s\S]*?width:\s*Math\.max\(0, parent\.width - 36\)/,
        "a strip as wide as the shell reads as a second card, not a tab behind it");
    assert.match(dock[1],
        /id:\s*taskProgressStrip[\s\S]*?height:\s*parent\.height \+ T3Theme\.panelRadius/,
        "the overhang is what the clip turns into square bottom corners");
    assert.match(dock[1],
        /id:\s*taskProgressSegments[\s\S]*?anchors\.verticalCenter:\s*taskProgressGlyph\.verticalCenter/,
        "the ticks belong on the count's line, not on a second row of their own");
});

test("the thread page interrupts the turn rather than stopping the session", () => {
    const page = fs.readFileSync(path.join(shellDir, "Popovers/T3ThreadPage.qml"), "utf8");
    const composerUse = page.match(/T3Composer\s*\{([\s\S]*?)\n\s{4}\}/);

    assert.ok(composerUse, "expected the thread page to host a T3Composer");
    assert.match(composerUse[1], /stoppable:\s*root\.working\b/,
        "background work keeps its own Stop in the banner above the composer");
    assert.match(composerUse[1], /onStopRequested:\s*T3Code\.interrupt\(root\.threadId\)/,
        "stopping the session would tear down a thread the user still wants");
    const singleton = fs.readFileSync(path.join(shellDir, "Common/T3Code.qml"), "utf8");
    assert.match(singleton, /function interrupt\(threadId\)\s*\{\s*T3Rpc\.interrupt\(threadId\);/);
});

// The picker mirrors the reference client: a provider rail on the left, one
// list on the right, retired models folded away, and search that hides the
// rail because it is deliberately global.
test("the model picker pairs a provider rail with one model list", () => {
    const picker = fs.readFileSync(path.join(shellDir, "Popovers/T3ModelPicker.qml"), "utf8");

    assert.match(picker, /id:\s*providerRail[\s\S]*?visible:\s*!root\.searching/,
        "a search that a rail still scopes is not a search");
    assert.match(picker, /id:\s*railIndicator[\s\S]*?Behavior on y/,
        "the selection should be followed, not re-found");
    assert.match(picker, /id:\s*favoritesRail[\s\S]*?visible:\s*T3Code\.favoriteModels\.length > 0/,
        "an empty shortlist is a rail entry that leads nowhere");
    assert.match(picker, /text:\s*"Legacy models"[\s\S]*?count \+ " models"/);
    assert.match(picker, /name:\s*"chevron_right"[\s\S]*?rotation:\s*root\.legacyExpanded \? 90 : 0/);
    assert.match(picker, /placeholder|Search models…/);
    assert.match(picker, /text:\s*"No models found"|"No models found"/);
    // A bare digit belongs to the search field the moment it has focus, so
    // the jump shortcut has to carry a modifier — as the reference's does.
    assert.match(picker,
        /event\.modifiers & Qt\.ControlModifier[\s\S]*?activateShortcut/);
    assert.match(picker, /text:\s*"Ctrl\+" \+ \(pickerRow\.modelData\.shortcut/);
});

// Favourites are localStorage in the reference client — per client, never
// synced — so this shell owns its own list rather than pretending otherwise.
test("starred models persist in shell state, not in the thread draft", () => {
    const favorites = fs.readFileSync(path.join(shellDir, "Common/T3Favorites.qml"), "utf8");
    const drafts = fs.readFileSync(path.join(shellDir, "Common/T3Drafts.qml"), "utf8");

    assert.match(favorites, /state\/cybexos\/shell\/t3-model-favorites\.json/);
    assert.doesNotMatch(favorites, /property string statePath:\s*\n?\s*Quickshell\.statePath\(/,
        "by-shell paths fork the list per config directory");
    assert.match(favorites, /FileView[\s\S]*?atomicWrites:\s*true/);
    assert.match(favorites, /function toggle\(instanceId, model\)/);
    assert.doesNotMatch(drafts, /favorites:\s*\[\]/,
        "a starred model outlives the draft it was starred from");

    const qmldir = fs.readFileSync(path.join(shellDir, "Common/qmldir"), "utf8");
    assert.match(qmldir, /singleton T3Favorites T3Favorites\.qml/);
});

test("the star is reachable, quiet until wanted, and never strands its own rail", () => {
    const picker = fs.readFileSync(path.join(shellDir, "Popovers/T3ModelPicker.qml"), "utf8");
    const row = picker.match(/id:\s*pickerRow\b([\s\S]*?)\n\s{24}\}/);

    assert.ok(row, "expected the picker's row delegate");
    assert.ok(row[1].indexOf("id: rowMouse") < row[1].indexOf("id: favoriteButton"),
        "the star overlaps the row's click target, so it must be the later sibling");
    assert.doesNotMatch(row[1], /rightMargin:\s*favoriteButton\.(visible|width)/,
        "carving a hole out of the row's hit box breaks the moment either size changes");
    assert.match(row[1],
        /id:\s*favoriteButton[\s\S]*?opacity:\s*pickerRow\.modelData\.favorite === true\s*\n\s*\|\| rowMouse\.containsMouse/,
        "a column of lit stars down an untouched list outshouts the model names");
    assert.match(row[1],
        /id:\s*favoriteButton[\s\S]*?onTriggered:\s*T3Code\.toggleFavoriteModel\(/);

    // Unstarring the last model takes its rail entry with it.
    assert.match(picker,
        /onFavoritesAvailableChanged:[\s\S]*?railId === "favorites"[\s\S]*?railId = currentInstanceId\(\)/,
        "standing on a rail that no longer exists leaves an empty panel and no way out");
});
