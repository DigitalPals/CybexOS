import QtQuick
import QtQuick.Shapes
import "../Common"
import "../Common/Format.js" as Format
import "../Common/LayoutHelpers.js" as LayoutHelpers

// A compact glyph button in the bar: one Tabler icons mark, an optional
// value beside it, and the quiet chip that lights under the pointer.
//
// Four shapes, because the design uses four; see `shape` below. What they
// have in common is the fill ladder — rest, hover, held, active — and the
// press that springs back, so any two of them side by side agree.
Rectangle {
    id: root

    // ---- panel wiring -----------------------------------------------------
    // Setting panelName makes this the bar's anchor for that popout and drives
    // registration, the held state and the opening click from the one name.
    // `host` is typed rather than duck-typed, so a typo in any of those calls
    // is a lint error naming the member, not a silent no-op.
    //
    // `isle` is the column the module actually sits in — the user can move
    // modules between columns, so it is assigned by the bar's ModuleSlot and
    // is not the registry's default island.
    //
    // `host` is required even for an icon that owns no panel: BarTooltip
    // dismisses itself against the bar-wide pointer state, so leaving it null
    // is what strands a tooltip on screen after a missed exit event.
    required property Bar host
    property string panelName: ""
    property string isle: ""

    // The item whose rectangle the popout hangs under. Defaults to this one;
    // a grouped module overrides it with the group pill, so the panel hangs
    // under the shape the user actually clicked.
    property Item anchorItem: root

    readonly property bool ownsPanel: panelName !== "" && host !== null

    // The bar assigns `host` from its slot's onLoaded, which runs after this
    // object is constructed — so registering only in Component.onCompleted
    // would run against a null host and silently never happen. Registration
    // is idempotent, so doing both is safe and covers either order.
    onOwnsPanelChanged: {
        if (ownsPanel)
            host.registerPanel(panelName, anchorItem);
    }

    // A grouped module learns which pill it sits in only after the bar has
    // loaded it, so the anchor can move once, from this chip to its group.
    // Re-registering under the same name replaces the entry rather than
    // adding one.
    onAnchorItemChanged: {
        if (ownsPanel)
            host.registerPanel(panelName, anchorItem);
    }

    Component.onCompleted: {
        if (ownsPanel)
            host.registerPanel(panelName, anchorItem);
    }

    Component.onDestruction: {
        if (ownsPanel)
            host.unregisterPanel(panelName, anchorItem);
    }

    // ---- shape ------------------------------------------------------------
    // "pill"  a chip that draws its own background
    // "inner" a chip inside a group's background: a step shorter, transparent
    //         at rest, so the group reads as one shape with a lit segment
    // "round" the circular buttons at either end of the bar
    // "bare"  a glyph inside a pill the group owns: no fill of its own, and no
    //         hover of its own either, because the pill lights instead
    property string shape: "pill"
    readonly property bool bare: shape === "bare"
    readonly property bool inner: shape === "inner"
    readonly property bool round: shape === "round"
    property real pillHeight: round ? Theme.roundButton
        : inner ? Theme.chipInnerHeight : Theme.chipHeight

    // Semantic icon name, e.g. "wifi".
    property string glyph
    property real glyphSize: Theme.barIconSize
    // Determinate task progress, 0..1. Anything at or above zero replaces the
    // glyph with a small ring so a long job reads at a glance; -1 restores
    // the glyph. The ring lives in the glyph's column, so a module that pins
    // `glyphWidth` keeps its width through the swap.
    property real progress: -1
    property color progressColor: Theme.barAccent
    // Fixed column for the glyph. The right cluster is right-anchored, so a
    // module that changes width slides every module beside it: pin the width
    // for icons that differ between states. 0 sizes to the glyph.
    property real glyphWidth: 0
    // Legacy plugin API: outlines are used regardless of this value.
    property real glyphFill: 0
    property real glyphWeight: 500
    property string label: ""
    property bool compact: false
    property int labelSize: Theme.barLabelSize
    property int labelWeight: Theme.weightMedium
    property bool active: false
    // The module's popout is expanded below it.
    property bool held: ownsPanel && host.popoutOpen(panelName)
    property bool alert: false
    property color idleColor: Theme.barIcon
    property color hoverColor: Theme.barTextHi
    property color labelColor: fg
    property real hPadding: label === "" || compact ? 6 : 7
    property real contentSpacing: 4
    property string tooltip: ""
    property int tooltipAlign: 0
    // Every module rests directly on the slab. Callers may still override
    // this for a deliberate state; ordinary shape selection never adds a
    // per-module tile.
    property color restFill: "transparent"

    signal clicked(real mouseX)
    signal middleClicked
    signal wheeled(int steps)
    signal entered
    signal exited

    property real wheelAccumulator: 0
    readonly property real detailSaving: label === "" ? 0
        : labelText.implicitWidth + contentSpacing

    // The shared bar-wide hit test drives the background, foreground and
    // tooltip together. It remains correct when a child MouseArea misses an
    // enter or exit while a detached layer surface is being mapped.
    readonly property bool hovered: hover.over

    readonly property color fg: active ? Theme.barAccentFg
        : alert ? Theme.barRedText
        : held || root.hovered ? hoverColor : idleColor

    implicitHeight: pillHeight
    implicitWidth: round ? Theme.roundButton : content.implicitWidth + hPadding * 2
    radius: round ? pillHeight / 2 : Theme.chipRadius
    color: active ? Theme.barAccent
        : alert ? Theme.barRedBg
        : held ? Theme.barChipHover
        : restFill
    anchors.verticalCenter: parent ? parent.verticalCenter : undefined

    // Press feedback. The design scales a round button harder than a chip;
    // both spring back, which is what makes a click feel answered rather than
    // merely registered.
    scale: mouse.pressed ? (round ? 0.88 : 0.95) : 1

    Behavior on scale {
        NumberAnimation {
            duration: Theme.pressDuration
            easing.type: Easing.BezierSpline
            easing.bezierCurve: Theme.springCurve
        }
    }

    Behavior on color {
        ColorAnimation { duration: Theme.chipFadeDuration }
    }

    Behavior on implicitWidth {
        enabled: !root.round
        NumberAnimation {
            duration: Theme.expandDuration
            easing.type: Easing.BezierSpline
            easing.bezierCurve: Theme.springCurve
        }
    }

    BarHover {
        id: hover
        anchors.fill: parent
        host: root.host
        target: root
        radius: parent.radius
        visualEnabled: !root.bare
        pressed: mouse.pressed
        tint: root.fg
        pressPoint: Qt.point(mouse.mouseX, mouse.mouseY)
    }

    Row {
        id: content
        anchors.centerIn: parent
        spacing: root.contentSpacing

        // The column is pinned on the wrapper, never on the Text: several of
        // these marks overflow their advance box, so giving the Text an
        // explicit width shifts what it draws.
        Item {
            visible: root.glyph !== "" && root.progress < 0
            anchors.verticalCenter: parent.verticalCenter
            width: root.glyphWidth > 0 ? root.glyphWidth : glyphText.implicitWidth
            height: glyphText.implicitHeight

            Sym {
                id: glyphText
                anchors.centerIn: parent
                name: root.glyph
                size: root.glyphSize
                symWeight: root.glyphWeight
                color: root.fg
            }
        }

        Item {
            visible: root.progress >= 0
            anchors.verticalCenter: parent.verticalCenter
            width: root.glyphWidth > 0 ? root.glyphWidth : ring.width
            height: ring.height

            Shape {
                id: ring
                anchors.centerIn: parent
                width: 15
                height: 15
                preferredRendererType: Shape.CurveRenderer

                ShapePath {
                    strokeColor: Theme.barDotDim
                    strokeWidth: 2.2
                    fillColor: "transparent"

                    PathAngleArc {
                        centerX: 7.5
                        centerY: 7.5
                        radiusX: 5.6
                        radiusY: 5.6
                        startAngle: -90
                        sweepAngle: 360
                    }
                }

                ShapePath {
                    strokeColor: root.progressColor
                    strokeWidth: 2.2
                    fillColor: "transparent"
                    capStyle: ShapePath.RoundCap

                    PathAngleArc {
                        centerX: 7.5
                        centerY: 7.5
                        radiusX: 5.6
                        radiusY: 5.6
                        startAngle: -90
                        sweepAngle: 360 * Format.clamp01(root.progress)

                        Behavior on sweepAngle {
                            NumberAnimation {
                                duration: Theme.chipFadeDuration
                                easing.type: Easing.OutCubic
                            }
                        }
                    }
                }
            }
        }

        Text {
            id: labelText
            visible: root.label !== "" && !root.compact
            anchors.verticalCenter: parent.verticalCenter
            text: root.label
            font.family: Theme.fontMenu
            font.pixelSize: root.labelSize
            font.weight: root.labelWeight
            font.features: Theme.tabularNumberFeatures
            color: root.alert ? Theme.barRedText : root.labelColor

            Behavior on color {
                ColorAnimation { duration: Theme.chipFadeDuration }
            }
        }
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.MiddleButton
        cursorShape: Qt.PointingHandCursor
        onEntered: {
            if (root.ownsPanel)
                root.host.hoverPopout(root.panelName, root.isle, root.anchorItem);
            root.entered();
        }
        // Pointer motion gives the latched switch another idempotent chance;
        // Bar's full-surface handler is the final fallback if this child loses
        // both events while the detached popout is being mapped.
        onPositionChanged: {
            if (root.ownsPanel)
                root.host.hoverPopout(root.panelName, root.isle, root.anchorItem);
        }
        onExited: root.exited()
        onClicked: mouse => {
            if (mouse.button === Qt.MiddleButton) {
                root.middleClicked();
                return;
            }
            if (root.ownsPanel)
                root.host.togglePopout(root.panelName, root.isle, root.anchorItem);
            root.clicked(mouse.x);
        }
        onWheel: wheel => {
            const delta = wheel.angleDelta.y !== 0 ? wheel.angleDelta.y
                : wheel.pixelDelta.y * 8;
            const result = LayoutHelpers.accumulateWheel(root.wheelAccumulator, delta, 120);
            root.wheelAccumulator = result.accumulator;
            if (result.steps !== 0)
                root.wheeled(result.steps);
            wheel.accepted = true;
        }
    }

    BarTooltip {
        check: hover.check
        text: root.tooltip
        align: root.tooltipAlign
        y: root.height + 8
        x: align < 0 ? 0 : align > 0 ? root.width - width : (root.width - width) / 2
    }
}
