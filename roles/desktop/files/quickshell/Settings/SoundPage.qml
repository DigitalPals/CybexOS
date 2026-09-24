pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Services.Pipewire
import "../Common"
import "../Common/AudioHelpers.js" as AudioHelpers
import "../Common/Format.js" as Format

// Settings -> Sound, built from settings rows (2026-09 redesign). It used to
// embed the bar drawer's Sound tab, whose own headings ("MICROPHONE 100")
// and row styles did not belong on a settings page. The data is the same:
// the Audio singleton for levels, mute and the default devices, PipeWire's
// node list for the devices to choose from, and SystemSettings.sound (pactl)
// for what Quickshell cannot reach — ports, balance, profiles and routing.
//
// Everything here applies at once; PipeWire owns these values, so there is
// nothing to reset and no Apply bar.
SettingsPage {
    id: page

    readonly property SystemSettingsBackend service: SystemSettings.sound
    readonly property var nodeValues: Pipewire.nodes ? Pipewire.nodes.values : []
    readonly property var sinkCandidates: AudioHelpers.outputDevices(
        nodeValues, Audio.outputSink, Audio.tuningPresent, Audio.speakerSink)
    readonly property var sourceCandidates: AudioHelpers.sourceDevices(nodeValues, Audio.source)
    // Application streams, tracked so their levels can be read and set. The
    // pactl snapshot names them by serial; PipeWire carries the same serial.
    readonly property var streamNodes: nodeValues.filter(node => node && node.isStream
        && !AudioHelpers.isQuickshellCapture(node) && !AudioHelpers.isTuningNode(node))

    // What the device lists show. Every node coming or going (a notification
    // sound, a browser tab, this page's own level meter) rebuilds the
    // candidate arrays, and PipeWire can signal a removal while its model is
    // still changing. So, as in the audio popover, the lists are published a
    // moment later and only when their members changed; the Repeaters diff by
    // node, and a row being hovered or focused survives. They are sorted by
    // name rather than current-first, so a row does not jump when chosen.
    property var localOutputs: []
    property var networkOutputs: []
    property var inputs: []
    property real micPeak: 0

    readonly property var snapshotSinks: service.snapshot.sinks || []
    readonly property var snapshotSources: service.snapshot.sources || []
    readonly property var cards: service.snapshot.cards || []
    // This page's own level meter records from the microphone too; it is
    // not an application the user runs.
    readonly property var streams: (service.snapshot.streams || []).filter(stream =>
        !/^(quickshell|qs)$/i.test(String(stream.label).trim()))
    // The default devices as pactl reports them, for ports and balance.
    readonly property var outputInfo: Audio.sink
        ? snapshotSinks.find(device => device.name === Audio.sink.name) || null : null
    readonly property var inputInfo: Audio.source
        ? snapshotSources.find(device => device.name === Audio.source.name) || null : null

    // A balance drag shows its own value until pactl has caught up, instead
    // of snapping back to the last snapshot between steps.
    property var pendingBalance: null
    property real heldBalance: NaN

    function publish() {
        const current = Audio.outputSink;
        const network = AudioHelpers.networkSinks(sinkCandidates, null);
        // A network output in use joins the local ones, where its check shows.
        const inUse = network.filter(node => AudioHelpers.sameNode(node, current));
        const local = AudioHelpers.sortSinks(
            AudioHelpers.localSinks(sinkCandidates, null).concat(inUse), null);
        const rest = network.filter(node => !AudioHelpers.sameNode(node, current));
        const sources = AudioHelpers.sortSources(sourceCandidates, null);
        if (!AudioHelpers.sameNodeList(localOutputs, local))
            localOutputs = local;
        if (!AudioHelpers.sameNodeList(networkOutputs, rest))
            networkOutputs = rest;
        if (!AudioHelpers.sameNodeList(inputs, sources))
            inputs = sources;
    }

    // With the XPS speaker filter, the physical speakers stand for the
    // filter's virtual sink, the way the drawer shows them.
    function isOutput(node) {
        return AudioHelpers.sameNode(node, Audio.outputSink)
            || (Audio.tuningPresent && AudioHelpers.sameNode(node, Audio.speakerSink)
                && AudioHelpers.sameNode(Audio.outputSink, Audio.tuningSink));
    }

    // AudioHelpers names Bluetooth devices with an icon the bundled Tabler
    // set does not carry; show the plain Bluetooth mark instead.
    function deviceGlyph(name) {
        return String(name).indexOf("bluetooth") === 0 ? "bluetooth" : name;
    }

    function streamNode(serial) {
        return streamNodes.find(node =>
            String(AudioHelpers.nodeProps(node)["object.serial"] || "") === serial) || null;
    }

    function streamDestinations(info) {
        return (info.kind === "sink-inputs" ? snapshotSinks : snapshotSources).map(device => ({
            value: device.name,
            label: AudioHelpers.friendlyDeviceLabel(device.label) || device.label
        }));
    }

    onSinkCandidatesChanged: publishDelay.restart()
    onSourceCandidatesChanged: publishDelay.restart()
    Component.onCompleted: publish()

    Timer {
        id: publishDelay
        interval: 75
        onTriggered: page.publish()
    }

    PwObjectTracker { objects: page.sinkCandidates }
    PwObjectTracker { objects: page.sourceCandidates }
    PwObjectTracker { objects: page.streamNodes }

    PwNodePeakMonitor {
        id: inputPeak
        node: Audio.source
        // The monitor holds a capture stream open on the source while it is
        // enabled; a muted microphone has nothing to meter.
        enabled: page.visible && Settings.panelOpen && !!Audio.source && !Audio.sourceMuted
    }

    // Sampled at ~15 Hz rather than bound to the peak, which moves at the
    // PipeWire buffer rate and would redraw the page at display rate.
    Timer {
        interval: 66
        repeat: true
        running: inputPeak.enabled
        onTriggered: page.micPeak = Format.clamp01(inputPeak.peak)
        onRunningChanged: {
            if (!running)
                page.micPeak = 0;
        }
    }

    Claim {
        active: page.visible && Settings.panelOpen
        onClaimed: page.service.acquire()
        onReleased: {
            page.pendingBalance = null;
            page.heldBalance = NaN;
            page.service.release();
        }
    }
    Timer {
        id: balanceDelay
        interval: 180
        onTriggered: {
            if (!page.pendingBalance)
                return;
            if (page.service.busy) {
                restart();
                return;
            }
            page.service.run(page.pendingBalance);
            page.pendingBalance = null;
        }
    }
    Timer {
        id: balanceRelease
        interval: 1500
        onTriggered: {
            if (page.pendingBalance || page.service.busy)
                restart();
            else
                page.heldBalance = NaN;
        }
    }

    // [label][level meter] lined up under the volume track above it.
    component LevelRow: SettingsRow {
        id: levelRow

        property real level: 0
        property real trackX: labelWidth
        property real trackSpan: 0

        controlLeft: meter.x

        Rectangle {
            id: meter
            x: levelRow.trackX
            y: levelRow.narrow
                ? Theme.settingsStackOffset + (Theme.settingsControlHeight - height) / 2
                : (levelRow.lineHeight - height) / 2
            width: Math.max(0, levelRow.trackSpan)
            height: 4
            radius: 2
            color: Theme.hairline
            opacity: levelRow.controlOpacity
            Accessible.role: Accessible.ProgressBar
            Accessible.name: levelRow.label

            Rectangle {
                width: Math.round(parent.width * Format.clamp01(levelRow.level))
                height: parent.height
                radius: 2
                color: Theme.ok
            }
        }
    }

    Column {
        width: parent.width
        spacing: Theme.settingsGroupSpacing

        SystemServiceStatus {
            width: parent.width
            service: page.service
            // Sound changes take a moment; a status line appearing above
            // would push the page down under the pointer mid-drag.
            showBusy: false
        }

        SettingsGroup {
            width: parent.width
            title: "Output"

            VolumeRow {
                width: parent.width
                label: "Volume"
                channelName: "output"
                value: Audio.level
                muted: Audio.muted
                disabledReason: Audio.ready ? "" : "No output device"
                onMoved: value => Audio.setVolume(value)
                onMuteToggled: Audio.toggleMuted()
            }
            SettingsRow {
                width: parent.width
                visible: page.localOutputs.length > 0
                label: "Output device"
                narrowHeight: Theme.settingsControlHeight
            }
            Repeater {
                model: ScriptModel {
                    values: page.localOutputs
                }
                delegate: ChoiceRow {
                    id: output
                    required property var modelData
                    width: parent ? parent.width : 0
                    glyph: page.deviceGlyph(AudioHelpers.sinkGlyph(output.modelData))
                    label: AudioHelpers.sinkLabel(output.modelData)
                    checked: page.isOutput(output.modelData)
                    onActivated: Audio.setDefaultSink(output.modelData)
                }
            }
            // AirPlay and other network targets can be a dozen rows; they
            // stay folded so the local devices keep the top of the list.
            SettingsDisclosure {
                width: parent.width
                visible: page.networkOutputs.length > 0
                text: page.networkOutputs.length === 1 ? "1 network output"
                    : page.networkOutputs.length + " network outputs"

                Repeater {
                    model: ScriptModel {
                        values: page.networkOutputs
                    }
                    delegate: ChoiceRow {
                        id: networkOutput
                        required property var modelData
                        width: parent ? parent.width : 0
                        glyph: "cast"
                        label: AudioHelpers.sinkLabel(networkOutput.modelData)
                        checked: page.isOutput(networkOutput.modelData)
                        onActivated: Audio.setDefaultSink(networkOutput.modelData)
                    }
                }
            }
            SystemChoice {
                width: parent.width
                visible: page.outputInfo !== null && page.outputInfo.ports.length > 1
                label: "Port"
                choices: page.outputInfo ? page.outputInfo.ports : []
                current: page.outputInfo ? page.outputInfo.port : ""
                onPicked: value => page.service.run({action: "port", kind: "sinks",
                    name: page.outputInfo.name, value: value})
            }
            SliderRow {
                width: parent.width
                visible: page.outputInfo !== null
                label: "Balance"
                disabledReason: page.outputInfo && !page.outputInfo.stereo
                    ? "Only stereo outputs have a balance" : ""
                value: !isNaN(page.heldBalance) ? page.heldBalance
                    : page.outputInfo ? page.outputInfo.balance : 0
                min: -1
                max: 1
                step: 0.05
                marks: [0]
                valueLabel: Math.abs(value) < 0.001 ? "Center"
                    : (value < 0 ? "L " : "R ") + Math.round(Math.abs(value) * 100)
                onMoved: value => {
                    page.heldBalance = value;
                    page.pendingBalance = {action: "balance", kind: "sinks",
                        name: page.outputInfo.name, value: value};
                    balanceDelay.restart();
                    balanceRelease.restart();
                }
            }
        }

        SettingsGroup {
            width: parent.width
            title: "Input"

            SettingsHint {
                width: parent.width
                text: page.inputs.length === 0 && !Audio.sourceReady
                    ? "No microphone or other input is connected." : ""
            }
            SettingsRow {
                width: parent.width
                visible: page.inputs.length > 0
                label: "Input device"
                narrowHeight: Theme.settingsControlHeight
            }
            Repeater {
                model: ScriptModel {
                    values: page.inputs
                }
                delegate: ChoiceRow {
                    id: input
                    required property var modelData
                    width: parent ? parent.width : 0
                    glyph: page.deviceGlyph(AudioHelpers.sourceGlyph(input.modelData))
                    label: AudioHelpers.sourceLabel(input.modelData)
                    checked: AudioHelpers.sameNode(input.modelData, Audio.source)
                    onActivated: Audio.setDefaultSource(input.modelData)
                }
            }
            VolumeRow {
                id: inputVolume
                width: parent.width
                visible: Audio.sourceReady
                label: "Input volume"
                channelName: "microphone"
                glyph: "mic"
                mutedGlyph: "mic_off"
                value: Audio.sourceLevel
                muted: Audio.sourceMuted
                onMoved: value => Audio.setSourceVolume(value)
                onMuteToggled: Audio.toggleSourceMuted()
            }
            LevelRow {
                width: parent.width
                visible: Audio.sourceReady
                label: "Input level"
                level: page.micPeak
                trackX: inputVolume.trackX
                trackSpan: inputVolume.trackSpan
                hint: Audio.sourceMuted ? "Unmute the input to see its level" : ""
            }
            SystemChoice {
                width: parent.width
                visible: page.inputInfo !== null && page.inputInfo.ports.length > 1
                label: "Port"
                choices: page.inputInfo ? page.inputInfo.ports : []
                current: page.inputInfo ? page.inputInfo.port : ""
                onPicked: value => page.service.run({action: "port", kind: "sources",
                    name: page.inputInfo.name, value: value})
            }
        }

        SettingsGroup {
            width: parent.width
            visible: page.cards.length > 0
            title: "Hardware profiles"

            Repeater {
                model: ScriptModel {
                    values: page.cards.map(card => card.name)
                }
                delegate: SystemChoice {
                    id: profile
                    required property string modelData
                    readonly property var card: page.cards.find(item => item.name === profile.modelData)
                        || {label: "", profiles: [], profile: "", name: ""}
                    width: parent ? parent.width : 0
                    label: card.label
                    choices: card.profiles
                    current: card.profile
                    onPicked: value => page.service.run({action: "profile", name: profile.card.name, value: value})
                }
            }
        }

        SettingsGroup {
            width: parent.width
            title: "Applications"

            Repeater {
                model: ScriptModel {
                    values: page.streams.map(stream => stream.serial)
                }
                delegate: StreamRow {
                    id: stream
                    required property string modelData
                    readonly property var info: page.streams.find(item => item.serial === stream.modelData)
                        || {kind: "sink-inputs", label: "", muted: false, serial: "", index: -1, target: -1}
                    readonly property var destinations: (stream.info.kind === "sink-inputs"
                        ? page.snapshotSinks : page.snapshotSources)
                    readonly property var node: page.streamNode(stream.modelData)
                    width: parent ? parent.width : 0
                    label: info.label
                    recording: info.kind !== "sink-inputs"
                    audio: node && node.audio ? node.audio : null
                    // PipeWire's own flag answers at once; pactl's arrives
                    // with the next snapshot.
                    muted: audio ? audio.muted : info.muted
                    model: page.streamDestinations(info)
                    current: (destinations.find(device => device.index === info.target) || {}).name || ""
                    onPicked: value => page.service.run({action: "route", kind: stream.info.kind,
                        index: stream.info.index, serial: stream.info.serial, value: value})
                    onMoved: value => {
                        if (stream.audio)
                            stream.audio.volume = value;
                    }
                    onMuteToggled: {
                        if (stream.audio)
                            stream.audio.muted = !stream.audio.muted;
                        else
                            page.service.run({action: "mute", kind: stream.info.kind,
                                index: stream.info.index, serial: stream.info.serial, value: !stream.info.muted});
                    }
                }
            }
            SettingsHint {
                width: parent.width
                text: page.service.loaded && page.streams.length === 0
                    ? "No application is playing or recording right now." : ""
            }
            ActionRow {
                width: parent.width
                label: "Advanced audio controls"
                hint: "Every port, profile and stream option, in Volume Control"

                SettingsAction {
                    text: "Open"
                    glyph: "open_in_new"
                    enabled: !SystemSettings.externalBusy
                    onTriggered: SystemSettings.openExternal("sound")
                }
            }
        }
    }
}
