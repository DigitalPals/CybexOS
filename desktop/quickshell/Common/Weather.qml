pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "ProcHelpers.js" as ProcHelpers

// Open-Meteo backed weather state for the bar chip + popover. No API key;
// location and cadence come from the weather module's settings (the old
// QS_WEATHER_* env vars are seeded into them once by Settings).
Singleton {
    id: root

    readonly property string latitude: String(Settings.modOpts.weather.lat)
    readonly property string longitude: String(Settings.modOpts.weather.lon)
    readonly property string place: Settings.modOpts.weather.place
    // The shipped default is 0°N 0°E, open sea in the Gulf of Guinea, and
    // the place name is only a label: without coordinates there is no
    // forecast worth fetching, and views say where to set them instead.
    readonly property bool locationSet: Number(Settings.modOpts.weather.lat) !== 0
        || Number(Settings.modOpts.weather.lon) !== 0

    // The menubar widget needs a current sky all the time; an open Day
    // sheet holds a claim for as long as it shows one. Nothing else polls.
    readonly property bool widgetOn: {
        const mods = Settings.mods;
        for (const col of ["left", "center", "right"]) {
            const hit = mods[col].find(m => m.id === "weather");
            if (hit)
                return hit.on;
        }
        return false;
    }
    property int watchers: 0
    readonly property bool wanted: locationSet && (widgetOn || watchers > 0)

    // A view arriving with nothing fresh to draw fetches at once.
    function acquire() {
        watchers++;
        if (NetworkStatus.online && locationSet && stale(600000))
            refresh();
    }

    function release() {
        watchers = Math.max(0, watchers - 1);
    }

    // Whether the forecast on hand is missing, failed, for another request
    // (location or unit), or older than `maxAgeMs`.
    function stale(maxAgeMs) {
        return !ready || fetchError !== "" || fetchedUrl !== url
            || Date.now() - updatedAt >= maxAgeMs;
    }

    readonly property int pollIntervalSecs: Settings.modOpts.weather.pollMins * 60
    property int consecutiveFailures: 0
    readonly property int retryIntervalSecs: Math.min(pollIntervalSecs,
        Math.min(15 * 60, 30 * Math.pow(2, Math.max(0, consecutiveFailures - 1))))

    // Three states, and consumers need all three apart. `ready` stays true
    // once a forecast has ever landed, so it is "there is something to
    // draw", not "the last fetch worked":
    //   !ready && !offline  — the first fetch has not come back yet
    //   !ready && offline   — nothing to draw and no way to get it
    //   ready && offline    — the last known sky, now going stale
    property bool ready: false
    // Why the last fetch failed, "" while it is working.
    property string fetchError: ""
    readonly property bool offline: fetchError !== ""
        || (NetworkStatus.known && !NetworkStatus.online)
    readonly property string unavailableReason: fetchError !== "" ? fetchError
        : NetworkStatus.known && !NetworkStatus.online
            ? "waiting for a network connection" : ""
    property double updatedAt: 0
    property int temp: 0
    property int feels: 0
    property int humidity: 0
    property int windKmh: 0
    property string windDir: ""
    property string condition: ""
    property int code: -1
    property bool isDay: true
    // [{ day, code, lo, hi }] — today plus four days out.
    property var days: []

    readonly property string url: "https://api.open-meteo.com/v1/forecast"
        + "?latitude=" + latitude + "&longitude=" + longitude
        + "&current=temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m,wind_direction_10m,is_day"
        + "&daily=weather_code,temperature_2m_max,temperature_2m_min"
        + "&timezone=auto&forecast_days=5"
        + (Settings.unit === "f" ? "&temperature_unit=fahrenheit" : "")

    Connections {
        target: Settings

        function onUnitChanged() {
            if (NetworkStatus.online && root.wanted)
                root.refresh(true);
        }

        // Any modOpts write lands here; only refetch when it moved the
        // request (location change), not on unrelated module options.
        function onModOptsChanged() {
            if (NetworkStatus.online && root.wanted && root.url !== root.fetchedUrl)
                root.refresh(true);
        }
    }

    Connections {
        target: NetworkStatus

        function onOnlineChanged() {
            if (!NetworkStatus.online)
                return;
            root.consecutiveFailures = 0;
            // A flapping link should not refetch a forecast that is still
            // fresh; a failed, missing or relocated one is fetched at once.
            // While idle, the resume check below does it instead.
            if (!root.wanted || Activity.idle || !root.stale(600000))
                return;
            root.refresh(true);
        }
    }

    Connections {
        target: Activity

        function onResumed() {
            if (NetworkStatus.online && root.wanted
                    && root.stale(root.pollIntervalSecs * 1000))
                root.refresh();
        }
    }

    onWantedChanged: {
        if (wanted && NetworkStatus.online && !Activity.idle && stale(600000))
            refresh();
    }

    // Coordinates cleared back to the default: the old sky belongs to a
    // place that is no longer configured, so it goes rather than lingers.
    onLocationSetChanged: {
        if (locationSet)
            return;
        if (fetchProc.running) {
            fetchProc.staleRuns++;
            fetchProc.running = false;
        }
        ready = false;
        fetchError = "";
        consecutiveFailures = 0;
        fetchedUrl = "";
        updatedAt = 0;
        code = -1;
        condition = "";
        days = [];
    }

    function describe(code) {
        if (code === 0)
            return "Clear sky";
        if (code === 1)
            return "Mostly clear";
        if (code === 2)
            return "Partly cloudy";
        if (code === 3)
            return "Overcast";
        if (code === 45 || code === 48)
            return "Fog";
        if (code >= 51 && code <= 57)
            return "Drizzle";
        if (code >= 61 && code <= 67)
            return "Rain";
        if (code >= 71 && code <= 77)
            return "Snow";
        if (code >= 80 && code <= 82)
            return "Rain showers";
        if (code === 85 || code === 86)
            return "Snow showers";
        if (code >= 95)
            return "Thunderstorm";
        return "—";
    }

    // Semantic icon name for a WMO code. Kept in the same code order as
    // glyphColor() below so a mark and its tint cannot disagree about the sky.
    function symbol(code, day) {
        if (code < 0)
            return "cloud_off";
        if (code === 0)
            return day ? "clear_day" : "bedtime";
        if (code === 1 || code === 2)
            return day ? "partly_cloudy_day" : "partly_cloudy_night";
        if (code === 3)
            return "cloud";
        if (code === 45 || code === 48)
            return "foggy";
        if (code >= 51 && code <= 57)
            return "rainy_light";
        if (code >= 61 && code <= 67)
            return "rainy";
        if (code >= 71 && code <= 77)
            return "weather_snowy";
        if (code >= 80 && code <= 82)
            return "rainy_heavy";
        if (code === 85 || code === 86)
            return "weather_snowy";
        if (code >= 95)
            return "thunderstorm";
        return "cloud";
    }

    // Kept in the same code order as symbol() so a mark and its tint never
    // disagree about what the sky is doing.
    function glyphColor(code, day) {
        if (code < 0)
            return Theme.textDim;
        if (code <= 2)
            return day ? Theme.wxSun : Theme.wxMoon;
        if (code === 3)
            return Theme.wxCloud;
        if (code === 45 || code === 48)
            return Theme.wxFog;
        if (code >= 51 && code <= 67)
            return Theme.wxRain;
        if (code >= 71 && code <= 77)
            return Theme.wxSnow;
        if (code >= 80 && code <= 82)
            return Theme.wxRain;
        if (code === 85 || code === 86)
            return Theme.wxSnow;
        if (code >= 95)
            return Theme.wxStorm;
        return Theme.textDim;
    }

    // The menubar can use a fixed/custom colour independent of the shell's
    // light/dark palette, so its weather mark needs the parallel bar tones.
    function barGlyphColor(code, day) {
        if (code < 0)
            return Theme.barTextDim;
        if (code <= 2)
            return day ? Theme.barWxSun : Theme.barWxMoon;
        if (code === 3)
            return Theme.barWxCloud;
        if (code === 45 || code === 48)
            return Theme.barWxFog;
        if (code >= 51 && code <= 67)
            return Theme.barWxRain;
        if (code >= 71 && code <= 77)
            return Theme.barWxSnow;
        if (code >= 80 && code <= 82)
            return Theme.barWxRain;
        if (code === 85 || code === 86)
            return Theme.barWxSnow;
        if (code >= 95)
            return Theme.barWxStorm;
        return Theme.barTextDim;
    }

    function compass(deg) {
        return ["N", "NE", "E", "SE", "S", "SW", "W", "NW"][Math.round(deg / 45) % 8];
    }

    // True when the body was a forecast this shell could read.
    function apply(text) {
        if (text.trim() === "")
            return false;
        try {
            const d = JSON.parse(text);
            const cur = d.current;
            temp = Math.round(cur.temperature_2m);
            feels = Math.round(cur.apparent_temperature);
            humidity = Math.round(cur.relative_humidity_2m);
            windKmh = Math.round(cur.wind_speed_10m);
            windDir = compass(cur.wind_direction_10m);
            code = cur.weather_code;
            isDay = cur.is_day === 1;
            condition = describe(cur.weather_code);
            const out = [];
            for (let i = 0; i < d.daily.time.length; i++) {
                out.push({
                    day: new Date(d.daily.time[i] + "T12:00:00").toLocaleDateString(Qt.locale("en_US"), "ddd"),
                    code: d.daily.weather_code[i],
                    lo: Math.round(d.daily.temperature_2m_min[i]),
                    hi: Math.round(d.daily.temperature_2m_max[i])
                });
            }
            days = out;
            updatedAt = Date.now();
            ready = true;
            return true;
        } catch (e) {
            console.warn("weather parse failed:", e);
            return false;
        }
    }

    property string fetchedUrl: ""

    function refresh(replaceRunning) {
        // Poll/retry timers do not cancel useful in-flight I/O. A changed
        // location, unit or network generation does, because its response is
        // no longer the request the UI is waiting for.
        if (fetchProc.running && replaceRunning !== true)
            return;
        fetchedUrl = url;
        if (fetchProc.running) {
            fetchProc.staleRuns++;
            fetchProc.running = false;
        }
        fetchProc.running = true;
    }

    // Everything a finished fetch has to say, in one place: the body when the
    // request worked, ProcHelpers.NOT_STARTED when curl never ran.
    function settle(exitCode, body, errText) {
        if (exitCode === 0 && apply(body)) {
            fetchError = "";
            consecutiveFailures = 0;
            return;
        }
        const reason = exitCode === 0
            ? "open-meteo sent a forecast this shell could not read"
            : ProcHelpers.commandError("curl", exitCode, errText, ProcHelpers.CURL_EXIT);
        // The retry timer runs every 30s until a forecast lands, so log the
        // transition rather than every attempt.
        if (fetchError !== reason)
            console.warn("weather unavailable:", reason);
        fetchError = reason;
        consecutiveFailures++;
    }

    Process {
        id: fetchProc
        // `curl -sf` says nothing at all when it fails: -s silences the error
        // text and -f empties the body on an HTTP error, so the exit status
        // is the entire report. It arrives after both streams close, and on
        // the falling edge of `running` even when curl never started.
        //
        // Runs killed by refresh() have yet to report in: their exit lands as
        // a crash some time after the replacement started, and is not news.
        property int staleRuns: 0
        property string body: ""
        property string errText: ""
        property bool exitSeen: false
        property int lastExit: 0

        command: ["curl", "-sf", "--max-time", "15", root.url]

        stdout: StdioCollector {
            onStreamFinished: fetchProc.body = text
        }
        stderr: StdioCollector {
            onStreamFinished: fetchProc.errText = text
        }
        onExited: (exitCode, exitStatus) => {
            fetchProc.exitSeen = true;
            fetchProc.lastExit = exitCode;
        }
        onRunningChanged: {
            if (running) {
                body = "";
                errText = "";
                exitSeen = false;
                lastExit = 0;
            } else if (staleRuns > 0) {
                staleRuns--;
            } else {
                root.settle(exitSeen ? lastExit : ProcHelpers.NOT_STARTED, body, errText);
            }
        }
    }

    // Neither poll runs for a forecast nobody is shown, nor while idle.
    Timer {
        interval: root.pollIntervalSecs * 1000
        running: NetworkStatus.online && root.wanted && !Activity.idle
        repeat: true
        onTriggered: root.refresh()
    }

    // Retry quickly while Wi-Fi is settling, then back off exponentially to
    // avoid hammering a failing endpoint. The normal poll remains the ceiling.
    Timer {
        interval: root.retryIntervalSecs * 1000
        running: NetworkStatus.online && root.wanted && !Activity.idle
            && (!root.ready || root.fetchError !== "")
        repeat: true
        onTriggered: root.refresh()
    }

    Component.onCompleted: {
        if (NetworkStatus.online && wanted)
            refresh();
    }
}
