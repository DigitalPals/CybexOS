// Pure classification, presentation, and ordering helpers for PipeWire audio
// nodes. Keep this file free of Qt APIs so the same rules can be exercised by
// the Node unit tests.

function values(list) {
    return list && typeof list.slice === "function" ? list.slice() : [];
}

function text(value) {
    return value === undefined || value === null ? "" : String(value);
}

function nodeName(node) {
    return node && typeof node.name === "string" ? node.name : "";
}

// PwNode.properties is not safe to read until the node is bound. Plain test
// fixtures do not carry `ready`, so only an explicit false suppresses access.
function nodeProps(node) {
    if (!node || node.ready === false || !node.properties)
        return {};
    return node.properties;
}

function sameNode(a, b) {
    if (!a || !b)
        return false;
    if (a === b)
        return true;
    if (a.id !== undefined && b.id !== undefined)
        return a.id === b.id;
    return nodeName(a) !== "" && nodeName(a) === nodeName(b);
}

function friendlyDeviceLabel(value) {
    var label = text(value).trim();
    label = label.replace(/^sof-soundwire\s+/i, "");
    label = label.replace(/^built-?in audio\s+/i, "");
    label = label.replace(/\s+Analog Stereo$/i, "");
    label = label.replace(/\s+Digital Stereo \([^)]*\)$/i, "");
    label = label.replace(/\s+Output$/i, "");
    label = label.replace(/\s+Input$/i, "");
    label = label.replace(/\bMicrophones\b/gi, "Microphone");
    return label.trim();
}

function rawDeviceLabel(node, fallback) {
    if (!node)
        return fallback;
    var props = nodeProps(node);
    return text(node.nickname || node.nick || props["node.nick"]
        || props["device.profile.description"] || node.description
        || props["node.description"] || node.name || fallback);
}

function sinkLabel(node) {
    if (!node)
        return "No output device";

    var name = nodeName(node);
    var label = rawDeviceLabel(node, "Unknown output");

    if (name === "xps_speaker_tuning")
        return "Laptop Speakers";
    if (/ADAM_Audio_D3V/i.test(name) || /PCM2704.*stereo audio DAC/i.test(label))
        return "ADAM D3V";
    if (/Studio_Display_XDR/i.test(name) || /Studio Display XDR/i.test(label))
        return "Studio Display XDR";
    if (/HiFi__Headphones__sink$/.test(name))
        return "Headphones";

    var hdmi = label.match(/HD Audio HDMI \/ DisplayPort ([0-9]+) Output/i);
    if (hdmi)
        return "HDMI / DisplayPort " + hdmi[1];

    return friendlyDeviceLabel(label) || "Unknown output";
}

function sourceLabel(node) {
    if (!node)
        return "No input device";

    var name = nodeName(node);
    if (/HiFi__(?:Mic|Microphone)__source$/.test(name))
        return "Microphone";
    if (/HiFi__Headset__source$/.test(name))
        return "Headset Microphone";

    return friendlyDeviceLabel(rawDeviceLabel(node, "Unknown input"))
        || "Unknown input";
}

function isNetworkSink(node) {
    var name = nodeName(node).toLowerCase();
    return name.indexOf("raop_sink.") === 0
        || name.indexOf("rtp_sink.") === 0
        || name.indexOf("roc_sink.") === 0
        || name.indexOf("tunnel_sink.") === 0;
}

function sortSinks(sinks, current) {
    return values(sinks).sort(function(a, b) {
        if (sameNode(a, current))
            return -1;
        if (sameNode(b, current))
            return 1;
        return sinkLabel(a).localeCompare(sinkLabel(b));
    });
}

function localSinks(sinks, current) {
    return sortSinks(values(sinks).filter(function(node) {
        return !isNetworkSink(node);
    }), current);
}

function networkSinks(sinks, current) {
    return sortSinks(values(sinks).filter(isNetworkSink), current);
}

// A single device list: current first even when it is an AirPlay target,
// followed by local outputs and then network outputs.
function orderedSinks(sinks, current) {
    return values(sinks).sort(function(a, b) {
        if (sameNode(a, current))
            return -1;
        if (sameNode(b, current))
            return 1;
        var networkOrder = Number(isNetworkSink(a)) - Number(isNetworkSink(b));
        return networkOrder !== 0
            ? networkOrder : sinkLabel(a).localeCompare(sinkLabel(b));
    });
}

function outputDevices(nodes, current, tuningPresent, hiddenSpeaker) {
    var list = values(nodes).filter(function(node) {
        if (!node || !node.isSink || node.isStream)
            return false;
        return !(tuningPresent && sameNode(node, hiddenSpeaker)
            && !sameNode(node, current));
    });
    if (current && !list.some(function(node) { return sameNode(node, current); }))
        list.unshift(current);
    return orderedSinks(list, current);
}

