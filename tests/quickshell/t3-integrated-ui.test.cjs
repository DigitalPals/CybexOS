const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { shellDir } = require("./shell.cjs");

function read(rel) {
    return fs.readFileSync(path.join(shellDir, rel), "utf8");
}

const files = [
    "T3CodePopover.qml", "T3InboxPage.qml", "T3ThreadPage.qml",
    "T3Composer.qml", "T3RequestCard.qml", "T3Picker.qml",
    "T3NewThreadPage.qml"
];

test("T3 adapts the shell palette inside a wider content-sized panel", () => {
    const theme = read("Common/T3Theme.qml");
    const popover = read("Popovers/T3CodePopover.qml");
    const panel = read("Popovers/PopoutPanel.qml");
    const host = read("Bar/PopoutHost.qml");

    assert.match(theme, /readonly property color canvas:\s*Theme\.background/);
    assert.match(theme, /readonly property color surface:\s*Theme\.popBg/);
    assert.match(theme, /readonly property color surfaceRaised:\s*Theme\.copyReferenceBg/);
    assert.match(theme, /readonly property color textPrimary:\s*Theme\.textHi/);
    assert.match(theme, /readonly property color accent:\s*SettingsHelpers\.ensureContrast\([\s\S]*?Theme\.accent\.toString\(\),\s*surfaceRaised\.toString\(\), 4\.5\)/);
    assert.match(theme, /readonly property color accentForeground:\s*SettingsHelpers\.ensureContrast\([\s\S]*?Theme\.accentFg\.toString\(\),\s*accent\.toString\(\), 4\.5\)/);
    assert.doesNotMatch(theme, /#346bf1|#1b4ed8/,
        "T3 must not retain a competing hard-coded blue accent");
    assert.match(popover, /surfaceColor:\s*Theme\.barSurface/);
    assert.match(popover,
        /implicitWidth:\s*availableWidth > 0[\s\S]{0,100}?Math\.min\(Theme\.t3MaxWidth, availableWidth\)/);
    assert.match(popover,
        /implicitHeight:\s*Math\.min\(maxPanelHeight, panelChromeHeight \+ pageBodyHeight\)/);
    assert.match(popover,
        /readonly property Item loadedPage:\s*pageLoader\.item as Item/);
    assert.match(popover,
        /pageNaturalHeight:\s*loadedPage[\s\S]{0,100}?loadedPage\.implicitHeight/);
    assert.doesNotMatch(popover,
        /workspaceExpanded|pageMaxWidth|threadMaxHeight|\b460\b|\b520\b|\b760\b/,
        "the dedicated drawer has no compact/expanded presentation modes");
    assert.match(popover,
        /BrandIcon\s*\{[\s\S]{0,220}?name:\s*"t3"[\s\S]{0,220}?colorized:\s*true[\s\S]{0,220}?T3Theme\.textPrimary\s*:\s*T3Theme\.textFaint/,
        "the one wordmark asset must follow the connected canvas tone");
    assert.match(panel, /property color surfaceColor:\s*Theme\.barSurface/);
    assert.match(host, /host\.activePanel\.surfaceColor/);
});

test("T3 pages size to content and keep chrome fixed around capped scrollers", () => {
    const popover = read("Popovers/T3CodePopover.qml");
    const inbox = read("Popovers/T3InboxPage.qml");
    const thread = read("Popovers/T3ThreadPage.qml");
    const newPage = read("Popovers/T3NewThreadPage.qml");

    assert.match(popover,
        /readonly property real maxPageBodyHeight:[\s\S]*?maxPanelHeight - panelChromeHeight/);
    assert.match(popover,
        /readonly property real pageBodyHeight:[\s\S]*?Math\.min\(maxPageBodyHeight,[\s\S]*?pageNaturalHeight/);
    assert.match(popover, /id:\s*pageLoader[\s\S]*?height:\s*root\.pageBodyHeight/);

    for (const page of [inbox, thread, newPage]) {
        assert.match(page, /readonly property real naturalHeight:/,
            "each T3 page must publish its content-driven height");
        assert.match(page,
            /implicitHeight:\s*Math\.min\(maxHeight, Math\.max\(1, naturalHeight\)\)/,
            "each T3 page must stop growing at the output cap");
    }

    const searchAt = inbox.indexOf("id: searchBox");
    const viewportAt = inbox.indexOf("id: viewport");
    const bodyAt = inbox.indexOf("id: body");
    assert.ok(searchAt >= 0 && searchAt < viewportAt && viewportAt < bodyAt,
        "inbox search must be fixed above the scrolling grouped list");
    assert.match(inbox,
        /id:\s*searchBox[\s\S]*?visible:\s*root\.totalThreadCount > 0 \|\| root\.searchText !== ""/);
    assert.match(inbox,
        /id:\s*viewport[\s\S]*?anchors\.top:\s*searchBox\.visible \? searchBox\.bottom : parent\.top[\s\S]*?anchors\.bottom:\s*parent\.bottom/);

    assert.match(thread, /id:\s*header[\s\S]*?anchors\.top:\s*parent\.top/);
    assert.match(thread,
        /id:\s*viewport[\s\S]*?anchors\.top:\s*gitFeedback\.bottom[\s\S]*?anchors\.bottom:\s*bottomDock\.top/);
    assert.match(thread,
        /id:\s*bottomDock[\s\S]*?anchors\.bottom:\s*parent\.bottom[\s\S]*?id:\s*composerAttachmentsViewport[\s\S]*?id:\s*composerDock/);

    assert.match(newPage,
        /id:\s*header[\s\S]*?anchors\.top:\s*parent\.top/);
    assert.match(newPage,
        /id:\s*viewport[\s\S]*?anchors\.top:\s*header\.bottom[\s\S]*?anchors\.bottom:\s*parent\.bottom/);
});

test("T3 inbox switches to two-line thread tiles below 360px", () => {
    const inbox = read("Popovers/T3InboxPage.qml");

    assert.match(inbox, /readonly property bool narrowRows:\s*width < 360/);
    assert.match(inbox,
        /id:\s*row[\s\S]*?height:\s*entry\.narrow \? 54 : T3Theme\.quietRowHeight/);
    assert.match(inbox,
        /id:\s*threadTitle[\s\S]*?y:\s*entry\.narrow \? 6/);
    assert.match(inbox,
        /id:\s*meta[\s\S]*?y:\s*entry\.narrow \? parent\.height - height - 6/);
});

test("Escape closes T3 layers, then navigates back, then reaches the host", () => {
    const popover = read("Popovers/T3CodePopover.qml");

    const escape = popover.match(/function handleEscape\(\): bool \{([\s\S]*?)\n    \}/);
    assert.ok(escape);
    const body = escape[1];
    const connection = body.indexOf("connectionMenuOpen");
    const threadLayer = body.indexOf("loadedThreadPage.closeOpenLayer()");
    const newLayer = body.indexOf("loadedNewThreadPage.closeOpenLayer()");
    const inbox = body.indexOf('page === "inbox"');
    const back = body.indexOf("showInbox()");
    assert.ok(connection >= 0 && connection < threadLayer && threadLayer < newLayer
        && newLayer < inbox && inbox < back);
    assert.match(body, /if \(page === "inbox"\)\s*return false;/,
        "Inbox must leave the final Escape for PopoutHost");
});

test("T3 navigation uses one contextual header and hides relay detail in overflow", () => {
    const popover = read("Popovers/T3CodePopover.qml");
    const footer = popover.match(/Item\s*\{\s*id:\s*footer\b([\s\S]*?)\n\s*Connections\s*\{/);

    assert.match(popover, /id:\s*inboxHeader[\s\S]*?visible:\s*root\.page === "inbox"/);
    assert.match(popover, /symbol:\s*"edit_square"/);
    assert.match(popover, /id:\s*connectionMenu/);
    assert.match(popover, /T3Code\.host\.replace/);
    assert.ok(footer, "expected the compact connection footer");
    assert.doesNotMatch(footer[1], /T3Code\.host/,
        "the raw relay host belongs in overflow, not permanent footer chrome");
});

test("T3 restores the last open non-settled thread across disposable popovers", () => {
    const popover = read("Popovers/T3CodePopover.qml");
    const code = read("Common/T3Code.qml");
    const detail = read("Common/T3Detail.qml");

    assert.match(detail, /property string lastViewedThreadId:\s*""/);
    assert.match(popover,
        /function showThread\(threadId\)[\s\S]*?T3Code\.rememberThread\(threadId\)/);
    assert.match(popover,
        /function showInbox\(\)[\s\S]*?T3Code\.forgetThread\(selectedThreadId\)/);
    assert.match(popover,
        /Component\.onCompleted:\s*root\.restoreThread\(\)/);
    assert.match(code,
        /function restorableThreadId\(\)[\s\S]*?!T3Threads\.shellReady[\s\S]*?thread\.lifecycle === "settled"/);
    assert.doesNotMatch(popover,
        /Component\.onDestruction:\s*T3Code\.forgetThread/,
        "closing the popout must not be mistaken for navigating back");
});

test("thread header identifies the project and provider without repeating the model", () => {
    const thread = read("Popovers/T3ThreadPage.qml");
    const metadata = thread.match(
        /Row\s*\{\s*id:\s*threadMetadata\b([\s\S]*?)\n\s*}\n\s*}\n\s*IconButton\s*\{\s*id:\s*openButton/);

    assert.ok(metadata, "expected the thread metadata row");
    assert.match(metadata[1], /name:\s*"folder"/);
    assert.match(metadata[1], /T3Code\.threadProviderIcon\(root\.threadId\)/);
    assert.match(metadata[1], /BrandIcon\s*\{[\s\S]*?name:\s*threadMetadata\.providerGlyph/);
    assert.doesNotMatch(metadata[1], /threadSelectionLabel|modelSelection/,
        "the compact header must not repeat the selected model");
});

test("thread page mirrors live task progress from plan-update activities", () => {
    const detail = read("Common/T3Detail.qml");
    const code = read("Common/T3Code.qml");
    const thread = read("Popovers/T3ThreadPage.qml");

    assert.match(detail,
        /detailTaskProgress:\s*Helpers\.taskProgress\(detailActivities,/);
    assert.match(code,
        /detailTaskProgress:\s*T3Detail\.detailTaskProgress/);
    assert.match(thread,
        /id:\s*taskProgressCard[\s\S]*?text:\s*"Tasks"/);
    assert.match(thread,
        /modelData\.status === "completed" \? T3Theme\.success[\s\S]*?"inProgress" \? T3Theme\.accent/);
    assert.match(thread,
        /taskProgress\.completedCount \+ "\/"[\s\S]*?taskProgress\.total/);
});

test("the T3 composer is one shell with inline controls, cornered like the bar", () => {
    const composer = read("Popovers/T3Composer.qml");
    const theme = read("Common/T3Theme.qml");

    assert.match(composer, /id:\s*composerShell[\s\S]*?radius:\s*T3Theme\.composerRadius/);
    // The old 22px pill was T3's own shape. The composer is a well inside a
    // panel that hangs off the menubar, so it takes the menubar's corner and
    // follows it when the bar's radius setting changes.
    assert.match(theme, /readonly property int composerRadius:\s*Theme\.panelRadius/);
    assert.match(read("Common/Theme.qml"),
        /readonly property int panelRadius:\s*Settings\.surfaceCornerRadius/);
});

test("the T3 composer exposes an attached settings drawer and round send action", () => {
    const composer = read("Popovers/T3Composer.qml");
    const send = composer.match(/Rectangle\s*\{\s*id:\s*sendButton\b([\s\S]*?)\n\s*Sym\s*\{/);

    assert.match(composer, /id:\s*settingsDrawer[\s\S]*?visible:\s*settingsPresentation\.expanded/);
    assert.match(composer, /text:\s*"Ask anything…"/);
    assert.ok(send, "expected the composer's Material Symbol send button");
    assert.match(send[1], /width:\s*Theme\.inlineActionHeight/);
    assert.match(send[1], /height:\s*Theme\.inlineActionHeight/);
    assert.match(send[1], /radius:\s*width \/ 2/);
    assert.match(composer,
        /name:\s*root\.sending \? "more_horiz" : "arrow_upward"/,
        "the one round action carries send and in-flight");
    assert.match(composer,
        /Rectangle\s*\{\s*visible:\s*root\.stopMode[\s\S]*?color:\s*T3Theme\.dangerForeground/,
        "and stop, as a drawn square the icon font cannot render cleanly");
    assert.doesNotMatch(composer, /Enter to send · Ctrl\+Enter/,
        "keyboard help must not be permanent visual chrome");
});

// A parked "progress_activity" is a half ring, which reads as a broken glyph
// rather than as work in flight. Every place the transcript shows it, it turns.
test("the thread's activity arcs spin while their work runs", () => {
    const thread = read("Popovers/T3ThreadPage.qml");

    assert.match(thread,
        /name:\s*"progress_activity"[\s\S]{0,400}?RotationAnimation on rotation\s*\{\s*running:\s*root\.working\b/,
        "the working row's arc must turn for as long as the turn runs");
    assert.match(thread,
        /id:\s*backgroundGlyph[\s\S]*?RotationAnimation on rotation\s*\{\s*running:\s*backgroundBanner\.visible && !root\.monitoring/,
        "the background banner turns its arc but not the watching eye");
});

test("thread transcript follows T3 message rhythm and attaches response UI", () => {
    const thread = read("Popovers/T3ThreadPage.qml");
    const message = thread.match(/component MessageCard:\s*Item\s*\{([\s\S]*?)\n\s*component MenuEntry:/);

    assert.ok(message, "expected the transcript message component");

    // One reading column for both roles. The right-aligned bubble spent a
    // fifth of a 460px measure saying what the speaker label says, and it was
    // the last card left in the transcript.
    assert.doesNotMatch(message[1], /messageWidth/,
        "a user turn no longer claims a narrower column than the reply to it");
    assert.doesNotMatch(message[1], /id:\s*userBubble/,
        "the user bubble is gone; a label and a hairline separate the turns");
    assert.match(message[1], /readonly property string speaker:\s*fromUser \? "YOU"/,
        "each turn opens with its speaker");
    assert.match(message[1], /color:\s*T3Theme\.border/,
        "and is separated from the one above it by a hairline");

    assert.match(message[1], /textFormat:\s*messageCard\.fromUser \? Text\.PlainText : Text\.MarkdownText/);
    assert.match(message[1], /root\.themedMarkdown\(messageCard\.message\.text\)/);
    assert.match(message[1], /messageHover\.hovered \|\| activeFocus/);

    // The metadata used to float because it had nowhere stable to sit: putting
    // it in the content column made every later message jump as the pointer
    // crossed a card. The speaker row is that stable home, so the overlay goes.
    assert.doesNotMatch(message[1], /id:\s*messageMetadata/,
        "hover metadata belongs in the speaker row, not in a floating pill");
    assert.match(message[1],
        /id:\s*speakerLabel[\s\S]*?id:\s*copyMessageButton[\s\S]*?id:\s*messageTime/,
        "the speaker row carries the copy action and the timestamp");
    assert.match(message[1],
        /id:\s*copyMessageButton[\s\S]{0,200}?visible:\s*messageCard\.metadataVisible/,
        "only the copy action is revealed on hover; the time is always readable");
    assert.doesNotMatch(message[1],
        /visible:\s*messageCard\.longMessage \|\| messageCard\.metadataVisible/,
        "hovering must not add a metadata row to the message column");

    const attachments = thread.indexOf("id: composerAttachmentsViewport");
    const composer = thread.lastIndexOf("id: composer");
    const timeline = thread.indexOf("id: timeline");
    const request = thread.indexOf("T3RequestCard {", timeline);
    assert.ok(attachments > timeline && attachments < composer);
    assert.ok(request >= attachments && request < composer,
        "requests must be attached above the composer rather than embedded in the timeline");

    const markdownCount = (thread.match(/Text\.MarkdownText/g) || []).length;
    const themedMarkdownCount = (thread.match(/root\.themedMarkdown\(/g) || []).length;
    assert.equal(themedMarkdownCount, markdownCount,
        "every Markdown surface must rewrite links before Qt applies its default blue");
    assert.match(thread,
        /function themedMarkdown\(markdown\)[\s\S]{0,180}?T3Code\.styleMarkdownLinks/);
    assert.doesNotMatch(thread, /linkColor:/,
        "linkColor does not style Qt's rich Markdown document and is false assurance");
    assert.match(thread,
        /root\.checkpoint\.filenames\.join\(" · "\)[\s\S]{0,260}?color:\s*T3Theme\.textSecondary/,
        "the changed-file list is readable neutral copy, not an accent or faint label");
});

test("composer-attached questions keep numbered options keyboard actionable", () => {
    const request = read("Popovers/T3RequestCard.qml");

    assert.match(request, /required property int index/);
    assert.match(request, /option\.index < 9 \? String\(option\.index \+ 1\)/);
    assert.match(request, /event\.key >= Qt\.Key_1 && event\.key <= Qt\.Key_9/);
});

test("inbox keeps flat wide rows, fixed search, and inline state", () => {
    const inbox = read("Popovers/T3InboxPage.qml");

    assert.match(inbox, /id:\s*searchBox/);
    assert.match(inbox,
        /height:\s*entry\.narrow \? 54 : T3Theme\.quietRowHeight/);
    // A parked thread is still quieter than working one — in type, not in
    // chrome. Nothing but attention and error paints a fill.
    assert.match(inbox, /entry\.subdued \? T3Theme\.textSecondary : T3Theme\.textPrimary/);
    assert.match(inbox, /T3Theme\.amberSoft\) : "transparent"/);
    assert.match(inbox, /name:\s*entry\.statusSymbol/);
    assert.doesNotMatch(inbox, /id:\s*rail\b/);
    assert.doesNotMatch(inbox, /Animation\.Infinite/,
        "thread state must not repaint the popout continuously");
});

test("all T3 views use the product typeface and Material Symbol controls", () => {
    const combined = files.map(file => read(`Popovers/${file}`)).join("\n");

    assert.doesNotMatch(combined, /Theme\.fontMenu|font\.family:\s*Theme\.fontMono/);
    assert.doesNotMatch(combined,
        /(?<!T3)Theme\.(?:surfaceStrong|surfaceMenu|insetSurface|textHi|textMid|textLow|textDim|textFaint|accentBg|accentFg|hoverFill|cardFill|hairlineSoft)/,
        "T3 views must consume shell colors through the T3Theme boundary");
    assert.doesNotMatch(combined, /[←↗↻⋯▴▾▸]/,
        "typographic control glyphs must use the shared symbol component");
    assert.match(combined, /Sym\s*\{/);
});
