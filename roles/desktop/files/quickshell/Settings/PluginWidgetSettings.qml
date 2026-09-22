pragma ComponentBehavior: Bound
import QtQuick
import "../Common"

Column {
    id: root
    required property var descriptor
    property string validationError: ""
    readonly property string widgetKey: descriptor.key || ""
    onWidgetKeyChanged: validationError = ""
    readonly property var settings: descriptor.settings || ({})
    // Discovery replaces descriptor objects. Preserve draft fields while the
    // same widget's values refresh, but recreate them when its identity changes.
    readonly property string fieldsJson: JSON.stringify([widgetKey, Object.keys(settings).sort()])
    spacing: 12
    function setValue(key, value) {
        const patch = {};
        patch[key] = value;
        UserPlugins.mergeSettings(descriptor.id, patch, descriptor.instanceName);
        validationError = "";
    }
    function commitValue(key, text) {
        const current = settings[key];
        if (typeof current === "string") { setValue(key, text); return; }
        try {
            const value = JSON.parse(text);
            if (typeof value !== typeof current || Array.isArray(value) !== Array.isArray(current)
                    || (current === null) !== (value === null))
                throw new Error("Keep the same value type for " + key + ".");
            setValue(key, value);
        } catch (error) {
            validationError = "Invalid value for " + key + ": " + error.message;
        }
    }
    SliderRow {
        width: parent.width
        label: "Width"
        min: 24; max: 320; step: 1; unit: "px"
        value: root.descriptor.width || 120
        enabled: !UserPlugins.busy
        onMoved: value => UserPlugins.configureWidget(root.descriptor, { width: Math.round(value) })
    }
    Text {
        width: parent.width
        leftPadding: Theme.settingsMarkInset
        text: "Plugin settings"
        font.family: Theme.fontMenu
        font.pixelSize: Theme.typography.primary
        font.weight: Theme.weightSemibold
        color: Theme.textHi
    }
    Text {
        width: parent.width
        leftPadding: Theme.settingsMarkInset
        text: "These settings are supplied by the plugin. Structured values use JSON; text fields use plain text."
        font.family: Theme.fontMenu
        font.pixelSize: Theme.typography.secondary
        color: Theme.textDim
        wrapMode: Text.Wrap
    }
    Repeater {
        model: JSON.parse(root.fieldsJson)[1]
        delegate: Loader {
            id: setting
            required property string modelData
            property string ownerKey: ""
            Component.onCompleted: ownerKey = root.widgetKey
            width: root.width
            readonly property var value: root.settings[modelData]
            sourceComponent: typeof value === "boolean" ? booleanField : valueField
            Component {
                id: booleanField
                SwitchRow {
                    width: setting.width
                    label: setting.modelData
                    checked: setting.value
                    enabled: !UserPlugins.busy
                    onToggled: value => root.setValue(setting.modelData, value)
                }
            }
            Component {
                id: valueField
                Column {
                    width: setting.width
                    spacing: 6
                    Text {
                        width: parent.width
                        leftPadding: Theme.settingsMarkInset
                        text: setting.modelData
                        color: Theme.textMid
                        font.family: Theme.fontMenu
                        font.pixelSize: Theme.typography.control
                        wrapMode: Text.Wrap
                    }
                    SettingsField {
                        id: input
                        x: Theme.settingsMarkInset
                        width: parent.width - x
                        readonly property string savedValue: typeof setting.value === "string" ? setting.value : JSON.stringify(setting.value)
                        Component.onCompleted: text = savedValue
                        onSavedValueChanged: { if (!activeFocus) text = savedValue; }
                        Accessible.name: setting.modelData
                        onEditingFinished: {
                            if (setting.ownerKey === root.widgetKey && text !== savedValue)
                                root.commitValue(setting.modelData, text);
                        }
                        Keys.onPressed: event => {
                            if (event.key === Qt.Key_Escape) {
                                text = savedValue;
                                root.validationError = "";
                                event.accepted = true;
                            }
                        }
                    }
                }
            }
        }
    }
    Text {
        width: parent.width
        visible: Object.keys(root.settings).length === 0
        leftPadding: Theme.settingsMarkInset
        text: "This plugin has no saved settings or declared defaults."
        font.family: Theme.fontMenu
        font.pixelSize: Theme.typography.secondary
        color: Theme.textDim
        wrapMode: Text.Wrap
    }
    ResponsiveActionRow {
        width: parent.width
        description: "Set a value the plugin documents but does not list here"
        SettingsAction {
            id: advancedAction
            property bool expanded: false
            text: expanded ? "Hide advanced settings" : "Add a plugin setting"
            glyph: "tune"
            onTriggered: expanded = !expanded
        }
    }
    Column {
        x: Theme.settingsMarkInset
        width: parent.width - x
        spacing: 8
        visible: advancedAction.expanded
        SettingsField {
            id: keyField
            width: parent.width
            placeholderText: "Setting name from the plugin documentation"
            Accessible.name: "Plugin setting name"
        }
        SettingsField {
            id: valueFieldInput
            width: parent.width
            placeholderText: "JSON value, for example true, 42, or \"text\""
            Accessible.name: "Plugin setting JSON value"
        }
        SettingsAction {
            text: "Save setting"
            glyph: "check"
            enabled: !UserPlugins.busy && keyField.text.trim() !== ""
            onTriggered: {
                try {
                    root.setValue(keyField.text.trim(), JSON.parse(valueFieldInput.text));
                    keyField.text = "";
                    valueFieldInput.text = "";
                } catch (error) { root.validationError = "Enter a valid JSON value: " + error.message; }
            }
        }
    }
    Text {
        width: parent.width
        visible: root.validationError !== ""
        leftPadding: Theme.settingsMarkInset
        text: root.validationError
        color: Theme.redText
        font.family: Theme.fontMenu
        font.pixelSize: Theme.typography.secondary
        wrapMode: Text.Wrap
        Accessible.role: Accessible.AlertMessage
    }
    ResponsiveActionRow {
        width: parent.width
        description: "Update, disable, or remove it on the Plugins page"
        SettingsAction {
            text: "Manage this plugin"
            glyph: "extension"
            onTriggered: Settings.page = "plugins"
        }
    }
}
