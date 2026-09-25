pragma Singleton
import QtQuick
import Quickshell
import "." as Common
import "SettingsHelpers.js" as SettingsHelpers
import "ShellMetrics.js" as ShellMetrics
import "Typography.js" as Typography

// Design tokens for the glass menubar ("QuickShell Menubar" redesign).
//
// Shell surfaces can be translucent over compositor blur or opaque. The
// `dark*` / `light*` literals below are the fixed reference palettes; semantic
// surface tokens choose glass or solid, and semantic color tokens keep views
// from knowing which variant is active.
//
// The opaque colors are also the glass surfaces' contrast references. Solid
// mode draws them through semantic aliases; views never paint them directly.
Singleton {
    id: root

    // Qt does not currently expose the platform's reduced-motion preference
    // through QStyleHints. Honour an explicit service/session override instead
    // and route every shared motion token through it. Power saver asks for
    // the same thing for the battery's sake: a transition that does not run
    // is frames the bars never redraw.
    readonly property string reducedMotionValue:
        (Quickshell.env("QS_REDUCED_MOTION") || "").trim().toLowerCase()
    readonly property bool reducedMotion:
        Settings.reducedMotion || Activity.powerSaver
        || ["1", "true", "yes", "on"].includes(reducedMotionValue)
    readonly property var metrics: ShellMetrics.calculate(Settings)
    readonly property real typeScale: metrics.fontScale
    readonly property real densityScale: metrics.density
    readonly property real contentScale: metrics.spacingScale
    readonly property int fontBaseSize: metrics.fontBase
    function scaled(value, scale) {
        return Math.round(value * (scale === undefined ? contentScale : scale));
    }

    function fitWidth(preferred, available, margin) {
        return ShellMetrics.fitWidth(preferred, available, margin || 0);
    }

    readonly property bool dark: Settings.themeMode !== "light"
    readonly property bool paletteActive:
        Settings.paletteMode === "wallpaper" && Common.Palette.ready

    // ---- reference surfaces (opaque; used for contrast math) --------------
    // The dark references are the edge-drawer redesign's warm charcoal: the
    // panel surface matches the default bar colour exactly, so an attached
    // drawer and the bar read as one continuous slab.
    //
    // Light mode mirrors that layering instead of inverting it: the large
    // surfaces (the default bar, its attached panels, dialogs) rest on a soft
    // grey near L* 93, and only small raised things — menus, a selected
    // segment — come up toward white. Near-white slabs read as glare at
    // desktop scale, and without a darker base nothing can look raised.
    readonly property color darkBackground: "#1a1917"
    readonly property color lightBackground: "#eae9ef"
    readonly property color darkPopBg: "#201e1b"
    readonly property color lightPopBg: "#f1f0f5"
    readonly property color background: paletteActive
        ? (dark ? Common.Palette.background : Common.Palette.surfaceContainerHigh)
        : dark ? darkBackground : lightBackground
    readonly property color popBg: paletteActive ? Common.Palette.surfaceContainerLow
        : dark ? darkPopBg : lightPopBg
    readonly property color darkMenuBg: "#26241f"
    readonly property color lightMenuBg: "#f8f7fa"
    readonly property color menuBg: paletteActive
        ? (dark ? Common.Palette.surfaceContainer : Common.Palette.surface)
        : dark ? darkMenuBg : lightMenuBg
    // The least favorable opaque backdrop for copy. In dark mode that is the
    // highest (lightest) container. In light mode it is the base with a
    // hovered chip on it: the darkest thing copy is drawn over. Calibrating
    // the shared copy colors here keeps one semantic ladder safe on every
    // panel, menu, and group surface.
    readonly property color copyReferenceBg: dark
        ? (paletteActive ? Common.Palette.surfaceContainerHigh : popBg)
        : SettingsHelpers.mixHex(background.toString(),
            lightInk.toString(),
            chipHoverAlpha)
    // The bar background is always the user's explicit bar-color choice.
    // Wallpaper mode still supplies accent/status colors, but never replaces
    // this surface. This is also the exact solid-mode fill.
    readonly property color barBg: Settings.effectiveBarColor

    // ---- glass ------------------------------------------------------------
    // The bar is the lighter glass; panels sit a step denser so copy stays
    // readable over a busy wallpaper.
    readonly property color glass: Qt.rgba(barBg.r, barBg.g, barBg.b,
        dark ? 0.52 : 0.55)
    readonly property color glassStrong: Qt.rgba(popBg.r, popBg.g, popBg.b,
        dark ? 0.72 : 0.80)
    // Menus that float above a panel need to stay legible over it.
    readonly property color glassMenu: Qt.rgba(menuBg.r, menuBg.g, menuBg.b,
        dark ? 0.88 : 0.92)
    // A dialog is the menubar unrolled rather than a card stacked on it, so it
    // takes the shell's deepest surface and lets the hairlines and the chip
    // fills below carry every group inside it. Denser than `glass` for the
    // same reason `glassStrong` is: it holds long copy over a busy wallpaper.
    readonly property color glassPanel: Qt.rgba(background.r, background.g,
        background.b, dark ? 0.72 : 0.80)
    // Rendering uses semantic surface tokens. The raw glass colours above
    // remain the translucent variants; disabling glass swaps in opaque
    // references without making nested chip/tile fills opaque.
    readonly property bool glassActive: Settings.glassEnabled && !Settings.highContrast
    readonly property color barSurface: glassActive ? glass : barBg
    readonly property color surfaceStrong: glassActive ? glassStrong : popBg
    readonly property color surfaceMenu: glassActive ? glassMenu : menuBg
    readonly property color panelSurface: glassActive ? glassPanel : background
    // Full-screen scrim behind the shortcut sheet. It dims in both modes: a
    // pale wash in light mode brightened the whole screen behind a modal.
    readonly property color scrim: dark
        ? Qt.rgba(10 / 255, 8 / 255, 22 / 255, 0.42)
        : Qt.rgba(24 / 255, 22 / 255, 44 / 255, 0.28)

    // Hairlines. Light mode draws them in ink: a white line on a pale
    // surface is invisible, and every edge then melts into one white field.
    readonly property color stroke: Settings.highContrast
        ? (dark ? Qt.rgba(1, 1, 1, 0.42) : Qt.rgba(0, 0, 0, 0.44))
        : paletteActive ? Common.Palette.outlineVariant
        : dark ? Qt.rgba(1, 1, 1, 0.13) : Qt.rgba(24 / 255, 22 / 255, 44 / 255, 0.13)
    readonly property color popBorder: stroke
    readonly property color hairline: stroke
    readonly property color hairlineSoft: paletteActive
        ? Qt.rgba(Common.Palette.outlineVariant.r, Common.Palette.outlineVariant.g,
            Common.Palette.outlineVariant.b, 0.32)
        : dark ? Qt.rgba(1, 1, 1, 0.05)
        : Qt.rgba(24 / 255, 22 / 255, 44 / 255, 0.06)

    // ---- menubar palette -------------------------------------------------
    // A chosen bar colour may deliberately disagree with the shell's global
    // light/dark mode. Derive its own foreground ladder so a white bar in a
    // dark shell (or the reverse) remains readable. The helper floors every
    // copy-bearing step at 4.5:1 against barBg.
    readonly property var barPalette: SettingsHelpers.barPalette(barBg.toString())
    readonly property bool barLightForeground:
        SettingsHelpers.relativeLuminance(barPalette.foreground) > 0.5
    readonly property color barTextHi: barPalette.textHi
    readonly property color barTextMid: barPalette.textMid
    readonly property color barTextLow: barPalette.textLow
    readonly property color barTextDim: barPalette.textDim
    readonly property color barTextFaint: barPalette.textFaint
    // Bright, cool resting ink shared by generic and product bar marks.
    readonly property color barIcon: barPalette.icon
    // The screenshot's workspace strip is the bar's clearest accent: a pale
    // blue current chip, quiet occupied labels, then tiny empty dots. Keep
    // those roles adaptive while restoring that hierarchy.
    readonly property color barWsCurrent: barAccent
    readonly property color barWsCurrentFg: barAccentFg
    readonly property color barWsCurrentGlow: barAccentGlow
    readonly property color barWsOccupied: barTextLow
    readonly property color barWsEmpty: barDotDim
    readonly property color barDotDim: barLightForeground
        ? Qt.rgba(1, 1, 1, 0.30) : Qt.rgba(0, 0, 0, 0.26)
    readonly property color barStroke: barLightForeground
        ? Qt.rgba(1, 1, 1, 0.13) : Qt.rgba(0, 0, 0, 0.14)
    readonly property color barChip: barLightForeground
        ? Qt.rgba(1, 1, 1, 0.05) : Qt.rgba(0, 0, 0, 0.05)
    readonly property color barChipHover: barLightForeground
        ? Qt.rgba(1, 1, 1, 0.09) : Qt.rgba(0, 0, 0, 0.09)

    readonly property color barAccent: SettingsHelpers.ensureContrast(
        paletteActive ? Common.Palette.primary.toString() : Settings.effectiveAccent,
        barBg.toString(), 4.5)
    readonly property var barAccentPalette: SettingsHelpers.barPalette(
        barAccent.toString())
    readonly property color barAccentFg: paletteActive
        ? SettingsHelpers.ensureContrast(Common.Palette.onPrimary.toString(),
            barAccent.toString(), 4.5) : barAccentPalette.foreground
    readonly property color barAccentGlow: Qt.rgba(
        barAccent.r, barAccent.g, barAccent.b, 0.50)
    readonly property color barRed: SettingsHelpers.ensureContrast(
        barLightForeground ? "#ff8f8f" : "#c22f2f",
        barBg.toString(), 4.5)
    readonly property var barRedPalette: SettingsHelpers.barPalette(barRed)
    readonly property color barRedFg: barRedPalette.foreground
    readonly property color barRedText: barRed
    readonly property color barAmber: SettingsHelpers.ensureContrast(
        barLightForeground ? "#ffc26e" : "#b5761e",
        barBg.toString(), 4.5)
    readonly property var barAmberPalette: SettingsHelpers.barPalette(barAmber)
    readonly property color barAmberFg: barAmberPalette.foreground
    readonly property color barGreen: SettingsHelpers.ensureContrast(
        barLightForeground ? "#63d68c" : "#1f9d57",
        barBg.toString(), 4.5)
    readonly property color barRedBg: Qt.rgba(
        barRedText.r, barRedText.g, barRedText.b, 0.18)
    readonly property color barAmberBg: Qt.rgba(
        barAmber.r, barAmber.g, barAmber.b, barLightForeground ? 0.17 : 0.14)

    readonly property color barWxSun: SettingsHelpers.ensureContrast(
        "#ffc26e", barBg.toString(), 4.5)
    readonly property color barWxMoon: SettingsHelpers.ensureContrast(
        "#bfc6da", barBg.toString(), 4.5)
    readonly property color barWxCloud: SettingsHelpers.ensureContrast(
        barLightForeground ? "#a8b0c4" : "#5c6377",
        barBg.toString(), 4.5)
    readonly property color barWxFog: SettingsHelpers.ensureContrast(
        barLightForeground ? "#949aa8" : "#5f6572",
        barBg.toString(), 4.5)
    readonly property color barWxRain: SettingsHelpers.ensureContrast(
        "#6ab0ea", barBg.toString(), 4.5)
    readonly property color barWxSnow: SettingsHelpers.ensureContrast(
        barLightForeground ? "#c8e2f5" : "#4a8fbe",
        barBg.toString(), 4.5)
    readonly property color barWxStorm: SettingsHelpers.ensureContrast(
        "#a992e0", barBg.toString(), 4.5)

    // ---- fills ------------------------------------------------------------
    // chip: a resting pill inside the bar. chipHover: the same pill lit, and
    // the open/held state. tile: a recessed block inside a panel.
    //
    // Light mode draws all three as ink over whatever surface is below —
    // Material's state-layer approach — in both palette modes. Tonal
    // container fills could not recess: on the light base the highest
    // container is the base itself, so hover and tiles disappeared.
    readonly property color lightInk: paletteActive ? Common.Palette.onSurface : "#18162c"
    readonly property real chipAlpha: 0.07
    readonly property real chipHoverAlpha: 0.13
    readonly property real tileAlpha: 0.06
    readonly property color chip: dark
        ? (paletteActive
            ? Qt.rgba(Common.Palette.surfaceContainer.r, Common.Palette.surfaceContainer.g,
                Common.Palette.surfaceContainer.b, 0.56)
            : Qt.rgba(1, 1, 1, 0.08))
        : Qt.rgba(lightInk.r, lightInk.g, lightInk.b, chipAlpha)
    readonly property color chipHover: dark
        ? (paletteActive
            ? Qt.rgba(Common.Palette.surfaceContainerHigh.r, Common.Palette.surfaceContainerHigh.g,
                Common.Palette.surfaceContainerHigh.b, 0.74)
            : Qt.rgba(1, 1, 1, 0.16))
        : Qt.rgba(lightInk.r, lightInk.g, lightInk.b, chipHoverAlpha)
    readonly property color tile: dark
        ? (paletteActive
            ? Qt.rgba(Common.Palette.surfaceContainerHigh.r, Common.Palette.surfaceContainerHigh.g,
                Common.Palette.surfaceContainerHigh.b, 0.62)
            : Qt.rgba(1, 1, 1, 0.09))
        : Qt.rgba(lightInk.r, lightInk.g, lightInk.b, tileAlpha)
    // The chosen option of a settings segmented control, raised out of its
    // chip-filled track: lighter than the track in dark mode, near white in
    // light mode, so the selection reads without borrowing the accent.
    readonly property color segmentSelected: dark
        ? Qt.rgba(1, 1, 1, 0.13) : Qt.rgba(1, 1, 1, 0.94)
    // Occupied workspace pips are functional state, not decorative furniture:
    // keep them well above dotDim while the focused pip remains uniquely accent.
    readonly property color wsOccupied: dark
        ? Qt.rgba(1, 1, 1, 0.72) : Qt.rgba(28 / 255, 26 / 255, 46 / 255, 0.62)

    // Aliases, so every popover keeps reading one vocabulary. There are no
    // cards left in the shell's dialogs, so the names that used to mean "a
    // container with a fill and a border" now mean the resting chip the
    // menubar draws: the same recessed step, without the container.
    readonly property color hoverFill: chip
    readonly property color hoverFillStrong: chipHover
    readonly property color activeFill: chip
    readonly property color cardFill: chip
    readonly property color insetSurface: chip

    // ---- text -------------------------------------------------------------
    // The design's --txt3 lands at 3.2:1 over the panel reference, below the
    // 4.5:1 floor this shell holds itself to. The low three steps are lifted
    // to the lightest value that clears AA and are verified by
    // tests/quickshell/typography.test.cjs; `dotDim` is the one decorative
    // token and must never carry copy.
    readonly property color darkTextHi: "#f2f0ea"
    readonly property color darkTextMid: "#b3afa4"
    readonly property color darkTextLow: "#a29e93"
    readonly property color darkTextDim: "#97938a"
    readonly property color darkTextFaint: "#8e8a7f"
    readonly property color darkIcon: "#c8c5bb"

    // The light ladder is held against `lightBackground` under a hovered
    // chip, the darkest surface copy sits on, rather than a lighter panel.
    readonly property color lightTextHi: "#1f1d2b"
    readonly property color lightTextMid: "#43415a"
    readonly property color lightTextLow: "#4f4d64"
    readonly property color lightTextDim: "#535168"
    readonly property color lightTextFaint: "#57556c"
    readonly property color lightIcon: "#37354c"

    readonly property var textPalette: paletteActive
        ? SettingsHelpers.semanticPalette(copyReferenceBg.toString(),
            Common.Palette.onSurface.toString(), Common.Palette.onSurfaceVariant.toString())
        : null
    readonly property color textHi: paletteActive ? textPalette.textHi
        : dark ? darkTextHi : lightTextHi
    readonly property color textMid: paletteActive ? textPalette.textMid
        : dark ? darkTextMid : lightTextMid
    readonly property color textLow: paletteActive ? textPalette.textLow
        : dark ? darkTextLow : lightTextLow
    readonly property color textDim: paletteActive ? textPalette.textDim
        : dark ? darkTextDim : lightTextDim
    readonly property color textFaint: paletteActive ? textPalette.textFaint
        : dark ? darkTextFaint : lightTextFaint
    readonly property color icon: paletteActive ? textPalette.icon
        : dark ? darkIcon : lightIcon
    // Decorative only — empty workspace pips and inactive rails.
    readonly property color dotDim: dark
        ? Qt.rgba(245 / 255, 244 / 255, 251 / 255, 0.30)
        : Qt.rgba(28 / 255, 26 / 255, 46 / 255, 0.26)
    // Copy drawn on top of the accent or on a photographic tile.
    readonly property color textOnAccent: accentFg

    // ---- accent and status -------------------------------------------------
    readonly property color accent: paletteActive ? Common.Palette.primary
        : Settings.effectiveAccent
    // Pale chosen accents are valid fills, but cannot also be readable ink
    // on light panels. Keep the user's color and resolve copy independently.
    readonly property color accentText: SettingsHelpers.ensureContrast(
        accent.toString(), copyReferenceBg.toString(), 4.5)
    // Derived rather than fixed white: the redesign's chartreuse accent needs
    // dark ink on it, and any pale fixed accent has the same problem.
    readonly property color accentFg: paletteActive
        ? SettingsHelpers.ensureContrast(Common.Palette.onPrimary.toString(),
            accent.toString(), 4.5)
        : (SettingsHelpers.foregroundFor(accent.toString()) === "#ffffff"
            ? "#ffffff" : "#1c1c12")
    // Full accent belongs on small state marks. Large selected controls use a
    // calmer opaque container mixed into the panel reference, so a vivid fixed
    // choice or wallpaper palette cannot turn broad UI areas fluorescent.
    readonly property color accentContainer: SettingsHelpers.mixHex(
        popBg.toString(), accent.toString(), dark ? 0.46 : 0.30)
    readonly property color accentContainerFg: SettingsHelpers.foregroundFor(
        accentContainer.toString())
    readonly property color accentSoft: paletteActive
        ? Qt.rgba(Common.Palette.primaryContainer.r, Common.Palette.primaryContainer.g,
            Common.Palette.primaryContainer.b, 0.72)
        : Qt.rgba(accent.r, accent.g, accent.b, 0.24)
    readonly property color accentGlow: Qt.rgba(accent.r, accent.g, accent.b, 0.50)
    readonly property color accentBg: accentSoft
    readonly property color accentBgSoft: paletteActive
        ? Qt.rgba(Common.Palette.primaryContainer.r, Common.Palette.primaryContainer.g,
            Common.Palette.primaryContainer.b, 0.42)
        : Qt.rgba(accent.r, accent.g, accent.b, 0.12)
    readonly property color accentHover: Qt.lighter(accent, 1.25)

    readonly property color red: paletteActive ? Common.Palette.errorRole : "#ff6b6b"
    readonly property color redText: paletteActive
        ? SettingsHelpers.ensureContrast(Common.Palette.errorRole.toString(),
            copyReferenceBg.toString(), 4.5) : dark ? "#ff8f8f" : "#c22f2f"
    readonly property color redBg: paletteActive
        ? Qt.rgba(Common.Palette.errorContainer.r, Common.Palette.errorContainer.g,
            Common.Palette.errorContainer.b, 0.68)
        : Qt.rgba(1, 107 / 255, 107 / 255, 0.18)
    readonly property color redBgSoft: paletteActive
        ? Qt.rgba(Common.Palette.errorContainer.r, Common.Palette.errorContainer.g,
            Common.Palette.errorContainer.b, 0.42)
        : Qt.rgba(1, 107 / 255, 107 / 255, 0.10)
    readonly property color redBorder: paletteActive ? Common.Palette.outlineVariant
        : Qt.rgba(1, 107 / 255, 107 / 255, 0.38)

    readonly property color amber: SettingsHelpers.ensureContrast(
        dark ? "#ffc26e" : "#b5761e", copyReferenceBg.toString(), 4.5)
    readonly property color amberBg: dark
        ? Qt.rgba(1, 194 / 255, 110 / 255, 0.17)
        : Qt.rgba(181 / 255, 118 / 255, 30 / 255, 0.14)
    readonly property color amberBgSoft: dark
        ? Qt.rgba(1, 194 / 255, 110 / 255, 0.09)
        : Qt.rgba(181 / 255, 118 / 255, 30 / 255, 0.08)
    readonly property color amberBorder: dark
        ? Qt.rgba(1, 194 / 255, 110 / 255, 0.38)
        : Qt.rgba(181 / 255, 118 / 255, 30 / 255, 0.35)

    readonly property color ok: SettingsHelpers.ensureContrast(
        dark ? "#63d68c" : "#1f9d57", copyReferenceBg.toString(), 4.5)
    readonly property color connected: ok
    readonly property color okBg: dark
        ? Qt.rgba(99 / 255, 214 / 255, 140 / 255, 0.16)
        : Qt.rgba(31 / 255, 157 / 255, 87 / 255, 0.14)
    readonly property color okBgSoft: dark
        ? Qt.rgba(99 / 255, 214 / 255, 140 / 255, 0.10)
        : Qt.rgba(31 / 255, 157 / 255, 87 / 255, 0.08)
    readonly property color okBorder: dark
        ? Qt.rgba(99 / 255, 214 / 255, 140 / 255, 0.30)
        : Qt.rgba(31 / 255, 157 / 255, 87 / 255, 0.30)

    // The update run's transaction feed. The tags keep the terminal update
    // script's cyan/pink source identity, recalibrated for the panel; `well`
    // is the one recessed console surface, the only fill that sits below the
    // tile instead of above it.
    readonly property color feedDnf: SettingsHelpers.ensureContrast(
        dark ? "#6cc7ec" : "#1d7fae", copyReferenceBg.toString(), 4.5)
    readonly property color feedFlatpak: SettingsHelpers.ensureContrast(
        dark ? "#e98fd2" : "#a83d8a", copyReferenceBg.toString(), 4.5)
    readonly property color well: dark
        ? Qt.rgba(16 / 255, 14 / 255, 28 / 255, 0.55)
        : Qt.rgba(24 / 255, 22 / 255, 44 / 255, 0.05)

    // Accent at an arbitrary alpha, for the few fills outside the standard
    // tints. Tracks the settings accent like accentSoft does.
    function accentAlpha(alpha) {
        return Qt.rgba(accent.r, accent.g, accent.b, alpha);
    }

    readonly property real stateHoverOpacity: 0.08
    readonly property real statePressedOpacity: 0.12

    // Weather icon tints — the one place the bar carries real colour, so
    // they stay a shade below full saturation to sit inside the palette.
    readonly property color wxSun: SettingsHelpers.ensureContrast(
        "#ffc26e", copyReferenceBg.toString(), 4.5)
    readonly property color wxMoon: SettingsHelpers.ensureContrast(
        "#bfc6da", copyReferenceBg.toString(), 4.5)
    readonly property color wxCloud: SettingsHelpers.ensureContrast(
        dark ? "#a8b0c4" : "#5c6377", copyReferenceBg.toString(), 4.5)
    readonly property color wxFog: SettingsHelpers.ensureContrast(
        dark ? "#949aa8" : "#5f6572", copyReferenceBg.toString(), 4.5)
    readonly property color wxRain: SettingsHelpers.ensureContrast(
        "#6ab0ea", copyReferenceBg.toString(), 4.5)
    readonly property color wxSnow: SettingsHelpers.ensureContrast(
        dark ? "#c8e2f5" : "#4a8fbe", copyReferenceBg.toString(), 4.5)
    readonly property color wxStorm: SettingsHelpers.ensureContrast(
        "#a992e0", copyReferenceBg.toString(), 4.5)

    // ---- typography --------------------------------------------------------
    // One face for the whole shell. `fontMenu` is settings-driven — the family
    // strings live in SettingsHelpers.FONT_CHOICES so the picker and this token
    // agree — and every surface draws through it: the bar, the panels hanging
    // off it, the launcher, the toasts and the overlays. `fontSans` is the
    // shipped default that `fontMenu` falls back to, and nothing draws it
    // directly; a view that named it would be opting out of the setting.
    readonly property string fontSans: "JetBrainsMono Nerd Font"
    readonly property string fontMenu: {
        const choice = Settings.fontChoices.find(f => f.id === Settings.font);
        return choice ? choice.family : fontSans;
    }
    readonly property string fontMono: "JetBrainsMono Nerd Font"
    // Numeric readings — the clock, percentages, meters, resets. The
    // edge-drawer redesign sets these in Geist Mono against Figtree UI copy,
    // so a reading is recognisably an instrument value rather than prose.
    readonly property string fontNumeric: Settings.font === "mono" ? fontMono : "Geist Mono"
    // Bundled Tabler icons. Sym owns name resolution, font loading and the
    // consistent outline rendering; views must not draw icon codepoints directly.
    readonly property string fontIcon: "Cybex Tabler Outline"

    // One library owns the scale AND its usage by native and plugin surfaces.
    readonly property var typography: Typography.resolve(fontBaseSize)
    // Compatibility aliases; new views select a named typography usage role.
    readonly property int fontMicro: typography.metadata
    readonly property int fontTiny: typography.secondary
    readonly property int fontCaption: typography.caption
    readonly property int fontSecondary: typography.secondary
    readonly property int fontBody: typography.primary
    readonly property int fontHeading: typography.heading
    readonly property int fontProminent: typography.title
    readonly property int fontDisplay: typography.display
    readonly property int fontHero: typography.displayLarge
    // Monospaced faces set wider than they are tall, so a measure that reads
    // comfortably at 1.45 in the proportional faces runs together in JetBrains
    // Mono. The step is per-face rather than global: raising it for everyone
    // would loosen prose that is already correct.
    readonly property real proseLineHeight: Settings.font === "mono" ? 1.55 : 1.45

    // Standard font weights match Omarchy's regular copy and bold headings.
    readonly property int weightRegular: 400
    readonly property int weightMedium: 500
    readonly property int weightSemibold: 600
    readonly property int weightBold: 700
    readonly property int weightHeavy: 750

    readonly property int iconTiny: scaled(11, typeScale)
    readonly property int iconSmall: scaled(13, typeScale)
    readonly property int iconMedium: scaled(16, typeScale)
    readonly property int iconLarge: scaled(20, typeScale)
    readonly property int iconHero: scaled(27, typeScale)

    // Bar labels share the body baseline used by controls and plugins.
    readonly property int barTextSize: typography.bar
    readonly property int barLabelSize: typography.bar
    readonly property int barIconSize: scaled(15, typeScale)
    readonly property var tabularNumberFeatures: ({ "tnum": 1 })

    // ---- metrics -----------------------------------------------------------
    // Bar geometry is settings-driven. Hug and attached styles meet the
    // screen edge; floating restores the screenshot's slightly wider side
    // inset while continuing to use the configurable gap and radius.
    readonly property int barHeight: Math.max(Settings.barHeight, chipHeight + 8)
    readonly property bool barFloating: Settings.barStyle === "floating"
    readonly property bool barHug: Settings.barStyle === "hug"
    readonly property int barTopMargin: barFloating ? Settings.gap : 0
    readonly property int barSideMargin: barFloating ? Settings.gap + 4 : 0
    readonly property int clusterRadius: barFloating ? Settings.barRadius : 0
    // One corner system for compositor windows and every non-pill shell
    // surface. Semantic aliases below keep call sites descriptive while the
    // geometry stays aligned with the Hug corners.
    readonly property int surfaceRadius: 16
    readonly property int hugCornerSize: surfaceRadius
    // Inner gutter either side of the bar's content, and the gap between the
    // three sections.
    readonly property int barPadding: 6
    readonly property int barSpacing: 4

    // Compact controls reproduce the original 22–26px rhythm while the
    // outer slab remains independently height-adjustable.
    readonly property int chipHeight: scaled(28)
    readonly property int chipInnerHeight: scaled(24)
    readonly property int chipRadius: 7
    readonly property int pillRadius: 999
    readonly property int roundButton: scaled(26)
    readonly property int tooltipHeight: scaled(28)

    readonly property int popWidth: scaled(408, contentScale)
    readonly property int popWideWidth: scaled(448, contentScale)
    // The edge drawer and the Day sheet: attached surfaces from the 2026-09
    // redesign. The drawer holds one width across all its tabs so switching
    // never slides the surface; the sheet hangs under the clock.
    readonly property int drawerWidth: scaled(Settings.drawerWidth, contentScale)
    readonly property int daySheetWidth: scaled(680, contentScale)
    readonly property int t3MinWidth: 360
    readonly property int t3MaxWidth: 520
    readonly property int surfacePadding: scaled(16)
    readonly property int controlHeight: scaled(46)
    // Inline action pills sit beside copy inside compact cards. They need a
    // smaller target than standalone header, footer and form controls so a
    // two-line tile does not grow or clip when its actions are revealed.
    readonly property int inlineActionHeight: scaled(32)
    readonly property int settingsControlHeight: Math.max(scaled(28), fontBody + scaled(12))
    readonly property int rowHeight: scaled(52)
    readonly property int tileHeight: scaled(64)
    readonly property int calendarCellSize: scaled(22)
    readonly property int pickerRowHeight: scaled(40)
    // A panel takes the shared surface corner and everything inside it takes the bar's
    // chip corner. `surfaceRadius` stays where it is: it is the compositor's
    // window rounding (roles/desktop/templates/looknfeel.lua.j2) and the Hug corners
    // that have to match it, not a shell-internal design choice.
    readonly property int popRadius: panelRadius
    readonly property int cardRadius: chipRadius
    readonly property int rowRadius: chipRadius
    readonly property int tileRadius: chipRadius
    // Gap between the bar's inner edge and the top of a panel hanging from it.
    readonly property int popGap: 6

    // ---- dialog metrics ----------------------------------------------------
    // A dialog answers to the bar rather than to the card system above: it
    // takes the bar's own corner, so squaring the menubar squares the panels
    // hanging off it, and its rows keep the bar's compact rhythm. The list row
    // is the menubar's own default height, held as a literal so a taller bar
    // does not drag every thread row up with it.
    readonly property color surfaceBorderBase: Settings.surfaceBorderMode === "custom"
        ? Settings.surfaceBorderColor : Settings.surfaceBorderMode === "subtle" ? stroke : accent
    readonly property color surfaceBorderColor: Qt.rgba(surfaceBorderBase.r, surfaceBorderBase.g,
        surfaceBorderBase.b, surfaceBorderBase.a * (Settings.highContrast ? 1 : Settings.surfaceBorderOpacity / 100))
    readonly property int surfaceBorderWidth: Settings.highContrast
        ? Math.max(2, Settings.surfaceBorderWidth) : Settings.surfaceBorderWidth
    readonly property int panelRadius: Settings.surfaceCornerRadius
    readonly property int panelPadding: scaled(14)
    readonly property int sectionHeaderHeight: scaled(22)
    readonly property int panelRowHeight: settingsControlHeight
    readonly property int listRowHeight: scaled(34)
    // A panel's title block: subject on one line, its qualifiers on the next,
    // closed by a hairline. The footer carries one line and no more.
    readonly property int panelHeaderHeight: scaled(52)
    readonly property int panelFooterHeight: scaled(30)
    // A row that genuinely carries two lines — a device and what it is doing,
    // a track and its artist. Most rows do not: one line and a right-aligned
    // qualifier is the shell's default, and `listRowHeight` is that.
    readonly property int panelTileHeight: scaled(48)
    // Between two rows in one group, and between two groups.
    readonly property int panelRowSpacing: scaled(2)
    readonly property int panelSectionSpacing: scaled(16)

    // The settings workspace uses one stable label lane in every font. Rows
    // stack below their labels only when the page itself becomes narrow.
    // Settings distinguish compact rows, related content, subsections and
    // groups. A subsection owns its leading space, including inside revealers.
    // A settings page is read top to bottom rather than glanced at like a
    // popover, so it spaces its groups wider than the panels do: the gap alone
    // separates them, and a heading sits visibly closer to its own rows than
    // to the group above.
    readonly property int settingsRowSpacing: scaled(4)
    readonly property int settingsContentSpacing: scaled(8)
    readonly property int settingsSubsectionSpacing: scaled(20)
    readonly property int settingsGroupSpacing: scaled(28)
    readonly property int controlSpacing: scaled(8)
    readonly property int iconTextSpacing: scaled(6)
    readonly property int settingsStackOffset: typography.control + settingsContentSpacing

    readonly property int settingsLabelWidth: scaled(132, typeScale)
    // The modified-mark gutter in front of every settings row: a 6px dot and
    // its gap, reserved so a row changing state never shifts its label.
    readonly property int settingsMarkInset: scaled(18)
    readonly property int settingsNarrowWidth: scaled(520, typeScale)

    // Switch geometry per surface, for Common/Toggle.qml: `box` is the hit
    // area, `track` the pill drawn centred inside it. The knob always sits
    // 4px inside the track height, so it follows from `track` alone.
    readonly property var switchPopover: ({
        box: Qt.size(44, 34),
        track: Qt.size(36, 21)
    })
    readonly property var switchRow: ({
        box: Qt.size(40, root.settingsControlHeight),
        track: Qt.size(36, 21)
    })
    readonly property var switchCompact: ({
        box: Qt.size(36, root.settingsControlHeight),
        track: Qt.size(32, 19)
    })

    // ---- motion ------------------------------------------------------------
    // Continuous movement inside the shell uses one physical spring. A panel
    // entering or leaving is directional instead: it decelerates away from
    // its trigger and accelerates back into it. Colour and opacity never
    // spring — an overshooting fade reads as a flicker.
    readonly property var springCurve: [0.34, 1.4, 0.28, 1.0, 1.0, 1.0]
    readonly property var easeOutCurve: [0.22, 1.0, 0.36, 1.0, 1.0, 1.0]
    readonly property var easeInCurve: [0.4, 0.0, 1.0, 1.0, 1.0, 1.0]

    // Hover tint and other pure colour cross-fades.
    readonly property int chipFadeDuration: reducedMotion ? 0 : 200
    // A control acknowledging a press (scale down and back).
    readonly property int pressDuration: reducedMotion ? 0 : 250
    // Something growing or sliding inside the bar: a revealed tray, a
    // widening workspace pip, the media transport unfolding.
    readonly property int expandDuration: reducedMotion ? 0 : 450
    // Surface-level colour changes — theme switch, accent change.
    readonly property int surfaceDuration: reducedMotion ? 0 : 450
    // A panel entering: the transform springs while opacity eases, so the
    // shape arrives a beat after the content becomes legible.
    readonly property int panelMotionDuration: reducedMotion ? 0 : 550
    readonly property int panelFadeDuration: reducedMotion ? 0 : 320
    readonly property int panelCloseDuration: reducedMotion ? 0 : 260
    // Cross-fade when one panel morphs into another in the same surface.
    readonly property int popoutContentFadeDuration: reducedMotion ? 0 : 150
    readonly property int popoutContentRevealDelay: reducedMotion ? 0 : 30
    // A row entering a list: the per-item stagger and its cap.
    readonly property int staggerStep: reducedMotion ? 0 : 26
    readonly property int staggerMax: 8

    // Bar popouts answer more quickly than modal surfaces. Opening and closing
    // are directional; only an already-open card morphing between triggers
    // keeps a small amount of overshoot.
    readonly property int popoutOpenDuration: reducedMotion ? 0 : 250
    readonly property int popoutCloseDuration: reducedMotion ? 0 : 165
    readonly property int popoutMorphDuration: reducedMotion ? 0 : 320
    readonly property int popoutFadeInDuration: reducedMotion ? 0 : 170
    readonly property int popoutFadeOutDuration: reducedMotion ? 0 : 120
    readonly property real popoutInitialScale: reducedMotion ? 1 : 0.975
    readonly property int popoutTravel: reducedMotion ? 0 : 10
    readonly property var popoutEnterCurve: [0.05, 0.7, 0.1, 1.0, 1.0, 1.0]
    readonly property var popoutExitCurve: easeInCurve
    readonly property var popoutMorphCurve: [0.34, 1.18, 0.28, 1.0, 1.0, 1.0]

    // The launcher is keyboard-critical and its warm content is usable while
    // the card enters. Keep its visual acknowledgment brisk and free of the
    // slower modal spring or per-result stagger.
    readonly property int launcherOpenDuration: reducedMotion ? 0 : 180
    readonly property int launcherCloseDuration: reducedMotion ? 0 : 120
    readonly property int launcherFadeInDuration: reducedMotion ? 0 : 110
    readonly property int launcherFadeOutDuration: reducedMotion ? 0 : 80
    readonly property int launcherResizeDuration: reducedMotion ? 0 : 140
    readonly property real launcherInitialScale: reducedMotion ? 1 : 0.985
    readonly property int launcherTravel: reducedMotion ? 0 : 8
    readonly property var launcherEnterCurve: popoutEnterCurve
    readonly property var launcherExitCurve: popoutExitCurve

    readonly property int popoutTabMinWidth: 104
    readonly property int popoutTabPadding: 24
    readonly property int popoutTabRadius: 17
}
