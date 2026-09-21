pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import QtQuick.Controls as Controls
import "../Common"
import "../Common" as Common
import "../Common/SettingsHelpers.js" as SettingsHelpers

// Appearance owns theme, palette, fixed colors, and typography. Bar geometry
// lives on the Bar page so each page describes one coherent task.
SettingsPage {
    id: page

    // Keep the shell's shipped accent in the preset model. The default is
    // intentionally referenced rather than repeated here so a future palette
    // refresh cannot leave the active color without a selected swatch.
    readonly property var accentChoices: [Settings.defaults.accent,
        "#9ecbeb", "#a992e0", "#79b88b", "#d3b47e", "#e8837a"]
    readonly property string tempPreview: Settings.unit === "f" ? "70°" : "21°"
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

    Component.onCompleted: {
        if (fixedPalette)
            revealFixedColors();
    }

    Timer {
        id: fixedColorScrollTimer
        interval: Theme.expandDuration
        onTriggered: page.revealFixedColorsNow()
    }

    SystemClock {
        id: clock
        precision: SystemClock.Minutes
    }

    Column {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: 12

        SettingsGroup {
            width: parent.width
            title: "Theme"
            dirty: Settings.themeMode !== Settings.defaults.themeMode
                || Settings.glassEnabled !== Settings.defaults.glassEnabled
                || Settings.highContrast !== Settings.defaults.highContrast
            onResetRequested: Settings.resetKeys(["themeMode", "glassEnabled",
                "highContrast"], "Theme")

            PickerRow {
                width: parent.width
                label: "Mode"
                settingKey: "themeMode"
                caption: "shell surfaces and text"
                captionMono: false
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
                    ? "Surface changed, but the compositor blur rule could not be updated"
                    : "Blurred translucent shell surfaces; off uses opaque surfaces"
            }
            SwitchRow {
                width: parent.width
                label: "High contrast"
                settingKey: "highContrast"
                description: "Opaque surfaces, stronger borders, and no compositor blur"
            }
        }

        SettingsGroup {
            width: parent.width
            title: "Colors"
            dirty: Settings.paletteMode !== Settings.defaults.paletteMode
                || Settings.barColorMode !== Settings.defaults.barColorMode
                || Settings.barCustomHue !== Settings.defaults.barCustomHue
                || Settings.barCustomSaturation !== Settings.defaults.barCustomSaturation
                || Settings.barCustomLightness !== Settings.defaults.barCustomLightness
                || Settings.accent !== Settings.defaults.accent
            onResetRequested: Settings.resetKeys(["paletteMode", "barColorMode",
                "barCustomHue", "barCustomSaturation", "barCustomLightness", "accent"], "Colors")

            PickerRow {
                width: parent.width
                label: "Accent source"
                settingKey: "paletteMode"
                caption: Settings.paletteMode === "wallpaper"
                    ? "current wallpaper" : "manual choices"
                captionMono: false
                // The group-level reset owns this compound choice and its
                // latent fixed values; a second row reset reads as clutter.
                dirty: false
                resetKeys: []
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

                Column {
                    width: fixedColorReveal.width
                    spacing: 6
                    SectionHeader { label: "ACCENT" }
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
                        width: parent.width
                        spacing: 9
                        Repeater {
                            id: swatchRepeater
                            model: page.accentChoices
                            delegate: Item {
                                id: swatch
                                required property string modelData
                                required property int index
                                readonly property bool selected: Settings.accent === modelData
                                width: 28; height: 28
                                activeFocusOnTab: selected || (index === 0
                                    && page.accentChoices.indexOf(Settings.accent) === -1)
                                Accessible.role: Accessible.RadioButton
                                Accessible.name: "Accent preset " + modelData
                                Accessible.checked: selected
                                Accessible.onPressAction: page.pickAccent(modelData)
                                Controls.ToolTip.visible: swatchMouse.containsMouse
                                Controls.ToolTip.text: "Use accent " + modelData
                                Keys.onPressed: event => {
                                    let next = -1;
                                    if (event.key === Qt.Key_Left || event.key === Qt.Key_Up)
                                        next = Math.max(0, index - 1);
                                    else if (event.key === Qt.Key_Right || event.key === Qt.Key_Down)
                                        next = Math.min(page.accentChoices.length - 1, index + 1);
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
                                    width: 18; height: 18; radius: 9
                                    color: swatch.modelData
                                }
                                Rectangle {
                                    anchors.fill: parent
                                    radius: 14
                                    color: "transparent"
                                    border.width: 1.5
                                    border.color: swatch.modelData
                                    visible: swatch.selected || swatch.activeFocus
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

                Column {
                    width: wallpaperPaletteReveal.width
                    spacing: 6
                    SectionHeader { label: "WALLPAPER PALETTE PREVIEW" }

                    Item {
                        width: parent.width
                        height: paletteContent.implicitHeight
                        Column {
                            id: paletteContent
                            width: parent.width
                            spacing: 7
                            Flow {
                                width: parent.width
                                spacing: 12
                                Repeater {
                                    model: page.paletteSwatches
                                    delegate: Row {
                                        required property var modelData
                                        spacing: 5
                                        Accessible.role: Accessible.StaticText
                                        Accessible.name: modelData.label + " palette color"

                                        Rectangle {
                                            anchors.verticalCenter: parent.verticalCenter
                                            width: 14; height: 14; radius: 4
                                            color: parent.modelData.color
                                            border.width: 1
                                            border.color: Theme.stroke
                                        }
                                        Text {
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: parent.modelData.label
                                            font.family: Theme.fontMenu
                                            font.pixelSize: Theme.fontCaption
                                            color: Theme.textDim
                                        }
                                    }
                                }
                            }
                            Text {
                                width: parent.width
                                text: Common.Palette.busy
                                    ? "Generating colors from the current wallpaper…"
                                    : Common.Palette.ready
                                    ? "Wallpaper palette ready · light and dark cached"
                                    : Common.Palette.error !== ""
                                    ? Common.Palette.error + " · using fixed colors"
                                    : "Waiting for the wallpaper palette"
                                font.family: Theme.fontMenu
                                font.pixelSize: Theme.fontCaption
                                color: Common.Palette.error !== ""
                                    ? Theme.redText : Theme.textDim
                                wrapMode: Text.Wrap
                                maximumLineCount: 2
                                elide: Text.ElideRight
                            }
                        }
                    }
                }
            }

            Column {
                id: barColorControls
                width: parent.width
                spacing: 6
                SectionHeader { label: "BAR BACKGROUND" }

                Flow {
                    width: parent.width
                    spacing: 9
                    Repeater {
                        id: barColorRepeater
                        model: Settings.barColorChoices
                        delegate: Item {
                            id: colorChoice
                            required property var modelData
                            required property int index
                            readonly property bool selected: Settings.barColorMode === modelData.id
                            readonly property string previewHex: Settings.previewBarColor(modelData.id)
                            width: 34; height: 34
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
                                border.color: colorChoice.selected ? Theme.accent : Theme.textHi
                            }
                            Rectangle {
                                anchors.centerIn: parent
                                width: 22; height: 22; radius: 11
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
                    width: parent.width
                    height: 24
                    Text {
                        anchors.left: parent.left
                        anchors.right: colorValue.left
                        anchors.rightMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        text: page.barColorLabel
                        font.family: Theme.fontMenu
                        font.pixelSize: Theme.fontCaption
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
                        font.pixelSize: Theme.fontCaption
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
                        spacing: 4
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
            title: "Shell sizing and surfaces"
            dirty: ["shellFontSize", "shellScale", "surfaceBorderMode", "surfaceBorderColor",
                "surfaceBorderWidth", "surfaceBorderOpacity", "surfaceCornerRadius"]
                .some(key => Settings[key] !== Settings.defaults[key])
            onResetRequested: Settings.resetKeys(["shellFontSize", "shellScale", "surfaceBorderMode",
                "surfaceBorderColor", "surfaceBorderWidth", "surfaceBorderOpacity", "surfaceCornerRadius"], "Shell appearance")
            SliderRow {
                width: parent.width
                label: "Base font"
                settingKey: "shellFontSize"
                min: 10; max: 24; step: 1
            }
            SliderRow {
                width: parent.width
                label: "UI scale"
                settingKey: "shellScale"
                min: 75; max: 200; step: 5; unit: "%"
            }
            PickerRow {
                width: parent.width
                label: "Panel border"
                settingKey: "surfaceBorderMode"
                model: [{ value: "accent", label: "Accent" }, { value: "subtle", label: "Subtle" },
                    { value: "custom", label: "Custom" }]
            }
            SettingsTextRow {
                width: parent.width
                visible: Settings.surfaceBorderMode === "custom"
                label: "Border color"
                value: Settings.surfaceBorderColor
                dirty: Settings.surfaceBorderColor !== Settings.defaults.surfaceBorderColor
                resetKeys: ["surfaceBorderColor"]
                onCommitted: text => {
                    if (/^#[0-9a-fA-F]{6}$/.test(text)) Settings.set("surfaceBorderColor", text);
                }
            }
            SliderRow {
                width: parent.width
                label: "Border width"
                settingKey: "surfaceBorderWidth"
                min: 0; max: 8; step: 1
            }
            SliderRow {
                width: parent.width
                label: "Border opacity"
                settingKey: "surfaceBorderOpacity"
                min: 0; max: 100; step: 5; unit: "%"
            }
            SliderRow {
                width: parent.width
                label: "Panel corners"
                settingKey: "surfaceCornerRadius"
                min: 0; max: 30; step: 1
            }
        }

        SettingsGroup {
            width: parent.width
            title: "Typography"
            dirty: Settings.font !== Settings.defaults.font
            onResetRequested: Settings.resetKeys(["font"], "Typography")

            Column {
                width: parent.width
                spacing: 3
                Repeater {
                    id: fontRepeater
                    model: Settings.fontChoices
                    delegate: Rectangle {
                        id: fontRow
                        required property var modelData
                        required property int index
                        readonly property bool selected: Settings.font === modelData.id
                        width: parent.width
                        height: Theme.scaled(38)
                        radius: Theme.rowRadius
                        color: selected ? Theme.accentAlpha(0.14) : "transparent"
                        border.width: activeFocus ? 1 : 0
                        border.color: Theme.accent
                        activeFocusOnTab: selected
                        Accessible.role: Accessible.RadioButton
                        Accessible.name: modelData.label + " menu font"
                        Accessible.checked: selected
                        Accessible.onPressAction: {
                            fontState.pulseCenter();
                            Settings.set("font", modelData.id);
                        }
                        Keys.onPressed: event => {
                            let next = -1;
                            if (event.key === Qt.Key_Up || event.key === Qt.Key_Left)
                                next = Math.max(0, index - 1);
                            else if (event.key === Qt.Key_Down || event.key === Qt.Key_Right)
                                next = Math.min(Settings.fontChoices.length - 1, index + 1);
                            else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                                    || event.key === Qt.Key_Space) {
                                fontState.pulseCenter();
                                Settings.set("font", modelData.id); event.accepted = true; return;
                            }
                            if (next >= 0) {
                                Settings.set("font", Settings.fontChoices[next].id);
                                fontRepeater.itemAt(next).forceActiveFocus();
                                event.accepted = true;
                            }
                        }
                        StateLayer {
                            id: fontState
                            anchors.fill: parent
                            radius: parent.radius
                            hovered: fontMouse.containsMouse
                            pressed: fontMouse.pressed
                            focused: fontRow.activeFocus
                            tint: fontRow.selected ? Theme.accent : Theme.textHi
                            pressPoint: Qt.point(fontMouse.mouseX, fontMouse.mouseY)
                        }
                        Rectangle {
                            id: radioRing
                            anchors.left: parent.left
                            anchors.leftMargin: 8
                            anchors.verticalCenter: parent.verticalCenter
                            width: 14; height: 14; radius: 7
                            color: "transparent"
                            border.width: 1.5
                            border.color: fontRow.selected ? Theme.accent : Theme.dotDim
                            Rectangle {
                                anchors.centerIn: parent
                                width: 6; height: 6; radius: 3
                                color: Theme.accent
                                visible: fontRow.selected
                            }
                        }
                        Text {
                            id: fontName
                            anchors.left: radioRing.right
                            anchors.leftMargin: 9
                            anchors.verticalCenter: parent.verticalCenter
                            width: Math.max(0, parent.width * 0.42 - x)
                            text: fontRow.modelData.label
                            font.family: fontRow.modelData.family
                            font.pixelSize: Theme.fontCaption
                            font.weight: Theme.weightMedium
                            color: fontRow.selected ? Theme.textHi : Theme.textMid
                            elide: Text.ElideRight
                        }
                        Text {
                            anchors.left: parent.left
                            anchors.leftMargin: parent.width * 0.44
                            anchors.right: parent.right
                            anchors.rightMargin: 8
                            anchors.verticalCenter: parent.verticalCenter
                            horizontalAlignment: Text.AlignRight
                            text: Qt.formatDateTime(clock.date, Settings.clock24 ? "HH:mm" : "h:mm AP")
                                + " · Wed 06 · " + page.tempPreview
                            font.family: fontRow.modelData.family
                            font.pixelSize: Theme.fontCaption
                            color: Theme.textLow
                            elide: Text.ElideLeft
                        }
                        MouseArea {
                            id: fontMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                fontRow.forceActiveFocus();
                                Settings.set("font", fontRow.modelData.id);
                            }
                        }
                    }
                }
            }
        }

        SettingsGroup {
            width: parent.width
            title: "Accessibility"
            dirty: Settings.reducedMotion !== Settings.defaults.reducedMotion
                || Settings.textScale !== Settings.defaults.textScale
                || Settings.interfaceDensity !== Settings.defaults.interfaceDensity
            onResetRequested: Settings.resetKeys(["reducedMotion", "textScale",
                "interfaceDensity"], "Accessibility")

            SwitchRow {
                width: parent.width
                label: "Reduce motion"
                settingKey: "reducedMotion"
                description: "Remove panel, reveal, hover, and activity animations"
            }
            PickerRow {
                width: parent.width
                label: "Text size"
                settingKey: "textScale"
                caption: "applies across the shell"
                captionMono: false
                model: [
                    { value: "default", label: "Default" },
                    { value: "large", label: "Large" },
                    { value: "larger", label: "Larger" }
                ]
            }
            PickerRow {
                width: parent.width
                label: "Control spacing"
                settingKey: "interfaceDensity"
                caption: "touch targets and row height"
                captionMono: false
                model: [
                    { value: "compact", label: "Compact" },
                    { value: "default", label: "Default" },
                    { value: "comfortable", label: "Comfortable" }
                ]
            }
        }

        SettingsGroup {
            width: parent.width
            title: "Preset"

            ResponsiveActionRow {
                width: parent.width
                actionsFirst: true
                description: "Shared typography, sizing and panel borders; keeps your accounts and layout"
                SettingsAction {
                    text: "Apply Omarchy"
                    glyph: "text_fields"
                    onTriggered: Settings.applyAppearancePreset("omarchy")
                }
                SettingsAction {
                    text: "Apply Cybex"
                    glyph: "text_fields"
                    onTriggered: Settings.applyAppearancePreset("cybex")
                }
            }

            ResponsiveActionRow {
                width: parent.width
                actionsFirst: true
                description: "Keeps widget order and stored floating dimensions"
                SettingsAction {
                    text: "Apply Layered Hug"
                    glyph: "auto_awesome"
                    onTriggered: Settings.applyLayeredHugPreset()
                }
            }
        }
    }
}
