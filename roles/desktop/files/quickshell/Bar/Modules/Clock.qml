import QtQuick
import Quickshell
import ".."
import "../../Common"

// The clock, and the date when there is room for it. Its transparent-resting
// pill is the calendar's independent pointer target.
BarModule {
    id: root

    moduleId: "clock"
    spacing: 0
    // Measure the configured date even while compact. `showDate` includes the
    // compact state and would otherwise erase the saving needed to restore it.
    detailSaving: Settings.modOpts.clock.showDate
        ? clockDate.implicitWidth + dateSeparator.width : 0

    // Named once: the date and the space before it are one decision, and binding
    // the spacer to the date's `visible` would make it depend on effective
    // visibility rather than on the thing that actually decides.
    readonly property bool showDate: Settings.modOpts.clock.showDate && !compact

    // Its own tick, the way the calendar popover and the settings preview
    // each keep theirs. It needs no `enabled` gate: the bar only instantiates
    // a module slot on a visible bar, so an unmapped output has no clock at
    // all rather than a disabled one.
    SystemClock {
        id: clock
        precision: Settings.modOpts.clock.seconds ? SystemClock.Seconds : SystemClock.Minutes
    }

    BarChip {
        id: chip

        host: root.host
        panelName: "calendar"
        isle: root.isle
        anchorItem: root.groupAnchor ?? chip
        spacing: 0
        tooltip: "Calendar"

        AnimatedText {
            anchors.verticalCenter: parent.verticalCenter
            animateChange: !Settings.modOpts.clock.seconds
            text: Qt.formatDateTime(clock.date, Settings.clock24
                ? (Settings.modOpts.clock.seconds ? "HH:mm:ss" : "HH:mm")
                : (Settings.modOpts.clock.seconds ? "h:mm:ss AP" : "h:mm AP"))
            // The time is an instrument reading: Geist Mono, per the
            // edge-drawer design's numeric face.
            font.family: Theme.fontNumeric
            font.pixelSize: Theme.typography.bar
            font.weight: Theme.weightBold
            font.letterSpacing: 0.3
            font.features: Theme.tabularNumberFeatures
            color: Theme.barTextHi
        }

        Divider {
            id: dateSeparator
            kind: "space"
            visible: root.showDate
        }

        Text {
            id: clockDate
            visible: root.showDate
            anchors.verticalCenter: parent.verticalCenter
            text: Qt.formatDateTime(clock.date, Settings.modOpts.clock.dateFormat)
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.bar
            font.weight: Theme.weightSemibold
            font.features: Theme.tabularNumberFeatures
            color: Theme.barTextMid
        }
    }
}
