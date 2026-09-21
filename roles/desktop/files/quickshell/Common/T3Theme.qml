pragma Singleton
import QtQuick
import Quickshell
import "SettingsHelpers.js" as SettingsHelpers

// T3 Code keeps its own spacing, radii, and surface hierarchy, but participates
// in the shell's semantic palette. This makes wallpaper and fixed accent
// choices flow into the workspace without making individual T3 views depend on
// shell implementation details.
Singleton {
    id: root

    readonly property bool dark: Theme.dark

    // The roles preserve T3's canvas -> card -> raised-control rhythm while
    // following the active fixed or wallpaper-derived shell colors. Floating
    // controls intentionally retain the shell's glass/solid preference.
    readonly property color canvas: Theme.background
    readonly property color chrome: Theme.background
    readonly property color surface: Theme.popBg
    readonly property color surfaceRaised: Theme.copyReferenceBg
    readonly property color overlay: Theme.menuBg
    readonly property color composerGlass: Theme.surfaceMenu

    readonly property color textPrimary: Theme.textHi
    readonly property color textSecondary: Theme.textMid
    readonly property color textMuted: Theme.textLow
    readonly property color textFaint: Theme.textFaint

    readonly property color border: Theme.hairlineSoft
    readonly property color borderStrong: Theme.stroke
    readonly property color hover: Theme.hoverFill
    readonly property color hoverStrong: Theme.hoverFillStrong

    // Accent is used as both copy (working state, links) and control fill, so
    // lift the selected shell accent to AA against the least favorable T3
    // surface. The paired foreground is independently checked against that
    // adjusted fill. With the current wallpaper palette this turns the former
    // dark blue into the shell's much brighter primary.
    readonly property color accent: SettingsHelpers.ensureContrast(
        Theme.accent.toString(), surfaceRaised.toString(), 4.5)
    readonly property color accentHover: dark
        ? Qt.lighter(accent, 1.14) : Qt.darker(accent, 1.10)
    readonly property color accentForeground: SettingsHelpers.ensureContrast(
        Theme.accentFg.toString(), accent.toString(), 4.5)
    readonly property color link: accent
    readonly property color accentSoft: Theme.accentBg
    readonly property color accentSubtle: Theme.accentBgSoft
    readonly property color focus: Settings.highContrast ? Theme.accentText : Theme.accentGlow

    readonly property color amber: Theme.amber
    readonly property color amberSoft: Theme.amberBgSoft
    readonly property color amberBorder: Theme.amberBorder
    readonly property color red: Theme.redText
    // `red` is a copy colour, and the palette's error role behind it is tuned
    // to be read *on* a dark surface — at circle size that pale tint reads as
    // pink, not as stop. A filled destructive control needs a mid-tone fill
    // instead, so this pair is seeded fixed the way `ok` and `amber` are, and
    // its foreground is checked rather than assumed.
    readonly property color danger: dark ? "#d83a3f" : "#c62828"
    readonly property color dangerHover: dark
        ? Qt.lighter(danger, 1.12) : Qt.darker(danger, 1.10)
    readonly property color dangerForeground: SettingsHelpers.ensureContrast(
        "#ffffff", danger.toString(), 4.5)
    readonly property color redSoft: Theme.redBgSoft
    readonly property color redBorder: Theme.redBorder
    readonly property color success: Theme.ok

    // T3 used to hold a product face of its own, which is why this was called
    // fontSans. It reads as a second application inside the shell — the bar
    // beside it obeys the Typography setting and this did not — so the views
    // now take the same face, and the token is named for the job rather than
    // for a classification it no longer makes.
    readonly property string fontUi: Theme.fontMenu
    readonly property string fontMono: Theme.fontMono
    readonly property var tabularNumberFeatures: Theme.tabularNumberFeatures

    // The panel answers to the menubar: same corner, same compact rhythm. Only
    // the composer keeps a shape of its own, and it is the bar's chip corner
    // rather than the old pill so the prompt reads as a well in the page.
    readonly property int outerRadius: Theme.panelRadius
    readonly property int composerRadius: Theme.panelRadius
    readonly property int panelRadius: Theme.panelRadius
    readonly property int rowRadius: Theme.chipRadius
    readonly property int controlRadius: Theme.chipRadius
    readonly property int pagePadding: Theme.panelPadding
    readonly property int headerHeight: Theme.panelHeaderHeight
    readonly property int footerHeight: Theme.panelFooterHeight
    // Every list row in the T3 and GitHub workspaces is one menubar tall.
    // Context trails the title and actions replace status in place, leaving
    // detailed copy to the page a row opens.
    readonly property int quietRowHeight: Theme.listRowHeight
    readonly property int iconButtonSize: Theme.chipHeight

    // T3 interactions are deliberately quick. Continuous state animation is
    // duty-cycled at the call site so idle windows do not repaint forever.
    readonly property int fastDuration: 140
    readonly property int normalDuration: 180
}