function isQuickshellCapture(node) {
    if (!node)
        return false;
    var props = nodeProps(node);
    var app = text(props["application.name"]).toLowerCase();
    var binary = text(props["application.process.binary"]).toLowerCase();
    var name = nodeName(node).toLowerCase();
    return name === "quickshell" || app === "quickshell"
        || (binary === "qs" && (node.isStream || name.indexOf("quickshell") !== -1));
}

function isAudioSource(node) {
    if (!node || node.isSink || node.isStream || isQuickshellCapture(node))
        return false;
    if (node.audio)
        return true;
    var mediaClass = text(node.type);
    return mediaClass.indexOf("Audio/Source") !== -1
        || mediaClass.indexOf("AudioSource") !== -1
        || mediaClass.indexOf("Source") !== -1;
}

function sortSources(sources, current) {
    return values(sources).sort(function(a, b) {
        if (sameNode(a, current))
            return -1;
        if (sameNode(b, current))
            return 1;
        return sourceLabel(a).localeCompare(sourceLabel(b));
    });
}

function sourceDevices(nodes, current) {
    var list = values(nodes).filter(isAudioSource);
    if (current && !isQuickshellCapture(current)
            && !list.some(function(node) { return sameNode(node, current); }))
        list.unshift(current);
    return sortSources(list, current);
}

// Across Quickshell releases `type` has appeared as a media-class string, an
// enum name, and a numeric flag. Playback streams consistently publish as
// stream sinks; the string checks cover the older representations.
function isPlaybackStream(node) {
    if (!node || !node.isStream)
        return false;
    if (node.isSink === true)
        return true;
    var mediaClass = text(node.type);
    return mediaClass.indexOf("Stream/Output/Audio") !== -1
        || mediaClass.indexOf("AudioOutStream") !== -1
        || mediaClass.indexOf("Output") !== -1;
}

function isTuningNode(node) {
    if (!node)
        return false;
    var props = nodeProps(node);
    var blob = [node.name, node.description, node.nickname,
        props["node.name"], props["node.description"],
        props["application.name"], props["media.name"],
        props["factory.name"]].map(text).join(" ").toLowerCase();
    return blob.indexOf("xps_speaker_tuning") !== -1
        || blob.indexOf("filter-chain") !== -1
        || blob.indexOf("filter_chain") !== -1
        || blob.indexOf("filter.chain") !== -1
        || blob.indexOf("easyeffects sink") !== -1
        || text(props["application.name"]).toLowerCase() === "easyeffects";
}

function playbackStreams(nodes) {
    return values(nodes).filter(function(node) {
        return isPlaybackStream(node) && !isQuickshellCapture(node)
            && !isTuningNode(node);
    });
}

function friendlyStreamLabel(label) {
    label = text(label).trim();
    if (!label)
        return "";
    var known = {
        "spotify": "Spotify",
        "chromium": "Chromium",
        "google chrome": "Google Chrome",
        "brave": "Brave",
        "firefox": "Firefox"
    };
    return known[label.toLowerCase()] || label;
}

function streamLabelKey(label) {
    return text(label).trim().toLowerCase();
}

function streamLabelIsGeneric(label) {
    var key = streamLabelKey(label);
    return key === "audio-src" || key === "audio stream" || key === "audio"
        || key === "playback" || key === "media playback" || key === "stream"
        || key === "unknown";
}

function rawStreamLabel(node) {
    if (!node)
        return "";
    var props = nodeProps(node);
    return props["application.name"] || node.description || props["media.name"]
        || props["node.name"] || node.name || "";
}

function mprisPlayerLabel(player) {
    if (!player)
        return "";
    return friendlyStreamLabel(player.identity || player.desktopEntry || "");
}

function mprisPlayerIsProxy(player) {
    var dbusName = text(player && player.dbusName).toLowerCase();
    var desktopEntry = text(player && player.desktopEntry).toLowerCase();
    return dbusName.indexOf("playerctld") !== -1 || desktopEntry === "playerctld";
}

function streamRepresentsMprisPlayer(streamLabel, playerLabel) {
    var streamKey = streamLabelKey(friendlyStreamLabel(streamLabel));
    var playerKey = streamLabelKey(playerLabel);
    if (!streamKey || !playerKey)
        return false;
    return streamKey === playerKey || streamKey.indexOf(playerKey) !== -1
        || playerKey.indexOf(streamKey) !== -1;
}

function mprisLabelsFor(players, predicate) {
    var candidates = [];
    var playing = [];
    var proxies = [];
    var playingProxies = [];
    values(players).forEach(function(player) {
        if (!player || (!player.isPlaying && !player.canPlay))
            return;
        var label = mprisPlayerLabel(player);
        if (!label || !predicate(label))
            return;
        if (mprisPlayerIsProxy(player)) {
            proxies.push(label);
            if (player.isPlaying)
                playingProxies.push(label);
        } else {
            candidates.push(label);
            if (player.isPlaying)
                playing.push(label);
        }
    });
    if (playing.length === 1)
        return playing[0];
    if (playing.length === 0 && playingProxies.length === 1)
        return playingProxies[0];
    if (candidates.length === 1)
        return candidates[0];
    if (candidates.length === 0 && proxies.length === 1)
        return proxies[0];
    return "";
}

