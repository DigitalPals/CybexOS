import QtQuick
import "../Common"

// [label][slider][mono value][undo].
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
    property alias marks: slider.marks
    property string unit: "px"
    property int decimals: 0
    // Overrides the numeric readout when the value formats as something
    // richer than number + unit (times, line counts).
    property string valueLabel: ""
    property int valueWidth: 44
    signal moved(real value)

    narrowHeight: Theme.settingsStackOffset + Theme.settingsControlHeight
    labelColor: slider.dimmed ? Theme.textDim : Theme.textMid

    HSlider {
        id: slider
        x: root.narrow ? root.markInset : root.labelWidth
        y: root.narrow ? Theme.settingsStackOffset : (root.lineHeight - height) / 2
        width: Math.max(0, root.narrow ? root.contentRight - x : valueText.x - x - Theme.controlSpacing)
        height: Theme.settingsControlHeight
        dimmed: root.unavailable
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
        y: root.narrow ? 0 : (root.lineHeight - height) / 2
        opacity: root.controlOpacity
        width: Math.max(root.valueWidth, implicitWidth)
        horizontalAlignment: Text.AlignRight
        text: root.valueLabel !== "" ? root.valueLabel
            : slider.value.toFixed(root.decimals) + " " + root.unit
        font.family: Theme.fontMono
        font.pixelSize: Theme.typography.control
        color: Theme.textMid
    }
}
