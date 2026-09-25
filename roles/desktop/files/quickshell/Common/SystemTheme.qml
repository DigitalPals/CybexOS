pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "." as Common
import "Format.js" as Format
import "ProcHelpers.js" as ProcHelpers
import "SettingsHelpers.js" as SettingsHelpers

// Carries the shell's resolved appearance to the rest of the desktop: the
// terminal, compositor, GTK and the lock screen. Theme has already chosen
// between the fixed and wallpaper palettes and applied its contrast floors, so
// this exports those results rather than a second design. scripts/
// theme-apply.py renders them into ~/.local/state/cybexos/theme and reloads
// only the applications whose files changed (docs/system-theme.md).
Singleton {
    id: root

    // Nothing is exported until settings have loaded and, in wallpaper mode,
    // a palette generation in flight has finished; otherwise every login and
    // wallpaper change would flash the fixed palette through every app.
    readonly property bool settled: Settings.loaded
        && !(Settings.paletteMode === "wallpaper" && Common.Palette.busy
            && !Common.Palette.ready)

    // Colours leave as opaque "#rrggbb": Theme's translucent tokens are
    // flattened over the base they are drawn on.
    function hex(value) {
        const c = Qt.color(value);
        return "#" + [c.r, c.g, c.b].map(channel =>
            Math.round(Format.clamp01(channel) * 255)
                .toString(16).padStart(2, "0")).join("");
    }

    function flatten(value, base) {
        const c = Qt.color(value);
        return SettingsHelpers.mixHex(hex(base), hex(c), c.a);
    }

    readonly property var tokens: ({
        v: 1,
        mode: Common.Theme.dark ? "dark" : "light",
        source: Common.Theme.paletteActive ? "wallpaper" : "fixed",
        colors: {
            background: hex(Common.Theme.background),
            surface: hex(Common.Theme.popBg),
            surfaceRaised: hex(Common.Theme.menuBg),
            bar: hex(Common.Theme.barBg),
            text: hex(Common.Theme.textHi),
            textMuted: hex(Common.Theme.textMid),
            textDim: hex(Common.Theme.textDim),
            accent: hex(Common.Theme.accent),
            onAccent: hex(Common.Theme.accentFg),
            accentText: hex(Common.Theme.accentText),
            accentContainer: hex(Common.Theme.accentContainer),
            stroke: flatten(Common.Theme.stroke, Common.Theme.background),
            red: hex(Common.Theme.redText),
            amber: hex(Common.Theme.amber),
            green: hex(Common.Theme.ok)
        },
        font: {ui: Common.Theme.fontMenu, mono: Common.Theme.fontMono},
        radius: Common.Theme.surfaceRadius,
        glass: Common.Theme.glassActive,
        wallpaper: Settings.wall !== "" ? Common.Wallpaper.currentIdentity : ""
    })
    readonly property string serialized: JSON.stringify(tokens)

    // What the last run reported, for `theme status` and Settings.
    property string appliedSerialized: ""
    property var lastReport: null
    property string error: ""
    property bool forceNext: false

    function apply(force) {
        if (force)
            forceNext = true;
        if (settled)
            applyTimer.restart();
    }

    function start() {
        if (!settled || applyProc.running)
            return;
        if (!forceNext && serialized === appliedSerialized)
            return;
        applyProc.force = forceNext;
        applyProc.payload = serialized;
        forceNext = false;
        applyProc.command = ["python3", Quickshell.shellDir + "/scripts/theme-apply.py", "apply"]
            .concat(applyProc.force ? ["--force"] : []);
        applyProc.running = true;
    }

    function status() {
        return JSON.stringify({settled: settled, applied: appliedSerialized === serialized,
            running: applyProc.running, error: error, report: lastReport});
    }

    // Dragging the accent hue or stepping through wallpapers changes the
    // tokens many times a second; only the value that stays is rendered.
    Timer {
        id: applyTimer
        interval: 400
        onTriggered: root.start()
    }

    onSerializedChanged: apply(false)
    onSettledChanged: apply(false)

    Process {
        id: applyProc
        property string payload: ""
        property bool force: false
        property string body: ""
        property bool exitSeen: false
        property int lastExit: 0

        stdinEnabled: true
        stdout: StdioCollector { onStreamFinished: applyProc.body = text }
        stderr: StdioCollector {}
        onStarted: write(payload + "\n")
        onExited: exitCode => {
            exitSeen = true;
            lastExit = exitCode;
        }
        onRunningChanged: {
            if (running) {
                body = "";
                exitSeen = false;
                lastExit = 0;
                return;
            }
            const code = exitSeen ? lastExit : ProcHelpers.NOT_STARTED;
            let report = null;
            try {
                report = JSON.parse(body);
            } catch (e) {
                report = null;
            }
            root.lastReport = report;
            // A failure is reported, not retried: retrying the same tokens
            // would fail the same way, and the next change of appearance (or
            // `theme apply`) runs every target again anyway.
            root.appliedSerialized = payload;
            if (report && typeof report === "object") {
                const failed = Object.keys(report.targets || {})
                    .filter(name => report.targets[name].error)
                    .map(name => name + ": " + report.targets[name].error);
                root.error = report.error || failed.join("; ");
            } else {
                root.error = code === ProcHelpers.NOT_STARTED
                    ? "could not start the theme renderer"
                    : "the theme renderer failed (exit " + code + ")";
            }
            if (root.error !== "")
                console.warn("system theme:", root.error);
            if (root.serialized !== root.appliedSerialized || root.forceNext)
                applyTimer.restart();
        }
    }
}
