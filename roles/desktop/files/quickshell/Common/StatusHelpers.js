// Pure status helpers shared by the bar and its popovers: percentage
// normalization, battery charge semantics, media player selection and marks.
// Keep this file free of Qt APIs so the same logic stays testable under Node.
//
// The battery and media functions take the service object itself (or null)
// rather than pre-read values: QML captures property reads made inside an
// imported helper, so a binding on `chargeState(device)` still re-evaluates
// when the device's state changes.

// ---- percentages ---------------------------------------------------------

// UPower reports 0..100 while some devices report 0..1, and Networking's
// signalStrength arrives 0..1 in this backend, so a value at or below 1 is
// read as a fraction. A literal 1% therefore reads as 100% — the same trade
// the three call sites each made separately before this was shared.
function normalizePercent(value) {
    var number = Number(value);
    if (!isFinite(number))
        return NaN;
    return number <= 1 ? number * 100 : number;
}

// Charge level of a UPower device, unrounded. No device (or an unreadable
// reading) is 0, so consumers can bind this straight to a real property.
function batteryPercent(device) {
    if (!device)
        return 0;
    var pct = normalizePercent(device.percentage);
    return isFinite(pct) ? pct : 0;
}

// Wi-Fi signal as whole percent, with -1 for "no reading" so callers can
// tell an unknown strength from a genuine 0%.
function signalPercent(strength) {
    if (strength === undefined || strength === null)
        return -1;
    var pct = normalizePercent(strength);
    return isFinite(pct) ? Math.round(pct) : -1;
}

// ---- battery -------------------------------------------------------------

// org.freedesktop.UPower.Device's published State values, which Quickshell's
// UPowerDeviceState enum mirrors. Kept numeric so this module needs no Qt
// import; status-helpers.test.cjs pins them against the installed qmltypes.
var BATTERY_STATE = {
    Unknown: 0,
    Charging: 1,
    Discharging: 2,
    Empty: 3,
    FullyCharged: 4,
    PendingCharge: 5,
    PendingDischarge: 6
};

// The single definition of charge semantics for bar and popover. "full" is
// deliberately distinct from "charging" — the popover names the two states
// apart while the bar draws both as plugged in — and everything else,
// including having no battery at all, counts as running on battery.
function chargeState(device) {
    var state = device ? device.state : undefined;
    if (state === BATTERY_STATE.Charging || state === BATTERY_STATE.PendingCharge)
        return "charging";
    if (state === BATTERY_STATE.FullyCharged)
        return "full";
    return "discharging";
}

// Charging or already full: what the bar's glyph and accent color mean.
function isPluggedIn(device) {
    return chargeState(device) !== "discharging";
}

// ---- media ---------------------------------------------------------------

// Quickshell's MprisPlaybackState enum; pinned by the same qmltypes test as
// BATTERY_STATE above.
var PLAYBACK_STATE = {
    Stopped: 0,
    Playing: 1,
    Paused: 2
};

// Semantic Tabler icon names. Players are
// identified by media type: a browser
// gets the globe, a video player the film mark, everything else the note.
var PLAYER_GLYPH = {
    spotify: "graphic_eq",
    firefox: "public",
    chromium: "public",
    edge: "public",
    youtube: "smart_display",
    video: "movie",
    generic: "music_note"
};

function textValue(value) {
    return value === undefined || value === null ? "" : String(value);
}

function playerIdentity(player) {
    if (!player)
        return "";
    return (textValue(player.identity) + " "
        + textValue(player.desktopEntry) + " "
        + textValue(player.dbusName)).toLowerCase();
}

// Browser MPRIS players identify as the browser even for an --app window.
// xesam:url is the one reliable distinction for the YouTube webapp used here.
function playerBrand(player) {
    if (!player)
        return "";
    if (playerIdentity(player).includes("youtube"))
        return "youtube";
    var metadata = player.metadata || {};
    var url = textValue(metadata["xesam:url"]).toLowerCase();
    if (/(?:^|:\/\/)(?:[^./]+\.)?(?:youtube\.com|youtu\.be)(?:[\/:?#]|$)/.test(url))
        return "youtube";
    return "";
}

// Names to try against Quickshell's desktop-entry index. The MPRIS hint wins,
// then known package ids bridge players whose hint is only a short name (the
// Spotify Flatpak says `spotify`, for example), and the display identity is a
// final heuristic for everything else.
function playerIconCandidates(player) {
    if (!player)
        return [];

    var candidates = [];
    function add(value) {
        value = textValue(value).trim();
        if (value !== "" && !candidates.some(function (candidate) {
            return candidate.toLowerCase() === value.toLowerCase();
        }))
            candidates.push(value);
    }

    add(player.desktopEntry);
    var id = playerIdentity(player);
    if (id.includes("spotify"))
        add("com.spotify.Client");
    if (id.includes("brave"))
        add("brave-browser");
    if (id.includes("firefox"))
        add("org.mozilla.firefox");
    if (id.includes("chromium"))
        add("chromium");
    if (id.includes("chrome"))
        add("google-chrome");
    if (id.includes("edge") || id.includes("msedge"))
        add("microsoft-edge");
    add(player.identity);
    return candidates;
}

// Which mark a player gets in the bar chip and in the popover's source
// switcher. Order matters: a browser playing a YouTube tab keeps its browser
// mark, and only players naming YouTube themselves take the YouTube one.
function playerGlyph(player) {
    if (!player)
        return PLAYER_GLYPH.generic;
    var id = playerIdentity(player);
    if (id.includes("spotify"))
        return PLAYER_GLYPH.spotify;
    if (id.includes("firefox") || id.includes("zen"))
        return PLAYER_GLYPH.firefox;
    if (id.includes("chromium") || id.includes("chrome") || id.includes("brave"))
        return PLAYER_GLYPH.chromium;
    if (id.includes("edge"))
        return PLAYER_GLYPH.edge;
    if (id.includes("youtube"))
        return PLAYER_GLYPH.youtube;
    if (id.includes("mpv") || id.includes("vlc") || id.includes("video"))
        return PLAYER_GLYPH.video;
    return PLAYER_GLYPH.generic;
}

// The player the shell speaks for: whatever is playing, else whatever is
// paused, else the first one known. The popover prepends its own manual
// source override and falls back to exactly this.
function activePlayer(players) {
    if (!players || players.length === 0)
        return null;
    var playing = players.find(function (player) {
        return player.isPlaying;
    });
    if (playing !== undefined)
        return playing;
    var paused = players.find(function (player) {
        return player.playbackState === PLAYBACK_STATE.Paused;
    });
    return paused !== undefined ? paused : players[0];
}

var exported = {
    normalizePercent: normalizePercent,
    batteryPercent: batteryPercent,
    signalPercent: signalPercent,
    BATTERY_STATE: BATTERY_STATE,
    chargeState: chargeState,
    isPluggedIn: isPluggedIn,
    PLAYBACK_STATE: PLAYBACK_STATE,
    PLAYER_GLYPH: PLAYER_GLYPH,
    playerBrand: playerBrand,
    playerIconCandidates: playerIconCandidates,
    playerGlyph: playerGlyph,
    activePlayer: activePlayer
};

if (typeof module !== "undefined" && module.exports)
    module.exports = exported;
