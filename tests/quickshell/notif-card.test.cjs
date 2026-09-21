const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { shellDir } = require("./shell.cjs");

// The toast overlay and the notification centre drew the same card anatomy
// twice, ~180 lines each, and the copies had drifted. Common/NotifCard.qml is
// now the only one; each surface supplies its own `style` object because the
// two differ almost entirely in type, and typography.test.cjs pins that split
// per file.
//
// A `style` object is a plain `var`, so a missing key is `undefined` at
// runtime with nothing to catch it — not a parse error, not a qmllint
// warning, just a card that silently draws at size 0 or with no font. The
// main assertion below is therefore that every key NotifCard reads is one
// every caller supplies.

const CARD = path.join("Common", "NotifCard.qml");
const CALLERS = ["NotificationToasts.qml", path.join("Popovers", "NotifsPopover.qml")];

function read(rel) {
    return fs.readFileSync(path.join(shellDir, rel), "utf8");
}

// Keys the card actually reads, as `card.style.<key>`.
function keysRead() {
    return new Set([...read(CARD).matchAll(/\bcard\.style\.(\w+)/g)].map(m => m[1]));
}

// Keys a caller's `readonly property var cardStyle: ({ … })` supplies.
function keysSupplied(rel) {
    const source = read(rel);
    const start = source.indexOf("readonly property var cardStyle: ({");
    assert.notEqual(start, -1, `${rel} must declare a cardStyle object`);
    const open = source.indexOf("{", start);
    let depth = 0;
    let end = -1;
    for (let i = open; i < source.length; i++) {
        if (source[i] === "{") depth++;
        else if (source[i] === "}" && --depth === 0) { end = i; break; }
    }
    assert.notEqual(end, -1, `${rel}: cardStyle object is unterminated`);
    const body = source.slice(open + 1, end);
    return new Set([...body.matchAll(/^\s*(\w+):/gm)].map(m => m[1]));
}

test("the card anatomy is defined once, in Common/", () => {
    assert.ok(fs.existsSync(path.join(shellDir, CARD)));
    for (const rel of CALLERS) {
        const source = read(rel);
        // A local `component NotifCard`/`AppIcon`/`ActionPills` is how the
        // duplication looked before; re-adding one splits them again.
        assert.doesNotMatch(source, /component\s+(NotifCard|AppIcon|ActionPills)\s*:/,
            `${rel} redefines a card piece that Common/ already owns`);
    }
});

test("web notification icons fall through to the shared origin resolver", () => {
    const icon = read(path.join("Common", "NotifIcon.qml"));
    const resolver = read(path.join("Common", "WebIcons.qml"));
    const notifs = read(path.join("Common", "Notifs.qml"));

    assert.match(icon, /WebIcons\.request\(entry\.webOrigin\)/);
    assert.match(icon, /WebIcons\.sourceFor\(entry\.webOrigin \|\| ""\)/);
    assert.match(icon, /status === Image\.Error[\s\S]*?root\.primaryFailed = true/,
        "an expired Chromium image-path must fall through to the cached favicon");
    assert.match(resolver, /scripts\/notification-icon\.py/);
    assert.match(resolver, /property var requested:\s*\(\{\}\)/,
        "toast and history instances must deduplicate origin lookups");
    const webBranch = notifs.match(/if \(entry\.webOrigin\) \{([\s\S]*?)\n        \}/);
    assert.ok(webBranch, "Notifs.iconSource must have an explicit web-origin branch");
    assert.match(webBranch[1], /entry\.image/);
    assert.doesNotMatch(webBranch[1], /entry\.appIcon/,
        "a known web origin must never fall back to the Brave product logo");
});

test("every style key the card reads is supplied by every caller", () => {
    const needed = keysRead();
    assert.ok(needed.size >= 10,
        `only found ${needed.size} style keys — has NotifCard stopped using card.style.*?`);
    for (const rel of CALLERS) {
        const supplied = keysSupplied(rel);
        const missing = [...needed].filter(key => !supplied.has(key)).sort();
        assert.deepEqual(missing, [], `${rel} leaves these style keys undefined`);
        const unused = [...supplied].filter(key => !needed.has(key)).sort();
        assert.deepEqual(unused, [], `${rel} supplies style keys nothing reads`);
    }
});

test("both surfaces take the one shell face, as typography.test.cjs requires", () => {
    // The toast and the notification centre draw the same card; they used to
    // hand it two different faces, which is how the same notification read as
    // two different products depending on where you saw it.
    const toast = keysSuppliedSource("NotificationToasts.qml");
    const centre = keysSuppliedSource(path.join("Popovers", "NotifsPopover.qml"));
    assert.match(toast, /face:\s*Theme\.fontMenu/,
        "the toast style must follow the Typography setting");
    assert.match(centre, /face:\s*Theme\.fontMenu/,
        "the centre style must follow the menu font");
    // The centre is a popover, so every size it names must be a Theme token —
    // the 12px floor is enforced there and nowhere else.
    assert.doesNotMatch(centre.replace(/^\s*(bodyLines|bodyLeading|trailingHeight):.*$/gm, ""),
        /:\s*\d+(?:\.\d+)?\s*,?$/m,
        "the centre style names a raw text size instead of a Theme token");
});

