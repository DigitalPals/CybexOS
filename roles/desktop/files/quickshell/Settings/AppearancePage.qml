pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls as Controls
import "../Common"
import "../Common" as Common
import "../Common/SettingsHelpers.js" as SettingsHelpers

// Appearance owns theme, text and size, colors, and panel chrome. Every
// control that changes how large the shell draws sits in one group, with the
// size it produces spelled out, because the three multiply rather than
// override one another. Bar geometry lives on the Bar page.
SettingsPage {
    id: page

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
    readonly property int barColorIndex: {
        for (let i = 0; i < Settings.barColorChoices.length; ++i) {
            if (Settings.barColorChoices[i].id === Settings.barColorMode)
                return i;
        }
        return 0;
    }
    readonly property string barColorLabel: Settings.barColorChoices[barColorIndex].label
    readonly property string textScaleLabel: Settings.textScale === "larger" ? "Larger (×1.3)"
        : Settings.textScale === "large" ? "Large (×1.15)" : "Default"
    readonly property string sizeSummary: "Text renders at " + Theme.metrics.fontBase
        + " px — " + Settings.shellFontSize + " px base, " + page.textScaleLabel
        + " text size, " + Settings.shellScale + "% UI scale"

    function accentName(value) {
        return page.accentNames[value] || value.toUpperCase();
    }

    function pickAccent(value) {
        Settings.set("accent", value);
    }

    function revealFixedColors() {
        fixedColorScrollTimer.restart();
    }

    function revealFixedColorsNow() {
        const firstBarSwatch = barColorRepeater.itemAt(0);
        const lastSwatch = swatchRepeater.itemAt(swatchRepeater.count - 1);
        page.revealFocus(firstBarSwatch || lastSwatch || fixedColorReveal);
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

            PickerRow {
                width: parent.width
                label: "Interface font"
                settingKey: "font"
                model: Settings.fontChoices.map(choice => ({
                    value: choice.id, label: choice.label
                }))
            }
            SliderRow {
                width: parent.width
                label: "Base font"
                settingKey: "shellFontSize"
                min: 10; max: 24; step: 1
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
                hint: "Enlarges text for readability on top of the base font"
            }
            SliderRow {
                width: parent.width
                label: "UI scale"
                settingKey: "shellScale"
                min: 75; max: 200; step: 5; unit: "%"
                marks: [100]
                hint: "Scales text and spacing together"
            }
            PickerRow {
                width: parent.width
                label: "Control spacing"
                settingKey: "interfaceDensity"
                model: [
                    { value: "compact", label: "Compact" },
                    { value: "default", label: "Default" },
                    { value: "comfortable", label: "Comfortable" }
                ]
                hint: "Row height and touch-target size"
            }
            SettingsHint {
                width: parent.width
                text: page.sizeSummary
                tone: "active"
            }
        }

        SettingsGroup {
            width: parent.width
            title: "Colors"

            PickerRow {
                width: parent.width
                label: "Accent source"
                settingKey: "paletteMode"
                hint: Settings.paletteMode === "wallpaper"
                    ? "The accent follows the current wallpaper" : "Choose the accent yourself"
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

            Revealer {
                id: fixedColorReveal
                width: parent.width
                reveal: page.fixedPalette

                SettingsSubsection {
                    width: fixedColorReveal.width
                    title: "Accent"
                    insetContent: false
                    SliderRow {
                        width: parent.width
                        label: "Accent hue"
                        resetKeys: ["accent"]
                        resetLabel: "Accent"
                        min: 0; max: 359; step: 1; unit: "°"
                        value: page.accentHue
                        hueTrack: true
                        dirty: Settings.accent !== Settings.defaults.accent
                        onMoved: value => page.pickAccent(SettingsHelpers.hueToHex(value))
                    }
                    Flow {
                        x: Theme.settingsMarkInset
                        width: parent.width - x
                        spacing: Theme.controlSpacing
                        Repeater {
                            id: swatchRepeater
                            model: page.accentChoices
                            delegate: Item {
                                id: swatch
                                required property string modelData
                                required property int index
                                readonly property bool selected: Settings.accent === modelData
                                width: Theme.settingsControlHeight; height: width
                                activeFocusOnTab: selected || (index === 0
                                    && page.accentChoices.indexOf(Settings.accent) === -1)
                                Accessible.role: Accessible.RadioButton
                                Accessible.name: page.accentName(modelData) + " accent"
                                Accessible.checked: selected
                                Accessible.onPressAction: page.pickAccent(modelData)
                                Controls.ToolTip.visible: swatchMouse.containsMouse
                                Controls.ToolTip.text: page.accentName(modelData) + " · " + modelData.toUpperCase()
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
                                    if (next >= 0) {
                                        page.pickAccent(page.accentChoices[next]);
                                        swatchRepeater.itemAt(next).forceActiveFocus();
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
            }

            Revealer {
                id: wallpaperPaletteReveal
                width: parent.width
                reveal: !page.fixedPalette

                SettingsSubsection {
                    width: wallpaperPaletteReveal.width
                    title: "Wallpaper palette"
                    insetContent: true

                    Item {
                        width: parent.width
                        height: paletteContent.implicitHeight
                        Column {
                            id: paletteContent
                            width: parent.width
                            spacing: Theme.settingsContentSpacing
                            Flow {
                                width: parent.width
                                spacing: Theme.controlSpacing
                                Repeater {
                                    model: page.paletteSwatches
                                    delegate: Row {
                                        required property var modelData
                                        spacing: Theme.iconTextSpacing
                                        Accessible.role: Accessible.StaticText
                                        Accessible.name: modelData.label + " palette color"

                                        Rectangle {
                                            anchors.verticalCenter: parent.verticalCenter
                                            width: Theme.iconSmall; height: width; radius: Theme.scaled(4)
                                            color: parent.modelData.color
                                            border.width: 1
                                            border.color: Theme.stroke
                                        }
                                        Text {
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: parent.modelData.label
                                            font.family: Theme.fontMenu
                                            font.pixelSize: Theme.typography.metadata
                                            color: Theme.textDim
                                        }
                                    }
                                }
                            }
                            SettingsHint {
                                width: parent.width
                                inset: false
                                text: Common.Palette.busy
                                    ? "Generating colors from the current wallpaper…"
                                    : Common.Palette.ready
                                    ? "Palette ready"
                                    : Common.Palette.error !== ""
                                    ? Common.Palette.error + " · using the fixed accent"
                                    : "Waiting for the wallpaper palette"
                                tone: Common.Palette.error !== "" ? "error" : "info"
                            }
                        }
                    }
                }
            }

            SettingsSubsection {
                id: barColorControls
                width: parent.width
                title: "Bar background"
                spacing: Theme.settingsContentSpacing

                Flow {
                    x: Theme.settingsMarkInset
                    width: parent.width - x
                    spacing: Theme.controlSpacing
                    Repeater {
                        id: barColorRepeater
                        model: Settings.barColorChoices
                        delegate: Item {
                            id: colorChoice
                            required property var modelData
                            required property int index
                            readonly property bool selected: Settings.barColorMode === modelData.id
                            readonly property string previewHex: Settings.previewBarColor(modelData.id)
                            width: Theme.listRowHeight; height: width
                            activeFocusOnTab: selected || (index === 0 && Settings.barColorMode === "")
                            Accessible.role: Accessible.RadioButton
                            Accessible.name: modelData.label + " menubar color"
                            Accessible.description: previewHex.toUpperCase()
                            Accessible.checked: selected
                            Accessible.onPressAction: Settings.set("barColorMode", modelData.id)
                            Controls.ToolTip.visible: colorMouse.containsMouse
                            Controls.ToolTip.text: modelData.label + " · " + previewHex.toUpperCase()
                            Keys.onPressed: event => {
                                let next = -1;
                                if (event.key === Qt.Key_Left || event.key === Qt.Key_Up)
                                    next = Math.max(0, index - 1);
                                else if (event.key === Qt.Key_Right || event.key === Qt.Key_Down)
                                    next = Math.min(Settings.barColorChoices.length - 1, index + 1);
                                else if (event.key === Qt.Key_Home)
                                    next = 0;
                                else if (event.key === Qt.Key_End)
                                    next = Settings.barColorChoices.length - 1;
                                else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                                        || event.key === Qt.Key_Space) {
                                    Settings.set("barColorMode", modelData.id);
                                    event.accepted = true; return;
                                }
                                if (next >= 0) {
                                    Settings.set("barColorMode", Settings.barColorChoices[next].id);
                                    barColorRepeater.itemAt(next).forceActiveFocus();
                                    event.accepted = true;
                                }
                            }
                            Rectangle {
                                anchors.fill: parent
                                radius: width / 2
                                color: "transparent"
                                border.width: colorChoice.selected ? 2 : colorChoice.activeFocus ? 1 : 0
                                border.color: colorChoice.selected ? Theme.accentText : Theme.textHi
                            }
                            Rectangle {
                                anchors.centerIn: parent
                                width: Theme.scaled(22); height: width; radius: width / 2
                                color: colorChoice.previewHex
                                border.width: 1
                                border.color: Theme.stroke
                            }
                            MouseArea {
                                id: colorMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    colorChoice.forceActiveFocus();
                                    Settings.set("barColorMode", colorChoice.modelData.id);
                                }
                            }
                        }
                    }
                }

                Item {
                    x: Theme.settingsMarkInset
                    width: parent.width - x
                    height: Theme.settingsControlHeight
                    Text {
                        anchors.left: parent.left
                        anchors.right: colorValue.left
                        anchors.rightMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        text: page.barColorLabel
                        font.family: Theme.fontMenu
                        font.pixelSize: Theme.typography.secondary
                        font.weight: Theme.weightSemibold
                        color: Theme.textMid
                        elide: Text.ElideRight
                    }
                    Text {
                        id: colorValue
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        width: Math.min(implicitWidth, parent.width * 0.55)
                        horizontalAlignment: Text.AlignRight
                        text: (Settings.barColorMode === "default"
                                || Settings.barColorMode === "macos" ? "adapts to theme · " : "")
                            + Settings.effectiveBarColor.toUpperCase()
                        font.family: Theme.fontMono
                        font.pixelSize: Theme.typography.secondary
                        color: Theme.textFaint
                        elide: Text.ElideLeft
                    }
                }

                Revealer {
                    id: customColorReveal
                    width: parent.width
                    reveal: Settings.barColorMode === "custom"
                    Column {
                        width: customColorReveal.width
                        spacing: Theme.settingsRowSpacing
                        SliderRow {
                            width: parent.width
                            label: "Hue"
                            settingKey: "barCustomHue"
                            min: 0; max: 359; step: 1; unit: "°"
                            hueTrack: true
                        }
                        SliderRow {
                            width: parent.width
                            label: "Saturation"
                            settingKey: "barCustomSaturation"
                            min: 0; max: 100; step: 1; unit: "%"
                            colorTrack: true
                            trackStart: SettingsHelpers.hslToHex(Settings.barCustomHue, 0,
                                Settings.barCustomLightness)
                            trackMiddle: SettingsHelpers.hslToHex(Settings.barCustomHue, 50,
                                Settings.barCustomLightness)
                            trackEnd: SettingsHelpers.hslToHex(Settings.barCustomHue, 100,
                                Settings.barCustomLightness)
                        }
                        SliderRow {
                            width: parent.width
                            label: "Lightness"
                            settingKey: "barCustomLightness"
                            min: 0; max: 100; step: 1; unit: "%"
                            colorTrack: true
                            trackStart: "#000000"
                            trackMiddle: SettingsHelpers.hslToHex(Settings.barCustomHue,
                                Settings.barCustomSaturation, 50)
                            trackEnd: "#ffffff"
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
                model: [{ value: "accent", label: "Accent" }, { value: "subtle", label: "Subtle" },
                    { value: "custom", label: "Custom" }]
            }
            SettingsTextRow {
                width: parent.width
                visible: Settings.surfaceBorderMode === "custom"
                label: "Border color"
                settingKey: "surfaceBorderColor"
                resetLabel: "Panel border color"
                hexColor: true
                placeholder: "#9ecbeb"
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
