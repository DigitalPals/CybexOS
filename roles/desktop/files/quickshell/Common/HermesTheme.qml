pragma Singleton
import QtQuick
import Quickshell
import "SettingsHelpers.js" as SettingsHelpers

// Hermes owns its information hierarchy while participating in the shell's
// active semantic palette. This mirrors the compact T3 workspace without
// coupling Hermes components to T3 product state.
Singleton {
    readonly property color canvas: Theme.background
    readonly property color surface: Theme.popBg
    readonly property color surfaceRaised: Theme.copyReferenceBg
    readonly property color overlay: Theme.menuBg
    readonly property color composer: Theme.surfaceMenu
    readonly property color composerGlass: Theme.surfaceMenu

    readonly property color textPrimary: Theme.textHi
    readonly property color textSecondary: Theme.textMid
    readonly property color textMuted: Theme.textLow
    readonly property color textFaint: Theme.textFaint

    readonly property color border: Theme.hairlineSoft
    readonly property color borderStrong: Theme.stroke
    readonly property color hover: Theme.hoverFill
    readonly property color hoverStrong: Theme.hoverFillStrong
    readonly property color accent: SettingsHelpers.ensureContrast(
        Theme.accent.toString(), surfaceRaised.toString(), 4.5)
    readonly property color accentHover: Theme.dark
        ? Qt.lighter(accent, 1.12) : Qt.darker(accent, 1.08)
    readonly property color accentForeground: SettingsHelpers.ensureContrast(
        Theme.accentFg.toString(), accent.toString(), 4.5)
    readonly property color accentSoft: Theme.accentBg
    readonly property color accentSubtle: Theme.accentBgSoft
    readonly property color focus: Settings.highContrast ? Theme.accentText : Theme.accentGlow
    readonly property color amber: Theme.amber
    readonly property color amberSoft: Theme.amberBgSoft
    readonly property color amberBorder: Theme.amberBorder
    readonly property color red: Theme.redText
    readonly property color danger: Theme.dark ? "#d83a3f" : "#c62828"
    readonly property color dangerHover: Theme.dark
        ? Qt.lighter(danger, 1.12) : Qt.darker(danger, 1.10)
    readonly property color dangerForeground: SettingsHelpers.ensureContrast(
        "#ffffff", danger.toString(), 4.5)
    readonly property color redSoft: Theme.redBgSoft
    readonly property color redBorder: Theme.redBorder
    readonly property color success: Theme.ok

    readonly property string fontUi: Theme.fontMenu
    readonly property string fontMono: Theme.fontMono
    readonly property var tabularNumberFeatures: Theme.tabularNumberFeatures

    readonly property int pagePadding: Theme.panelPadding
    readonly property int headerHeight: Theme.panelHeaderHeight
    readonly property int footerHeight: Theme.panelFooterHeight
    readonly property int panelRadius: Theme.panelRadius
    readonly property int composerRadius: Theme.panelRadius
    readonly property int rowRadius: Theme.chipRadius
    readonly property int controlRadius: Theme.chipRadius
    readonly property int iconButtonSize: Theme.chipHeight
    readonly property int rowHeight: Theme.listRowHeight
    readonly property int fastDuration: 140
    readonly property int normalDuration: 180
}
