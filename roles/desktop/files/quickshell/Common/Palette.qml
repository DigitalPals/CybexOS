pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "PaletteHelpers.js" as PaletteHelpers
import "ProcHelpers.js" as ProcHelpers

// Wallpaper-derived Material tonal-spot palette. The cache always holds both
// light and dark variants, so switching theme mode is a property selection —
// never another Matugen invocation. It keeps the most recent wallpapers,
// keyed by path plus mtime and size, and nothing runs while the fixed
// palette is selected.
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
    property string activeStamp: ""

    readonly property color background: active.background || "#121318"
    readonly property color surface: active.surface || (Settings.themeMode === "light"
        ? "#ffffff" : "#161424")
    readonly property color surfaceContainerLow: active.surfaceContainerLow
        || (Settings.themeMode === "light" ? "#eeedf3" : "#171526")
    readonly property color surfaceContainer: active.surfaceContainer
        || (Settings.themeMode === "light" ? "#fcfcff" : "#1a182c")
    readonly property color surfaceContainerHigh: active.surfaceContainerHigh
        || (Settings.themeMode === "light" ? "#e6e4ec" : "#292637")
    // Material's on-* roles are held as *Ink. QML reads a member named "on"
    // plus a capital as a signal handler, and one that shadows a sibling
    // property (onSurface beside surface, onPrimary beside primary) silently
    // stayed at its default, black, which made every wallpaper palette's
    // copy a grey computed from black and its accent ink pure black.
    readonly property color surfaceInk: active.onSurface
        || (Settings.themeMode === "light" ? "#1c1a2e" : "#f5f4fb")
    readonly property color surfaceVariantInk: active.onSurfaceVariant
        || (Settings.themeMode === "light" ? "#4a4860" : "#a1a0a9")
    readonly property color primary: active.primary || Settings.effectiveAccent
    readonly property color primaryContainer: active.primaryContainer
        || Settings.effectiveAccent
    readonly property color primaryInk: active.onPrimary || "#ffffff"
    readonly property color outlineVariant: active.outlineVariant
        || (Settings.themeMode === "light" ? "#c6c4cc" : "#45434f")
    readonly property color errorRole: active.error
        || (Settings.themeMode === "light" ? "#c22f2f" : "#ff8f8f")
    readonly property color errorContainer: active.errorContainer
        || (Settings.themeMode === "light" ? "#ffdad6" : "#93000a")
    readonly property color errorInk: active.onError
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
        if (Settings.paletteMode !== "wallpaper") {
            variants = null;
            ready = false;
            busy = false;
            error = "";
            queuedIdentity = "";
            return;
        }
        if (identity === "" || Settings.wall === "") {
            variants = null;
            ready = false;
            busy = false;
            error = "No wallpaper is selected";
            return;
        }
        // A palette cached for this path is shown straight away; the queued
        // stat below then confirms the file is still the one it was made
        // from before anything is regenerated.
        const cached = PaletteHelpers.readCache(cacheStore.text(), identity);
        if (cached) {
            usePalette(identity, cached);
        } else {
            // Drop the previous wallpaper immediately. Theme renders its
            // fixed fallback until this identity has a complete, validated
            // result.
            variants = null;
            ready = false;
            error = "";
            busy = true;
        }
        queuedIdentity = identity;
        generationTimer.restart();
    }

    function startQueued() {
        if (statProc.running || paletteProc.running || queuedIdentity === "")
            return;
        if (queuedIdentity !== wallpaperIdentity) {
            queuedIdentity = wallpaperIdentity;
            generationTimer.restart();
            return;
        }
        activeIdentity = queuedIdentity;
        queuedIdentity = "";
        statProc.command = ["stat", "-L", "-c", "%Y %s", "--", activeIdentity];
        statProc.running = true;
    }

    // A request that arrived while a stage was running only queued itself;
    // go round again for whatever is current now.
    function drainQueue() {
        if (queuedIdentity !== "")
            Qt.callLater(requestCurrent);
    }

    function finishStat(output) {
        const identity = activeIdentity;
        if (!PaletteHelpers.resultIsCurrent(identity, wallpaperIdentity)
                || Settings.paletteMode !== "wallpaper") {
            activeIdentity = "";
            Qt.callLater(requestCurrent);
            return;
        }
        // An unreadable file has no fingerprint; Matugen then reports why.
        const stamp = PaletteHelpers.fingerprint(output);
        const cached = stamp !== ""
            ? PaletteHelpers.readCache(cacheStore.text(), identity, stamp) : null;
        if (cached) {
            activeIdentity = "";
            usePalette(identity, cached);
            drainQueue();
            return;
        }
        variants = null;
        ready = false;
        error = "";
        busy = true;
        activeStamp = stamp;
        // Bounded so an image Matugen chokes on cannot leave `busy` stuck.
        paletteProc.command = ["timeout", "20s"].concat(["matugen", "image", activeIdentity,
            "--type", "scheme-tonal-spot", "--dry-run", "--json", "hex", "--quiet"]);
        paletteProc.running = true;
    }

    function finishGeneration(exitCode, output) {
        const completedIdentity = activeIdentity;
        const completedStamp = activeStamp;
        activeIdentity = "";
        activeStamp = "";
        const current = PaletteHelpers.resultIsCurrent(completedIdentity,
            wallpaperIdentity) && Settings.paletteMode === "wallpaper";
        if (exitCode === 0) {
            const palette = PaletteHelpers.sanitizeMatugen(output);
            if (palette) {
                const serialized = PaletteHelpers.serializeCache(completedIdentity,
                    palette, completedStamp, cacheStore.text());
                if (serialized !== "") {
                    try {
                        cacheStore.setText(serialized);
                    } catch (cacheError) {
                        console.warn("wallpaper palette cache write failed:", cacheError);
                    }
                }
                if (current)
                    usePalette(completedIdentity, palette);
            } else if (current) {
                ready = false;
                busy = false;
                error = "Matugen returned an invalid palette";
                console.warn("wallpaper palette output was malformed");
            }
        } else if (current) {
            ready = false;
            busy = false;
            // `timeout` reports 124 when it had to stop Matugen and 127 when
            // Matugen itself is missing.
            error = exitCode === ProcHelpers.NOT_STARTED || exitCode === 127
                ? "Matugen is not installed"
                : exitCode === 124 ? "Matugen timed out"
                : "Could not generate the wallpaper palette";
            console.warn("wallpaper palette generation failed:", exitCode);
        }
        if ((!current && !ready) || queuedIdentity !== "")
            Qt.callLater(requestCurrent);
    }

    Timer {
        id: generationTimer
        interval: 180
        onTriggered: root.startQueued()
    }

    // Only the falling edge of `running` is guaranteed, so both stages settle
    // there; a stat that could not start simply yields no fingerprint.
    Process {
        id: statProc

        stdout: StdioCollector {
            id: statOut
        }

        onRunningChanged: {
            if (!running && root.activeIdentity !== "")
                root.finishStat(statOut.text);
        }
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

    Connections {
        target: Settings

        function onPaletteModeChanged() {
            root.requestCurrent();
        }
    }

    Component.onCompleted: requestCurrent()
}
