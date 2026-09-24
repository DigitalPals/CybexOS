pragma ComponentBehavior: Bound
import QtQuick
import "../Common"
import "../Common" as Common
import "../Common/SettingsHelpers.js" as SettingsHelpers

// Appearance owns theme, text and size, colors, and panel chrome. Every
// control that changes how large the shell draws sits in one group under a
// live preview of the result, because they multiply rather than override one
// another. Three stay in view; the base size they build on is an advanced
// option (2026-09 redesign). Bar geometry and its background live on the Bar
// page.
SettingsPage {
    id: page
    pageReset: true

    // Keep the shell's shipped accent in the preset model. The default is
    // intentionally referenced rather than repeated here so a future palette
    // refresh cannot leave the active color without a selected swatch.
    readonly property var accentChoices: [Settings.defaults.accent,
        "#9ecbeb", "#a992e0", "#79b88b", "#d3b47e", "#e8837a"]
    readonly property var accentNames: {
        const names = { "#9ecbeb": "Sky", "#a992e0": "Lavender", "#79b88b": "Sage",
            "#d3b47e": "Sand", "#e8837a": "Coral" };
        names[Settings.defaults.accent] = "Default";
        return names;
    }
    readonly property int accentHue: SettingsHelpers.hexHue(Settings.accent, 204)
    readonly property bool fixedPalette: Settings.paletteMode === "fixed"
    readonly property var paletteSwatches: [
        { label: "Surface", color: Common.Palette.surface },
        { label: "Panel", color: Theme.popBg },
        { label: "Group", color: Common.Palette.surfaceContainerHigh },
        { label: "Primary", color: Theme.accent },
        { label: "Outline", color: Theme.stroke },
        { label: "Error", color: Theme.red }
    ]
    readonly property string paletteStatus: Common.Palette.busy
        ? "Generating colors from the current wallpaper…"
        : Common.Palette.ready
        ? "Generated from " + Settings.wall
        : Common.Palette.error !== ""
        ? Common.Palette.error + " · using the fixed accent"
        : "Waiting for the wallpaper palette"

    function accentName(value) {
        return page.accentNames[value] || value.toUpperCase();
    }

    function pickAccent(value) {
        Settings.set("accent", value);
    }

    // The interface font dropdown draws each choice in its own face.
    function fontFamily(id) {
        const choice = Settings.fontChoices.find(entry => entry.id === id);
        return choice ? choice.family : Theme.fontMenu;
    }

    function revealFixedColors() {
        fixedColorScrollTimer.restart();
    }

    function revealFixedColorsNow() {
        // The hue row closes the revealed block; bringing its foot into view
        // brings the presets above it along.
        page.revealFocus(accentHueRow);
    }

    Timer {
        id: fixedColorScrollTimer
        interval: Theme.expandDuration
        onTriggered: page.revealFixedColorsNow()
    }

    Column {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Theme.settingsGroupSpacing

        SettingsGroup {
            width: parent.width
            title: "Theme"

            PickerRow {
                width: parent.width
                label: "Mode"
                settingKey: "themeMode"
                model: [
                    { value: "dark", label: "Dark" },
                    { value: "light", label: "Light" }
                ]
            }
            SwitchRow {
                width: parent.width
                label: "Glass effect"
                settingKey: "glassEnabled"
                description: Settings.glassApplyError
                    ? "Panels changed, but the compositor blur could not be updated"
                    : "Translucent panels with background blur"
                hintTone: Settings.glassApplyError ? "error" : "info"
                disabledReason: Settings.highContrast
                    ? "Off while High contrast is on" : ""
            }
        }

        SettingsGroup {
            width: parent.width
            title: "Text & size"

            // Replaces the sentence that spelled out the rendered size: the
            // bar and a popover, drawn at whatever the rows below produce.
            TextSizePreview {
                width: parent.width
            }
            SelectRow {
                width: parent.width
                label: "Interface font"
                settingKey: "font"
                model: Settings.fontChoices.map(choice => ({
                    value: choice.id, label: choice.label
                }))
                fontFor: value => page.fontFamily(value)
            }
            PickerRow {
                width: parent.width
                label: "Text size"
                settingKey: "textScale"
                model: [
                    { value: "default", label: "Default" },
                    { value: "large", label: "Large" },
                    { value: "larger", label: "Larger" }
                ]
            }
            SliderRow {
                width: parent.width
                label: "Interface scale"
                settingKey: "shellScale"
                min: 75; max: 200; step: 5; unit: "%"
                marks: [100]
                hint: "Scales text and spacing together"
            }
            PickerRow {
                width: parent.width
                label: "Density"
                settingKey: "interfaceDensity"
                model: [
                    { value: "compact", label: "Compact" },
                    { value: "default", label: "Default" },
                    { value: "comfortable", label: "Comfortable" }
                ]
                hint: "Row height and touch-target size"
            }
            // The base size is what Text size and Interface scale multiply,
            // so it is rarely the control to reach for; a search for it
            // still opens the disclosure.
            SettingsDisclosure {
                width: parent.width
                text: "Advanced text options"
                keys: ["shellFontSize"]

                SliderRow {
                    width: parent.width
                    label: "Base font size"
                    settingKey: "shellFontSize"
                    min: 10; max: 24; step: 1
                    hint: "The size that Text size and Interface scale build on"
                }
            }
        }

        SettingsGroup {
            width: parent.width
            title: "Colors"

            PickerRow {
                width: parent.width
                label: "Accent source"
                settingKey: "paletteMode"
                // Returning to the wallpaper restores the fixed accent too:
                // it is hidden under Wallpaper, and a reset should not leave
                // a changed value out of sight.
                resetKeys: ["paletteMode", "accent"]
                hint: Settings.paletteMode === "wallpaper"
                    ? "Follows the current wallpaper" : "Stays the same when the wallpaper changes"
                model: [
                    { value: "wallpaper", label: "Wallpaper" },
                    { value: "fixed", label: "Fixed" }
                ]
                onPicked: value => {
                    if (value === "fixed")
                        page.revealFixedColors();
                    else
                        fixedColorScrollTimer.stop();
                }
            }

            // Fixed: the presets and a hue for anything between them. The
            // rows sit directly under Accent source, with no heading of
            // their own, as the options it revealed.
            Revealer {
                id: fixedColorReveal
                width: parent.width
                reveal: page.fixedPalette

                Column {
                    width: fixedColorReveal.width
                    spacing: Theme.settingsRowSpacing

                    SettingsRow {
                        id: accentRow
                        readonly property int swatchSize: Theme.settingsControlHeight
                        readonly property real swatchesWidth: page.accentChoices.length * swatchSize
                            + (page.accentChoices.length - 1) * swatchFlow.spacing

                        width: parent.width
                        label: "Accent color"
                        settingKey: "accent"
                        resetLabel: "Accent"
                        hint: page.accentNames[Settings.accent]
                            ? page.accentNames[Settings.accent] + " · " + Settings.accent.toUpperCase()
                            : "Custom hue · " + Settings.accent.toUpperCase()
                        wideHeight: Math.max(Theme.panelRowHeight, swatchFlow.implicitHeight) + rowPad * 2
                        narrowHeight: Theme.settingsStackOffset + swatchFlow.implicitHeight
                        narrowLabelInset: accentRow.undoWidth
                        controlLeft: accentRow.narrow ? accentRow.labelWidth : swatchFlow.x

                        // One tab stop; the arrow keys rove between the
                        // presets and pick as they go, like a segmented row.
                        Flow {
                            id: swatchFlow
                            width: accentRow.narrow
                                ? Math.max(0, accentRow.contentRight - accentRow.markInset)
                                : Math.min(accentRow.swatchesWidth,
                                    Math.max(0, accentRow.contentRight - accentRow.labelWidth))
                            x: accentRow.narrow ? accentRow.markInset : accentRow.contentRight - width
                            y: accentRow.narrow ? Theme.settingsStackOffset
                                : (accentRow.lineHeight - height) / 2
                            spacing: Theme.controlSpacing
                            opacity: accentRow.controlOpacity

                            Repeater {
                                id: swatchRepeater
                                model: page.accentChoices
                                delegate: Item {
                                    id: swatch
                                    required property string modelData
                                    required property int index
                                    readonly property bool selected: Settings.accent === modelData
                                    width: accentRow.swatchSize; height: width
                                    activeFocusOnTab: selected || (index === 0
                                        && page.accentChoices.indexOf(Settings.accent) === -1)
                                    Accessible.role: Accessible.RadioButton
                                    Accessible.name: page.accentName(modelData) + " accent"
                                    Accessible.checked: selected
                                    Accessible.onPressAction: page.pickAccent(modelData)
                                    Keys.onPressed: event => {
                                        let next = -1;
                                        if (event.key === Qt.Key_Left || event.key === Qt.Key_Up)
                                            next = Math.max(0, index - 1);
                                        else if (event.key === Qt.Key_Right || event.key === Qt.Key_Down)
                                            next = Math.min(page.accentChoices.length - 1, index + 1);
                                        else if (event.key === Qt.Key_Home)
                                            next = 0;
                                        else if (event.key === Qt.Key_End)
                                            next = page.accentChoices.length - 1;
                                        else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                                                || event.key === Qt.Key_Space) {
                                            page.pickAccent(modelData); event.accepted = true; return;
                                        }
                                        // Focus before the pick: see PillRow.
                                        if (next >= 0) {
                                            swatchRepeater.itemAt(next).forceActiveFocus();
                                            page.pickAccent(page.accentChoices[next]);
                                            event.accepted = true;
                                        }
                                    }
                                    Rectangle {
                                        anchors.centerIn: parent
                                        width: Theme.scaled(18); height: width; radius: width / 2
                                        color: swatch.modelData
                                    }
                                    Rectangle {
                                        anchors.fill: parent
                                        radius: width / 2
                                        color: "transparent"
                                        border.width: 1.5
                                        border.color: swatch.activeFocus ? Theme.textHi : Theme.accentText
                                        visible: swatch.selected || swatch.activeFocus || swatchMouse.containsMouse
                                    }
                                    SettingsTooltip {
                                        visible: swatchMouse.containsMouse
                                        text: page.accentName(swatch.modelData) + " · "
                                            + swatch.modelData.toUpperCase()
                                    }
                                    MouseArea {
                                        id: swatchMouse
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            swatch.forceActiveFocus();
                                            page.pickAccent(swatch.modelData);
                                        }
                                    }
                                }
                            }
                        }
                    }
                    SliderRow {
                        id: accentHueRow
                        width: parent.width
                        label: "Accent hue"
                        min: 0; max: 359; step: 1; unit: "°"
                        value: page.accentHue
                        hueTrack: true
                        // The same stored color as the presets above; that
                        // row carries its changed mark and its reset.
                        dirty: false
                        resetKeys: []
                        onMoved: value => page.pickAccent(SettingsHelpers.hueToHex(value))
                    }
                }
            }

            // Wallpaper: the generated palette, read-only, where the presets
            // were. Its status line says what it was made from, or why it
            // fell back.
            Revealer {
                id: wallpaperPaletteReveal
                width: parent.width
                reveal: !page.fixedPalette

                SettingsRow {
                    id: paletteRow
                    width: wallpaperPaletteReveal.width
                    label: "Wallpaper palette"
                    hint: page.paletteStatus
                    hintTone: Common.Palette.error !== "" ? "error" : "info"
                    narrowLabelInset: paletteRow.undoWidth
                    controlLeft: paletteRow.narrow ? paletteRow.labelWidth : paletteContent.x

                    Row {
                        id: paletteContent
                        x: paletteRow.narrow ? paletteRow.markInset : paletteRow.contentRight - width
                        y: paletteRow.narrow
                            ? Theme.settingsStackOffset + (Theme.settingsControlHeight - height) / 2
                            : (paletteRow.lineHeight - height) / 2
                        spacing: Theme.scaled(5)

                        Repeater {
                            model: page.paletteSwatches
                            delegate: Rectangle {
                                id: paletteChip
                                required property var modelData
                                width: Theme.scaled(18, Theme.typeScale); height: width
                                radius: Theme.scaled(5)
                                color: modelData.color
                                border.width: 1
                                border.color: Theme.stroke
                                Accessible.role: Accessible.StaticText
                                Accessible.name: modelData.label + " palette color"

                                SettingsTooltip {
                                    visible: chipHover.hovered
                                    text: paletteChip.modelData.label
                                }
                                HoverHandler {
                                    id: chipHover
                                }
                            }
                        }
                    }
                }
            }
        }

        SettingsGroup {
            width: parent.width
            title: "Panels"

            PickerRow {
                width: parent.width
                label: "Border"
                settingKey: "surfaceBorderMode"
                resetLabel: "Panel border"
                // The custom color only means something under Custom.
                resetKeys: ["surfaceBorderMode", "surfaceBorderColor"]
                model: [{ value: "accent", label: "Accent" }, { value: "subtle", label: "Subtle" },
                    { value: "custom", label: "Custom" }]
            }
            Revealer {
                id: borderColorReveal
                width: parent.width
                reveal: Settings.surfaceBorderMode === "custom"

                SettingsTextRow {
                    width: borderColorReveal.width
                    label: "Border color"
                    settingKey: "surfaceBorderColor"
                    resetLabel: "Panel border color"
                    hexColor: true
                    placeholder: "#9ecbeb"
                }
            }
            SliderRow {
                width: parent.width
                label: "Border width"
                settingKey: "surfaceBorderWidth"
                resetLabel: "Panel border width"
                min: 0; max: 8; step: 1
            }
            SliderRow {
                width: parent.width
                label: "Border opacity"
                settingKey: "surfaceBorderOpacity"
                resetLabel: "Panel border opacity"
                min: 0; max: 100; step: 5; unit: "%"
                disabledReason: Settings.surfaceBorderWidth === 0 ? "No border at width 0" : ""
            }
            SliderRow {
                width: parent.width
                label: "Corners"
                settingKey: "surfaceCornerRadius"
                resetLabel: "Panel corners"
                min: 0; max: 30; step: 1
            }
        }

        PluginAppearance { width: parent.width }

        SettingsGroup {
            width: parent.width
            title: "Accessibility"

            SwitchRow {
                width: parent.width
                label: "High contrast"
                settingKey: "highContrast"
                description: "Solid panels and stronger borders"
            }
            SwitchRow {
                width: parent.width
                label: "Reduce motion"
                settingKey: "reducedMotion"
                description: "Turns off panel, reveal and hover animations"
            }
        }
    }
}
