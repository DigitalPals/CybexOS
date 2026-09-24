pragma ComponentBehavior: Bound
import QtQuick

SettingsGroup {
    id: root
    property var config: ({method: "auto", addresses: "", gateway: "", dns: "", autoDns: true})
    signal edited(var value)
    function change(key, value) {
        const next = Object.assign({}, config);
        next[key] = value;
        edited(next);
    }
    PickerRow {
        width: parent.width
        label: "Method"
        current: root.config.method
        model: [{value: "auto", label: "Automatic"}, {value: "manual", label: "Manual"}, {value: "disabled", label: "Disabled"}]
        onPicked: value => root.change("method", value)
    }
    SettingsField {
        width: parent.width
        visible: root.config.method === "manual"
        placeholderText: "Addresses and prefixes, separated by commas"
        Accessible.name: root.title + " addresses and prefixes"
        text: root.config.addresses
        onTextEdited: root.change("addresses", text)
    }
    SettingsField {
        width: parent.width
        visible: root.config.method === "manual"
        placeholderText: "Gateway (optional)"
        Accessible.name: root.title + " gateway"
        text: root.config.gateway
        onTextEdited: root.change("gateway", text)
    }
    SwitchRow {
        width: parent.width
        visible: root.config.method !== "disabled"
        label: "Automatic DNS"
        checked: root.config.autoDns
        onToggled: value => root.change("autoDns", value)
    }
    SettingsField {
        width: parent.width
        visible: root.config.method !== "disabled"
        placeholderText: "Additional DNS servers, separated by commas"
        Accessible.name: root.title + " DNS servers"
        text: root.config.dns
        onTextEdited: root.change("dns", text)
    }
}
