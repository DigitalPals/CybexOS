const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { shellDir, load } = require("./shell.cjs");

const H = load("AudioHelpers.js");

const laptop = {
    id: 1,
    isSink: true,
    isStream: false,
    name: "xps_speaker_tuning",
    description: "Laptop Speakers",
};
const physicalSpeaker = {
    id: 2,
    isSink: true,
    isStream: false,
    name: "alsa_output.pci.sof_sdw.HiFi__Speaker__sink",
    description: "sof-soundwire Speakers",
};
const adam = {
    id: 3,
    isSink: true,
    isStream: false,
    name: "alsa_output.usb-Vendor_strings_are_placed_here._ADAM_Audio_D3V-00.analog-stereo",
    description: "PCM2704 16-bit stereo audio DAC Analog Stereo",
};
const studio = {
    id: 4,
    isSink: true,
    isStream: false,
    name: "alsa_output.usb-Apple_Inc._Studio_Display_XDR_123.analog-stereo",
    description: "Studio Display XDR Analog Stereo",
};
const hdmi = {
    id: 5,
    isSink: true,
    isStream: false,
    name: "alsa_output.pci.HiFi__HDMI2__sink",
    description: "Core Ultra Processors (Series 3) HD Audio HDMI / DisplayPort 2 Output",
};
const airplay = {
    id: 6,
    isSink: true,
    isStream: false,
    name: "raop_sink.Sonos.local",
    description: "Living Room",
};

test("output and input devices get concise labels", () => {
    assert.equal(H.sinkLabel(laptop), "Laptop Speakers");
    assert.equal(H.sinkLabel(adam), "ADAM D3V");
    assert.equal(H.sinkLabel(studio), "Studio Display XDR");
    assert.equal(H.sinkLabel(hdmi), "HDMI / DisplayPort 2");
    assert.equal(H.sourceLabel({
        ready: true,
        name: "alsa_input.pci.sof_sdw.HiFi__Mic__source",
        properties: { "node.nick": "Built-in Audio Microphones Input" },
    }), "Microphone");
    assert.equal(H.sinkLabel(null), "No output device");
    assert.equal(H.sourceLabel(null), "No input device");
});

test("local outputs remain complete while network outputs are grouped separately", () => {
    const sinks = [airplay, studio, hdmi, adam, laptop];
    assert.deepEqual(H.localSinks(sinks, laptop), [laptop, adam, hdmi, studio]);
    assert.deepEqual(H.networkSinks(sinks, laptop), [airplay]);
    assert.equal(H.isNetworkSink({ name: "bluez_output.headphones" }), false);
});

test("the unified output list orders current, local, then network devices", () => {
    const kitchen = {
        id: 7,
        isSink: true,
        isStream: false,
        name: "raop_sink.Kitchen.local",
        description: "Kitchen",
    };
    assert.deepEqual(H.orderedSinks(
        [airplay, studio, hdmi, adam, laptop, kitchen], airplay),
    [airplay, adam, hdmi, laptop, studio, kitchen]);
    assert.deepEqual(H.sortSinks([laptop, adam, studio], studio),
        [studio, adam, laptop]);
});

test("playback streams and physical input sources are classified safely", () => {
    assert.equal(H.isPlaybackStream({ isStream: true, isSink: true }), true);
    assert.equal(H.isPlaybackStream({
        isStream: true,
        isSink: false,
        type: "Stream/Output/Audio",
    }), true);
    assert.equal(H.isPlaybackStream({
        isStream: true,
        isSink: false,
        type: "AudioInStream",
    }), false);
    assert.equal(H.isPlaybackStream({ isStream: false, isSink: true }), false);

    const mic = {
        id: 20,
        isSink: false,
        isStream: false,
        type: "AudioSource",
        description: "USB Microphone",
    };
    const quickshell = {
        id: 21,
        isSink: false,
        isStream: false,
        type: "AudioSource",
        name: "quickshell",
    };
    assert.equal(H.isAudioSource(mic), true);
    assert.equal(H.isAudioSource(quickshell), false);
    assert.deepEqual(H.sourceDevices([quickshell, mic], mic), [mic]);
});

