pragma ComponentBehavior: Bound
import QtQuick
import Quickshell.Hyprland
import "../Common"
import "../Common/WorkspaceMotion.js" as WorkspaceMotion

// The screenshot's hybrid workspace strip: occupied workspaces are numbers,
// empty slots are dots, and the current workspace is a wider accent chip. Dot
// mode remains available, and the current chip keeps its directional motion.
Rectangle {
    id: root

    property Bar host: null

    readonly property bool numbered: Settings.modOpts.ws.style === "numbers"
    readonly property int focusedId: Hyprland.focusedWorkspace
        ? Hyprland.focusedWorkspace.id : -1
    readonly property int slots: Math.max(Settings.modOpts.ws.minSlots,
        ...Hyprland.workspaces.values.map(workspace => workspace.id))
    readonly property var existingIds:
        Hyprland.workspaces.values.map(workspace => workspace.id).sort((a, b) => a - b)
    // Hyprland republishes its workspace list on every focus change and window
    // event, so the id list is recomputed often and almost always comes out
    // the same. Round-tripping through a string gives the Repeater a new
    // model only when the ids really change; a fresh array every time would
    // recreate every pip (and its hover/tooltip state) on each event.
    readonly property string visibleIdsKey: JSON.stringify(WorkspaceMotion.visibleIds(slots,
        existingIds, -1, Settings.modOpts.ws.hideEmpty))
    readonly property var visibleIds: JSON.parse(visibleIdsKey)
    readonly property string structureKey: JSON.stringify([
        slots, existingIds, Settings.modOpts.ws.hideEmpty
    ])
    property int previousFocusedId: -1
    property bool indicatorReady: false
    property bool snapRequested: true

    implicitWidth: pips.width + 10
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
            focusedId, animate && indicatorReady && !snapRequested);
        activeLozenge.leftDuration = durations.left;
        activeLozenge.rightDuration = durations.right;
        activeLozenge.animateEdges = durations.direction !== 0;
        activeLozenge.leftEdge = bounds.left;
        activeLozenge.rightEdge = bounds.right;
        indicatorReady = true;
        previousFocusedId = focusedId;
        snapRequested = false;
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
        anchors.centerIn: parent
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
                Accessible.name: "Workspace " + wsId
                    + (focused ? ", current" : urgent ? ", urgent"
                        : exists ? ", occupied" : ", empty")
                Accessible.onPressAction: {
                    workspaceState.pulseCenter();
                    Hyprland.dispatch("hl.dsp.focus({ workspace = " + wsId + " })");
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
                    text: slot.wsId
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
                    onClicked: Hyprland.dispatch(
                        "hl.dsp.focus({ workspace = " + slot.wsId + " })")
                }

                BarTooltip {
                    check: workspaceState.check
                    text: "Workspace " + slot.wsId
                        + (slot.focused ? " · current" : slot.urgent ? " · urgent"
                            : slot.exists ? " · occupied" : " · empty")
                    y: root.height + 8
                    x: (slot.width - width) / 2
                }
            }
        }
    }

    Component.onCompleted: Qt.callLater(() => {
        root.snapRequested = true;
        root.settleIndicator(false);
    })
}
