import QtQuick
import "../Common"

// [label 90][slider][mono value 44][undo 18].
SettingsRow {
    id: root

    property alias value: slider.value
    property alias min: slider.min
    property alias max: slider.max
    property alias step: slider.step
    property alias dimmed: slider.dimmed
    property alias gradientTrack: slider.gradientTrack
    property alias hueTrack: slider.hueTrack
    property alias colorTrack: slider.colorTrack
    property alias trackStart: slider.trackStart
    property alias trackMiddle: slider.trackMiddle
    property alias trackEnd: slider.trackEnd
    property string unit: "px"
    property int decimals: 0
    // Overrides the numeric readout when the value formats as something
    // richer than number + unit (times, line counts).
    property string valueLabel: ""
    property int valueWidth: 44
    signal moved(real value)

    narrowHeight: Theme.scaled(52)
    labelColor: slider.dimmed ? Theme.textDim : Theme.textMid

    HSlider {
        id: slider
        x: root.narrow ? 0 : root.labelWidth
        y: root.narrow ? Theme.scaled(23) : (parent.height - height) / 2
        width: root.narrow ? parent.width : valueText.x - x - 10
        height: Theme.settingsControlHeight
        // Every settings row overrides this; the default matters only so a
        // row that forgets stays stepped rather than silently continuous.
        step: 1
        value: root.stored !== undefined ? root.stored : 0
        accessibleName: root.label
        onMoved: value => {
            root.commit(value);
            root.moved(value);
        }
    }

    Text {
        id: valueText
        x: root.contentRight - width
        y: root.narrow ? 0 : (parent.height - height) / 2
        width: root.valueWidth
        horizontalAlignment: Text.AlignRight
        text: root.valueLabel !== "" ? root.valueLabel
            : slider.value.toFixed(root.decimals) + " " + root.unit
        font.family: Theme.fontMono
        font.pixelSize: Theme.fontCaption
        color: Theme.textMid
    }
}
