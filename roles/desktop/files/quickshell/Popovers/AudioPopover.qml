pragma ComponentBehavior: Bound
import QtQuick
import Quickshell.Services.Pipewire
import "../Common"
import "../Common/AudioHelpers.js" as AudioHelpers
import "../Common/Format.js" as Format

// Full audio control in the Lumen visual language: the shared master state,
// output and input routing, live microphone activity, and application streams.
// Repeaters never bind to PipeWire's live object model. Node removal signals
// can be dispatched while that model is mutating, so a short timer publishes
// panel-local snapshots only after the mutation has settled.
Surface {
    id: root

    implicitWidth: availableWidth > 0
        ? Math.min(Theme.popWideWidth, availableWidth) : Theme.popWideWidth
    spacing: 0

    readonly property real preferredHeightCap: 620
    readonly property real heightLimit: root.availableHeight > 0
        ? Math.min(root.availableHeight, root.preferredHeightCap)
        : root.preferredHeightCap
    readonly property real naturalHeight: panelColumn.implicitHeight
        + root.padding * 2
    implicitHeight: Math.max(root.padding * 2 + 1,
        Math.min(root.naturalHeight, root.heightLimit))

    readonly property var nodeValues: Pipewire.nodes ? Pipewire.nodes.values : []
    readonly property var mprisPlayers: Media.players
    readonly property var sinkCandidates: AudioHelpers.outputDevices(
        nodeValues, Audio.outputSink, Audio.tuningPresent, Audio.speakerSink)
    readonly property var sourceCandidates: AudioHelpers.sourceDevices(
        nodeValues, Audio.source)
    readonly property var playbackCandidates: AudioHelpers.playbackStreams(nodeValues)
    readonly property var readyPlaybackStreams: AudioHelpers.sortPlaybackStreams(
        playbackCandidates.filter(node => node && node.audio), mprisPlayers)

    property var displaySinks: []
    property var displaySources: []
    property var displayStreams: []
    property bool outputDevicesOpen: false
    property bool inputDevicesOpen: false

    readonly property bool hasOutput: Audio.ready
    readonly property bool hasInput: Audio.sourceReady
    readonly property bool anyAudible: AudioHelpers.anyAudible(
        hasOutput, Audio.muted, hasInput, Audio.sourceMuted)
    readonly property string outputGlyph: AudioHelpers.outputGlyph(
        Audio.level, Audio.muted, Audio.ready)
    readonly property string heroStatus: !Audio.ready ? "No output device"
        : (Audio.muted ? "Muted" : Audio.volume + "%")
            + " · " + Audio.outputName

    function refreshSnapshots() {
        const nextSinks = AudioHelpers.listSnapshot(sinkCandidates);
        const nextSources = AudioHelpers.listSnapshot(sourceCandidates);
        const nextStreams = AudioHelpers.listSnapshot(readyPlaybackStreams);
        // Assigning an unchanged QObject array still rebuilds its Repeater.
        // Keep focus and pointer state intact when only another node class
        // changed (for example, an AirPlay sink arriving while Tab is in the
        // input section).
        if (!AudioHelpers.sameNodeList(displaySinks, nextSinks))
            displaySinks = nextSinks;
        if (!AudioHelpers.sameNodeList(displaySources, nextSources))
            displaySources = nextSources;
        if (!AudioHelpers.sameNodeList(displayStreams, nextStreams))
            displayStreams = nextStreams;
    }

    function scheduleSnapshotRefresh() {
        snapshotRefresh.restart();
    }

    function selectOutput(node) {
        outputDevicesOpen = false;
        Audio.setDefaultSink(node);
        Qt.callLater(() => outputPicker.forceActiveFocus());
    }

    function selectInput(node) {
        inputDevicesOpen = false;
        Audio.setDefaultSource(node);
        Qt.callLater(() => inputPicker.forceActiveFocus());
    }

    function ensureVisible(item) {
        if (!item || !scrollArea || scrollArea.contentHeight <= scrollArea.height)
            return;
        const point = item.mapToItem(panelColumn, 0, 0);
        const margin = 8;
        const top = point.y - margin;
        const bottom = point.y + item.height + margin;
        const viewTop = scrollArea.contentY;
        const viewBottom = viewTop + scrollArea.height;
        const maximum = Math.max(0, scrollArea.contentHeight - scrollArea.height);
        if (top < viewTop)
            scrollArea.contentY = Math.max(0, top);
        else if (bottom > viewBottom)
            scrollArea.contentY = Math.min(maximum, bottom - scrollArea.height);
    }

    onSinkCandidatesChanged: scheduleSnapshotRefresh()
    onSourceCandidatesChanged: scheduleSnapshotRefresh()
    onReadyPlaybackStreamsChanged: scheduleSnapshotRefresh()
    Component.onCompleted: refreshSnapshots()

    Timer {
        id: snapshotRefresh
        interval: 75
        repeat: false
        onTriggered: root.refreshSnapshots()
    }

    // Track the node groups that the panel reads. Candidate streams are
    // tracked before their audio group is ready; the ready list above then
    // republishes once volume and mute become available.
    PwObjectTracker { objects: root.sinkCandidates }
    PwObjectTracker { objects: root.sourceCandidates }
    PwObjectTracker { objects: root.playbackCandidates }

    PwNodePeakMonitor {
        id: inputPeakMonitor
        node: Audio.source
        enabled: root.visible && !!Audio.source
    }

    component MuteButton: Rectangle {
        id: muteButton

        property bool muted: false
        property bool ready: true
        property string channelName: "audio"
        property string audibleGlyph: "volume_up"
        property string mutedGlyph: "volume_off"
        property int controlSize: 34
        signal triggered

        width: controlSize
        height: controlSize
        radius: Theme.rowRadius
        color: muted ? Theme.redBgSoft : "transparent"
        opacity: ready ? 1 : 0.4
        enabled: ready
        activeFocusOnTab: ready && visible
        Accessible.role: Accessible.Button
        Accessible.name: (muted ? "Unmute " : "Mute ") + channelName
        Accessible.onPressAction: muteButton.triggered()
        border.width: activeFocus ? 1 : 0
        border.color: Theme.accent

        onActiveFocusChanged: if (activeFocus) root.ensureVisible(muteButton)

        Keys.onPressed: event => {
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                    || event.key === Qt.Key_Space) {
                muteState.pulseCenter();
                muteButton.triggered();
                event.accepted = true;
            }
        }

        StateLayer {
            id: muteState
            anchors.fill: parent
            radius: parent.radius
            hovered: muteMouse.containsMouse
            pressed: muteMouse.pressed
            focused: muteButton.activeFocus
            tint: muteButton.muted ? Theme.redText : Theme.textHi
            pressPoint: Qt.point(muteMouse.mouseX, muteMouse.mouseY)
        }

        Sym {
            anchors.centerIn: parent
            name: muteButton.muted ? muteButton.mutedGlyph : muteButton.audibleGlyph
            size: Theme.iconMedium
            fill: muteButton.muted ? 1 : 0
            color: muteButton.muted ? Theme.redText : Theme.textMid
        }

        MouseArea {
            id: muteMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                muteButton.forceActiveFocus();
                muteButton.triggered();
            }
        }
    }

    // The current route remains visible while the full device list stays out
    // of the way. Activating this selection box expands the inline choices,
    // preserving the popover's normal focus and scrolling behaviour.
    component DevicePicker: Rectangle {
        id: devicePicker

        property string currentLabel: "No device"
        property string detailText: "No devices available"
        property string glyph: "volume_off"
        property string channelName: "Audio"
        property bool expanded: false
        property bool ready: true
        signal activated
        signal collapseRequested

        width: parent ? parent.width : 0
        height: 48
        radius: Theme.rowRadius
        color: pickerMouse.containsMouse && devicePicker.ready
            ? Theme.chipHover : Theme.chip
        enabled: ready
        opacity: ready ? 1 : 0.55
        activeFocusOnTab: ready && visible
        Accessible.role: Accessible.Button
        Accessible.name: channelName + " device, " + currentLabel
        Accessible.description: detailText + ". "
            + (expanded ? "Device list expanded" : "Device list collapsed")
        Accessible.onPressAction: devicePicker.activated()
        border.width: activeFocus || expanded ? 1 : 0
        border.color: Theme.accent

        onActiveFocusChanged: if (activeFocus) root.ensureVisible(devicePicker)

        Keys.onPressed: event => {
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                    || event.key === Qt.Key_Space) {
                pickerState.pulseCenter();
                devicePicker.activated();
                event.accepted = true;
            } else if (event.key === Qt.Key_Escape && devicePicker.expanded) {
                devicePicker.collapseRequested();
                event.accepted = true;
            }
        }

        StateLayer {
            id: pickerState
            anchors.fill: parent
            radius: parent.radius
            hovered: pickerMouse.containsMouse
            pressed: pickerMouse.pressed
            focused: devicePicker.activeFocus
            tint: Theme.textHi
            pressPoint: Qt.point(pickerMouse.mouseX, pickerMouse.mouseY)
        }

        Sym {
            id: pickerIcon
            anchors.left: parent.left
            anchors.leftMargin: 11
            anchors.verticalCenter: parent.verticalCenter
            width: 22
            name: devicePicker.glyph
            size: Theme.iconMedium
            fill: 1
            color: devicePicker.ready ? Theme.accent : Theme.textDim
        }

        Column {
            anchors.left: pickerIcon.right
            anchors.leftMargin: 10
            anchors.right: pickerChevron.left
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            spacing: 1

            Text {
                width: parent.width
                text: devicePicker.currentLabel
                elide: Text.ElideRight
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.primary
                font.weight: Theme.weightSemibold
                color: devicePicker.ready ? Theme.textHi : Theme.textDim
            }

            Text {
                width: parent.width
                text: devicePicker.detailText
                elide: Text.ElideRight
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.secondary
                font.weight: Theme.weightMedium
                color: Theme.textDim
            }
        }

        Sym {
            id: pickerChevron
            anchors.right: parent.right
            anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            width: 18
            name: devicePicker.expanded ? "expand_less" : "expand_more"
            size: Theme.iconSmall
            color: devicePicker.ready ? Theme.textLow : Theme.textDim
        }

        MouseArea {
            id: pickerMouse
            anchors.fill: parent
            enabled: devicePicker.ready
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                devicePicker.forceActiveFocus();
                devicePicker.activated();
            }
        }
    }

    component SinkRow: Rectangle {
        id: sinkRow

        required property var sinkNode
        readonly property bool isDefault: AudioHelpers.sameNode(
            sinkNode, Audio.outputSink)
        readonly property bool network: AudioHelpers.isNetworkSink(sinkNode)

        width: parent ? parent.width - 4 : 0
        x: 2
        height: Theme.listRowHeight
        radius: Theme.rowRadius
        color: isDefault ? Theme.chip
            : sinkMouse.containsMouse ? Theme.chipHover : "transparent"
        activeFocusOnTab: root.outputDevicesOpen && visible
        Accessible.role: Accessible.RadioButton
        Accessible.name: "Use " + AudioHelpers.sinkLabel(sinkNode)
        Accessible.description: isDefault ? "Current output"
            : network ? "Network or AirPlay output" : "Output device"
        Accessible.checked: isDefault
        Accessible.onPressAction: root.selectOutput(sinkNode)
        border.width: activeFocus ? 1 : 0
        border.color: Theme.accent

        onActiveFocusChanged: if (activeFocus) root.ensureVisible(sinkRow)

        Keys.onPressed: event => {
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                    || event.key === Qt.Key_Space) {
                root.selectOutput(sinkRow.sinkNode);
                event.accepted = true;
            } else if (event.key === Qt.Key_Escape) {
                root.outputDevicesOpen = false;
                Qt.callLater(() => outputPicker.forceActiveFocus());
                event.accepted = true;
            }
        }

        StateLayer {
            anchors.fill: parent
            radius: parent.radius
            hovered: sinkMouse.containsMouse
            pressed: sinkMouse.pressed
            focused: sinkRow.activeFocus
            tint: sinkRow.isDefault ? Theme.accent : Theme.textHi
            pressPoint: Qt.point(sinkMouse.mouseX, sinkMouse.mouseY)
        }

        Sym {
            id: sinkIcon
            anchors.left: parent.left
            anchors.leftMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            width: 20
            name: AudioHelpers.sinkGlyph(sinkRow.sinkNode)
            size: Theme.iconMedium
            fill: sinkRow.isDefault ? 1 : 0
            color: sinkRow.isDefault ? Theme.accent : Theme.textLow
        }

        Text {
            anchors.left: sinkIcon.right
            anchors.leftMargin: 10
            anchors.right: sinkCheck.left
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            text: AudioHelpers.sinkLabel(sinkRow.sinkNode)
            elide: Text.ElideRight
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.primary
            font.weight: sinkRow.isDefault ? Theme.weightSemibold : Theme.weightRegular
            color: sinkRow.isDefault ? Theme.textHi : Theme.textLow
        }

        Sym {
            id: sinkCheck
            anchors.right: parent.right
            anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            width: 18
            name: sinkRow.isDefault ? "check" : sinkRow.network ? "cast" : ""
            size: Theme.iconSmall
            color: sinkRow.isDefault ? Theme.accent : Theme.textDim
        }

        MouseArea {
            id: sinkMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                sinkRow.forceActiveFocus();
                root.selectOutput(sinkRow.sinkNode);
            }
        }
    }

    component SourceRow: Rectangle {
        id: sourceRow

        required property var sourceNode
        readonly property bool isDefault: AudioHelpers.sameNode(
            sourceNode, Audio.source)

        width: parent ? parent.width - 4 : 0
        x: 2
        height: Theme.listRowHeight
        radius: Theme.rowRadius
        color: isDefault ? Theme.chip
            : sourceMouse.containsMouse ? Theme.chipHover : "transparent"
        activeFocusOnTab: root.inputDevicesOpen && visible
        Accessible.role: Accessible.RadioButton
        Accessible.name: "Use " + AudioHelpers.sourceLabel(sourceNode)
        Accessible.description: isDefault ? "Current input" : "Input device"
        Accessible.checked: isDefault
        Accessible.onPressAction: root.selectInput(sourceNode)
        border.width: activeFocus ? 1 : 0
        border.color: Theme.accent

        onActiveFocusChanged: if (activeFocus) root.ensureVisible(sourceRow)

        Keys.onPressed: event => {
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                    || event.key === Qt.Key_Space) {
                root.selectInput(sourceRow.sourceNode);
                event.accepted = true;
            } else if (event.key === Qt.Key_Escape) {
                root.inputDevicesOpen = false;
                Qt.callLater(() => inputPicker.forceActiveFocus());
                event.accepted = true;
            }
        }

        StateLayer {
            anchors.fill: parent
            radius: parent.radius
            hovered: sourceMouse.containsMouse
            pressed: sourceMouse.pressed
            focused: sourceRow.activeFocus
            tint: sourceRow.isDefault ? Theme.accent : Theme.textHi
            pressPoint: Qt.point(sourceMouse.mouseX, sourceMouse.mouseY)
        }

        Sym {
            id: sourceIcon
            anchors.left: parent.left
            anchors.leftMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            width: 20
            name: AudioHelpers.sourceGlyph(sourceRow.sourceNode)
            size: Theme.iconMedium
            fill: sourceRow.isDefault ? 1 : 0
            color: sourceRow.isDefault ? Theme.accent : Theme.textLow
        }

        Text {
            anchors.left: sourceIcon.right
            anchors.leftMargin: 10
            anchors.right: sourceCheck.left
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            text: AudioHelpers.sourceLabel(sourceRow.sourceNode)
            elide: Text.ElideRight
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.primary
            font.weight: sourceRow.isDefault
                ? Theme.weightSemibold : Theme.weightRegular
            color: sourceRow.isDefault ? Theme.textHi : Theme.textLow
        }

        Sym {
            id: sourceCheck
            anchors.right: parent.right
            anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            width: 18
            name: sourceRow.isDefault ? "check" : ""
            size: Theme.iconSmall
            color: Theme.accent
        }

        MouseArea {
            id: sourceMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                sourceRow.forceActiveFocus();
                root.selectInput(sourceRow.sourceNode);
            }
        }
    }

    component StreamRow: Rectangle {
        id: streamRow

        required property var streamNode
        readonly property var streamAudio: streamNode && streamNode.audio
            ? streamNode.audio : null
        readonly property real streamLevel: streamAudio
            ? Format.clamp01(streamAudio.volume) : 0
        readonly property bool streamMuted: streamAudio ? streamAudio.muted : false
        readonly property string streamName: AudioHelpers.streamLabel(
            streamNode, root.mprisPlayers, root.displayStreams)

        width: parent ? parent.width : 0
        height: streamColumn.implicitHeight + 14
        radius: Theme.rowRadius
        color: Theme.chip

        Column {
            id: streamColumn
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: 8
            anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            spacing: 3

            Row {
                id: streamHeader
                width: parent.width
                height: 30
                spacing: 8

                MuteButton {
                    id: streamMute
                    anchors.verticalCenter: parent.verticalCenter
                    controlSize: 30
                    muted: streamRow.streamMuted
                    ready: streamRow.streamAudio !== null
                    channelName: streamRow.streamName
                    onTriggered: {
                        if (streamRow.streamAudio)
                            streamRow.streamAudio.muted = !streamRow.streamAudio.muted;
                    }
                }

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    width: streamHeader.width - streamMute.width
                        - streamPercent.width - streamHeader.spacing * 2
                    text: streamRow.streamName
                    elide: Text.ElideRight
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.primary
                    font.weight: Theme.weightMedium
                    color: streamRow.streamMuted ? Theme.textDim : Theme.textHi
                }

                Text {
                    id: streamPercent
                    anchors.verticalCenter: parent.verticalCenter
                    width: 42
                    horizontalAlignment: Text.AlignRight
                    text: Math.round(streamRow.streamLevel * 100) + "%"
                    font.family: Theme.fontMono
                    font.pixelSize: Theme.typography.secondary
                    font.weight: Theme.weightSemibold
                    font.features: Theme.tabularNumberFeatures
                    color: streamRow.streamMuted ? Theme.textDim : Theme.textLow
                }
            }

            BlockMeter {
                id: streamSlider
                width: parent.width
                height: 8
                interactive: true
                step: 0.05
                value: streamRow.streamLevel
                dimmed: streamRow.streamAudio === null
                opacity: streamRow.streamMuted ? 0.5 : 1
                accessibleName: streamRow.streamName + " volume"
                Accessible.description: Math.round(streamRow.streamLevel * 100)
                    + " percent"
                onActiveFocusChanged: if (activeFocus) root.ensureVisible(streamSlider)
                onMoved: value => {
                    if (streamRow.streamAudio)
                        streamRow.streamAudio.volume = Format.clamp01(value);
                }
            }
        }
    }

    Item {
        id: viewport

        width: parent.width
        height: Math.max(1, root.implicitHeight - root.padding * 2)

        Flickable {
            id: scrollArea

            anchors.fill: parent
            clip: true
            contentWidth: width
            contentHeight: panelColumn.implicitHeight
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height
            pixelAligned: true

            Column {
                id: panelColumn

                x: 2
                width: scrollArea.width - 8
                spacing: Theme.panelSectionSpacing

                // Hero: responsive output mark, current route/status, and a
                // global switch whose checked state means some channel is on.
                Item {
                    id: hero
                    width: parent.width
                    height: 68

                    Item {
                        id: heroGlyphBox
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        width: 58
                        height: 58

                        Sym {
                            anchors.centerIn: parent
                            name: root.outputGlyph
                            size: Theme.fontHero + 6
                            fill: Audio.muted ? 0 : 1
                            color: Audio.muted || !Audio.ready
                                ? Theme.textDim : Theme.accent
                        }
                    }

                    Column {
                        anchors.left: heroGlyphBox.right
                        anchors.leftMargin: 12
                        anchors.right: heroToggle.left
                        anchors.rightMargin: 12
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 3

                        Text {
                            width: parent.width
                            text: "Audio"
                            elide: Text.ElideRight
                            font.family: Theme.fontMenu
                            font.pixelSize: Theme.typography.heading
                            font.weight: Theme.weightSemibold
                            color: Theme.textHi
                        }

                        Text {
                            width: parent.width
                            text: root.heroStatus
                            elide: Text.ElideRight
                            font.family: Theme.fontMenu
                            font.pixelSize: Theme.typography.secondary
                            font.weight: Theme.weightMedium
                            color: Audio.muted ? Theme.textDim : Theme.textLow
                        }
                    }

                    Toggle {
                        id: heroToggle
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        enabled: root.hasOutput || root.hasInput
                        activeFocusOnTab: enabled && visible
                        checked: root.anyAudible
                        accessibleName: root.anyAudible
                            ? "Mute all audio" : "Unmute all audio"
                        Accessible.role: Accessible.CheckBox
                        Accessible.name: heroToggle.accessibleName
                        onActiveFocusChanged: if (activeFocus) root.ensureVisible(heroToggle)
                        onToggled: value => Audio.setAllMuted(!value)
                    }
                }

                Column {
                    id: outputSection
                    width: parent.width
                    spacing: 6

                    SectionLabel {
                        width: parent.width
                        text: "OUTPUT"
                        detail: Audio.ready ? Audio.volume + "%" : "--"
                    }

                    Row {
                        id: outputControls
                        width: parent.width
                        height: 36
                        spacing: 10

                        MuteButton {
                            id: outputMute
                            anchors.verticalCenter: parent.verticalCenter
                            muted: Audio.muted
                            ready: Audio.ready
                            channelName: "output"
                            onTriggered: Audio.toggleMuted()
                        }

                        BlockMeter {
                            id: outputSlider
                            anchors.verticalCenter: parent.verticalCenter
                            width: outputControls.width - outputMute.width
                                - outputControls.spacing
                            height: 8
                            interactive: true
                            step: 0.05
                            value: Audio.level
                            dimmed: !Audio.ready
                            opacity: Audio.muted ? 0.5 : 1
                            accessibleName: "Output volume"
                            Accessible.description: Audio.ready
                                ? Audio.volume + " percent" : "Unavailable"
                            onActiveFocusChanged: if (activeFocus)
                                root.ensureVisible(outputSlider)
                            onMoved: value => Audio.setVolume(value)
                        }
                    }

                    DevicePicker {
                        id: outputPicker
                        currentLabel: Audio.ready && Audio.outputSink
                            ? AudioHelpers.sinkLabel(Audio.outputSink)
                            : "No output selected"
                        detailText: root.displaySinks.length === 0
                            ? "No devices available"
                            : (root.outputDevicesOpen ? "Choose output" : "Current output")
                                + " · " + root.displaySinks.length + " device"
                                + (root.displaySinks.length === 1 ? "" : "s")
                        glyph: Audio.outputSink
                            ? AudioHelpers.sinkGlyph(Audio.outputSink) : "volume_off"
                        channelName: "Output"
                        ready: root.displaySinks.length > 0
                        expanded: root.outputDevicesOpen
                        onActivated: root.outputDevicesOpen = !root.outputDevicesOpen
                        onCollapseRequested: root.outputDevicesOpen = false
                    }

                    Column {
                        id: outputDeviceList
                        visible: root.outputDevicesOpen
                        width: parent.width
                        spacing: 2

                        Repeater {
                            model: root.displaySinks

                            delegate: SinkRow {
                                required property var modelData
                                sinkNode: modelData
                            }
                        }
                    }
                }

                Column {
                    id: inputSection
                    width: parent.width
                    spacing: 6

                    SectionLabel {
                        width: parent.width
                        text: "INPUT"
                        detail: Audio.sourceReady ? Audio.sourceVolume + "%" : "--"
                    }

                    Row {
                        id: inputControls
                        width: parent.width
                        height: 36
                        spacing: 10

                        MuteButton {
                            id: inputMute
                            anchors.verticalCenter: parent.verticalCenter
                            muted: Audio.sourceMuted
                            ready: Audio.sourceReady
                            channelName: "input"
                            audibleGlyph: "mic"
                            mutedGlyph: "mic_off"
                            onTriggered: Audio.toggleSourceMuted()
                        }

                        BlockMeter {
                            id: inputSlider
                            anchors.verticalCenter: parent.verticalCenter
                            width: inputControls.width - inputMute.width
                                - inputControls.spacing
                            height: 8
                            interactive: true
                            step: 0.05
                            value: Audio.sourceLevel
                            dimmed: !Audio.sourceReady
                            opacity: Audio.sourceMuted ? 0.5 : 1
                            accessibleName: "Input volume"
                            Accessible.description: Audio.sourceReady
                                ? Audio.sourceVolume + " percent" : "Unavailable"
                            onActiveFocusChanged: if (activeFocus)
                                root.ensureVisible(inputSlider)
                            onMoved: value => Audio.setSourceVolume(value)
                        }
                    }

                    Row {
                        id: peakRow
                        visible: Audio.source !== null
                        width: parent.width
                        height: 16
                        spacing: 10
                        opacity: Audio.sourceMuted ? 0.4 : 1

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            width: 58
                            text: "LIVE MIC"
                            font.family: Theme.fontMenu
                            font.pixelSize: Theme.typography.metadata
                            font.weight: Theme.weightSemibold
                            font.letterSpacing: 0.7
                            color: Theme.textDim
                        }

                        BlockMeter {
                            anchors.verticalCenter: parent.verticalCenter
                            width: peakRow.width - 58 - peakRow.spacing
                            height: 7
                            value: Audio.sourceMuted ? 0
                                : Format.clamp01(inputPeakMonitor.peak)
                            fillColor: Theme.accent

                            Behavior on value {
                                NumberAnimation { duration: Theme.reducedMotion ? 0 : 70 }
                            }
                        }
                    }

                    DevicePicker {
                        id: inputPicker
                        currentLabel: Audio.sourceReady && Audio.source
                            ? AudioHelpers.sourceLabel(Audio.source)
                            : "No input selected"
                        detailText: root.displaySources.length === 0
                            ? "No devices available"
                            : (root.inputDevicesOpen ? "Choose input" : "Current input")
                                + " · " + root.displaySources.length + " device"
                                + (root.displaySources.length === 1 ? "" : "s")
                        glyph: Audio.source
                            ? AudioHelpers.sourceGlyph(Audio.source) : "mic_off"
                        channelName: "Input"
                        ready: root.displaySources.length > 0
                        expanded: root.inputDevicesOpen
                        onActivated: root.inputDevicesOpen = !root.inputDevicesOpen
                        onCollapseRequested: root.inputDevicesOpen = false
                    }

                    Column {
                        id: inputDeviceList
                        visible: root.inputDevicesOpen
                        width: parent.width
                        spacing: 2

                        Repeater {
                            model: root.displaySources

                            delegate: SourceRow {
                                required property var modelData
                                sourceNode: modelData
                            }
                        }
                    }
                }

                Column {
                    id: applicationsSection
                    visible: root.displayStreams.length > 0
                    width: parent.width
                    spacing: 8
                    bottomPadding: 8

                    SectionLabel {
                        width: parent.width
                        text: "APPLICATIONS"
                        detail: root.displayStreams.length
                    }

                    Repeater {
                        model: root.displayStreams

                        delegate: StreamRow {
                            required property var modelData
                            streamNode: modelData
                        }
                    }
                }
            }
        }

        ScrollChrome {
            anchors.fill: parent
            target: scrollArea
        }
    }
}
