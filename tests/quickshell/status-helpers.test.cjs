const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { load } = require("./shell.cjs");

const H = load("StatusHelpers.js");

function player(identity, desktopEntry = "", extra = {}) {
    return {
        identity,
        desktopEntry,
        isPlaying: false,
        playbackState: H.PLAYBACK_STATE.Stopped,
        ...extra,
    };
}

// ---- percentages ---------------------------------------------------------

test("percentages normalize whichever scale the backend reports", () => {
    assert.equal(H.normalizePercent(0.42), 42);
    assert.equal(H.normalizePercent(1), 100);
    assert.equal(H.normalizePercent(42), 42);
    assert.equal(H.normalizePercent(100), 100);
    assert.equal(H.normalizePercent(0), 0);
});

test("battery percent falls back to zero rather than to an unusable reading", () => {
    assert.equal(H.batteryPercent({ percentage: 0.735 }), 73.5);
    assert.equal(H.batteryPercent({ percentage: 73.5 }), 73.5);
    assert.equal(H.batteryPercent(null), 0);
    assert.equal(H.batteryPercent(undefined), 0);
    assert.equal(H.batteryPercent({}), 0);
});

test("signal percent rounds and keeps -1 for an unknown strength", () => {
    assert.equal(H.signalPercent(0.674), 67);
    assert.equal(H.signalPercent(67.4), 67);
    assert.equal(H.signalPercent(0), 0);
    assert.equal(H.signalPercent(undefined), -1);
    assert.equal(H.signalPercent(null), -1);
    // Never NaN: the popover scales icon opacity by this value.
    assert.equal(H.signalPercent("weak"), -1);
});

// ---- battery -------------------------------------------------------------

test("charge state separates active charging, preservation and full", () => {
    const state = H.BATTERY_STATE;
    assert.equal(H.chargeState({ state: state.Charging }), "charging");
    assert.equal(H.chargeState({ state: state.PendingCharge }), "pending-charge");
    assert.equal(H.chargeState({ state: state.FullyCharged }), "full");
    assert.equal(H.chargeState({ state: state.Discharging }), "discharging");
    assert.equal(H.chargeState({ state: state.PendingDischarge }), "discharging");
    assert.equal(H.chargeState({ state: state.Empty }), "discharging");
    assert.equal(H.chargeState({ state: state.Unknown }), "discharging");
    assert.equal(H.chargeState(null), "discharging");
});

test("power source is independent of charge state and preservation is explained", () => {
    const paused = { state: H.BATTERY_STATE.PendingCharge };
    assert.equal(H.isPluggedIn(paused), true);
    assert.equal(H.isPluggedIn(paused, true), false);
    assert.equal(H.isPluggedIn({ state: H.BATTERY_STATE.Discharging }, false), true);
    assert.equal(H.batteryStatus("pending-charge", true, true), "Plugged in · Charge limited");
    assert.equal(H.batteryStatus("pending-charge", true, false), "Plugged in · Not charging");
    assert.equal(H.batteryStatus("charging", true, true), "Charging");
    assert.equal(H.batteryStatus("full", true, true), "Fully charged");
    assert.equal(H.batteryStatus("pending-charge", false, true), "On battery");
});

test("bar and popover agree: a full battery is plugged in but not charging", () => {
    const full = { state: H.BATTERY_STATE.FullyCharged };
    assert.equal(H.chargeState(full) === "charging", false);
    assert.equal(H.isPluggedIn(full), true);
    assert.equal(H.isPluggedIn({ state: H.BATTERY_STATE.Charging }), true);
    assert.equal(H.isPluggedIn({ state: H.BATTERY_STATE.Discharging }), false);
    assert.equal(H.isPluggedIn(null), false);
});

// ---- media ---------------------------------------------------------------

test("player glyphs cover every source the bar and the popover can show", () => {
    const glyph = H.PLAYER_GLYPH;
    assert.equal(H.playerGlyph(player("Spotify", "spotify")), glyph.spotify);
    assert.equal(H.playerGlyph(player("Firefox", "firefox")), glyph.firefox);
    assert.equal(H.playerGlyph(player("Zen Browser", "zen")), glyph.firefox);
    assert.equal(H.playerGlyph(player("Chromium", "chromium")), glyph.chromium);
    assert.equal(H.playerGlyph(player("Brave", "brave-browser")), glyph.chromium);
    assert.equal(H.playerGlyph(player("Microsoft Edge", "msedge")), glyph.edge);
    assert.equal(H.playerGlyph(player("YouTube Music", "youtube-music")), glyph.youtube);
    assert.equal(H.playerGlyph(player("mpv", "mpv")), glyph.video);
    assert.equal(H.playerGlyph(player("VLC media player", "vlc")), glyph.video);
    assert.equal(H.playerGlyph(player("Rhythmbox", "rhythmbox")), glyph.generic);
    assert.equal(H.playerGlyph(null), glyph.generic);
});

