import QtQuick
import "../Common"

// One scrolling settings page. Its content is a single column of bounded
// width, centered in the pane, so a wide window does not push the controls a
// long way from their labels (2026-09 redesign).
//
// A top-level page sets `pageReset` and gains a "Reset <Page> to defaults"
// action at its foot while any of its values differs from the default; the
// window header no longer carries that action. `overlay` holds items pinned
// over the scrolling content — a preview kept in view at the top, an Apply
// bar at the bottom — and `topInset`/`bottomInset` keep the content clear
// of them.
Flickable {
    id: root
    default property alias content: contentRoot.data
    property alias overlay: overlayLayer.data
    property int spacing: Theme.settingsGroupSpacing
    property int maxContentWidth: Theme.scaled(640, Theme.typeScale)
    property real topInset: 0
    property real bottomInset: 0
    property bool pageReset: false
    property string resetSection: Settings.page
    property string resetText: "Reset " + Settings.pageInfo(resetSection).label + " to defaults"
    readonly property bool resetShown: pageReset && Settings.revision >= 0
        && Settings.sectionDirty(resetSection)
    readonly property bool scrollbarVisible: contentHeight > height - topInset - bottomInset + 1
    // Always reserved: tying the gutter to scrollbarVisible loops, because
    // the narrower content re-wraps taller, which flips scrollbarVisible.
    readonly property int scrollGutter: 8
    readonly property alias columnWidth: contentRoot.width

    contentWidth: width
    contentHeight: contentRoot.height
        + (resetShown ? Theme.settingsGroupSpacing + resetFooter.height : 0)
    topMargin: topInset
    bottomMargin: bottomInset
    boundsBehavior: Flickable.StopAtBounds
    interactive: contentHeight > height - topInset - bottomInset
    clip: true
    flickDeceleration: 3000

    // A search jump lands on the row whose settingKey matches
    // Settings.highlightKey; the row draws its own accent wash, this scrolls
    // it into view. Depth-first over the visual tree because rows sit inside
    // groups, columns and revealers at varying depths.
    function rowForKey(item, key) {
        if (!item)
            return null;
        if (item.settingKey !== undefined && item.settingKey === key)
            return item;
        for (const child of item.children) {
            const hit = rowForKey(child, key);
            if (hit)
                return hit;
        }
        return null;
    }

    function revealHighlight() {
        if (Settings.highlightKey === "")
            return;
        const row = rowForKey(contentRoot, Settings.highlightKey);
        if (row)
            revealFocus(row);
    }

    // A freshly loaded page is still growing when the jump first measures
    // it: revealers open to their natural height over expandDuration. Measure
    // once more after they settle so a row near the bottom is not left
    // below the fold.
    Timer {
        id: highlightSettle
        interval: Theme.expandDuration + 50
        onTriggered: root.revealHighlight()
    }

    Connections {
        target: Settings
        function onHighlightKeyChanged() {
            root.revealHighlight();
            highlightSettle.restart();
        }
    }

    // Pages incubate after the jump has already set the key; one layout pass
    // later the rows have real geometry to scroll to.
    // A QObject-bound callback is canceled if a loader destroys this page first.
    Component.onCompleted: {
        Qt.callLater(root.revealHighlight);
        highlightSettle.restart();
    }

    function revealFocus(item) {
        if (!item)
            return;
        // Window focus also moves to navigation and search outside this page.
        let ancestor = item;
        while (ancestor && ancestor !== contentRoot && ancestor !== resetFooter)
            ancestor = ancestor.parent;
        if (!ancestor)
            return;
        // A focused control inside a settings row brings the whole row into
        // view, hint line included, as long as the row fits the viewport.
        const viewport = height - topInset - bottomInset;
        for (let row = item; row && row !== contentRoot; row = row.parent) {
            if (row.hintTone !== undefined && row.lineHeight !== undefined) {
                if (row.height <= viewport - 8)
                    item = row;
                break;
            }
        }
        const point = item.mapToItem(root.contentItem, 0, 0);
        const top = point.y;
        const bottom = top + item.height;
        const first = contentY + topInset;
        const last = contentY + height - bottomInset;
        const minY = -topInset;
        const maxY = Math.max(minY, contentHeight - height + bottomInset);
        if (top < first)
            contentY = Math.max(minY, top - topInset - 4);
        else if (bottom > last)
            contentY = Math.max(minY, Math.min(maxY, bottom - height + bottomInset + 4));
    }

    Connections {
        target: root.Window.window
        enabled: target !== null
        function onActiveFocusItemChanged() {
            const item = root.Window.window ? root.Window.window.activeFocusItem : null;
            if (item)
                root.revealFocus(item);
        }
    }

    Item {
        id: contentRoot
        width: Math.min(root.maxContentWidth, Math.max(0, root.width - root.scrollGutter))
        x: Math.max(0, Math.floor((root.width - root.scrollGutter - width) / 2))
        height: childrenRect.height
    }

    // The page's own reset, at its foot: it names what it resets and only
    // appears while there is something to reset. Undo follows in the rail.
    Item {
        id: resetFooter
        visible: root.resetShown
        x: contentRoot.x
        y: contentRoot.height + Theme.settingsGroupSpacing
        width: contentRoot.width
        height: Theme.chipHeight

        SettingsAction {
            anchors.right: parent.right
            anchors.rightMargin: Theme.chipHeight
            text: root.resetText
            glyph: "undo"
            onTriggered: Settings.resetSection(root.resetSection)
        }
    }

    Item {
        id: overlayLayer
        // Flickable normally reparents declarative children to contentItem;
        // pinned items stay fixed to the viewport while the page moves.
        parent: root
        anchors.fill: parent
        z: 2
    }

    ScrollChrome {
        // Flickable normally reparents declarative children to contentItem;
        // this overlay must stay fixed to the viewport while the page moves.
        parent: root
        anchors.fill: parent
        z: 3
        target: root
    }
}
