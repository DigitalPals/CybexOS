pragma ComponentBehavior: Bound
import QtQuick
import "../Common"
import "../Common/LayoutHelpers.js" as LayoutHelpers
import "../Common/SettingsHelpers.js" as SettingsHelpers

// One section of the menubar, and the thing that decides where its pills are.
//
// Grouping remains behavioral rather than decorative. T3, usage and GitHub
// retain their shared ordering/anchor contract, while every group rests
// directly on the single bar slab. Every interactive widget owns its own
// pointer target and dedicated view.
//
// Grouping follows adjacency in the user's own module order, so dragging a
// module out of a run in the settings window splits the pill exactly there.
Item {
    id: root

    required property Bar host
    required property string col
    property var model: []
    property int spacing: Theme.barSpacing

    // The Repeaters below are keyed on structure alone — which ids sit in
    // which group, in what order. Settings reassigns `mods` and `modOpts`
    // wholesale on every edit, so a model built from those objects would
    // hand the Repeater a fresh array for any widget option toggle and
    // tear down every group and module Loader on every output (the tray
    // forgets it was expanded, Wifi re-acquires Tailscale, anchors
    // re-register). A string property only notifies when its value really
    // changes; the live entry (`on`, `detail`) is looked up by id instead,
    // so flag changes flow through bindings into the surviving slots.
    readonly property string groupsKey: JSON.stringify(LayoutHelpers.groupModules(
        (model || []).map(entry => ({ id: entry.id })),
        id => SettingsHelpers.moduleGroup(id, Settings.modOpts)))
    readonly property var groups: JSON.parse(groupsKey)
    readonly property var entriesById: {
        const out = {};
        (model || []).forEach(entry => out[entry.id] = entry);
        return out;
    }

    function liveEntry(id) {
        return entriesById[id] ?? null;
    }

    implicitWidth: row.implicitWidth
    implicitHeight: Theme.barHeight

    Row {
        id: row
        anchors.verticalCenter: parent.verticalCenter
        spacing: root.spacing

        Repeater {
            id: groupRepeater
            model: root.groups

            delegate: Item {
                id: group

                required property var modelData
                readonly property string kind: modelData.kind
                readonly property var items: modelData.items
                // A group whose every module is switched off or ruled out (no
                // player, no battery, no updates) takes its pill with it.
                readonly property bool populated: {
                    for (let i = 0; i < items.length; i++) {
                        if (root.host.moduleShown(root.liveEntry(items[i].entry.id)))
                            return true;
                    }
                    return false;
                }

                // Whether anything before position `at` in this group is on
                // screen: a divider is only a separator when there is
                // something on both sides of it. Derived from the same
                // reactive inputs as the slot's own visibility rather than
                // from the laid-out items, so it never lags a frame behind.
                function shownBefore(at) {
                    for (let i = 0; i < at && i < items.length; i++) {
                        if (root.host.moduleShown(root.liveEntry(items[i].entry.id)))
                            return true;
                    }
                    return false;
                }

                visible: populated
                width: populated ? pill.width : 0
                height: Theme.barHeight
                anchors.verticalCenter: parent.verticalCenter
                onWidthChanged: root.host.scheduleFit()

                // Group furniture is transparent at rest. Pointer targets
                // live inside the modules, so adjacent solo widgets remain
                // independently clickable even when they share a cluster.
                Rectangle {
                    id: pill

                    readonly property string isle: root.col
                    // Filled group kinds (the clock pill, the status glyph
                    // run) rest on a visible chip per the edge-drawer design;
                    // the rest stay transparent furniture.
                    readonly property bool filled:
                        SettingsHelpers.groupFilled(group.kind)
                    readonly property real pad: filled ? 5 : 0

                    width: slotRow.implicitWidth + pad * 2
                    height: Theme.chipHeight
                    radius: Theme.chipRadius
                    anchors.verticalCenter: parent.verticalCenter
                    color: filled ? Theme.barChip : "transparent"

                    // A module appearing or dropping its detail resizes the
                    // pill around it; the glide is what keeps the neighbours
                    // from snapping sideways.
                    Behavior on width {
                        enabled: root.host.animationsReady
                            && !(group.items.length === 1
                                && group.items[0].entry.id === "indicators"
                                && root.host.indicatorDisclosureAnimating)
                        NumberAnimation {
                            duration: Theme.expandDuration
                            easing.type: Easing.BezierSpline
                            easing.bezierCurve: Theme.springCurve
                        }
                    }

                    Row {
                        id: slotRow
                        z: 2
                        anchors.verticalCenter: parent.verticalCenter
                        x: pill.pad
                        spacing: group.kind === "chip" ? 2
                            : root.spacing

                        Repeater {
                            id: slotRepeater
                            model: group.items

                            delegate: Row {
                                id: entry

                                required property var modelData

                                // `active`, not `visible`: an item's `visible`
                                // reads back its *effective* visibility, which
                                // includes this Row — so binding to it makes
                                // the wrapper depend on itself and latch at
                                // false, and a module that only turns on later
                                // (a track starts, updates appear, a tray icon
                                // registers) never gets on screen.
                                visible: slotLoader.active
                                    && !root.host.moduleOverflowed(entry.modelData.entry.id)
                                // Null-guarded: the delegate evaluates once
                                // while it is still being reparented, and an
                                // unguarded read lands a TypeError in the
                                // journal that the deploy health gate then
                                // refuses to snapshot past.
                                anchors.verticalCenter: parent
                                    ? parent.verticalCenter : undefined
                                spacing: 0

                                Divider {
                                    kind: "rule"
                                    visible: group.kind !== "solo"
                                        && group.shownBefore(entry.modelData.at)
                                }

                                ModuleSlot {
                                    id: slotLoader
                                    host: root.host
                                    col: root.col
                                    modelData: root.liveEntry(entry.modelData.entry.id)
                                        ?? entry.modelData.entry
                                    index: entry.modelData.index
                                    groupHovered: entry.modelData.entry.id === "indicators"
                                        && root.host.indicatorTriggerHovered
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
