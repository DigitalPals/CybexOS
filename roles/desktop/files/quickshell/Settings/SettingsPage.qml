import QtQuick
import "../Common"

Flickable {
    id: root
    default property alias content: contentRoot.data
    property int spacing: Theme.settingsGroupSpacing
    readonly property bool scrollbarVisible: contentHeight > height + 1
    // Always reserved: tying the gutter to scrollbarVisible loops, because
    // the narrower content re-wraps taller, which flips scrollbarVisible.
    readonly property int scrollGutter: 8

    contentWidth: width
    contentHeight: contentRoot.childrenRect.height
    boundsBehavior: Flickable.StopAtBounds
    interactive: contentHeight > height
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
        while (ancestor && ancestor !== contentRoot)
            ancestor = ancestor.parent;
        if (!ancestor)
            return;
        // A focused control inside a settings row brings the whole row into
        // view, hint line included, as long as the row fits the viewport.
        for (let row = item; row && row !== contentRoot; row = row.parent) {
            if (row.hintTone !== undefined && row.lineHeight !== undefined) {
                if (row.height <= height - 8)
                    item = row;
                break;
            }
        }
        const point = item.mapToItem(contentRoot, 0, 0);
        const top = point.y;
        const bottom = top + item.height;
        if (top < contentY)
            contentY = Math.max(0, top - 4);
        else if (bottom > contentY + height)
            contentY = Math.max(0, Math.min(contentHeight - height, bottom - height + 4));
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
        width: root.width - root.scrollGutter
        height: childrenRect.height
    }

    ScrollChrome {
        // Flickable normally reparents declarative children to contentItem;
        // this overlay must stay fixed to the viewport while the page moves.
        parent: root
        anchors.fill: parent
        target: root
    }
}
