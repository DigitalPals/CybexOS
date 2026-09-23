pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "PaletteHelpers.js" as PaletteHelpers
import "ProcHelpers.js" as ProcHelpers

// Wallpaper-derived Material tonal-spot palette. The cache always holds both
// light and dark variants, so switching theme mode is a property selection —
// never another Matugen invocation.
Singleton {
    id: root

    readonly property string cachePath:
        Quickshell.env("HOME") + "/.local/state/cybexos/shell/wallpaper-palette.json"
    readonly property string wallpaperIdentity: Wallpaper.currentIdentity
    property var variants: null
    readonly property var active: PaletteHelpers.activeVariant(variants,
        Settings.themeMode) || ({})
    property bool ready: false
    property bool busy: false
    property string error: ""
    property string queuedIdentity: ""
    property string activeIdentity: ""

    readonly property color background: active.background || "#121318"
    readonly property color surface: active.surface || (Settings.themeMode === "light"
        ? "#ffffff" : "#161424")
    readonly property color surfaceContainerLow: active.surfaceContainerLow
        || (Settings.themeMode === "light" ? "#eeedf3" : "#171526")
    readonly property color surfaceContainer: active.surfaceContainer
        || (Settings.themeMode === "light" ? "#fcfcff" : "#1a182c")
    readonly property color surfaceContainerHigh: active.surfaceContainerHigh
        || (Settings.themeMode === "light" ? "#e6e4ec" : "#292637")
    readonly property color onSurface: active.onSurface
        || (Settings.themeMode === "light" ? "#1c1a2e" : "#f5f4fb")
    readonly property color onSurfaceVariant: active.onSurfaceVariant
        || (Settings.themeMode === "light" ? "#4a4860" : "#a1a0a9")
    readonly property color primary: active.primary || Settings.effectiveAccent
    readonly property color primaryContainer: active.primaryContainer
        || Settings.effectiveAccent
    readonly property color onPrimary: active.onPrimary || "#ffffff"
    readonly property color outlineVariant: active.outlineVariant
        || (Settings.themeMode === "light" ? "#c6c4cc" : "#45434f")
    readonly property color errorRole: active.error
        || (Settings.themeMode === "light" ? "#c22f2f" : "#ff8f8f")
    readonly property color errorContainer: active.errorContainer
        || (Settings.themeMode === "light" ? "#ffdad6" : "#93000a")
    readonly property color onError: active.onError
        || (Settings.themeMode === "light" ? "#ffffff" : "#690005")

    function usePalette(identity, palette) {
        if (!PaletteHelpers.resultIsCurrent(identity, wallpaperIdentity))
            return false;
        variants = palette;
        ready = true;
        busy = false;
        error = "";
        queuedIdentity = "";
        return true;
    }

    function requestCurrent() {
        const identity = wallpaperIdentity;
        generationTimer.stop();
        if (identity === "" || Settings.wall === "") {
            variants = null;
            ready = false;
            busy = false;
            error = "No wallpaper is selected";
            return;
        }
        const cached = PaletteHelpers.readCache(cacheStore.text(), identity);
        if (cached) {
            queuedIdentity = "";
            usePalette(identity, cached);
            return;
        }
        // Drop the previous wallpaper immediately. Theme renders its fixed
        // fallback until this identity has a complete, validated result.
        variants = null;
        ready = false;
        error = "";
        queuedIdentity = identity;
        busy = true;
        generationTimer.restart();
    }

    function startQueued() {
        if (paletteProc.running || queuedIdentity === "")
            return;
        if (queuedIdentity !== wallpaperIdentity) {
            queuedIdentity = wallpaperIdentity;
            generationTimer.restart();
            return;
        }
        activeIdentity = queuedIdentity;
        queuedIdentity = "";
        paletteProc.command = ["matugen", "image", activeIdentity,
            "--type", "scheme-tonal-spot", "--dry-run", "--json", "hex", "--quiet"];
        paletteProc.running = true;
    }

    function queueLatest() {
        queuedIdentity = wallpaperIdentity;
        busy = true;
        generationTimer.restart();
    }

    function finishGeneration(exitCode, output) {
        const completedIdentity = activeIdentity;
        activeIdentity = "";
        const current = PaletteHelpers.resultIsCurrent(completedIdentity,
            wallpaperIdentity);
        if (exitCode === 0) {
            const palette = PaletteHelpers.sanitizeMatugen(output);
            if (palette && current) {
                usePalette(completedIdentity, palette);
                const serialized = PaletteHelpers.serializeCache(completedIdentity,
                    palette);
                if (serialized !== "") {
                    try {
                        cacheStore.setText(serialized);
                    } catch (cacheError) {
                        console.warn("wallpaper palette cache write failed:", cacheError);
                    }
                }
            } else if (!palette && current) {
                ready = false;
                busy = false;
                error = "Matugen returned an invalid palette";
                console.warn("wallpaper palette output was malformed");
            }
        } else if (current) {
            ready = false;
            busy = false;
            error = exitCode === ProcHelpers.NOT_STARTED
                ? "Matugen is not installed"
                : "Could not generate the wallpaper palette";
            console.warn("wallpaper palette generation failed:", exitCode);
        }
        if (((!current && !ready) || queuedIdentity !== "")
                && wallpaperIdentity !== "")
            Qt.callLater(queueLatest);
    }

    Timer {
        id: generationTimer
        interval: 180
        onTriggered: root.startQueued()
    }

    Process {
        id: paletteProc
        property bool exitSeen: false
        property int lastExit: 0

        stdout: StdioCollector {
            id: paletteOut
        }

        onExited: exitCode => {
            exitSeen = true;
            lastExit = exitCode;
        }
        onRunningChanged: {
            if (running) {
                exitSeen = false;
                lastExit = 0;
                return;
            }
            if (root.activeIdentity !== "")
                root.finishGeneration(exitSeen ? lastExit : ProcHelpers.NOT_STARTED,
                    paletteOut.text);
        }
    }

    FileView {
        id: cacheStore
        path: root.cachePath
        printErrors: false
        atomicWrites: true
        blockWrites: true
        blockLoading: true
        onLoaded: root.requestCurrent()
        onLoadFailed: root.requestCurrent()
    }

    Connections {
        target: Wallpaper

        function onCurrentIdentityChanged() {
            root.requestCurrent();
        }
    }

    Component.onCompleted: requestCurrent()
}
