pragma ComponentBehavior: Bound
import QtQuick
import "../Common"
import "../Common/PluginSchema.js" as PluginSchema

Column {
    id: root
    required property var descriptor
    property string validationError: ""
    readonly property string widgetKey: descriptor.key || ""
    onWidgetKeyChanged: validationError = ""
    readonly property var settings: descriptor.settings || ({})
    // The plugin's declared settings, drawn as ordinary settings rows. Saved
    // keys the schema does not describe stay in the raw editor below them.
    readonly property var schema: PluginSchema.fields(descriptor.manifest || {}, settings,
        descriptor.defaults || {})
    readonly property var schemaFields: schema.fields
    // Discovery replaces descriptor objects. Preserve rows and draft fields
    // while the same widget's values refresh, but recreate them when its
    // identity or its set of keys changes.
    readonly property string schemaJson: JSON.stringify([widgetKey,
        schemaFields.map(field => field.key + ":" + field.type + (field.slider ? ":slider" : ""))])
    readonly property string fieldsJson: JSON.stringify([widgetKey, schema.other])
    // One label column for every row here (SettingsRow.minimumLabelWidth,
    // gutter excluded), wide enough for the longest plugin label up to a
    // share of the dialog; longer ones elide.
    readonly property int labelColumn: Math.round(Math.max(Theme.settingsLabelWidth,
        Math.min(labelProbe.implicitWidth + Theme.controlSpacing * 2,
            width * 0.42 - Theme.settingsMarkInset)))
    spacing: 12

    function fieldFor(key) {
        return schemaFields.find(field => field.key === key) || null;
    }
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
        minimumLabelWidth: root.labelColumn
        label: "Width"
        min: 24; max: 320; step: 1; unit: "px"
        value: root.descriptor.width || 120
        enabled: !UserPlugins.busy
        onMoved: value => UserPlugins.configureWidget(root.descriptor, { width: Math.round(value) })

        // Measures the labels for labelColumn. Laid-out text, not a
        // FontMetrics call, so the column follows the face as it resolves.
        // Parked in this row because the dialog's own Column would give it
        // a slot; transparent rather than hidden, which would zero it.
        Column {
            id: labelProbe
            opacity: 0
            enabled: false
            Accessible.ignored: true
            Repeater {
                // Keyed like the rows, so a saved value does not rebuild it.
                model: ["Width"].concat(JSON.parse(root.schemaJson)[1])
                Text {
                    required property string modelData
                    readonly property var field: root.fieldFor(modelData.split(":")[0])
                    text: modelData === "Width" ? modelData : field ? field.label : ""
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.control
                    Accessible.ignored: true
                }
            }
        }
    }

    SettingsGroup {
        width: parent.width
        visible: root.schemaFields.length > 0
        title: "Plugin settings"

        Repeater {
            model: JSON.parse(root.schemaJson)[1]
            delegate: Loader {
                id: row
                required property string modelData
                readonly property string key: modelData.split(":")[0]
                readonly property var field: root.fieldFor(key)
                // What the control shows while a write is in flight: the
                // helper round-trips through a process and a rescan, and a
                // control that snapped back meanwhile would read as refused.
                property var pending: undefined
                readonly property var shown: pending !== undefined ? pending
                    : field ? field.value : undefined
                property string error: ""
                width: parent ? parent.width : 0
                active: field !== null
                onFieldChanged: {
                    if (pending !== undefined && field
                            && JSON.stringify(field.value) === JSON.stringify(pending))
                        pending = undefined;
                }
                function write(value) {
                    pending = value;
                    error = "";
                    root.setValue(key, value);
                }
                function reset() {
                    if (field && field.hasDefault)
                        write(field.defaultValue);
                }
                Connections {
                    target: UserPlugins
                    function onErrorChanged() {
                        if (UserPlugins.error !== "")
                            row.pending = undefined;
                    }
                }
                Timer {
                    // Sliders report every step of a drag; save where it rests.
                    id: settle
                    interval: 300
                    onTriggered: root.setValue(row.key, row.pending)
                }
                sourceComponent: !field ? null
                    : field.type === "boolean" ? switchField
                    : field.type === "enum" ? pickerField
                    : field.type === "multiselect" ? chipsField
                    : field.slider ? sliderField
                    : textField

                Component {
                    id: switchField
                    SwitchRow {
                        width: row.width
                        minimumLabelWidth: root.labelColumn
                        label: row.field.label
                        description: row.field.description
                        checked: row.shown === true
                        dirty: row.field.dirty
                        onToggled: value => row.write(value)
                        onResetRequested: row.reset()
                    }
                }
                Component {
                    id: pickerField
                    PickerRow {
                        width: row.width
                        minimumLabelWidth: root.labelColumn
                        label: row.field.label
                        hint: row.field.description
                        model: row.field.options
                        current: row.shown
                        dirty: row.field.dirty
                        onPicked: value => row.write(value)
                        onResetRequested: row.reset()
                    }
                }
                Component {
                    id: chipsField
                    ChipToggleRow {
                        width: row.width
                        minimumLabelWidth: root.labelColumn
                        label: row.field.label
                        hint: chosen.length === 0 && row.field.emptyText !== ""
                            ? row.field.emptyText : row.field.description
                        model: row.field.options
                        chosen: row.shown || []
                        dirty: row.field.dirty
                        onToggledOption: value => row.write(PluginSchema.toggled(row.field, chosen, value))
                        onResetRequested: row.reset()
                    }
                }
                Component {
                    id: sliderField
                    SliderRow {
                        width: row.width
                        minimumLabelWidth: root.labelColumn
                        label: row.field.label
                        hint: row.field.description
                        min: row.field.min
                        max: row.field.max
                        step: row.field.step
                        value: row.shown
                        unit: ""
                        decimals: row.field.type === "integer" || row.field.step >= 1 ? 0
                            : row.field.step === 0 ? 2
                            : Math.min(3, (String(row.field.step).split(".")[1] || "").length)
                        valueWidth: 52
                        dirty: row.field.dirty
                        onMoved: value => {
                            row.pending = value;
                            settle.restart();
                        }
                        onResetRequested: {
                            settle.stop();
                            row.reset();
                        }
                    }
                }
                Component {
                    id: textField
                    SettingsTextRow {
                        width: row.width
                        minimumLabelWidth: root.labelColumn
                        label: row.field.label
                        numeric: row.field.type !== "string"
                        value: String(row.shown)
                        hint: row.error !== "" ? row.error : row.field.description
                        hintTone: row.error !== "" ? "error" : "info"
                        dirty: row.field.dirty
                        onCommitted: text => {
                            if (row.field.type === "string") {
                                row.write(text);
                                return;
                            }
                            const number = PluginSchema.parseNumber(row.field, text);
                            if (number === null)
                                row.error = PluginSchema.numberHint(row.field);
                            else
                                row.write(number);
                        }
                        onResetRequested: row.reset()
                    }
                }
            }
        }
    }

    SettingsGroup {
        width: parent.width
        visible: root.schemaFields.length === 0 || root.schema.other.length > 0
        title: root.schemaFields.length > 0 ? "Other saved settings" : "Plugin settings"

        Text {
            width: parent.width
            leftPadding: Theme.settingsMarkInset
            text: root.schemaFields.length > 0
                ? "Saved values the plugin does not describe. Structured values use JSON; text fields use plain text."
                : "These settings are supplied by the plugin. Structured values use JSON; text fields use plain text."
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
