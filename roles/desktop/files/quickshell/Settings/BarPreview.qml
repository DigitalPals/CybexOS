pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Widgets
import "../Common"
import "../Common/BarGeometry.js" as BarGeometry
import "../Common/WidgetEditor.js" as Editor

// The bar in miniature, pinned over the Bar page (2026-09 redesign): a strip
// of the wallpaper with the bar drawn on it the way Bar.qml draws the real
// one — its edge, style, height, gap, corners and colour — and the enabled
// widgets of each section as their icons. Every value it reads is the live
// setting, so the Layout, Background and Behavior rows below change it as
// they change the bar.
//
// It is a schematic, not a second editor. A widget here opens its options
// (the same dialog as its pill), but reordering stays with the lanes and
// their keyboard path, so there is one drag model to learn and to test.
Item {
    id: root

    // WidgetEditor.catalog() entries. The preset preview hands in a
    // hypothetical catalog instead of the stored one.
    property var entries: []
    // The widget a lane drag is carrying: it dims here as it does there.
    property string draggingKey: ""
    // Off while the preview shows a preset rather than the bar as it is.
    property bool interactive: true
    signal widgetActivated(string key)

    // A true-to-scale bar would be a sliver at this width. The bar's own
    // geometry is drawn at a fixed ratio instead, so its height, gap and
    // radius stay legible and still move in proportion to their settings.
    readonly property real ratio: 0.72
    readonly property bool atTop: Settings.position !== "bottom"
    readonly property real barHeight: Math.round(Theme.barHeight * ratio)
    readonly property real edgeInset: Math.round(Theme.barTopMargin * ratio)
    readonly property real sideInset: Math.round(Theme.barSideMargin * ratio)
    readonly property real slabRadius: Math.min(Math.round(Theme.clusterRadius * ratio), barHeight / 2)
    readonly property real cornerSize: Math.round(Theme.hugCornerSize * ratio)
    readonly property real chipHeight: Math.max(0, barHeight - Math.round(Theme.controlSpacing * ratio))
    readonly property real iconSize: Math.max(Theme.iconTiny, Math.round(Theme.barIconSize * ratio))
    // Tiled windows start below the bar when it reserves its space, and at
    // the screen edge (under the bar) when it does not: Reserve space and
    // Auto-hide show here as the window moving.
    readonly property real windowInset: Math.round(BarGeometry.exclusiveZone({
            style: Settings.barStyle,
            gap: Settings.gap,
            height: Theme.barHeight,
            autoHide: Settings.autoHide,
            exclusive: Settings.exclusive
        }) * ratio) + Math.round(Theme.controlSpacing * ratio)
    readonly property string timeText: Qt.formatDateTime(clock.date,
        Settings.clock24 ? "HH:mm" : "h:mm AP")
    readonly property string dateText: Settings.modOpts.clock.showDate
        ? Qt.formatDateTime(clock.date, Settings.modOpts.clock.dateFormat) : ""

    implicitHeight: Theme.scaled(96)
    Accessible.role: Accessible.Graphic
    Accessible.name: "Bar preview"
    Accessible.description: (atTop ? "Top" : "Bottom") + " of the screen, "
        + Settings.barStyle + " style, " + Theme.barHeight + " pixels high"

    SystemClock {
        id: clock
        precision: SystemClock.Minutes
        enabled: root.visible
    }

    ClippingRectangle {
        id: screen
        anchors.fill: parent
        radius: Theme.chipRadius
        color: Theme.cardFill
        border.width: 1
        border.color: Theme.hairline
        contentInsideBorder: true

        Image {
            anchors.fill: parent
            source: Wallpaper.current
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            // A strip this size needs no more than a thumbnail's worth of
            // pixels; decoding at full size would hold a 4K texture for it.
            sourceSize.width: Theme.scaled(640)
            opacity: status === Image.Ready ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: Theme.chipFadeDuration } }
        }

        // One tiled window, to show what the bar leaves room for.
        Rectangle {
            x: Math.round(parent.width * 0.14)
            width: Math.round(parent.width * 0.72)
            y: root.atTop ? root.windowInset : Math.round(Theme.controlSpacing * root.ratio)
            height: Math.max(0, parent.height - root.windowInset
                - Math.round(Theme.controlSpacing * root.ratio))
            radius: Theme.chipRadius
            color: Qt.rgba(Theme.background.r, Theme.background.g, Theme.background.b, 0.84)
            border.width: 1
            border.color: Theme.stroke
            Behavior on y { NumberAnimation { duration: Theme.chipFadeDuration } }
            Behavior on height { NumberAnimation { duration: Theme.chipFadeDuration } }
        }

        Item {
            id: slab
            x: root.sideInset
            y: root.atTop ? root.edgeInset : parent.height - root.edgeInset - height
            width: parent.width - root.sideInset * 2
            height: root.barHeight
            // Auto-hide: the bar is away until the pointer reaches the edge.
            opacity: Settings.autoHide ? 0.55 : 1

            Rectangle {
                anchors.fill: parent
                radius: root.slabRadius
                color: Theme.barSurface
            }

            // Hug's inverted corners, placed and mirrored as Bar.qml does.
            HugCorner {
                visible: Theme.barHug
                x: 0
                y: root.atTop ? parent.height : -height
                cornerSize: root.cornerSize
                bottomCorner: !root.atTop
                fillColor: Theme.barSurface
            }
            HugCorner {
                visible: Theme.barHug
                x: parent.width - width
                y: root.atTop ? parent.height : -height
                cornerSize: root.cornerSize
                rightCorner: true
                bottomCorner: !root.atTop
                fillColor: Theme.barSurface
            }

            Item {
                id: lanes
                anchors.fill: parent
                anchors.leftMargin: Math.round(Theme.barPadding * root.ratio)
                anchors.rightMargin: Math.round(Theme.barPadding * root.ratio)
                clip: true

                Row {
                    id: leftSection
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Math.round(Theme.barSpacing * root.ratio)
                    Repeater {
                        model: Editor.sectionEntries(root.entries, "left")
                        delegate: PreviewWidget {}
                    }
                }
                Row {
                    // Centred like the bar's, and pushed aside rather than
                    // drawn over a crowded neighbour, as the bar shifts its
                    // centre once there is no detail left to compact.
                    readonly property real gutter: Math.round(Theme.barSpacing * 2 * root.ratio)
                    x: Math.max(leftSection.width > 0 ? leftSection.width + gutter : 0,
                        Math.min((parent.width - width) / 2,
                            rightSection.x - (rightSection.width > 0 ? gutter : 0) - width))
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Math.round(Theme.barSpacing * root.ratio)
                    Repeater {
                        model: Editor.sectionEntries(root.entries, "center")
                        delegate: PreviewWidget {}
                    }
                }
                Row {
                    id: rightSection
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Math.round(Theme.barSpacing * root.ratio)
                    Repeater {
                        model: Editor.sectionEntries(root.entries, "right")
                        delegate: PreviewWidget {}
                    }
                }
            }
        }
    }

    // One widget on the miniature bar: its catalog icon, except where the bar
    // itself draws something more recognisable (the clock's time, the
    // workspace strip).
    component PreviewWidget: Item {
        id: widget

        required property var modelData
        readonly property bool isClock: !modelData.plugin && modelData.id === "clock"
        readonly property bool isWorkspaces: !modelData.plugin && modelData.id === "ws"
        readonly property real contentWidth: isClock ? clockText.implicitWidth
            : isWorkspaces ? pips.implicitWidth : root.iconSize

        width: Math.max(height, contentWidth + Math.round(Theme.controlSpacing * root.ratio) * 2)
        height: root.chipHeight
        opacity: modelData.key === root.draggingKey ? 0.35 : 1
        Accessible.ignored: true

        Rectangle {
            anchors.fill: parent
            radius: Math.round(Theme.chipRadius * root.ratio)
            color: Theme.barChipHover
            visible: widgetMouse.containsMouse
        }

        Sym {
            visible: !widget.isClock && !widget.isWorkspaces
            anchors.centerIn: parent
            name: widget.modelData.glyph || "extension"
            size: root.iconSize
            color: Theme.barIcon
        }

        Text {
            id: clockText
            visible: widget.isClock
            anchors.centerIn: parent
            text: (root.dateText !== "" ? root.dateText + "  " : "") + root.timeText
            font.family: Theme.fontNumeric
            font.pixelSize: Theme.typography.metadata
            font.weight: Theme.weightBold
            font.features: Theme.tabularNumberFeatures
            color: Theme.barTextHi
        }

        // The workspace strip: the current one lit in the bar accent, two
        // occupied, one empty — numbered or dotted as the widget is set.
        Row {
            id: pips
            visible: widget.isWorkspaces
            anchors.centerIn: parent
            spacing: Math.round(Theme.barSpacing * root.ratio)
            readonly property bool dots: Settings.modOpts.ws.style === "dots"
            Repeater {
                model: 4
                delegate: Rectangle {
                    id: pip
                    required property int index
                    readonly property bool current: index === 0
                    anchors.verticalCenter: parent.verticalCenter
                    width: pips.dots ? (current ? root.iconSize : Math.round(root.iconSize / 2))
                        : Math.round(root.iconSize * 1.1)
                    height: pips.dots ? Math.round(root.iconSize / 2) : Math.round(root.iconSize * 1.1)
                    radius: pips.dots ? height / 2 : Math.round(Theme.chipRadius * root.ratio)
                    color: current ? Theme.barWsCurrent
                        : pips.dots ? (index < 3 ? Theme.barWsOccupied : Theme.barWsEmpty)
                        : "transparent"
                    Text {
                        visible: !pips.dots
                        anchors.centerIn: parent
                        text: String(pip.index + 1)
                        font.family: Theme.fontNumeric
                        font.pixelSize: Theme.typography.metadata
                        font.weight: Theme.weightSemibold
                        color: pip.current ? Theme.barWsCurrentFg
                            : pip.index < 3 ? Theme.barWsOccupied : Theme.barWsEmpty
                    }
                }
            }
        }

        MouseArea {
            id: widgetMouse
            anchors.fill: parent
            enabled: root.interactive
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.widgetActivated(widget.modelData.key)
        }

        SettingsTooltip {
            visible: widgetMouse.containsMouse
            text: widget.modelData.name
        }
    }
}
