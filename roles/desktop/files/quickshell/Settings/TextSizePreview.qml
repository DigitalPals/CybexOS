pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import "../Common"

// The Text & size group's live sample: a strip of the bar and a popover
// hanging under it, drawn with the shell's own typography roles, icon sizes
// and spacing. Base size, Text size, Interface scale and Density multiply
// rather than override one another, so the group shows their product instead
// of spelling it out in a sentence (2026-09 redesign); the caption keeps the
// resulting pixel size for anyone who wants the number.
//
// It sits in the row grid: it starts at the label lane and ends where the
// rows' controls end, one reset column short of the edge. Nothing in it is
// interactive.
Item {
    id: root

    // The popover's natural width, as a real one grows with the content scale.
    readonly property int popoverWidth: Theme.scaled(250)
    readonly property int framePad: Theme.scaled(12)
    readonly property int gap: Theme.scaled(10)
    readonly property string caption: "Preview · text renders at " + Theme.metrics.fontBase + " px"
    // The caption shares the popover's line while the room beside it holds
    // the whole caption, and drops under it otherwise.
    readonly property bool captionBeside: content.width - popover.width - Theme.controlSpacing
        >= captionText.implicitWidth

    implicitHeight: frame.height + Theme.scaled(4) * 2
    height: implicitHeight
    Accessible.role: Accessible.StaticText
    Accessible.name: root.caption

    // The clock reads hours and minutes; tick on the minute, and only while
    // the preview is on screen.
    SystemClock {
        id: clock
        precision: SystemClock.Minutes
        enabled: root.visible
    }

    Rectangle {
        id: frame
        x: Theme.settingsMarkInset
        y: Theme.scaled(4)
        width: Math.max(0, root.width - x - Theme.chipHeight)
        height: content.height + root.framePad * 2
        radius: Theme.chipRadius + Theme.scaled(3)
        color: "transparent"
        border.width: 1
        border.color: Theme.hairlineSoft

        Item {
            id: content
            x: root.framePad
            y: root.framePad
            width: Math.max(0, frame.width - root.framePad * 2)
            height: popover.y + popover.height
                + (root.captionBeside ? 0 : root.gap + captionText.implicitHeight)
            Accessible.ignored: true

            // The bar: numbered workspaces, the clock, and status icons.
            Rectangle {
                id: strip
                width: parent.width
                height: Theme.chipHeight + Theme.scaled(6)
                radius: Theme.chipRadius + Theme.scaled(2)
                color: Theme.chip

                Row {
                    anchors.left: parent.left
                    anchors.leftMargin: Theme.scaled(4)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.scaled(2)

                    Repeater {
                        model: 3
                        delegate: Rectangle {
                            id: workspace
                            required property int index
                            width: Theme.chipInnerHeight
                            height: Theme.chipInnerHeight
                            radius: Theme.chipRadius
                            color: index === 0 ? Theme.accent : "transparent"

                            Text {
                                anchors.centerIn: parent
                                text: String(workspace.index + 1)
                                font.family: Theme.fontMenu
                                font.pixelSize: Theme.typography.bar
                                font.weight: workspace.index === 0 ? Theme.weightBold : Theme.weightMedium
                                font.features: Theme.tabularNumberFeatures
                                color: workspace.index === 0 ? Theme.accentFg : Theme.textLow
                            }
                        }
                    }
                }

                Row {
                    anchors.centerIn: parent
                    spacing: Theme.scaled(6)

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: Qt.formatDateTime(clock.date, "ddd d MMM")
                        font.family: Theme.fontMenu
                        font.pixelSize: Theme.typography.bar
                        font.weight: Theme.weightSemibold
                        color: Theme.textMid
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: Qt.formatDateTime(clock.date, Settings.clock24 ? "HH:mm" : "h:mm AP")
                        font.family: Theme.fontNumeric
                        font.pixelSize: Theme.typography.bar
                        font.weight: Theme.weightBold
                        font.features: Theme.tabularNumberFeatures
                        color: Theme.textHi
                    }
                }

                Row {
                    anchors.right: parent.right
                    anchors.rightMargin: Theme.scaled(10)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.scaled(8)

                    Repeater {
                        model: ["wifi", "volume_up", "battery_full"]
                        delegate: Sym {
                            required property string modelData
                            anchors.verticalCenter: parent.verticalCenter
                            name: modelData
                            size: Theme.barIconSize
                            color: Theme.icon
                        }
                    }
                }
            }

            // A popover row pair, hanging from the bar's right-hand icons.
            Rectangle {
                id: popover
                x: parent.width - width
                y: strip.height + root.gap
                width: Math.min(parent.width, root.popoverWidth)
                height: popoverRows.implicitHeight + Theme.scaled(10) * 2
                radius: Theme.chipRadius + Theme.scaled(3)
                color: Theme.chip

                Column {
                    id: popoverRows
                    x: Theme.scaled(10)
                    y: Theme.scaled(10)
                    width: parent.width - x * 2
                    spacing: Theme.scaled(8)

                    PreviewLine {
                        glyph: "volume_up"
                        label: "Volume"
                        value: "40%"
                    }
                    Rectangle {
                        width: parent.width
                        height: Theme.scaled(4)
                        radius: height / 2
                        color: Theme.chipHover

                        Rectangle {
                            width: parent.width * 0.4
                            height: parent.height
                            radius: parent.radius
                            color: Theme.accent
                        }
                    }
                    PreviewLine {
                        glyph: "wifi"
                        label: "Wi-Fi"
                        value: "Connected"
                    }
                }
            }

            Text {
                id: captionText
                x: 0
                y: root.captionBeside ? popover.y + popover.height - height
                    : popover.y + popover.height + root.gap
                width: root.captionBeside ? implicitWidth : parent.width
                text: root.caption
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.secondary
                color: Theme.textFaint
                elide: Text.ElideRight
            }
        }
    }

    component PreviewLine: Item {
        id: line
        property string glyph
        property string label
        property string value
        width: parent ? parent.width : 0
        height: Math.max(lineIcon.height, lineLabel.implicitHeight)

        Sym {
            id: lineIcon
            anchors.verticalCenter: parent.verticalCenter
            name: line.glyph
            size: Theme.iconMedium
            color: Theme.icon
        }
        Text {
            id: lineLabel
            anchors.left: lineIcon.right
            anchors.leftMargin: Theme.iconTextSpacing
            anchors.right: lineValue.left
            anchors.rightMargin: Theme.controlSpacing
            anchors.verticalCenter: parent.verticalCenter
            text: line.label
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.control
            color: Theme.textHi
            elide: Text.ElideRight
        }
        Text {
            id: lineValue
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: line.value
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.control
            color: Theme.textFaint
        }
    }
}
