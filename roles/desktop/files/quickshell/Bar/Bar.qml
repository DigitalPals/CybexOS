pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Services.SystemTray
import Quickshell.Wayland
import "../Common"
import "../Common/BarGeometry.js" as BarGeometry
import "../Common/LayoutHelpers.js" as LayoutHelpers
import "../Common/PanelRegistryData.js" as PanelRegistry
import "../Common/WidgetCatalog.js" as WidgetCatalog

PanelWindow {
    id: barWindow

    anchors {
        top: Settings.position === "top"
        bottom: Settings.position === "bottom"
        left: true
        right: true
    }
    property var compactIds: []
    property var overflowIds: []
    property real centerShift: 0
    // Follow the clock's local geometry synchronously. Updating this from the
    // deferred fit pass left it one rendered frame behind an animated child,
    // which showed up as a right/left rebound during indicator disclosure.
    readonly property real centerPinBias: {
        void slotRegistryRevision;
        const actual = currentCenterExtents();
        return centerCluster.width / 2 - actual.left;
    }
    // What the centre cluster is actually drawn at. The fit pass moves
    // `centerShift` in one step when a module appears or the bar is resized;
    // routing it through a second property lets the pill glide there, and a
    // Behavior cannot be attached to a grouped anchor property directly.
    property real animatedCenterShift: centerShift

    Behavior on animatedCenterShift {
        enabled: barWindow.animationsReady
        NumberAnimation {
            duration: Theme.expandDuration
            easing.type: Easing.BezierSpline
            easing.bezierCurve: Theme.springCurve
        }
    }
    // Shared pointer truth for tooltips. Individual MouseAreas can miss an
    // exit when the pointer leaves this layer surface, while the full-window
    // handler below still reports that the bar itself is no longer hovered.
    readonly property bool tooltipPointerInside: barHover.hovered
    // Hovering the clock discloses its neighbouring quick actions. This is
    // resolved by the bar-wide pointer path so mapping a detached popout cannot
    // strand disclosure on a missed child enter/exit event.
    property bool indicatorTriggerHovered: false
    // The Indicators revealer owns its width spring while opening or closing;
    // its Cluster wrapper yields so the two animations do not compound.
    property bool indicatorDisclosureAnimating: false
    property point tooltipPointerPosition: Qt.point(-1, -1)
    readonly property int safetyGutter: 8
    readonly property int closedHeight: Theme.barTopMargin + Theme.barHeight + 34
    readonly property string outputName: screen ? screen.name : ""
    readonly property bool popoutHost: outputName !== ""
        && Popouts.hostScreenName === outputName
    readonly property bool popoutActive: popoutHost && Popouts.open
    implicitHeight: closedHeight
    // The bar edge's y inside this window: hugging the anchored screen edge
    // with the configured gap on either position.
    readonly property real barY: BarGeometry.barY({
        style: Settings.barStyle,
        gap: Settings.gap,
        height: Theme.barHeight,
        position: Settings.position,
        windowHeight: height
    })
    // Balanced spacing: with Hyprland's gaps_out on top of the exclusive
    // zone, windows end up exactly barTopMargin below the bar's inner edge —
    // the same gap as outside it. Auto-hide and "reserve space" off both drop
    // the zone entirely.
    exclusiveZone: BarGeometry.exclusiveZone({
        style: Settings.barStyle,
        gap: Settings.gap,
        height: Theme.barHeight,
        autoHide: Settings.autoHide,
        exclusive: Settings.exclusive
    })
    color: "transparent"

    // Geometry animations stay off until the bar has laid itself out once, so
    // the first frame is the finished bar rather than a pill growing out of
    // nothing on every shell start.
    property bool animationsReady: false

    Timer {
        id: settleTimer
        interval: 240
        running: true
        onTriggered: barWindow.animationsReady = true
    }

    // ---- auto-hide ----------------------------------------------------
    // The window stays mapped; only the content slides away and the input
    // mask shrinks to a thin reveal strip at the screen edge, so clicks
    // pass through the vacated area.
    property bool revealed: true
    readonly property bool hidden: Settings.autoHide && !revealed && !popoutActive
    property real hideShift: hidden ? BarGeometry.hideShift({
        style: Settings.barStyle,
        gap: Settings.gap,
        height: Theme.barHeight,
        position: Settings.position
    }) : 0

    Behavior on hideShift {
        NumberAnimation {
            duration: Theme.expandDuration
            easing.type: Easing.BezierSpline
            easing.bezierCurve: Theme.springCurve
        }
    }

    Timer {
        id: hideTimer
        interval: 1600
        onTriggered: {
            if (Settings.autoHide && !barHover.hovered)
                barWindow.revealed = false;
        }
    }

    Connections {
        target: Settings

        function onAutoHideChanged() {
            if (Settings.autoHide) {
                hideTimer.restart();
            } else {
                hideTimer.stop();
                barWindow.revealed = true;
            }
        }

        function onPanelOpenChanged() {
            if (!Settings.panelOpen && Settings.autoHide)
                hideTimer.restart();
        }
    }

    Connections {
        target: Popouts

        function onOpenChanged() {
            if (!Popouts.open && Settings.autoHide)
                hideTimer.restart();
        }
    }

    // A persisted auto-hide setting does not emit onAutoHideChanged during
    // construction, so explicitly arm the initial idle countdown.
    Component.onCompleted: {
        if (Settings.autoHide)
            hideTimer.restart();
    }

    mask: Region { item: barWindow.hidden ? revealStrip : barStrip }

    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    WlrLayershell.namespace: "qs-bar"

    // ---- shared service state ----------------------------------------

    // One bar exists per output, but only the focused bar carries the Wayland
    // inhibitor. SysInfo's systemd-inhibit is what actually holds the session
    // awake, so duplicating this per output would add no protection.
    IdleInhibitor {
        window: barWindow
        enabled: SysInfo.idleInhibited && barWindow.visible
            && barWindow.screen === Screens.focused
    }

    function popoutOpen(name) {
        return popoutActive && Popouts.currentName === name;
    }

    // Published in window coordinates for the independent popout layer.
    // Keeping the panels in another Wayland surface prevents their Loader and
    // height changes from resizing/remapping the menubar itself.
    // The y here is deliberately position-independent: it encodes the
    // section's distance from the bar's anchored screen edge, which is what
    // the popout geometry consumes — PopoutHost mirrors itself for bottom bars.
    readonly property rect leftIslandRect: Qt.rect(
        Theme.barSideMargin, Theme.barTopMargin,
        leftSection.width + Theme.barPadding, Theme.barHeight)
    readonly property rect centerIslandRect: Qt.rect(
        Math.round((barWindow.width - centerCluster.width) / 2
            + barWindow.centerPinBias + barWindow.animatedCenterShift), Theme.barTopMargin,
        Math.max(1, centerCluster.width), Theme.barHeight)
    readonly property rect rightIslandRect: Qt.rect(
        barWindow.width - Theme.barSideMargin - rightSection.width - Theme.barPadding,
        Theme.barTopMargin,
        rightSection.width + Theme.barPadding, Theme.barHeight)

    // Where a module sits, in the window coordinates the popout layer uses:
    // its panel hangs under the module itself rather than under the section
    // the module happens to live in.
    function anchorOf(item) {
        const p = item.mapToItem(null, 0, 0);
        return Qt.rect(p.x, p.y, item.width, item.height);
    }

    // Panel-name → module item, maintained by the settings-driven module
    // components as their Loaders create and destroy them. Read only from
    // imperative code paths, so plain mutation without notify is fine.
    property var panelAnchors: ({})

    function registerPanel(name, item) {
        panelAnchors[name] = item;
    }

    function unregisterPanel(name, item) {
        if (panelAnchors[name] === item)
            delete panelAnchors[name];
    }

    // Whether a module is on screen at all, beyond the user having enabled it:
    // media only while something is playing, Bluetooth only when connected,
    // battery only on laptops, weather once there is a forecast, a reason
    // there is not, or a location to ask for, and the two modules that are
    // their own reason to exist — the updates chip and the tray — only while
    // they have something to show.
    //
    // Every such rule belongs here and nowhere else. The bar's dividers and its
    // group pills read the same function, so a module that hid itself by some
    // other means would leave a separator with nothing on one side of it and a
    // pill with nothing inside it.
    function autoRule(id) {
        switch (id) {
        case "media": return Media.hasTrack;
        case "weather": return Weather.ready || Weather.offline || !Weather.locationSet;
        case "bt": return BluetoothState.connected;
        case "batt": return Battery.isLaptop;
        case "updates": return Updates.total > 0 || Updates.error !== ""
            || Updates.runState !== "idle" || Updates.rebootRecommended;
        case "tray": return SystemTray.items.values.length > 0;
        default: return true;
        }
    }

    function moduleShown(entry) {
        return !!entry && entry.on === true && autoRule(entry.id)
            && !moduleOverflowed(entry.id);
    }

    function moduleCompact(id) {
        return compactIds.indexOf(id) !== -1;
    }

    function moduleOverflowed(id) {
        return overflowIds.indexOf(id) !== -1;
    }

    function currentOverflowItems() {
        return overflowIds.map(id => ({
            id: id,
            label: WidgetCatalog.widgetName(id),
            panel: PanelRegistry.panelForModule(id)
        }));
    }

    // The More chip calls this on every pointer motion (its recovery path for
    // a lost enter). Reassigning the singleton rebuilds the open popover's
    // Repeater, so only publish a list that actually differs — which still
    // lets this output's list replace another output's.
    function prepareOverflow() {
        const next = currentOverflowItems();
        if (JSON.stringify(next) !== JSON.stringify(BarOverflow.items))
            BarOverflow.items = next;
    }

    function toggleOverflow(item) {
        prepareOverflow();
        togglePopout("overflow", "right", item);
    }

    // ---- fit pass ------------------------------------------------------
    // Live ModuleSlots, keyed by module id. The clusters nest their slots
    // inside group pills, so the fit pass registers them here on the way in
    // rather than trying to walk two levels of Repeater back out.
    property var slotRegistry: ({})
    // Object key mutation has no QML notify signal of its own. This revision
    // makes bindings that resolve a registered slot rerun on lifecycle changes.
    property int slotRegistryRevision: 0

    function registerSlot(id, slot) {
        slotRegistry[id] = slot;
        slotRegistryRevision++;
        scheduleFit();
    }

    function unregisterSlot(id, slot) {
        if (slotRegistry[id] === slot) {
            delete slotRegistry[id];
            slotRegistryRevision++;
            scheduleFit();
        }
    }

    function scheduleFit() {
        fitTimer.restart();
    }

    // ---- rearranging widgets in place -----------------------------------
    // Dragging a widget along the bar is the same edit as dragging its row in
    // Shell settings, and both commit through LayoutHelpers.moveWidget. Only
    // the measurement differs: the settings list has one fixed row pitch to
    // divide by, while the bar has to ask its live slots where they actually
    // came to rest — every widget is a different width, and a group pill puts
    // padding around whatever it holds.
    //
    // Nothing moves during the drag. The widget under the pointer only dims,
    // a caret marks the gap it would land in, and the layout is left alone
    // until the drop — the same contract the settings list keeps, and the
    // only one where the bar does not slide out from under the pointer.
    property var dragWidget: null      // { id, fromCol }
    property var dragDrop: null        // { col, idx }, idx measured pre-removal
    property point dragPos: Qt.point(0, 0)
    readonly property bool rearranging: dragWidget !== null

    function pluginsFor(col) {
        return col === "left" ? leftPlugins
            : col === "center" ? centerPlugins : rightPlugins;
    }

    function pluginDropIndex(col, x) {
        const area = pluginsFor(col);
        for (let i = 0; i < area.entries.length; i++) {
            const slot = area.slotFor(area.entries[i].key);
            if (slot && x < slot.mapToItem(contentFrame, slot.width / 2, 0).x)
                return i;
        }
        return area.entries.length;
    }

    function clusterFor(col) {
        return col === "left" ? leftCluster
            : col === "center" ? centerCluster : rightCluster;
    }

    // A drawn widget's center, in contentFrame coordinates, or undefined when
    // it is not on screen to have one.
    function widgetCenterX(id) {
        void slotRegistryRevision;
        const slot = slotRegistry[id];
        if (!slot || !slot.active || slot.width <= 0)
            return undefined;
        return slot.mapToItem(contentFrame, slot.width / 2, 0).x;
    }

    function widgetCenters(col) {
        const centers = {};
        for (const entry of Settings.mods[col]) {
            const x = widgetCenterX(entry.id);
            if (x !== undefined)
                centers[entry.id] = x;
        }
        return centers;
    }

    // The widget a press at `pos` means. Inside a widget wins outright; past
    // its edge the nearest one within half a chip still counts, so the padding
    // a group pill puts around its contents — and the fine rule between two
    // widgets sharing one — picks up the widget the pointer is plainly on
    // rather than nothing at all.
    function widgetAtPoint(pos) {
        void slotRegistryRevision;
        // Plugin keys include the instance name and live outside Settings.mods.
        for (const col of ["left", "center", "right"]) {
            const area = pluginsFor(col);
            for (const entry of area.entries) {
                const slot = area.slotFor(entry.key);
                if (!slot)
                    continue;
                const local = slot.mapFromItem(contentFrame, pos.x, pos.y);
                if (local.x >= 0 && local.x <= slot.width
                        && local.y >= 0 && local.y <= slot.height)
                    return { pluginKey: entry.key, name: entry.name, fromCol: col };
            }
        }
        let best = null;
        const tolerance = Theme.chipHeight / 2;
        let bestDistance = Infinity;
        for (const col of ["left", "center", "right"]) {
            // Stay within the cluster. The launcher and Fedora buttons share a
            // Row with the left and right clusters but are the bar's own
            // furniture, not widgets — dragging off one must not pick up
            // whichever widget happens to sit next to it.
            const cluster = clusterFor(col);
            if (!cluster || cluster.width <= 0)
                continue;
            const origin = cluster.mapToItem(contentFrame, 0, 0).x;
            if (pos.x < origin - tolerance
                    || pos.x > origin + cluster.width + tolerance)
                continue;
            for (const entry of Settings.mods[col]) {
                const slot = slotRegistry[entry.id];
                if (!slot || !slot.active || slot.width <= 0)
                    continue;
                const left = slot.mapToItem(contentFrame, 0, 0).x;
                const distance = pos.x < left ? left - pos.x
                    : pos.x > left + slot.width ? pos.x - left - slot.width : 0;
                if (distance < bestDistance) {
                    bestDistance = distance;
                    best = { id: entry.id, fromCol: col };
                }
            }
        }
        return bestDistance <= tolerance ? best : null;
    }

    function beginWidgetDrag(pos) {
        const found = widgetAtPoint(pos);
        if (!found)
            return;
        // A popout left open would hang off an anchor that is about to move,
        // and it covers the very gap the drop is aiming for.
        if (Popouts.open)
            Popouts.close();
        if (UserPlugins.activePopout) {
            const owner = UserPlugins.activePopout;
            if (typeof owner.close === "function")
                owner.close();
            UserPlugins.releasePopout(owner);
        }
        dragWidget = found;
        dragPos = Qt.point(pos.x, pos.y);
        updateWidgetDrop(dragPos);
    }

    function updateWidgetDrop(pos) {
        // Leaving the bar band cancels rather than drops. The gesture has left
        // the strip it edits, and a widget thrown at the desktop has no second
        // meaning worth inventing — releasing there puts it back.
        const slack = Theme.barHeight;
        if (pos.y < -slack || pos.y > contentFrame.height + slack) {
            dragDrop = null;
            return;
        }
        const col = LayoutHelpers.barDropColumn(pos.x, {
            leftEnd: leftSection.x + leftSection.width,
            centerStart: centerCluster.x,
            centerEnd: centerCluster.x + centerCluster.width,
            rightStart: rightSection.x
        });
        const idx = dragWidget && dragWidget.pluginKey
            ? pluginDropIndex(col, pos.x)
            : LayoutHelpers.barDropIndex(Settings.mods[col], widgetCenters(col), pos.x);
        if (!dragDrop || dragDrop.col !== col || dragDrop.idx !== idx)
            dragDrop = { col: col, idx: idx };
    }

    // Where to draw the caret for the current drop: the gap before the first
    // drawn widget at or after the index, else after the last drawn one before
    // it, else the empty cluster's own origin.
    function dropCaretX() {
        void slotRegistryRevision;
        if (!dragDrop)
            return 0;
        if (dragWidget && dragWidget.pluginKey) {
            const area = pluginsFor(dragDrop.col);
            for (let i = dragDrop.idx; i < area.entries.length; i++) {
                const slot = area.slotFor(area.entries[i].key);
                if (slot)
                    return slot.mapToItem(contentFrame, 0, 0).x - Theme.barSpacing / 2;
            }
            for (let i = dragDrop.idx - 1; i >= 0; i--) {
                const slot = area.slotFor(area.entries[i].key);
                if (slot)
                    return slot.mapToItem(contentFrame, slot.width, 0).x + Theme.barSpacing / 2;
            }
            return area.mapToItem(contentFrame, 0, 0).x;
        }
        const list = Settings.mods[dragDrop.col];
        const gap = Theme.barSpacing / 2;
        for (let i = dragDrop.idx; i < list.length; i++) {
            const slot = slotRegistry[list[i].id];
            if (slot && slot.active && slot.width > 0)
                return slot.mapToItem(contentFrame, 0, 0).x - gap;
        }
        for (let i = dragDrop.idx - 1; i >= 0; i--) {
            const slot = slotRegistry[list[i].id];
            if (slot && slot.active && slot.width > 0)
                return slot.mapToItem(contentFrame, slot.width, 0).x + gap;
        }
        const cluster = clusterFor(dragDrop.col);
        return cluster ? cluster.mapToItem(contentFrame, 0, 0).x : 0;
    }

    function commitWidgetDrag() {
        if (dragWidget && dragDrop && dragWidget.pluginKey) {
            UserPlugins.moveWidget(dragWidget.pluginKey, dragDrop.col, dragDrop.idx);
        } else if (dragWidget && dragDrop) {
            const result = LayoutHelpers.moveWidget(Settings.mods,
                dragWidget.fromCol, dragWidget.id, dragDrop.col, dragDrop.idx);
            if (result)
                Settings.setModuleOrder(result.mods.left, result.mods.center,
                    result.mods.right);
        }
        cancelWidgetDrag();
    }

    function cancelWidgetDrag() {
        dragWidget = null;
        dragDrop = null;
    }

    // Every module that has detail text to give up, with what giving it up
    // would save and which column it would save it in.
    function measuredSlots() {
        const entries = [];
        const metrics = currentCenterExtents();
        for (const id of Object.keys(slotRegistry)) {
            const slot = slotRegistry[id];
            if (!slot || !slot.active)
                continue;
            entries.push({
                id: id,
                col: slot.col,
                saving: slot.detailSaving,
                width: slot.width + (moduleCompact(id) ? slot.detailSaving : 0),
                currentWidth: slot.width,
                policy: slot.modelData.detail ?? "auto",
                centerSide: slot.col === "center" && id !== "clock"
                    && slot.mapToItem(centerCluster, 0, 0).x + slot.width / 2
                        <= metrics.left ? "left" : "right"
            });
        }
        return entries;
    }

    function itemCenterXWithin(item, ancestor) {
        let position = item.width / 2;
        let current = item;
        // Read every intermediate x explicitly. mapToItem() returns the same
        // number, but its internal transform walk does not expose those notify
        // dependencies to a QML binding, leaving the clock pin one layout
        // update behind a Row whose preceding child is changing width.
        while (current && current !== ancestor) {
            position += current.x;
            current = current.parent;
        }
        return current === ancestor ? position : ancestor.width / 2;
    }

    function currentClockPin() {
        const clockSlot = slotRegistry.clock;
        if (clockSlot && clockSlot.active && clockSlot.col === "center")
            return itemCenterXWithin(clockSlot, centerCluster);
        return centerCluster.width / 2;
    }

    function currentCenterExtents() {
        const pin = currentClockPin();
        return {
            left: Math.max(0, pin),
            right: Math.max(0, centerCluster.width - pin)
        };
    }

    function reconstructedCenterExtents(entries) {
        const actual = currentCenterExtents();
        const result = { left: actual.left, right: actual.right };
        for (const entry of entries) {
            if (entry.col !== "center" || !moduleCompact(entry.id))
                continue;
            const side = entry.centerSide === "left" ? "left" : "right";
            result[side] += entry.saving;
        }
        for (const entry of entries) {
            if (entry.col !== "center" || !moduleOverflowed(entry.id))
                continue;
            const side = entry.centerSide === "left" ? "left" : "right";
            result[side] += entry.currentWidth;
        }
        return result;
    }

    // The width a section would occupy with nothing compacted, which is what
    // the fit pass has to reason about — otherwise a module that has already
    // given up its label reads as small enough and never gets it back.
    function reconstructedWidth(width, col, entries) {
        let result = width;
        for (const entry of entries) {
            if (entry.col === col && moduleCompact(entry.id))
                result += entry.saving;
            if (entry.col === col && moduleOverflowed(entry.id))
                result += entry.currentWidth;
        }
        return result;
    }

    function recomputeFit() {
        const entries = measuredSlots();
        const centerExtents = reconstructedCenterExtents(entries);
        const result = LayoutHelpers.fitBar({
            width: width,
            sideMargin: Theme.barSideMargin + Theme.barPadding,
            gutter: safetyGutter,
            widths: {
                left: reconstructedWidth(leftSection.width, "left", entries),
                center: reconstructedWidth(centerCluster.width, "center", entries),
                right: reconstructedWidth(rightSection.width
                    - (overflowIds.length > 0
                        ? overflowButton.width + Theme.barSpacing : 0), "right", entries)
            },
            centerExtents: centerExtents,
            entries: entries,
            overflowWidth: Theme.chipHeight + Theme.barSpacing
        });
        if (JSON.stringify(compactIds) !== JSON.stringify(result.compact))
            compactIds = result.compact;
        if (JSON.stringify(overflowIds) !== JSON.stringify(result.overflow))
            overflowIds = result.overflow;
        centerShift = result.centerOffset;
    }

    onWidthChanged: fitTimer.restart()

    Timer {
        id: fitTimer
        // Width changes are animated. Re-fitting an intermediate spring frame
        // feeds a partial width back into compaction and can make the selected
        // detail set oscillate indefinitely. Debounce through the full spring,
        // then measure the stable compact or expanded geometry once.
        interval: Math.max(1, Theme.expandDuration + 20)
        onTriggered: barWindow.recomputeFit()
    }

    function moduleForPanel(name) {
        const item = panelAnchors[name];
        return item && item.visible ? item : null;
    }

    // A module disabled from the settings window takes its open popout with
    // it; callLater lets the Repeater rebuild settle first.
    Connections {
        target: Settings

        function onModsChanged() {
            fitTimer.restart();
            // Every output runs this handler, but only the popout's host owns
            // the module whose detached panel is open.
            // A panel no module owns (settings, control, tailscale) can never
            // fail this sweep honestly: moduleForPanel() is always null for it.
            if (!barWindow.popoutActive
                || PanelRegistry.ownerless(Popouts.currentName))
                return;
            Qt.callLater(() => {
                if (Popouts.open && !barWindow.moduleForPanel(Popouts.currentName))
                    Popouts.close();
            });
        }
    }

    // Module id -> its file. The modules live in Bar/Modules/ and share a
    // BarModule base, which is what lets ModuleSlot hold them as a type
    // rather than duck-typing its way through Loader.item.
    readonly property var moduleSources: ({
        ws: "Modules/Workspaces.qml", media: "Modules/Media.qml",
        clock: "Modules/Clock.qml", weather: "Modules/Weather.qml",
        notes: "Modules/Notes.qml",
        indicators: "Modules/Indicators.qml",
        t3: "Modules/T3.qml", hermes: "Modules/Hermes.qml",
        usage: "Modules/Usage.qml",
        gh: "Modules/GitHub.qml", updates: "Modules/Updates.qml",
        tray: "Modules/Tray.qml", notifications: "Modules/Notifications.qml",
        vol: "Modules/Volume.qml", wifi: "Modules/Wifi.qml",
        batt: "Modules/Battery.qml", bt: "Modules/Bluetooth.qml"
    })

    function sameAnchor(a, b) {
        return Math.abs(a.x - b.x) < 0.5
            && Math.abs(a.y - b.y) < 0.5
            && Math.abs(a.width - b.width) < 0.5
            && Math.abs(a.height - b.height) < 0.5;
    }

    function togglePopout(name, isle, item) {
        Popouts.toggle(name, isle, anchorOf(item), outputName);
    }

    function openPopout(name, isle, item) {
        Popouts.openPanel(name, isle, anchorOf(item), outputName);
    }

    // Desktop-menu semantics, tunable from the Drawer settings page. The
    // default ("open") latches the menu session with a click, then crossing
    // another menu-bearing item switches the existing surface in place.
    // "always" lets a hover open the session by itself; "off" keeps hover
    // inert entirely, so only clicks navigate.
    function hoverPopout(name, isle, item) {
        if (rearranging || Settings.drawerHover === "off")
            return false;
        if (!Popouts.open && Settings.drawerHover !== "always")
            return false;
        if (!popoutOpen(name))
            openPopout(name, isle, item);
        return true;
    }

    function itemContainsPoint(item, position) {
        if (!item || !item.visible || item.width <= 0 || item.height <= 0)
            return false;
        const local = item.mapFromItem(null, position.x, position.y);
        return local.x >= 0 && local.x <= item.width
            && local.y >= 0 && local.y <= item.height;
    }

    // Mapping the detached layer surface can prevent a child MouseArea from
    // receiving its next enter or motion event. The bar-wide HoverHandler
    // keeps receiving pointer motion, so resolve its scene point against the
    // same registered anchors as a reliable second path.
    function hoverPanelAt(position) {
        // Crossing a widget mid-drag is the drag, not a menu transition.
        if (rearranging || Settings.drawerHover === "off")
            return;
        if (!Popouts.open && Settings.drawerHover !== "always")
            return;

        // Usage owns one panel anchor but several provider targets. Resolve
        // the provider first; treating the whole group as a generic anchor
        // would open the right panel with whichever provider was selected last.
        const usageItem = panelAnchors.usage;
        if (usageItem && usageItem.visible
                && usageItem.providerAtScenePoint !== undefined) {
            const provider = usageItem.providerAtScenePoint(position);
            if (provider !== "") {
                Usage.selected = provider;
                hoverPopout("usage",
                    usageItem.isle || Popouts.defaultIsland.usage, usageItem);
                return;
            }
        }

        for (const name of Object.keys(panelAnchors)) {
            const item = panelAnchors[name];
            if (!itemContainsPoint(item, position))
                continue;
            hoverPopout(name, item.isle || Popouts.defaultIsland[name], item);
            return;
        }
    }

    // IPC opens and transitions initiated inside a popout do not carry a new
    // module rectangle. Only the popout's owning bar may resolve that module:
    // every output is visible now, and letting all of them publish their local
    // rectangle makes different-sized outputs bounce the shared anchor forever.
    Connections {
        target: Popouts

        function onChanged() {
            if (!barWindow.popoutActive)
                return;
            Qt.callLater(() => {
                if (!barWindow.popoutActive)
                    return;
                if (PanelRegistry.centerAnchored(Popouts.currentName)) {
                    if (Popouts.island !== "center" || Popouts.anchorRect.width !== 0) {
                        Popouts.island = "center";
                        Popouts.anchorRect = Qt.rect(0, 0, 0, 0);
                        Popouts.changed();
                    }
                    return;
                }
                const item = barWindow.moduleForPanel(Popouts.currentName);
                if (!item || item.width <= 0)
                    return;
                const anchor = barWindow.anchorOf(item);
                if (barWindow.sameAnchor(Popouts.anchorRect, anchor))
                    return;
                Popouts.anchorRect = anchor;
                Popouts.changed();
            });
        }
    }

    // Input region for the bar strip itself.
    Item {
        id: barStrip
        x: 0
        y: Settings.position === "top" ? 0 : barWindow.height - height
        width: parent.width
        height: Theme.barTopMargin + Theme.barHeight
    }

    // Hover target while hidden: a thin strip hugging the bar's screen edge.
    Item {
        id: revealStrip
        x: 0
        y: Settings.position === "top" ? 0 : barWindow.height - height
        width: parent.width
        height: 8
    }

    // Tracks the pointer over whatever the window's input mask admits.
    Item {
        id: hoverLayer
        anchors.fill: parent
        z: 100

        HoverHandler {
            id: barHover
            blocking: false

            onPointChanged: {
                const scenePoint = hoverLayer.mapToItem(null,
                    point.position.x, point.position.y);
                barWindow.tooltipPointerPosition = scenePoint;
                barWindow.hoverPanelAt(scenePoint);
                barWindow.indicatorTriggerHovered = barWindow.itemContainsPoint(
                    barWindow.panelAnchors.calendar, scenePoint);
            }

            onHoveredChanged: {
                if (hovered) {
                    hideTimer.stop();
                    barWindow.revealed = true;
                } else if (Settings.autoHide) {
                    hideTimer.restart();
                }
                if (!hovered)
                    barWindow.indicatorTriggerHovered = false;
            }
        }
    }

    // ---- the slab ------------------------------------------------------
    // One continuous surface. In glass mode the compositor supplies the blur
    // behind its tint (see roles/desktop/templates/looknfeel.lua.j2); solid mode uses
    // the same selected menubar color at full opacity.
    Item {
        id: slabLayer
        x: Theme.barSideMargin
        y: barWindow.barY
        width: parent.width - 2 * Theme.barSideMargin
        height: Theme.barHeight

        transform: Translate {
            y: barWindow.hideShift
        }

        RectangularShadow {
            visible: Theme.barFloating && !Settings.glassEnabled
            anchors.fill: barSlab
            radius: Theme.clusterRadius
            blur: 16
            spread: 0
            offset.y: 4
            color: Qt.rgba(0, 0, 0, 0.35)
        }

        Rectangle {
            id: barSlab
            anchors.fill: parent
            radius: Theme.clusterRadius
            color: Theme.barSurface

            Behavior on color {
                ColorAnimation { duration: Theme.surfaceDuration }
            }

            Behavior on radius {
                enabled: barWindow.animationsReady
                NumberAnimation {
                    duration: Theme.surfaceDuration
                    easing.type: Easing.BezierSpline
                    easing.bezierCurve: Theme.springCurve
                }
            }

        }

        HugCorner {
            visible: Theme.barHug
            x: 0
            y: Settings.position === "top" ? parent.height : -height
            bottomCorner: Settings.position === "bottom"
            fillColor: Theme.barSurface
        }

        HugCorner {
            visible: Theme.barHug
            x: parent.width - width
            y: Settings.position === "top" ? parent.height : -height
            rightCorner: true
            bottomCorner: Settings.position === "bottom"
            fillColor: Theme.barSurface
        }

        // Right-click anywhere on the slab opens Shell settings. Module mouse
        // areas only accept the left button, so right-clicks fall through the
        // layout layer to this area.
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.RightButton
            onClicked: Settings.togglePanel(undefined, barWindow.outputName)
        }
    }

    // ---- layout ------------------------------------------------------

    Item {
        id: contentFrame
        x: Theme.barSideMargin
        y: barWindow.barY
        width: parent.width - 2 * Theme.barSideMargin
        height: Theme.barHeight

        transform: Translate {
            y: barWindow.hideShift
        }

        // Dragging a widget along the bar.
        //
        // This has to live on the widgets' own ancestor, not on an overlay
        // stacked above them. An Item carrying a pointer handler is hit-tested
        // like any other: put one on top and it swallows the press, and every
        // widget stops opening its panel. From here the chip's own MouseArea
        // is still hit first and still gets its click, while this handler
        // watches the same press and only takes the grab once the pointer has
        // travelled far enough to mean a drag. That is what lets one gesture
        // mean "open" and the other "move" with no mode to enter first — and
        // it works because no bar widget sets `preventStealing`.
        DragHandler {
            id: widgetDrag
            target: null
            acceptedButtons: Qt.LeftButton
            // Wider than the platform default. The bar is short and dense, and
            // a hand that shifts a few pixels while clicking a widget means to
            // click it.
            dragThreshold: 10
            grabPermissions: PointerHandler.CanTakeOverFromItems
                | PointerHandler.CanTakeOverFromHandlersOfDifferentType
                | PointerHandler.ApprovesTakeOverByAnything

            onActiveChanged: {
                if (active)
                    barWindow.beginWidgetDrag(centroid.pressPosition);
                else
                    barWindow.commitWidgetDrag();
            }

            onCentroidChanged: {
                if (!active || !barWindow.rearranging)
                    return;
                barWindow.dragPos = Qt.point(centroid.position.x,
                    centroid.position.y);
                barWindow.updateWidgetDrop(barWindow.dragPos);
            }
        }

        // LEFT — the launcher, then workspaces and media.
        Row {
            id: leftSection
            anchors.left: parent.left
            anchors.leftMargin: Theme.barPadding
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.barSpacing

            BarIcon {
                host: barWindow
                shape: "pill"
                glyph: "apps"
                glyphSize: Theme.barIconSize
                glyphWeight: 500
                idleColor: Theme.barIcon
                restFill: Launcher.open && Launcher.screen === barWindow.screen
                    ? Theme.barChipHover : "transparent"
                hPadding: 5
                tooltip: "Apps  ·  Super Space"
                tooltipAlign: -1
                onClicked: Launcher.toggle(barWindow.screen)
            }

            UserWidgets {
                id: leftPlugins
                barHost: barWindow
                section: "left"
                screenName: barWindow.outputName
                availableWidth: Math.max(0, barWindow.width * 0.15)
                onImplicitWidthChanged: barWindow.scheduleFit()
            }

            Cluster {
                id: leftCluster
                host: barWindow
                col: "left"
                model: Settings.mods.left
                onImplicitWidthChanged: barWindow.scheduleFit()
            }
        }

        // CENTER — independent action, calendar and forecast pills, pinned on
        // the clock so disclosure grows outwards without moving the time.
        Row {
            id: centerCluster
            spacing: Theme.barSpacing
            // Algebraically this is the former centered anchor plus pin bias,
            // but as one binding it cannot render between the two halves of
            // that cancellation. The clock's local center is the only moving
            // input while indicators disclose on its left.
            x: parent.width / 2 - barWindow.currentClockPin()
                + barWindow.animatedCenterShift
            anchors.verticalCenter: parent.verticalCenter
            onImplicitWidthChanged: barWindow.scheduleFit()

            Cluster {
                host: barWindow
                col: "center"
                model: Settings.mods.center
            }
            UserWidgets {
                id: centerPlugins
                barHost: barWindow
                section: "center"
                screenName: barWindow.outputName
                availableWidth: Math.max(0, barWindow.width * 0.15)
            }
        }

        // RIGHT — configured modules, then the fixed Control Panel trigger.
        // Recording lives beside the clock with the other active quick actions.
        Row {
            id: rightSection
            anchors.right: parent.right
            anchors.rightMargin: Theme.barPadding
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.barSpacing

            UserWidgets {
                id: rightPlugins
                barHost: barWindow
                screenName: barWindow.screen ? barWindow.screen.name : ""
                availableWidth: Math.max(0, barWindow.width * 0.25)
                onImplicitWidthChanged: barWindow.scheduleFit()
            }

            Cluster {
                id: rightCluster
                host: barWindow
                col: "right"
                model: Settings.mods.right
                onImplicitWidthChanged: barWindow.scheduleFit()
            }

            BarChip {
                id: overflowButton

                visible: barWindow.overflowIds.length > 0
                host: barWindow
                panelName: "overflow"
                isle: "right"
                hPadding: 6
                preparePanel: () => barWindow.prepareOverflow()
                tooltip: barWindow.overflowIds.length + " hidden widgets"
                tooltipAlign: 1
                Accessible.role: Accessible.Button
                Accessible.name: "More widgets"
                Accessible.description: tooltip
                Sym {
                    anchors.verticalCenter: parent.verticalCenter
                    name: "more_horiz"
                    size: Theme.barIconSize
                    color: overflowButton.fg
                }
            }

            BarChip {
                id: controlButton

                host: barWindow
                panelName: "control"
                isle: "right"
                hPadding: 5
                tooltip: "Control Panel"
                tooltipAlign: 1

                BarBrandIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    width: Theme.barIconSize
                    height: Theme.barIconSize
                    name: "fedora"
                    highlighted: controlButton.held || controlButton.hovered
                }
            }
        }
    }

    // ---- rearrange overlay ---------------------------------------------
    // The drop indicator and the widget in flight, drawn above the bar's
    // content. Visual only: it carries no MouseArea and no pointer handler,
    // which is the whole reason it can sit on top without stopping a click
    // from reaching the widget underneath. The drag itself is handled from
    // contentFrame, where the press is still shared with the widgets.
    //
    // Mirrors contentFrame's geometry and transform so both use one set of
    // coordinates — the same ones the drop measurements are taken in.
    Item {
        id: rearrangeLayer
        x: contentFrame.x
        y: contentFrame.y
        width: contentFrame.width
        height: contentFrame.height
        z: 60

        // Named rather than read back off the caret: `visible` returns an
        // item's *effective* visibility, so a sibling binding to it depends on
        // the parent chain too and latches the moment the tree is rearranged.
        readonly property bool caretShown: barWindow.rearranging
            && barWindow.dragDrop !== null

        transform: Translate {
            y: barWindow.hideShift
        }

        // The gap the widget will land in.
        Rectangle {
            id: dropCaret
            visible: rearrangeLayer.caretShown
            x: barWindow.dropCaretX() - width / 2
            y: (parent.height - height) / 2
            width: 2
            height: Theme.chipHeight
            radius: 1
            color: Theme.barAccent
            z: 1
            // Deliberately not animated, like the settings list's caret: it
            // would otherwise slide in from the bar's left edge on pickup,
            // since there is no previous gap for it to have come from.
        }

        RectangularShadow {
            visible: rearrangeLayer.caretShown
            x: dropCaret.x
            y: dropCaret.y
            width: dropCaret.width
            height: dropCaret.height
            radius: 1
            blur: 8
            color: Theme.barAccentGlow
            z: 1
        }

        RectangularShadow {
            visible: barWindow.rearranging
            x: dragProxy.x
            y: dragProxy.y
            width: dragProxy.width
            height: dragProxy.height
            radius: dragProxy.radius
            blur: 12
            offset.y: 2
            color: Qt.rgba(0, 0, 0, 0.35)
            z: 2
        }

        // The widget in flight. A name rather than a copy of the widget: the
        // real one is still drawn in place under the pointer, and two of the
        // same thing on one bar reads as a duplicate rather than a move.
        Rectangle {
            id: dragProxy
            visible: barWindow.rearranging
            x: LayoutHelpers.clamp(barWindow.dragPos.x - width / 2,
                0, Math.max(0, parent.width - width))
            y: (parent.height - height) / 2
            width: proxyRow.implicitWidth + 18
            height: Theme.chipHeight
            radius: Theme.chipRadius
            color: Theme.barSurface
            border.width: 1
            // The border carries whether releasing now would commit: away from
            // the bar the drop clears, and the proxy says so before the user
            // lets go rather than after.
            border.color: barWindow.dragDrop ? Theme.barAccent : Theme.barStroke
            z: 3

            // No drag handle here, unlike the settings row's proxy: the chip
            // is already attached to the pointer, and the bar draws its copy
            // in the menu face like everything else on it.
            Text {
                id: proxyRow
                anchors.centerIn: parent
                text: barWindow.dragWidget
                    ? (barWindow.dragWidget.name || WidgetCatalog.widgetName(barWindow.dragWidget.id)) : ""
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.bar
                font.weight: Theme.weightMedium
                color: Theme.barTextHi
            }
        }
    }
}
