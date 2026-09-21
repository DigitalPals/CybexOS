import QtQuick
import ".."
import "../../Common"

// Battery gets its own detail target and is shown only on laptops (auto-rule).
//
// The mark is Material's vertical battery turned on its side, which is how the
// design draws it, and it fills with the charge so the glyph itself carries
// the reading before the percentage does.
BarModule {
    id: root

    moduleId: "batt"
    spacing: 4
    detailSaving: Settings.modOpts.batt.showPct ? percentLabel.implicitWidth + spacing : 0

    readonly property int level: Math.round(Battery.percent)
    readonly property bool critical: !Battery.pluggedIn
        && level <= Settings.modOpts.batt.critAt
    readonly property bool low: !Battery.pluggedIn
        && level <= Settings.modOpts.batt.warnAt

    BarChip {
        id: chip

        host: root.host
        panelName: "battery"
        isle: root.isle
        anchorItem: root.groupAnchor ?? chip
        spacing: root.spacing
        idleColor: root.critical ? Theme.barRedText
            : root.low ? Theme.barAmber
            : Battery.pluggedIn ? Theme.barAccent : Theme.barIcon
        // Warnings keep their semantic tone; ordinary battery states use the
        // same brighter hover foreground as every other menubar icon.
        hoverColor: root.critical ? Theme.barRedText
            : root.low ? Theme.barAmber : Theme.barTextHi
        tooltip: "Battery " + root.level + "%"
            + (Battery.charging ? " · charging"
                : Battery.full ? " · fully charged" : "")
        tooltipAlign: 1

        Item {
            anchors.verticalCenter: parent.verticalCenter
            // A fixed column: the charging mark is wider than the plain one,
            // and the right cluster is right-anchored, so an unpinned swap
            // would slide every module beside it.
            width: Theme.barIconSize + 2
            height: Theme.barIconSize + 2

            Sym {
                anchors.centerIn: parent
                name: Battery.charging ? "battery_charging_full"
                    : root.critical ? "battery_alert"
                    : root.level >= 95 ? "battery_full"
                    : root.level >= 80 ? "battery_6_bar"
                    : root.level >= 65 ? "battery_5_bar"
                    : root.level >= 50 ? "battery_4_bar"
                    : root.level >= 35 ? "battery_3_bar"
                    : root.level >= 20 ? "battery_2_bar"
                    : "battery_1_bar"
                size: Theme.barIconSize
                fill: 1
                rotation: 90
                color: chip.fg
            }
        }

        Text {
            id: percentLabel
            visible: Settings.modOpts.batt.showPct && !root.compact
            anchors.verticalCenter: parent.verticalCenter
            text: root.level + "%"
            font.family: Theme.fontNumeric
            font.pixelSize: Theme.typography.bar
            font.weight: Theme.weightBold
            font.features: Theme.tabularNumberFeatures
            color: root.critical ? Theme.barRedText
                : root.low ? Theme.barAmber : Theme.barTextMid
        }
    }
}
