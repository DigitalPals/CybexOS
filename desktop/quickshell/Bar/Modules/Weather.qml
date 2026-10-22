import QtQuick
import ".."
import "../../Common"

// Weather gets its own forecast pill: a sky mark and the temperature, with the
// condition spelled out when the bar is wide enough.
//
// An enabled weather module stays on the bar while it is offline: a segment
// that vanishes cannot say why. For the same reason one with no location
// shows a location mark that says to set one; its Day sheet links to the
// setting. Only the gap before the first forecast lands is blank, and that
// gate is the bar's auto-rule rather than this file's, so the space before
// the segment agrees with it.
BarModule {
    id: root

    moduleId: "weather"
    spacing: 5
    detailSaving: condition.implicitWidth + spacing

    BarChip {
        id: chip

        host: root.host
        panelName: "weather"
        isle: root.isle
        anchorItem: root.groupAnchor ?? chip
        spacing: 5
        // The condition palette remains the resting identity; interaction
        // joins the shared high-foreground hover state.
        idleColor: Weather.barGlyphColor(Weather.code, Weather.isDay)
        tooltip: !Weather.locationSet ? "Weather · set a location in Settings"
            : Weather.offline ? "Weather · offline" : "Weather"

        Sym {
            anchors.verticalCenter: parent.verticalCenter
            name: !Weather.locationSet ? "add_location"
                : Weather.symbol(Weather.code, Weather.isDay)
            size: Theme.iconSmall + 1
            // Weather.code is -1 until a forecast lands, and barGlyphColor()
            // already answers that with the "no data" resting tone.
            color: chip.fg
            // A current condition keeps the full-strength colour used in the
            // desktop reference. Only stale/offline data is deliberately dim.
            opacity: chip.held || chip.hovered || !Weather.offline ? 1 : 0.52

            Behavior on opacity {
                NumberAnimation { duration: Theme.chipFadeDuration }
            }
        }

        Text {
            // No location, no reading: the mark alone is the compact state.
            visible: Weather.locationSet
            anchors.verticalCenter: parent.verticalCenter
            // Weather.temp is 0 with nothing loaded, and "0°" is a reading. A
            // dash is not.
            text: Weather.ready ? Weather.temp + "°" : "—"
            font.family: Theme.fontNumeric
            font.pixelSize: Theme.typography.bar
            font.weight: Theme.weightBold
            font.features: Theme.tabularNumberFeatures
            // Dimmed while offline, so a forecast that has stopped being
            // refreshed does not read as current.
            color: Weather.offline ? Theme.barTextFaint : Theme.barTextMid
        }

        Text {
            id: condition
            visible: !root.compact
            anchors.verticalCenter: parent.verticalCenter
            text: !Weather.locationSet ? "Set location"
                : Weather.ready ? Weather.condition : "unavailable"
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.bar
            font.weight: Theme.weightSemibold
            color: Theme.barTextLow
        }
    }
}
