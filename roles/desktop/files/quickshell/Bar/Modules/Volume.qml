import QtQuick
import ".."
import "../../Common"

// Output volume: its independent chip opens audio detail, while the wheel
// keeps adjusting the level without opening the panel.
BarModule {
    id: root

    moduleId: "vol"
    spacing: 4
    detailSaving: Settings.modOpts.vol.showPct ? percentLabel.implicitWidth + spacing : 0

    BarChip {
        id: chip

        host: root.host
        panelName: "audio"
        isle: root.isle
        anchorItem: root.groupAnchor ?? chip
        spacing: root.spacing
        idleColor: Audio.muted ? Theme.barRedText : Theme.barIcon
        hoverColor: Audio.muted ? Theme.barRedText : Theme.barTextHi
        tooltip: "Volume " + Audio.volume + "%"
            + (Audio.muted ? " · muted" : "") + " · wheel to adjust"
        tooltipAlign: 1

        Sym {
            anchors.verticalCenter: parent.verticalCenter
            name: Audio.muted || Audio.volume === 0 ? "volume_off"
                : Audio.volume < 50 ? "volume_down" : "volume_up"
            size: Theme.barIconSize
            color: chip.fg
        }

        Text {
            id: percentLabel
            visible: Settings.modOpts.vol.showPct && !root.compact
            anchors.verticalCenter: parent.verticalCenter
            text: Audio.volume + "%"
            font.family: Theme.fontNumeric
            font.pixelSize: Theme.typography.bar
            font.weight: Theme.weightBold
            font.features: Theme.tabularNumberFeatures
            color: Audio.muted ? Theme.barRedText : Theme.barTextMid
        }
    }

    // A handler rather than another MouseArea: it takes the wheel without
    // competing with the chip's click target.
    WheelHandler {
        target: null
        onWheel: event => {
            const delta = event.angleDelta.y !== 0
                ? event.angleDelta.y : event.pixelDelta.y * 8;
            if (delta === 0)
                return;
            const steps = delta > 0 ? 1 : -1;
            Audio.stepVolume(steps * (Settings.modOpts.vol.step / 100));
        }
    }
}
