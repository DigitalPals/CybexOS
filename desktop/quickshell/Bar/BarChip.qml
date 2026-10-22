import QtQuick
import "../Common"

// A content chip in the bar: the same compact shape BarIcon draws for glyph
// modules, wrapping arbitrary content instead of glyph + label.
//
// Like BarIcon, this knows nothing about the content it wraps. It supplies the
// shared resting/hover foreground as `fg`; content keeps its semantic colours
// where needed and binds ordinary icons to that one value.
Rectangle {
    id: root

    default property alias content: content.data

    // ---- panel wiring -----------------------------------------------------
    // Setting panelName makes this the bar's anchor for that popout and drives
    // registration, the held state and the opening click from the one name.
    // `host` is typed rather than duck-typed, so a typo in any of those calls
    // is a lint error naming the member, not a silent no-op.
    required property Bar host
    property string panelName: ""
    property string isle: ""

    // The item whose rectangle the popout hangs under. Defaults to this one;
    // a grouped chip overrides it with the group pill.
    property Item anchorItem: root

    readonly property bool ownsPanel: panelName !== "" && host !== null

    onOwnsPanelChanged: {
        if (ownsPanel)
            host.registerPanel(panelName, anchorItem);
    }

    // A grouped module learns which pill it sits in only after the bar has
    // loaded it, so the anchor can move once, from this chip to its group.
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

    // "pill" rests directly on the menubar slab; "inner" is a step shorter
    // for grouped modules. Both rest transparent so every module shares the
    // same slab rather than reading as a separate tile.
    property string shape: "pill"
    readonly property bool inner: shape === "inner"
    property real pillHeight: inner ? Theme.chipInnerHeight : Theme.chipHeight

    property real hPadding: 7
    property real spacing: 5
    property real leftPadding: hPadding
    property real rightPadding: hPadding
    property color restFill: "transparent"
    property color hoverFill: Theme.barChipHover
    property color idleColor: Theme.barIcon
    property color hoverColor: Theme.barTextHi
    // The module's popout is expanded below it.
    property bool held: ownsPanel && host.popoutOpen(panelName)
    property bool pressFeedback: true
    property string tooltip: ""
    property int tooltipAlign: 0
    property var preparePanel: null

    // The shared bar-wide hit test drives the background, module colours and
    // tooltip together. It remains correct when a child MouseArea misses an
    // enter or exit while a detached layer surface is being mapped.
    readonly property bool hovered: hover.over
    readonly property color fg: held || hovered ? hoverColor : idleColor

    signal clicked()
    signal entered()
    signal exited()

    implicitHeight: pillHeight
    implicitWidth: content.implicitWidth + leftPadding + rightPadding
    radius: Theme.chipRadius
    color: held ? hoverFill : restFill
    anchors.verticalCenter: parent ? parent.verticalCenter : undefined
    scale: pressFeedback && mouse.pressed ? 0.96 : 1

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

    // The media chip unfolds its transport under the pointer and the T3 chip
    // swaps between a count and a word; both change width in place, and both
    // should glide rather than jump.
    Behavior on implicitWidth {
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
        radius: root.radius
        pressed: mouse.pressed
        tint: Theme.barTextHi
        pressPoint: Qt.point(mouse.mouseX, mouse.mouseY)
    }

    Row {
        id: content
        anchors.verticalCenter: parent.verticalCenter
        x: root.leftPadding
        spacing: root.spacing
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onEntered: {
            if (root.preparePanel)
                root.preparePanel();
            if (root.ownsPanel)
                root.host.hoverPopout(root.panelName, root.isle, root.anchorItem);
            root.entered();
        }
        // See BarIcon: motion is the first recovery path, and hoverPopout is a
        // no-op for the panel that is already current.
        onPositionChanged: {
            if (root.preparePanel)
                root.preparePanel();
            if (root.ownsPanel)
                root.host.hoverPopout(root.panelName, root.isle, root.anchorItem);
        }
        onExited: root.exited()
        onClicked: {
            if (root.preparePanel)
                root.preparePanel();
            if (root.ownsPanel)
                root.host.togglePopout(root.panelName, root.isle, root.anchorItem);
            root.clicked();
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