test("the toast countdown stays inside the rounded notification card", () => {
    const toast = read("NotificationToasts.qml");

    assert.match(toast, /height:\s*contentHeight\s*\n/,
        "the countdown belongs in the card padding, not in extra space below its content");
    assert.match(toast, /anchors\.leftMargin:\s*card\.padH/);
    assert.match(toast, /anchors\.rightMargin:\s*card\.padH/);
    assert.match(toast, /anchors\.bottomMargin:\s*card\.padV\s*\/\s*2/,
        "the countdown must be inset from the card's curved bottom edge");
    assert.doesNotMatch(toast, /anchors\.margins:\s*1/,
        "a nearly edge-to-edge bar escapes the rounded card silhouette");
});

test("toast geometry and list motion stay compact and edge-aware", () => {
    const toast = read("NotificationToasts.qml");

    assert.match(toast,
        /readonly property int cardWidth:\s*Math\.max\(1, Math\.min\(Theme\.scaled\(380, Theme\.contentScale\),/,
        "toast cards must stay compact and clamp on unusually narrow outputs");
    assert.match(toast, /edgeMargin:\s*Math\.max\(10, Theme\.barSideMargin\)/,
        "attached bars still need a screen-edge gutter");
    assert.match(toast, /ListView\s*\{\s*id:\s*toastList/);
    assert.match(toast, /add:\s*Transition[\s\S]*?property:\s*"x"/,
        "new toasts should arrive from their configured screen edge");
    assert.match(toast, /addDisplaced:\s*Transition[\s\S]*?Theme\.springCurve/,
        "existing cards should settle when a newer toast arrives");
    assert.match(toast, /remove:\s*Transition[\s\S]*?property:\s*"x"/,
        "expired toasts should leave toward their configured screen edge");
    assert.match(toast, /removeDisplaced:\s*Transition[\s\S]*?Theme\.springCurve/,
        "surviving cards should settle instead of jumping into the gap");
    assert.match(toast, /property real reservedListHeight:\s*0/,
        "the panel must remain mapped while the exit transition paints");
    assert.match(toast,
        /visible:\s*Notifs\.toasts\.length > 0 \|\| reservedListHeight > 0/,
        "the final toast's exit must finish before the layer is unmapped");
});

test("toast hover and a history disclosure reveal the full notification text", () => {
    const card = read(CARD);
    const toast = read("NotificationToasts.qml");
    const centre = read(path.join("Popovers", "NotifsPopover.qml"));

    assert.match(card, /property bool expandTextOnHover:\s*false/);
    assert.match(card, /property bool allowTextExpansion:\s*false/);
    assert.match(card, /property bool textExpandedByUser:\s*false/);
    assert.match(card,
        /readonly property bool textExpanded:\s*textExpandedByUser\s*\n\s*\|\| \(expandTextOnHover && hovered\)/);
    assert.equal((card.match(
        /elide:\s*card\.textExpanded \? Text\.ElideNone : Text\.ElideRight/g
    ) || []).length, 3,
    "the app name, summary, and body must all stop eliding while expanded");
    assert.match(card,
        /maximumLineCount:\s*card\.textExpanded\s*\n\s*\? 2147483647\s*:\s*Math\.max\(1, card\.style\.bodyLines\)/,
        "the body line preference is only a collapsed-state limit");
    assert.match(toast, /expandTextOnHover:\s*true/);
    assert.doesNotMatch(centre, /expandTextOnHover:\s*true/,
        "hovering through notification history should keep its layout stable");
    assert.match(centre, /allowTextExpansion:\s*true/,
        "history rows must expose the explicit full-text disclosure");
    assert.match(card,
        /showTextDisclosure:\s*allowTextExpansion\s*\n\s*&& \(textExpandedByUser \|\| textTruncated\)/,
        "the disclosure should only be visible when text is cut off or open");
    assert.match(card,
        /\+ \(card\.allowTextExpansion \? textDisclosure\.width : 0\)/,
        "history cards must reserve a stable slot so truncation cannot form a geometry loop");
    assert.match(card, /name:\s*card\.textExpandedByUser\s*\n\s*\? "expand_less" : "expand_more"/);
    assert.match(card, /Accessible\.name:\s*card\.textExpandedByUser\s*\n\s*\? "Collapse notification text"\s*\n\s*:\s*"Show full notification"/);
    assert.match(card, /onClicked:\s*\{[\s\S]*?card\.toggleTextExpansion\(\);[\s\S]*?\}/,
        "the disclosure must consume its own click instead of invoking the notification");
});

function keysSuppliedSource(rel) {
    const source = read(rel);
    const start = source.indexOf("readonly property var cardStyle: ({");
    const end = source.indexOf("})", start);
    assert.ok(start !== -1 && end !== -1, `${rel} must declare a cardStyle object`);
    return source.slice(start, end);
}