test("tuning nodes, capture streams, and the hidden physical speaker stay out", () => {
    const playback = {
        id: 30,
        isStream: true,
        isSink: true,
        ready: true,
        properties: { "application.name": "Firefox" },
    };
    const capture = {
        id: 31,
        isStream: true,
        isSink: false,
        type: "AudioInStream",
        ready: true,
        properties: { "application.name": "Recorder" },
    };
    const tuning = {
        id: 32,
        isStream: true,
        isSink: true,
        name: "output.xps_speaker_tuning",
    };
    const filter = {
        id: 33,
        isStream: true,
        isSink: true,
        ready: true,
        properties: { "factory.name": "support.filter-chain" },
    };
    assert.deepEqual(H.playbackStreams([capture, tuning, filter, playback]),
        [playback]);
    assert.equal(H.isTuningNode(tuning), true);
    assert.deepEqual(H.outputDevices(
        [physicalSpeaker, studio, laptop], laptop, true, physicalSpeaker),
    [laptop, studio]);
});

test("generic application streams fall back to the unmatched MPRIS identity", () => {
    const players = [
        {
            identity: "Spotify",
            desktopEntry: "spotify",
            canPlay: true,
            isPlaying: true,
            dbusName: "org.mpris.MediaPlayer2.spotify",
        },
        {
            identity: "Chromium",
            canPlay: true,
            isPlaying: false,
            dbusName: "org.mpris.MediaPlayer2.chromium",
        },
    ];
    const chromium = {
        ready: true,
        properties: { "application.name": "Chromium" },
    };
    const generic = {
        ready: true,
        properties: { "application.name": "audio-src" },
    };
    const streams = [chromium, generic];

    assert.equal(H.streamRepresentsMprisPlayer(
        "Chromium", "Chromium Browser"), true);
    assert.equal(H.matchingMprisStreamLabel("Chromium", players), "Chromium");
    assert.equal(H.unmatchedMprisStreamLabel(
        "audio-src", players, streams), "Spotify");
    assert.equal(H.streamLabel(generic, players, streams), "Spotify");
    assert.deepEqual(H.sortPlaybackStreams([generic, chromium], players),
        [chromium, generic]);
});

test("snapshots tolerate empty, transient, and large node lists", () => {
    assert.deepEqual(H.listSnapshot(null), []);
    assert.deepEqual(H.outputDevices([], null, false, null), []);
    assert.deepEqual(H.sourceDevices([], null), []);

    const live = [laptop, adam];
    const snapshot = H.listSnapshot(live);
    live.splice(0, live.length);
    assert.deepEqual(snapshot, [laptop, adam]);
    assert.equal(H.sameNodeList(snapshot, [laptop, adam]), true);
    assert.equal(H.sameNodeList(snapshot, [adam, laptop]), false);
    assert.equal(H.sameNodeList(snapshot, [laptop]), false);

    const many = Array.from({ length: 24 }, (_, index) => ({
        id: 100 + index,
        isSink: true,
        isStream: false,
        name: `alsa_output.usb.${index}`,
        description: `Output ${index}`,
    }));
    assert.equal(H.outputDevices(many, many[17], false, null).length, 24);
    assert.equal(H.outputDevices(many, many[17], false, null)[0], many[17]);
});

test("global mute state only counts channels that exist", () => {
    assert.equal(H.anyAudible(false, false, false, false), false);
    assert.equal(H.anyAudible(true, false, false, false), true);
    assert.equal(H.anyAudible(true, true, true, false), true);
    assert.equal(H.anyAudible(true, true, true, true), false);
    assert.equal(H.outputGlyph(0.2, false, true), "volume_mute");
    assert.equal(H.outputGlyph(0.5, false, true), "volume_down");
    assert.equal(H.outputGlyph(0.8, false, true), "volume_up");
    assert.equal(H.outputGlyph(0.8, true, true), "volume_off");
});

