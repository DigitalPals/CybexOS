pragma ComponentBehavior: Bound
import QtQuick
import "../Common"
import "../Common/SettingsHelpers.js" as SettingsHelpers

// The menubar's own background, on the Bar page beside the bar's shape. The
// accent and palette stay on Appearance; this color only paints the slab.
//
// One settings row like any other (2026-09 redesign): the label on the left,
// the swatches ending on the page's control edge, and what the choice
// resolves to — its name and colour, and whether it follows the theme — on
// the row's hint line. Custom reveals its sliders as attached sub-rows.
SettingsGroup {
    id: barColorControls
    width: parent.width
    title: "Background"

    readonly property int barColorIndex: {
        for (let i = 0; i < Settings.barColorChoices.length; ++i) {
            if (Settings.barColorChoices[i].id === Settings.barColorMode)
                return i;
        }
        return 0;
    }
    readonly property string barColorLabel: Settings.barColorChoices[barColorIndex].label
    readonly property bool adaptive: Settings.barColorMode === "default"
        || Settings.barColorMode === "macos"

    SettingsRow {
        id: barColorRow
        width: parent.width
        label: "Bar background"
        settingKey: "barColorMode"
        resetKeys: ["barColorMode", "barCustomHue", "barCustomSaturation", "barCustomLightness"]
        hint: barColorControls.barColorLabel + " · "
            + (barColorControls.adaptive ? "adapts to the theme · " : "")
            + Settings.effectiveBarColor.toUpperCase()
        narrowHeight: Theme.settingsStackOffset + swatches.height
        wideHeight: Math.max(Theme.panelRowHeight, swatches.height) + barColorRow.rowPad * 2
        narrowLabelInset: barColorRow.undoWidth
        controlLeft: swatches.x

        Row {
            id: swatches
            x: barColorRow.narrow ? barColorRow.markInset : barColorRow.contentRight - width
            y: barColorRow.narrow ? Theme.settingsStackOffset : (barColorRow.lineHeight - height) / 2
            opacity: barColorRow.controlOpacity
            spacing: Theme.scaled(2)
            Accessible.role: Accessible.Grouping
            Accessible.name: "Bar background"

            Repeater {
                id: barColorRepeater
                model: Settings.barColorChoices
                delegate: Item {
                    id: colorChoice
                    required property var modelData
                    required property int index
                    readonly property bool selected: Settings.barColorMode === modelData.id
                    readonly property string previewHex: Settings.previewBarColor(modelData.id)
                    width: Theme.settingsControlHeight; height: width
                    activeFocusOnTab: selected || (index === 0 && Settings.barColorMode === "")
                    Accessible.role: Accessible.RadioButton
                    Accessible.name: modelData.label + " menubar color"
                    Accessible.description: previewHex.toUpperCase()
                    Accessible.checked: selected
                    Accessible.onPressAction: barColorRow.commit(modelData.id)
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
                            barColorRow.commit(modelData.id);
                            event.accepted = true; return;
                        }
                        // Focus before the pick: see PillRow.
                        if (next >= 0) {
                            barColorRepeater.itemAt(next).forceActiveFocus();
                            barColorRow.commit(Settings.barColorChoices[next].id);
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
                        width: Math.round(parent.width * 0.68); height: width; radius: width / 2
                        color: colorChoice.previewHex
                        border.width: 1
                        border.color: Theme.stroke
                    }
                    SettingsTooltip {
                        visible: colorMouse.containsMouse
                        text: colorChoice.modelData.label + " · " + colorChoice.previewHex.toUpperCase()
                    }
                    MouseArea {
                        id: colorMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            colorChoice.forceActiveFocus();
                            barColorRow.commit(colorChoice.modelData.id);
                        }
                    }
                }
            }
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
