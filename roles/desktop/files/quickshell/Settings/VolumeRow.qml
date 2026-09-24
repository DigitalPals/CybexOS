import QtQuick
import "../Common"

// [label][mute][slider][level][undo gutter] for a live PipeWire level: the
// output volume, the microphone. The value belongs to PipeWire, not
// shell.json, so there is no default to return to and the row never wears
// the modified mark. Muting keeps the level; the slider still moves, and the
// readout says Muted until the channel is unmuted.
SettingsRow {
    id: root

    // PipeWire's own 0..1 scale; above 1 is software gain set elsewhere,
    // which the readout reports and the track clamps.
    property real value: 0
    property bool muted: false
    property string glyph: "volume_up"
    property string mutedGlyph: "volume_off"
    property string channelName: root.label.toLowerCase()
    // Matches SliderRow, so a volume track is as long as any other.
    property int trackWidth: Theme.scaled(220, Theme.typeScale)
    signal moved(real value)
    signal muteToggled()

    readonly property real valueWidth: Math.max(Theme.scaled(44),
        Math.ceil(mutedMetrics.advanceWidth), Math.ceil(fullMetrics.advanceWidth))
    // Where the track lies, so a level meter on the next row can line up
    // with it.
    readonly property real trackX: slider.x
    readonly property real trackSpan: slider.width

    dirty: false
    resetKeys: []
    narrowHeight: Theme.settingsStackOffset + Theme.settingsControlHeight
    controlLeft: mute.x

    TextMetrics {
        id: mutedMetrics
        font: valueText.font
        text: "Muted"
    }
    TextMetrics {
        id: fullMetrics
        font: valueText.font
        text: "100%"
    }

    MuteButton {
        id: mute
        x: root.narrow ? root.markInset : slider.x - Theme.controlSpacing - width
        y: root.narrow ? Theme.settingsStackOffset : (root.lineHeight - height) / 2
        opacity: root.controlOpacity
        muted: root.muted
        glyph: root.glyph
        mutedGlyph: root.mutedGlyph
        channelName: root.channelName
        onToggled: root.muteToggled()
    }

    HSlider {
        id: slider
        x: root.narrow ? mute.x + mute.width + Theme.controlSpacing
            : valueText.x - Theme.controlSpacing - width
        y: root.narrow ? Theme.settingsStackOffset : (root.lineHeight - height) / 2
        width: Math.max(0, root.narrow ? root.contentRight - x
            : Math.min(root.trackWidth, valueText.x - Theme.controlSpacing
                - root.labelWidth - mute.width - Theme.controlSpacing))
        height: Theme.settingsControlHeight
        dimmed: root.unavailable
        min: 0
        max: 1
        step: 0.01
        value: root.value
        accessibleName: root.label
        onMoved: value => root.moved(value)
    }

    Text {
        id: valueText
        x: root.contentRight - width
        y: root.narrow ? 0 : (root.lineHeight - height) / 2
        width: root.valueWidth
        opacity: root.controlOpacity
        horizontalAlignment: Text.AlignRight
        text: root.muted ? "Muted" : Math.round(root.value * 100) + "%"
        font.family: Theme.fontMono
        font.pixelSize: Theme.typography.control
        color: root.muted ? Theme.textFaint : Theme.textMid
    }
}