test("player glyphs match on the desktop entry and ignore case", () => {
    assert.equal(H.playerGlyph(player("", "org.mozilla.firefox")), H.PLAYER_GLYPH.firefox);
    assert.equal(H.playerGlyph(player("SPOTIFY", "")), H.PLAYER_GLYPH.spotify);
});

test("a browser playing a YouTube tab keeps its browser mark", () => {
    // The branch order is what decides this, so it is worth pinning: a
    // Chrome PWA identifies as YouTube Music but is still Chrome.
    assert.equal(
        H.playerGlyph(player("YouTube Music", "chrome-youtube-music")),
        H.PLAYER_GLYPH.chromium);
    assert.equal(
        H.playerGlyph(player("Firefox", "firefox", { trackTitle: "youtube" })),
        H.PLAYER_GLYPH.firefox);
});

test("media brands recognize YouTube webapps from their MPRIS URL", () => {
    assert.equal(H.playerBrand(player("Brave", "", {
        dbusName: "org.mpris.MediaPlayer2.brave.instance42",
        metadata: { "xesam:url": "https://www.youtube.com/watch?v=abc" },
    })), "youtube");
    assert.equal(H.playerBrand(player("Brave", "brave-browser", {
        metadata: { "xesam:url": "https://music.youtube.com/watch?v=abc" },
    })), "youtube");
    assert.equal(H.playerBrand(player("YouTube Music", "chrome-youtube-music")),
        "youtube");
    assert.equal(H.playerBrand(player("Brave", "brave-browser", {
        metadata: { "xesam:url": "https://example.com/youtube.com/watch" },
    })), "");
});

test("player icon candidates bridge MPRIS names to installed desktop entries", () => {
    assert.deepEqual(H.playerIconCandidates(player("Spotify", "spotify")),
        ["spotify", "com.spotify.Client"]);
    assert.deepEqual(H.playerIconCandidates(player("Brave", "")),
        ["brave-browser", "Brave"]);
    assert.deepEqual(H.playerIconCandidates(player("Firefox", "org.mozilla.firefox")),
        ["org.mozilla.firefox", "Firefox"]);
    assert.deepEqual(H.playerIconCandidates(player("Rhythmbox", "rhythmbox")),
        ["rhythmbox"]);
    assert.deepEqual(H.playerIconCandidates(null), []);
});

test("the active player is playing, else paused, else the first known", () => {
    const stopped = player("Rhythmbox");
    const paused = player("Firefox", "firefox", {
        playbackState: H.PLAYBACK_STATE.Paused,
    });
    const playing = player("Spotify", "spotify", {
        isPlaying: true,
        playbackState: H.PLAYBACK_STATE.Playing,
    });

    assert.equal(H.activePlayer([stopped, paused, playing]), playing);
    assert.equal(H.activePlayer([stopped, paused]), paused);
    assert.equal(H.activePlayer([stopped]), stopped);
    assert.equal(H.activePlayer([]), null);
    assert.equal(H.activePlayer(undefined), null);
});

// ---- enum mirrors --------------------------------------------------------
//
// The two enums above are mirrored numerically so the helpers stay free of Qt
// imports. Check them against the installed type information, so a
// Quickshell upgrade that renumbers either one fails here rather than silently
// reporting the wrong battery state. The gate requires Quickshell (CI installs
// it too), so a missing type file is a broken install, not a reason to skip.

function qmlRoot() {
    const candidates = [
        process.env.QT_INSTALL_QML,
        "/usr/lib64/qt6/qml",
        "/usr/lib/qt6/qml",
    ];
    return candidates.find(dir => dir && fs.existsSync(dir)) ?? null;
}

function enumValues(file, component) {
    const source = fs.readFileSync(file, "utf8");
    const block = source.slice(source.indexOf(`name: "${component}"`));
    assert.ok(block !== "", `${component} missing from ${file}`);
    const match = block.match(/values:\s*\[([^\]]*)\]/);
    assert.ok(match, `${component} declares no plain enum value list`);
    const names = match[1].match(/"([^"]+)"/g).map(name => name.slice(1, -1));
    return Object.fromEntries(names.map((name, index) => [name, index]));
}

const root = qmlRoot();
const skip = root === null ? "Qt QML directory not found" : false;

test("the mirrored UPower device states match the installed enum", { skip }, () => {
    const file = path.join(root, "Quickshell/Services/UPower",
        "quickshell-service-upower.qmltypes");
    assert.ok(fs.existsSync(file), `${file} missing (dnf install quickshell)`);
    assert.deepEqual(
        enumValues(file, "qs::service::upower::UPowerDeviceState"),
        H.BATTERY_STATE);
});

test("the mirrored Mpris playback states match the installed enum", { skip }, () => {
    const file = path.join(root, "Quickshell/Services/Mpris",
        "quickshell-service-mpris.qmltypes");
    assert.ok(fs.existsSync(file), `${file} missing (dnf install quickshell)`);
    assert.deepEqual(
        enumValues(file, "qs::service::mpris::MprisPlaybackState"),
        H.PLAYBACK_STATE);
});
