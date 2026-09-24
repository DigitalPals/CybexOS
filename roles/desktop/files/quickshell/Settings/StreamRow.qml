import QtQuick
import "../Common"

// [application][mute][level][device][undo gutter]: one application's
// playback or recording on a single line — whether it is muted, how loud it
// is, and where it goes. The level appears once the page has found the
// stream's PipeWire node (`audio`); routing and mute work without it. The
// values belong to PipeWire, so the row never wears the modified mark.
SettingsRow {
    id: root

    property alias model: select.model
    property var current
    property bool muted: false
    property bool recording: false
    // The stream's PwNodeAudio, or null.
    property var audio: null
    property int trackWidth: Theme.scaled(160, Theme.typeScale)
    signal picked(var value)
    signal muteToggled()
    signal moved(real value)

    readonly property bool hasLevel: audio !== null

    dirty: false
    resetKeys: []
    hint: recording ? "Recording" : "Playback"
    narrowHeight: Theme.settingsStackOffset + Theme.settingsControlHeight
    narrowLabelInset: root.undoWidth
    controlLeft: mute.x

    MuteButton {
        id: mute
        x: root.narrow ? root.markInset
            : (root.hasLevel ? level.x : select.x) - Theme.controlSpacing - width
        y: root.narrow ? Theme.settingsStackOffset : (root.lineHeight - height) / 2
        opacity: root.controlOpacity
        muted: root.muted
        glyph: root.recording ? "mic" : "volume_up"
        mutedGlyph: root.recording ? "mic_off" : "volume_off"
        channelName: root.label
        onToggled: root.muteToggled()
    }

    HSlider {
        id: level
        visible: root.hasLevel
        x: root.narrow ? mute.x + mute.width + Theme.controlSpacing
            : select.x - Theme.controlSpacing - width
        y: root.narrow ? Theme.settingsStackOffset : (root.lineHeight - height) / 2
        width: !root.hasLevel ? 0 : Math.max(0, root.narrow
            ? select.x - Theme.controlSpacing - x
            : Math.min(root.trackWidth, select.x - Theme.controlSpacing
                - root.labelWidth - mute.width - Theme.controlSpacing))
        height: Theme.settingsControlHeight
        min: 0
        max: 1
        step: 0.01
        value: root.audio ? Math.min(1, root.audio.volume) : 0
        accessibleName: root.label + " volume"
        onMoved: value => root.moved(value)
    }

    SettingsSelect {
        id: select
        // A level on the line leaves the device name less room.
        maximumWidth: Theme.scaled(root.hasLevel ? 180 : 280, Theme.typeScale)
        readonly property real room: root.contentRight - mute.width - Theme.controlSpacing
            - (root.narrow ? root.markInset : root.labelWidth)
            - (root.hasLevel ? Theme.scaled(60) + Theme.controlSpacing : 0)
        width: Math.min(naturalWidth, Math.max(0, room))
        x: root.contentRight - width
        y: root.narrow ? Theme.settingsStackOffset : (root.lineHeight - height) / 2
        opacity: root.controlOpacity
        current: root.current
        accessibleName: root.label + (root.recording ? " records from" : " plays on")
        onPicked: value => root.picked(value)
    }
}
