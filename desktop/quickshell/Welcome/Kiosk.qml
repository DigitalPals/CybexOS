pragma Singleton
import QtQuick
import Quickshell

// The installer's design tokens, so the welcome guide continues the screen
// people just installed with. The colours are installer/kiosk/ui/theme.slint
// verbatim (welcome-kiosk.test.cjs keeps them equal) and do not follow the
// desktop's theme: the guide is drawn in the fixed brand palette, and the
// Style step previews the user's own choice instead.
//
// Every length is written in the installer's 1280×800 design pixels and
// drawn through px(), which applies the zoom WelcomeWindow derives from the
// screen with the installer's rule (installer/kiosk/src/zoom.rs).
Singleton {
    readonly property color bg: "#1a1b1e"
    readonly property color bgDeep: "#141517"
    readonly property color card: "#202125"
    readonly property color card2: "#26272c"
    readonly property color line: "#2f3136"
    readonly property color line2: "#3b3d43"
    readonly property color ink: "#f3f2ec"
    readonly property color fog: "#a6a8a1"
    readonly property color faint: "#6e7069"
    readonly property color accent: "#60a5fa"
    readonly property color accentInk: "#1a1b1e"
    readonly property color accentTint: "#2060a5fa"
    readonly property color accentSoft: "#1460a5fa"
    readonly property color red: "#ff6b57"
    readonly property color redTint: "#14ff6b57"
    readonly property color redLine: "#59ff6b57"
    readonly property color amber: "#f2c14e"
    readonly property color amberTint: "#1ff2c14e"
    readonly property color scrim: "#9e0a0a0b"
    readonly property color boot: "#0d0d0d"
    // From the design reference's CSS (installer/ui-reference/index.html):
    // the selected-card ring, a selected row's edge and the focused field glow.
    readonly property color accentRing: "#1a60a5fa"
    readonly property color accentLine: "#5960a5fa"
    readonly property color accentGlow: "#2960a5fa"
    readonly property color amberLine: "#66f2c14e"

    readonly property string sans: "Space Grotesk"
    readonly property string mono: "JetBrains Mono"

    // Design pixels to logical pixels on the guide's screen.
    property real zoom: 1
    function px(value: real): real { return value * zoom; }

    // installer/kiosk/src/zoom.rs: the 1280×800 canvas fitted to the panel's
    // physical pixels, two decimals. Two differences: the guide rounds down,
    // so the canvas never overflows the screen (1440×900 gives 1.12 where the
    // installer's 1.13 crops 3 px a side), and it goes down to 0.6 instead of
    // 0.8, so a small screen still shows all of it.
    function zoomFor(width: real, height: real, ratio: real): real {
        const scale = ratio > 0 ? ratio : 1;
        if (width <= 0 || height <= 0)
            return 1;
        const fit = Math.min(width / 1280, height / 800) * scale;
        return Math.floor(Math.max(0.6, Math.min(3, fit)) * 100 + 1e-6) / 100 / scale;
    }
}
