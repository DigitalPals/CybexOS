pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Services.Pipewire
import "Format.js" as Format
import "AudioHelpers.js" as AudioHelpers

// Default audio devices for the whole shell. Pipewire only populates a
// node's `audio` group while something tracks it, and the bar is
// instantiated once per output — four separate PwObjectTrackers used to
// bind the same two nodes, one of them multiplied by the monitor count.
// This is the single tracker; consumers read the derived values.
//
// Volume is exposed both ways on purpose: `volume` is the rounded percent
// every label and meter wants, while `setVolume`/`toggleMuted` take the
// 0..1 scale Pipewire stores, so no consumer has to convert twice or
// repeat the null guards.
Singleton {
    id: root

    // The XPS speaker filter is a virtual sink in front of the physical
    // speakers. Keep the virtual node at unity gain and expose the underlying
    // speaker as the control sink; external outputs continue to use the normal
    // PipeWire default directly.
    readonly property var outputSink: Pipewire.defaultAudioSink
    readonly property var tuningSink: Pipewire.nodes.values.find(n =>
        n.isSink && !n.isStream && n.name === "xps_speaker_tuning") ?? null
    readonly property var speakerSink: Pipewire.nodes.values.find(n =>
        n.isSink && !n.isStream
            && /^alsa_output.*sof_sdw.*HiFi__Speaker__sink$/.test(n.name || "")) ?? null
    readonly property bool tuningPresent: tuningSink !== null
    readonly property var sink: outputSink === tuningSink && speakerSink !== null
        ? speakerSink : outputSink
    readonly property var source: Pipewire.defaultAudioSource
    readonly property string outputName: AudioHelpers.sinkLabel(outputSink)

    // A node exists before its audio group arrives, so "there is a sink"
    // and "the sink can be read" are different questions. Snapshot the
    // nullable groups first: on startup QML can reevaluate a dependent value
    // while the older `ready` binding still says true for the previous node.
    readonly property var sinkAudio: sink && sink.audio ? sink.audio : null
    readonly property var sourceAudio: source && source.audio ? source.audio : null
    readonly property bool ready: sinkAudio !== null
    readonly property bool sourceReady: sourceAudio !== null

    // Percent for labels and glyph thresholds; `level` is the same reading on
    // Pipewire's own 0..1 scale, for sliders that would otherwise snap to
    // whole percents on read-back.
    readonly property int volume: sinkAudio ? Math.round(sinkAudio.volume * 100) : 0
    readonly property real level: sinkAudio ? sinkAudio.volume : 0
    readonly property bool muted: sinkAudio ? sinkAudio.muted : false

    readonly property int sourceVolume: sourceAudio
        ? Math.round(sourceAudio.volume * 100) : 0
    readonly property real sourceLevel: sourceAudio ? sourceAudio.volume : 0
    readonly property bool sourceMuted: sourceAudio ? sourceAudio.muted : false

    // Setters take the 0..1 scale and clamp — the wheel handlers all stepped
    // and clamped this identically.
    function setVolume(fraction) {
        if (!ready)
            return;
        sinkAudio.volume = Format.clamp01(fraction);
    }

    function stepVolume(delta) {
        if (ready)
            setVolume(sinkAudio.volume + delta);
    }

    function toggleMuted() {
        if (ready)
            setMuted(!sinkAudio.muted);
    }

    function setMuted(muted) {
        if (ready)
            sinkAudio.muted = muted;
    }

    // Pipewire remembers this as a preference, so it survives the node
    // disappearing and coming back. Move application streams as well: changing
    // only the metadata default otherwise leaves already-playing audio behind.
    // The helper filters on application.name, keeping the XPS filter-chain's
    // internal output pinned to the physical speakers.
    function setDefaultSink(node) {
        if (!node || !node.name)
            return;
        Pipewire.preferredDefaultAudioSink = node;
        Quickshell.execDetached(["bash", Quickshell.shellDir + "/scripts/audio-route", node.name]);
    }

    // As with outputs, the PipeWire preference controls future clients while
    // the PulseAudio-compatible helper moves recording streams that already
    // exist. This keeps an open recorder on the input selected in the panel.
    function setDefaultSource(node) {
        if (!node || !node.name)
            return;
        Pipewire.preferredDefaultAudioSource = node;
        Quickshell.execDetached(["bash",
            Quickshell.shellDir + "/scripts/audio-source-route", node.name]);
    }

    function setSourceVolume(fraction) {
        if (!sourceReady)
            return;
        sourceAudio.volume = Format.clamp01(fraction);
    }

    function toggleSourceMuted() {
        if (sourceReady)
            setSourceMuted(!sourceAudio.muted);
    }

    function setSourceMuted(muted) {
        if (sourceReady)
            sourceAudio.muted = muted;
    }

    function setAllMuted(muted) {
        setMuted(muted);
        setSourceMuted(muted);
    }

    PwObjectTracker {
        objects: [root.outputSink, root.sink, root.source]
    }
}
