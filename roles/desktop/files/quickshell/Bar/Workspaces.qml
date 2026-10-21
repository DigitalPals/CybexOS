pragma ComponentBehavior: Bound
import QtQuick
import Quickshell.Hyprland
import "../Common"
import "../Common/WorkspaceMotion.js" as WorkspaceMotion
import "../Common/WorkspaceHelpers.js" as WorkspaceHelpers

// The screenshot's hybrid workspace strip: occupied workspaces are numbers,
// empty slots are dots, and the current workspace is a wider accent chip. Dot
// mode remains available, and the current chip keeps its directional motion.
Rectangle {
    id: root

    property Bar host: null

    readonly property bool numbered: Settings.modOpts.ws.style === "numbers"
    readonly property string monitorName: host ? host.outputName : Screens.focused ? Screens.focused.name : ""
    readonly property var monitorState: DesktopWorkspaces.monitor(monitorName)
    readonly property var liveMonitor: host && host.screen ? Hyprland.monitorFor(host.screen) : Hyprland.focusedMonitor
    // Every display marks the workspace it shows, including an unfocused
    // display. The runtime snapshot also corrects stale monitor IPC events.
    readonly property int focusedId: monitorState ? monitorState.activeWorkspace
        : liveMonitor && liveMonitor.activeWorkspace ? liveMonitor.activeWorkspace.id : -1
    // Only numbered workspaces get a slot: the scratchpad and other special
    // workspaces show over the current one and never shift the strip.
    readonly property var existingIds: WorkspaceMotion.regularIds(Hyprland.workspaces.values)
    readonly property int slots: Math.max(Settings.modOpts.ws.minSlots, ...existingIds)
    // Hyprland republishes its workspace list on every focus change and window
    // event, so the id list is recomputed often and almost always comes out
    // the same. Round-tripping through a string gives the Repeater a new
    // model only when the ids really change; a fresh array every time would
    // recreate every pip (and its hover/tooltip state) on each event.
    readonly property var entries: WorkspaceHelpers.barEntries(DesktopWorkspaces.snapshot,
        monitorName, Hyprland.workspaces.values, Settings.modOpts.ws.minSlots,
        Settings.modOpts.ws.hideEmpty, focusedId)
    readonly property string visibleIdsKey: JSON.stringify(entries.map(entry => entry.id))
    readonly property var visibleIds: JSON.parse(visibleIdsKey)
    readonly property string structureKey: JSON.stringify([
        visibleIdsKey, monitorName, Settings.modOpts.ws.hideEmpty
    ])
    readonly property var activeWorkspace: DesktopWorkspaces.workspace(focusedId)
    readonly property string activeLayout: activeWorkspace ? activeWorkspace.layout : "dwindle"
    property real wheelAccumulator: 0
    property int previousFocusedId: -1
    property bool indicatorReady: false
    property bool snapRequested: true

    implicitWidth: pips.width + 10 + (layoutChip.visible ? layoutChip.width + 4 : 0)
    implicitHeight: Theme.chipHeight
    radius: Theme.chipRadius
    color: "transparent"
    anchors.verticalCenter: parent ? parent.verticalCenter : undefined

    Behavior on color {
        ColorAnimation { duration: Theme.surfaceDuration }
    }

    Behavior on implicitWidth {
        enabled: root.host !== null && root.host.animationsReady
        NumberAnimation {
            duration: Theme.expandDuration
            easing.type: Easing.BezierSpline
            easing.bezierCurve: Theme.springCurve
        }
    }

    function settleIndicator(animate) {
        const bounds = WorkspaceMotion.indicatorBounds(visibleIds, focusedId);
        if (!bounds) {
            indicatorReady = false;
            previousFocusedId = focusedId;
            return;
        }
        const durations = WorkspaceMotion.edgeDurations(previousFocusedId,
            focusedId, animate && indicatorReady && !snapRequested && !Theme.reducedMotion);
        activeLozenge.leftDuration = durations.left;
        activeLozenge.rightDuration = durations.right;
        activeLozenge.animateEdges = durations.direction !== 0;
        activeLozenge.leftEdge = bounds.left;
        activeLozenge.rightEdge = bounds.right;
        indicatorReady = true;
        previousFocusedId = focusedId;
        snapRequested = false;
    }

    function focusWorkspace(id) {
        DesktopWorkspaces.focus(id);
    }

    function scrollWorkspaces(wheel) {
        wheelAccumulator += wheel.angleDelta.y !== 0 ? wheel.angleDelta.y / 120 : wheel.pixelDelta.y / 40;
        const steps = Math.trunc(wheelAccumulator);
        wheelAccumulator -= steps;
        if (steps === 0)
            return;
        if (DesktopWorkspaces.ready) {
            for (let step = 0; step < Math.min(10, Math.abs(steps)); step++)
                DesktopWorkspaces.next(steps > 0 ? -1 : 1, monitorName);
        } else {
            const at = visibleIds.indexOf(focusedId);
            const next = Math.max(0, Math.min(visibleIds.length - 1, at - steps));
            if (at >= 0 && next !== at)
                focusWorkspace(visibleIds[next]);
        }
        wheel.accepted = true;
    }

    onFocusedIdChanged: focusSettle.restart()
    onStructureKeyChanged: {
        snapRequested = true;
        focusSettle.restart();
    }

    Connections {
        target: Settings

        // Any settings reload or hide-empty/style structural change seats the
        // indicator instantly. Ordinary Hyprland focus changes never touch
        // modOpts and retain their directional motion.
        function onModOptsChanged() {
            root.snapRequested = true;
            focusSettle.restart();
        }
    }

    Timer {
        id: focusSettle
        interval: 0
        onTriggered: root.settleIndicator(true)
    }

    Item {
        id: pips
        x: 5
        anchors.verticalCenter: parent.verticalCenter
        width: root.visibleIds.length * WorkspaceMotion.CELL_WIDTH
        height: Theme.chipHeight

        Rectangle {
            id: activeLozenge

            property real leftEdge: -2
            property real rightEdge: 24
            property int leftDuration: 0
            property int rightDuration: 0
            property bool animateEdges: false

            visible: root.indicatorReady
            x: leftEdge
            y: (parent.height - height) / 2
            width: Math.max(1, rightEdge - leftEdge)
            height: root.numbered ? Theme.chipInnerHeight : 8
            radius: Theme.chipRadius
            color: Theme.barWsCurrent
            z: 1

            Behavior on leftEdge {
                enabled: activeLozenge.animateEdges
                NumberAnimation {
                    duration: activeLozenge.leftDuration
                    easing.type: Easing.OutCubic
                }
            }

            Behavior on rightEdge {
                enabled: activeLozenge.animateEdges
                NumberAnimation {
                    duration: activeLozenge.rightDuration
                    easing.type: Easing.OutCubic
                }
            }

            Behavior on height {
                NumberAnimation { duration: Theme.chipFadeDuration }
            }

            Behavior on color {
                ColorAnimation { duration: Theme.reducedMotion ? 0 : 200 }
            }
        }

        Repeater {
            model: root.visibleIds

            delegate: Item {
                id: slot

                required property int index
                required property int modelData
                readonly property int wsId: modelData
                readonly property var entry: root.entries.find(entry => entry.id === wsId) ?? null
                readonly property string label: entry ? entry.label : String(wsId)
                readonly property var ws: Hyprland.workspaces.values.find(
                    workspace => workspace.id === wsId) ?? null
                readonly property bool exists: ws !== null
                readonly property bool focused: root.focusedId === wsId
                readonly property bool urgent: exists && ws.urgent
                readonly property bool showNumber: root.numbered && exists
                readonly property color restingTone: urgent
                    ? (showNumber ? Theme.barRedBg : Theme.barRed)
                    : showNumber
                        ? (workspaceState.over ? Theme.barChip : "transparent")
                        : exists ? Theme.barWsOccupied : Theme.barWsEmpty

                x: index * WorkspaceMotion.CELL_WIDTH
                width: WorkspaceMotion.CELL_WIDTH
                height: Theme.chipHeight
                // The travelling accent is a sibling of these delegates. Keep
                // each label/dot above it so the focused number is never
                // painted under the chip it identifies.
                z: 2

                Accessible.role: Accessible.Button
                Accessible.name: I18n.tr("Workspace") + " " + label
                    + (focused ? ", current" : urgent ? ", urgent"
                        : exists ? ", occupied" : ", empty")
                Accessible.onPressAction: {
                    workspaceState.pulseCenter();
                    root.focusWorkspace(wsId);
                }

                Rectangle {
                    anchors.centerIn: parent
                    width: slot.showNumber ? Theme.chipInnerHeight
                        : root.numbered ? 4 : 6
                    height: slot.showNumber ? Theme.chipInnerHeight : width
                    radius: slot.showNumber ? Theme.chipRadius : width / 2
                    color: slot.restingTone

                    Behavior on color {
                        ColorAnimation { duration: Theme.reducedMotion ? 0 : 200 }
                    }
                }

                BarHover {
                    id: workspaceState
                    anchors.fill: parent
                    anchors.margins: 1
                    host: root.host
                    target: slot
                    radius: Theme.chipRadius
                    pressed: wsMouse.pressed
                    tint: Theme.barTextHi
                    pressPoint: Qt.point(wsMouse.mouseX - 1, wsMouse.mouseY - 1)
                    z: 2
                }

                Text {
                    visible: slot.showNumber
                    anchors.centerIn: parent
                    text: slot.label
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.bar
                    font.weight: slot.focused || slot.urgent
                        ? Theme.weightSemibold : Theme.weightMedium
                    font.features: Theme.tabularNumberFeatures
                    color: slot.focused ? Theme.barWsCurrentFg
                        : slot.urgent ? Theme.barRedFg
                        : Theme.barTextLow
                    z: 3

                    Behavior on color {
                        ColorAnimation { duration: Theme.reducedMotion ? 0 : 200 }
                    }
                }

                MouseArea {
                    id: wsMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.focusWorkspace(slot.wsId)
                    onWheel: wheel => root.scrollWorkspaces(wheel)
                }

                BarTooltip {
                    check: workspaceState.check
                    text: I18n.tr("Workspace") + " " + slot.label
                        + (slot.entry && slot.entry.guest ? " · " + I18n.tr("Visiting workspace") : "")
                        + (slot.focused && root.activeWorkspace ? " · " + DesktopWorkspaces.layoutLabel(root.activeLayout, root.activeWorkspace.nativeLayout) : "")
                    y: root.height + 8
                    x: (slot.width - width) / 2
                }
            }
        }
    }

    Item {
        id: layoutChip
        visible: root.activeWorkspace !== null && DesktopWorkspaces.canSetLayout(root.activeWorkspace)
        x: pips.x + pips.width + 4
        width: 24
        height: parent.height
        Accessible.role: Accessible.Button
        Accessible.name: I18n.tr("Cycle workspace layout") + ": " + DesktopWorkspaces.layoutLabel(root.activeLayout, root.activeWorkspace ? root.activeWorkspace.nativeLayout : "")
        Accessible.onPressAction: DesktopWorkspaces.cycleLayout(root.focusedId)
        BarHover {
            id: layoutState
            anchors.fill: parent
            host: root.host
            target: layoutChip
            radius: Theme.chipRadius
            pressed: layoutMouse.pressed
            tint: Theme.barTextHi
            pressPoint: Qt.point(layoutMouse.mouseX, layoutMouse.mouseY)
        }
        Sym {
            anchors.centerIn: parent
            name: DesktopWorkspaces.layoutGlyph(root.activeLayout)
            size: Theme.iconSmall
            color: Theme.barTextLow
        }
        MouseArea {
            id: layoutMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: DesktopWorkspaces.cycleLayout(root.focusedId)
            onWheel: wheel => root.scrollWorkspaces(wheel)
        }
        BarTooltip {
            check: layoutState.check
            text: I18n.tr("Cycle workspace layout") + ": " + DesktopWorkspaces.layoutLabel(root.activeLayout, root.activeWorkspace ? root.activeWorkspace.nativeLayout : "")
            y: root.height + 8
            x: (parent.width - width) / 2
        }
    }

    Component.onCompleted: Qt.callLater(() => {
        root.snapRequested = true;
        root.settleIndicator(false);
    })
}