function matchingMprisStreamLabel(label, players) {
    if (streamLabelIsGeneric(label))
        return "";
    return mprisLabelsFor(players, function(playerLabel) {
        return streamRepresentsMprisPlayer(label, playerLabel);
    });
}

function unmatchedMprisStreamLabel(label, players, streams) {
    if (!streamLabelIsGeneric(label))
        return "";
    return mprisLabelsFor(players, function(playerLabel) {
        return !values(streams).some(function(stream) {
            var other = rawStreamLabel(stream);
            return !streamLabelIsGeneric(other)
                && streamRepresentsMprisPlayer(other, playerLabel);
        });
    });
}

function streamLabel(node, players, streams) {
    if (!node)
        return "Application";
    var label = rawStreamLabel(node);
    return friendlyStreamLabel(matchingMprisStreamLabel(label, players)
        || unmatchedMprisStreamLabel(label, players, streams) || label)
        || "Application";
}

function sortPlaybackStreams(streams, players) {
    var list = values(streams);
    return list.sort(function(a, b) {
        return streamLabel(a, players, list).localeCompare(
            streamLabel(b, players, list));
    });
}

function listSnapshot(list) {
    return values(list);
}

function sameNodeList(a, b) {
    var left = values(a);
    var right = values(b);
    if (left.length !== right.length)
        return false;
    for (var index = 0; index < left.length; index++) {
        if (!sameNode(left[index], right[index]))
            return false;
    }
    return true;
}

function anyAudible(outputReady, outputMuted, inputReady, inputMuted) {
    return (outputReady && !outputMuted) || (inputReady && !inputMuted);
}

function outputGlyph(volume, muted, ready) {
    if (!ready || muted || volume <= 0)
        return "volume_off";
    if (volume < 0.34)
        return "volume_mute";
    if (volume < 0.67)
        return "volume_down";
    return "volume_up";
}

function sinkGlyph(node) {
    if (!node)
        return "speaker";
    var props = nodeProps(node);
    var blob = [node.name, node.description, node.nickname,
        props["device.icon-name"], props["device.product.name"]]
        .map(text).join(" ").toLowerCase();
    if (isNetworkSink(node))
        return "cast";
    if (/headphone|headset|earbud|earphone|airpod/.test(blob))
        return "headphones";
    if (blob.indexOf("bluetooth") !== -1 || nodeName(node).indexOf("bluez_") === 0)
        return "bluetooth_audio";
    if (blob.indexOf("hdmi") !== -1 || blob.indexOf("display") !== -1)
        return "tv";
    return "speaker";
}

function sourceGlyph(node) {
    if (!node)
        return "mic";
    var props = nodeProps(node);
    var blob = [node.name, node.description, node.nickname,
        props["device.icon-name"], props["device.product.name"]]
        .map(text).join(" ").toLowerCase();
    if (blob.indexOf("bluetooth") !== -1 || nodeName(node).indexOf("bluez_") === 0)
        return "bluetooth_audio";
    if (/webcam|camera/.test(blob))
        return "videocam";
    if (/headphone|headset/.test(blob))
        return "headset_mic";
    return "mic";
}

var exported = {
    values: values,
    nodeProps: nodeProps,
    sameNode: sameNode,
    friendlyDeviceLabel: friendlyDeviceLabel,
    sinkLabel: sinkLabel,
    sourceLabel: sourceLabel,
    isNetworkSink: isNetworkSink,
    sortSinks: sortSinks,
    localSinks: localSinks,
    networkSinks: networkSinks,
    orderedSinks: orderedSinks,
    outputDevices: outputDevices,
    isQuickshellCapture: isQuickshellCapture,
    isAudioSource: isAudioSource,
    sortSources: sortSources,
    sourceDevices: sourceDevices,
    isPlaybackStream: isPlaybackStream,
    isTuningNode: isTuningNode,
    playbackStreams: playbackStreams,
    friendlyStreamLabel: friendlyStreamLabel,
    streamLabelIsGeneric: streamLabelIsGeneric,
    rawStreamLabel: rawStreamLabel,
    mprisPlayerLabel: mprisPlayerLabel,
    streamRepresentsMprisPlayer: streamRepresentsMprisPlayer,
    matchingMprisStreamLabel: matchingMprisStreamLabel,
    unmatchedMprisStreamLabel: unmatchedMprisStreamLabel,
    streamLabel: streamLabel,
    sortPlaybackStreams: sortPlaybackStreams,
    listSnapshot: listSnapshot,
    sameNodeList: sameNodeList,
    anyAudible: anyAudible,
    outputGlyph: outputGlyph,
    sinkGlyph: sinkGlyph,
    sourceGlyph: sourceGlyph
};

if (typeof module !== "undefined" && module.exports)
    module.exports = exported;
