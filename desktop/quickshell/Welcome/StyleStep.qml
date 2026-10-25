pragma ComponentBehavior: Bound
import QtQuick
import "../Common"
import "../Common/ThemeHelpers.js" as ThemeHelpers
import "../Settings" as SettingsUi
Column {
    id: root
    spacing: Theme.scaled(18)
    readonly property var accents: [Settings.defaults.accent, "#9ecbeb", "#a992e0", "#79b88b", "#d3b47e", "#e8837a"]
    Component.onCompleted: { if (!Themes.loaded) Themes.refresh(); }
    Row {
        spacing: Theme.controlSpacing
        Repeater {
            model: [{value: "dark", label: I18n.tr("Dark")}, {value: "light", label: I18n.tr("Light")}]
            delegate: SettingsUi.SettingsAction {
                required property var modelData
                text: modelData.label
                primary: Settings.themeMode === modelData.value
                Accessible.role: Accessible.RadioButton
                Accessible.checked: primary
                onTriggered: Settings.set("themeMode", modelData.value)
            }
        }
    }
    GuideText { text: I18n.tr("Choose a starting point"); font.weight: Theme.weightSemibold }
    Flow {
        width: parent.width; spacing: Theme.scaled(10)
        Repeater {
            model: Themes.entries
            delegate: Rectangle {
                id: card
                required property var modelData
                readonly property var swatches: ThemeHelpers.swatches(modelData, {
                    dark: {background: Theme.darkBackground.toString(), text: Theme.darkTextHi.toString()},
                    light: {background: Theme.lightBackground.toString(), text: Theme.lightTextHi.toString()}})
                width: Theme.scaled(140); height: Theme.scaled(92); radius: Theme.cardRadius
                color: Theme.cardFill
                border.width: activeFocus || Themes.current.value === modelData.id ? 2 : 1
                border.color: activeFocus ? Theme.textHi : Themes.current.value === modelData.id ? Theme.accent : Theme.stroke
                activeFocusOnTab: true
                Accessible.role: Accessible.RadioButton
                Accessible.name: modelData.name
                Accessible.checked: Themes.current.value === modelData.id
                Accessible.onPressAction: Themes.apply(modelData.id)
                Keys.onPressed: event => {
                    if ([Qt.Key_Return, Qt.Key_Enter, Qt.Key_Space].includes(event.key)) {
                        Themes.apply(modelData.id); event.accepted = true;
                    }
                }
                Row {
                    anchors.horizontalCenter: parent.horizontalCenter; y: Theme.scaled(16); spacing: Theme.controlSpacing
                    Repeater {
                        model: card.swatches
                        delegate: Rectangle { required property string modelData; width: Theme.scaled(22); height: width; radius: width / 2; color: modelData; border.width: 1; border.color: Theme.stroke }
                    }
                }
                GuideText {
                    anchors.left: parent.left; anchors.right: parent.right; anchors.margins: Theme.controlSpacing
                    anchors.bottom: parent.bottom; anchors.bottomMargin: Theme.scaled(12)
                    text: card.modelData.name; horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight; maximumLineCount: 1
                    font.pixelSize: Theme.typography.secondary
                }
                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { card.forceActiveFocus(); Themes.apply(card.modelData.id); } }
            }
        }
    }
    GuideText { width: parent.width; visible: Themes.error !== ""; text: Themes.error; color: Theme.redText }
    SettingsUi.PickerRow {
        width: parent.width; label: I18n.tr("Accent source"); settingKey: "paletteMode"
        model: [{value: "wallpaper", label: I18n.tr("Match my wallpaper")}, {value: "fixed", label: I18n.tr("Fixed")}]
    }
    Row {
        visible: Settings.paletteMode === "fixed"; spacing: Theme.scaled(10)
        Repeater {
            model: root.accents
            delegate: Rectangle {
                id: swatch
                required property string modelData
                width: Theme.scaled(34); height: width; radius: width / 2; color: modelData
                border.width: activeFocus || Settings.accent === modelData ? 3 : 1
                border.color: activeFocus ? Theme.textHi : Settings.accent === modelData ? Theme.accentText : Theme.stroke
                activeFocusOnTab: true
                Accessible.role: Accessible.RadioButton
                Accessible.name: I18n.format("Use accent %1", [modelData])
                Accessible.checked: Settings.accent === modelData
                Accessible.onPressAction: Settings.set("accent", modelData)
                Keys.onPressed: event => {
                    if ([Qt.Key_Return, Qt.Key_Enter, Qt.Key_Space].includes(event.key)) {
                        Settings.set("accent", modelData); event.accepted = true;
                    }
                }
                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { swatch.forceActiveFocus(); Settings.set("accent", swatch.modelData); } }
            }
        }
    }
    SettingsUi.SwitchRow {
        width: parent.width; label: I18n.tr("Glass effect"); settingKey: "glassEnabled"
        disabledReason: Settings.highContrast ? I18n.tr("Off while High contrast is on") : ""
    }
    SettingsUi.PickerRow {
        width: parent.width; label: I18n.tr("Text size"); settingKey: "textScale"
        model: [{value: "default", label: I18n.tr("Default")}, {value: "large", label: I18n.tr("Large")}, {value: "larger", label: I18n.tr("Larger")}]
    }
}
