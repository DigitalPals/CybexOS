pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Shapes
import "../Common"
import "../Common/SettingsHelpers.js" as SettingsHelpers
import "IdleTimelineModel.js" as Model

// The top of the Power page's Idle group: the delay choices along one axis,
// a Never zone at its end, and a marker for Screen off, Lock and Suspend at
// their current values. Three dropdowns cannot show their order at a
// glance; this can, and above all the case they hide — the screen going
// dark before the session locks, when waking it skips the lock screen. That
// stretch is shaded and named on the hint line; otherwise the line reads the
// order back (IdleTimelineModel.assessment).
//
// Markers at one delay share a dot. A label that would collide with its
// neighbour rises above it on a longer stem (IdleTimelineModel.layout).
// The picture takes no input and stays out of the accessibility tree; its
// hint line carries the same information in words.
Item {
    id: root

    // Dimmed while a user hypridle.conf decides the timeouts instead.
    property bool overridden: false

    readonly property var axisValues: Model.axis([SettingsHelpers.IDLE_SCREEN_OFF_MINS,
        SettingsHelpers.IDLE_LOCK_MINS, SettingsHelpers.IDLE_SUSPEND_MINS])
    readonly property var values: ({
        idleScreenOffMins: Settings.idleScreenOffMins,
        idleLockMins: Settings.idleLockMins,
        idleSuspendMins: Settings.idleSuspendMins
    })
    readonly property var verdict: Model.assessment(values, Settings.idleSuspendBatteryOnly, axisValues)

    // The axis runs along the label lane and stops, like every control on
    // the page, at the rows' reset column; the Never zone ends it.
    readonly property real contentRight: Math.max(0, width - Theme.chipHeight)
    readonly property int neverWidth: Theme.scaled(56, Theme.typeScale)
    readonly property int neverHeight: Math.ceil(tickMetrics.height) + Theme.scaled(6)
    readonly property real axisLeft: Theme.settingsMarkInset
    readonly property real axisRight: Math.max(axisLeft + 1,
        contentRight - neverWidth - Theme.controlSpacing)
    readonly property int dotSize: Theme.scaled(10)
    readonly property int lineHeight: Math.ceil(labelMetrics.height)
    readonly property int lineGap: Theme.scaled(2)
    readonly property int labelIconGap: Theme.scaled(4)

    readonly property var placement: {
        // advanceWidth() is a call, not a property, so name the font to
        // re-measure when the interface font or size changes.
        void labelMetrics.font;
        const widths = {};
        for (const event of Model.EVENTS)
            widths[event.label] = Math.ceil(labelMetrics.advanceWidth(event.label))
                + Theme.iconSmall + labelIconGap;
        return Model.layout(Model.groups(values, axisValues), {
            left: axisLeft,
            right: axisRight,
            neverCenter: contentRight - neverWidth / 2,
            neverRight: contentRight,
            widths: widths,
            lineHeight: lineHeight,
            lineGap: lineGap,
            // Wider than a word space, so two neighbouring labels never
            // read as one phrase ("Lock Screen off"); closer ones lift.
            boxGap: Theme.scaled(16),
            baseStem: Theme.scaled(4),
            neverStem: Math.max(0, (neverHeight - dotSize) / 2) + Theme.scaled(4),
            dotRadius: dotSize / 2
        });
    }

    // Everything hangs off the axis line, which sits just below the
    // tallest stack of labels.
    readonly property real axisY: Theme.scaled(4) + placement.top + dotSize / 2
    readonly property real tickTop: axisY + Math.max(dotSize, neverHeight) / 2 + Theme.scaled(2)
    readonly property real tickLabelTop: tickTop + Theme.scaled(6)
    readonly property real trackHeight: tickLabelTop + Math.ceil(tickMetrics.height)

    function xAt(fraction) {
        return axisLeft + fraction * (axisRight - axisLeft);
    }

    implicitHeight: trackHeight + Theme.settingsContentSpacing + summary.height
        + Theme.settingsRowSpacing
    height: implicitHeight

    FontMetrics {
        id: labelMetrics
        font.family: Theme.fontMenu
        font.pixelSize: Theme.typography.secondary
    }

    FontMetrics {
        id: tickMetrics
        font.family: Theme.fontMenu
        font.pixelSize: Theme.typography.metadata
    }

    Item {
        id: track
        width: root.width
        height: root.trackHeight
        opacity: root.overridden ? 0.45 : 1

        Rectangle {
            x: root.axisLeft
            y: root.axisY - 1
            width: root.axisRight - root.axisLeft
            height: 2
            radius: 1
            color: Theme.chipHover
        }

        // The stretch where the screen is dark but not locked.
        Rectangle {
            visible: root.verdict.band !== null
            x: visible ? root.xAt(root.verdict.band.from) : 0
            width: visible ? Math.max(Theme.scaled(4), root.xAt(root.verdict.band.to) - x) : 0
            y: root.axisY - height / 2
            height: Theme.scaled(8)
            radius: 2
            color: Theme.amberBg
            border.width: 1
            border.color: Theme.amber
        }

        Repeater {
            model: root.axisValues

            delegate: Item {
                id: tick
                required property int modelData
                required property int index
                x: root.xAt(root.axisValues.length > 1 ? index / (root.axisValues.length - 1) : 0)

                Rectangle {
                    x: 0
                    y: root.tickTop
                    width: 1
                    height: Theme.scaled(4)
                    color: Theme.hairline
                }
                Text {
                    x: -width / 2
                    y: root.tickLabelTop
                    text: Model.tickLabel(tick.modelData)
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.metadata
                    font.features: Theme.tabularNumberFeatures
                    color: Theme.textFaint
                    Accessible.ignored: true
                }
            }
        }

        // Never is not a time, so it is a dashed zone rather than a tick.
        Item {
            x: root.contentRight - root.neverWidth
            y: root.axisY - root.neverHeight / 2
            width: root.neverWidth
            height: root.neverHeight

            // The default geometry renderer strokes the dashes.
            Shape {
                anchors.fill: parent

                ShapePath {
                    strokeColor: Theme.hairline
                    strokeWidth: 1
                    strokeStyle: ShapePath.DashLine
                    dashPattern: [3, 3]
                    fillColor: "transparent"

                    PathRectangle {
                        x: 0.5
                        y: 0.5
                        width: root.neverWidth - 1
                        height: root.neverHeight - 1
                        radius: Theme.scaled(5)
                    }
                }
            }
            Text {
                anchors.centerIn: parent
                text: "Never"
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.metadata
                color: Theme.textFaint
                Accessible.ignored: true
            }
        }

        // Stems and dots, one per group; Never has neither.
        Repeater {
            model: root.placement.groups.filter(group => !group.never)

            delegate: Item {
                id: group
                required property var modelData

                Rectangle {
                    x: Math.round(group.modelData.x)
                    y: root.axisY - root.dotSize / 2 - group.modelData.stem
                    width: 1
                    height: group.modelData.stem
                    color: Theme.hairline
                }
                Rectangle {
                    x: group.modelData.x - width / 2
                    y: root.axisY - height / 2
                    width: root.dotSize
                    height: root.dotSize
                    radius: height / 2
                    color: Theme.accent
                }
            }
        }

        // Labels come as one flat list, each with its own place, so no
        // delegate reads another's context — a nested Repeater's rows
        // outlived their group while the idle values changed.
        Repeater {
            model: root.placement.lines

            delegate: Row {
                id: marker
                required property var modelData
                x: marker.modelData.align === "left" ? marker.modelData.boxLeft
                    : marker.modelData.align === "right"
                        ? marker.modelData.boxLeft + marker.modelData.boxWidth - width
                    : marker.modelData.boxLeft + (marker.modelData.boxWidth - width) / 2
                y: root.axisY - root.dotSize / 2 - marker.modelData.lift - height
                height: root.lineHeight
                spacing: root.labelIconGap

                Sym {
                    anchors.verticalCenter: parent.verticalCenter
                    name: marker.modelData.icon
                    size: Theme.iconSmall
                    color: marker.modelData.never ? Theme.textFaint : Theme.icon
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: marker.modelData.label
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.secondary
                    color: marker.modelData.never ? Theme.textFaint : Theme.textHi
                    Accessible.ignored: true
                }
            }
        }
    }

    SettingsHint {
        id: summary
        y: root.trackHeight + Theme.settingsContentSpacing
        width: root.contentRight
        text: root.overridden
            ? "Shown for reference. Your hypridle.conf sets the idle timeouts."
            : root.verdict.text
        tone: root.overridden ? "info" : root.verdict.tone
    }
}
