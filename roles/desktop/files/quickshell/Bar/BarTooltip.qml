import QtQuick
import "../Common"

// The hover tip under a bar module: the same glass a panel is made of, at
// panel density, so it reads as a very small popover rather than a system
// tooltip pasted over the shell.
Item {
    id: root

    property string text: ""
    // -1 left, 0 centered, 1 right.
    property int align: 0
    property bool ready: false
    // The module's shared pointer state, not a bare bool: a MouseArea on a
    // layer surface can miss its exit event, and a tooltip armed off that
    // stale value has nothing left to dismiss it. Taking the check as a typed,
    // required object means a raw `containsMouse` cannot reach here by
    // mistake, and that the tip agrees with the pill it hangs under — both
    // read the one answer.
    required property PointerCheck check
    readonly property bool activeHover: check.over

    width: tip.implicitWidth
    height: tip.implicitHeight
    z: 1000
    opacity: ready ? 1 : 0
    // Popouts.open stays a hard cut (see the Connections note below); only
    // hover-driven appearance eases.
    visible: text !== "" && !Popouts.open && opacity > 0.01

    // Rises the last few pixels into place as it fades in — the same
    // vocabulary as a panel arriving, at a tenth of the distance.
    transform: [
        Translate {
            y: root.ready ? 0 : (Settings.position === "bottom" ? 4 : -4)

            Behavior on y {
                NumberAnimation {
                    duration: Theme.chipFadeDuration
                    easing.type: Easing.BezierSpline
                    easing.bezierCurve: Theme.springCurve
                }
            }
        },
        // Call sites place the tip 8px below their module (y: parent.height +
        // 8); with a bottom bar this shifts it to 8px above instead.
        Translate {
            y: Settings.position === "bottom" && root.parent
                ? -(root.height + root.parent.height + 16) : 0
        }
    ]

    Behavior on opacity {
        NumberAnimation { duration: Theme.chipFadeDuration; easing.type: Easing.OutCubic }
    }

    onActiveHoverChanged: {
        if (activeHover)
            delay.restart();
        else {
            delay.stop();
            ready = false;
        }
    }

    // Mapping the separate popout surface can prevent the bar MouseArea
    // from receiving its final exit event. Do not carry an armed tooltip
    // across either edge of that surface's lifetime: otherwise it reappears
    // at its old module as soon as the popout closes.
    Connections {
        target: Popouts

        function onOpenChanged() {
            delay.stop();
            root.ready = false;
        }
    }

    Timer {
        id: delay
        interval: 550
        onTriggered: root.ready = root.activeHover
    }

    Rectangle {
        id: tip
        implicitWidth: label.implicitWidth + 20
        implicitHeight: Theme.tooltipHeight
        radius: Math.min(Theme.panelRadius, height / 2)
        color: Theme.surfaceMenu
        border.width: Theme.surfaceBorderWidth
        border.color: Theme.surfaceBorderColor

        Text {
            id: label
            anchors.centerIn: parent
            text: root.text
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.tooltip
            font.weight: Theme.weightSemibold
            color: Theme.textMid
        }
    }
}