test("the audio panel has routing, mixer, peak, snapshot, and scroll structure", () => {
    const control = fs.readFileSync(path.join(shellDir,
        "Popovers/ControlCenterPopover.qml"), "utf8");
    const picker = fs.readFileSync(path.join(shellDir,
        "Popovers/AudioPopover.qml"), "utf8");
    const blockMeter = fs.readFileSync(path.join(shellDir,
        "Popovers/BlockMeter.qml"), "utf8");
    const audio = fs.readFileSync(path.join(shellDir, "Common/Audio.qml"), "utf8");

    assert.match(control, /Accessible\.name:\s*"Choose audio output"/);
    assert.match(control, /Popouts\.openPanel\("audio",\s*"right"\)/);
    assert.doesNotMatch(picker, /\.slice\(0,\s*6\)/);
    assert.match(picker, /preferredHeightCap:\s*620/);
    assert.match(picker, /Math\.min\(root\.availableHeight,\s*root\.preferredHeightCap\)/);
    assert.match(picker, /Flickable\s*\{/);
    assert.match(picker, /ScrollChrome\s*\{/);

    assert.match(picker, /property var displaySinks:\s*\[\]/);
    assert.match(picker, /property var displaySources:\s*\[\]/);
    assert.match(picker, /property var displayStreams:\s*\[\]/);
    assert.match(picker, /property bool outputDevicesOpen:\s*false/);
    assert.match(picker, /property bool inputDevicesOpen:\s*false/);
    assert.match(picker, /id:\s*snapshotRefresh[\s\S]{0,80}interval:\s*75/);
    assert.match(picker, /onSinkCandidatesChanged:\s*scheduleSnapshotRefresh/);
    assert.match(picker, /AudioHelpers\.sameNodeList\(displaySources,\s*nextSources\)/);
    assert.match(picker, /model:\s*root\.displaySinks/);
    assert.match(picker, /model:\s*root\.displaySources/);
    assert.match(picker, /model:\s*root\.displayStreams/);

    assert.match(picker, /PwNodePeakMonitor\s*\{/);
    assert.match(picker, /node:\s*Audio\.source/);
    assert.match(picker, /function selectInput\(node\)[\s\S]{0,100}inputDevicesOpen\s*=\s*false[\s\S]{0,100}Audio\.setDefaultSource\(node\)/);
    assert.match(picker, /function selectOutput\(node\)[\s\S]{0,100}outputDevicesOpen\s*=\s*false[\s\S]{0,100}Audio\.setDefaultSink\(node\)/);
    assert.match(picker, /component DevicePicker:\s*Rectangle/);
    assert.match(picker, /currentLabel:\s*Audio\.ready[\s\S]{0,100}AudioHelpers\.sinkLabel\(Audio\.outputSink\)/);
    assert.match(picker, /currentLabel:\s*Audio\.sourceReady[\s\S]{0,100}AudioHelpers\.sourceLabel\(Audio\.source\)/);
    assert.match(picker, /id:\s*outputDeviceList[\s\S]{0,80}visible:\s*root\.outputDevicesOpen/);
    assert.match(picker, /id:\s*inputDeviceList[\s\S]{0,80}visible:\s*root\.inputDevicesOpen/);
    assert.match(picker, /text:\s*"OUTPUT"/);
    assert.match(picker, /text:\s*"INPUT"/);
    assert.match(picker, /text:\s*"APPLICATIONS"/);
    assert.equal((picker.match(/SectionLabel\s*\{/g) || []).length, 3,
        "output, input, and applications retain their labeled dividers");
    assert.doesNotMatch(picker, /HDivider\s*\{/,
        "the audio panel has no additional full-width divider rules");
    assert.match(picker, /id:\s*applicationsSection[\s\S]{0,180}bottomPadding:\s*8/,
        "application streams retain a small inset below the final volume row");
    assert.match(picker, /visible:\s*root\.displayStreams\.length\s*>\s*0/);
    assert.match(picker, /streamAudio\.volume\s*=\s*Format\.clamp01\(value\)/);
    assert.doesNotMatch(picker, /max:\s*1\.5/);
    assert.doesNotMatch(picker, /HSlider\s*\{/);
    assert.ok((picker.match(/interactive:\s*true/g) || []).length >= 3,
        "master, input, and application volumes are interactive block meters");
    assert.ok((picker.match(/BlockMeter\s*\{/g) || []).length >= 4,
        "all three volumes and the live microphone use the blocked design");
    assert.match(blockMeter, /Format\.clamp01\(stepped\)/,
        "the shared blocked control clamps interaction to 100%");
    assert.match(blockMeter, /Accessible\.role:\s*Accessible\.Slider/);
    assert.match(blockMeter, /Qt\.Key_Left[\s\S]{0,300}Qt\.Key_Right/);
    assert.match(blockMeter, /Qt\.Key_Home[\s\S]{0,100}Qt\.Key_End/);
    assert.match(picker, /Accessible\.role:\s*Accessible\.RadioButton/);
    assert.match(picker, /Qt\.Key_Return[\s\S]{0,100}Qt\.Key_Space/);
    assert.match(picker, /Audio\.setAllMuted\(!value\)/);

    assert.match(audio, /scripts\/audio-route/);
    assert.match(audio, /function setDefaultSource\(node\)/);
    assert.match(audio, /Pipewire\.preferredDefaultAudioSource\s*=\s*node/);
    assert.match(audio, /scripts\/audio-source-route/);
    assert.match(audio, /readonly property var sinkAudio:\s*sink && sink\.audio/);
    assert.match(audio, /readonly property var sourceAudio:\s*source && source\.audio/);
    assert.doesNotMatch(audio, /ready \?[^\n]*sink\.audio/,
        "a stale ready binding must not dereference a disappearing PipeWire group");
});

test("the output routing helper moves named apps but leaves filter internals", () => {
    const route = fs.readFileSync(path.join(shellDir, "scripts/audio-route"), "utf8");
    assert.match(route, /pactl set-default-sink "\$target"/);
    assert.match(route, /application\[\.\]name/);
    assert.match(route, /pactl move-sink-input "\$input" "\$target"/);
    assert.doesNotMatch(route, /pactl list sink-inputs short/);
});

test("the output routing helper finds running streams under a translated locale", () => {
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "audio-route-"));
    try {
        const bin = path.join(tmp, "bin");
        const calls = path.join(tmp, "calls.log");
        fs.mkdirSync(bin);
        // pactl translates the long listing's headers; Dutch is what a user
        // who picked nl_NL in the installer sees. Property keys stay English.
        fs.writeFileSync(path.join(bin, "pactl"), `#!/usr/bin/env bash
printf '%s\\n' "LC_ALL=\${LC_ALL:-} $*" >>"$AUDIO_ROUTE_CALLS"
[[ \${1:-} == list ]] || exit 0
if [[ \${LC_ALL:-} == C ]]; then header='Sink Input'; else header='Afvoer-invoer'; fi
printf '%s #41\\n\\tProperties:\\n\\t\\tapplication.name = "Firefox"\\n' "$header"
printf '%s #42\\n\\tProperties:\\n\\t\\tnode.name = "speaker-filter"\\n' "$header"
printf '%s #43\\n\\tProperties:\\n\\t\\tapplication.name = "mpv"\\n' "$header"
`, { mode: 0o755 });
        const run = spawnSync("bash", [path.join(shellDir, "scripts/audio-route"), "usb-dac"], {
            encoding: "utf8",
            env: {
                ...process.env,
                PATH: `${bin}:${process.env.PATH}`,
                LANG: "nl_NL.UTF-8",
                LC_ALL: "nl_NL.UTF-8",
                AUDIO_ROUTE_CALLS: calls,
            },
        });
        assert.equal(run.status, 0, run.stderr);
        const moves = fs.readFileSync(calls, "utf8").split("\n")
            .filter(line => line.includes("move-sink-input"))
            .map(line => line.replace(/^LC_ALL=\S* /, ""));
        assert.deepEqual(moves, ["move-sink-input 41 usb-dac", "move-sink-input 43 usb-dac"],
            "application streams move; the filter-chain internal stays put");
    } finally {
        fs.rmSync(tmp, { recursive: true, force: true });
    }
});

test("the input routing helper updates the default and existing recorders", () => {
    const route = fs.readFileSync(path.join(shellDir,
        "scripts/audio-source-route"), "utf8");
    assert.match(route, /pactl set-default-source "\$target"/);
    assert.match(route, /pactl list short source-outputs/);
    assert.match(route, /pactl move-source-output "\$output" "\$target"/);
});
