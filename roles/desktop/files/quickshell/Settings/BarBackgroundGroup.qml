pragma ComponentBehavior: Bound
import QtQuick
import "../Common"
import "../Common/SettingsHelpers.js" as SettingsHelpers

// The menubar's own background, on the Bar page beside the bar's shape. The
// accent and palette stay on Appearance; this color only paints the slab.
SettingsGroup {
    id: barColorControls
    width: parent.width
    title: "Background"
    rowSpacing: Theme.settingsContentSpacing

    readonly property int barColorIndex: {
        for (let i = 0; i < Settings.barColorChoices.length; ++i) {
            if (Settings.barColorChoices[i].id === Settings.barColorMode)
                return i;
        }
        return 0;
    }
    readonly property string barColorLabel: Settings.barColorChoices[barColorIndex].label

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
                    // Focus before the pick: see PillRow.
                    if (next >= 0) {
                        barColorRepeater.itemAt(next).forceActiveFocus();
                        Settings.set("barColorMode", Settings.barColorChoices[next].id);
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
            text: barColorControls.barColorLabel
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
