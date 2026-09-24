pragma ComponentBehavior: Bound
import QtQuick
import "../Common"

SettingsPage {
    id: page
    readonly property SystemSettingsBackend service: SystemSettings.network
    property var draft: null
    property bool dirty: false
    property int secondsLeft: 0
    readonly property var profiles: service.snapshot.profiles || []
    readonly property var editableProfiles: profiles.map(p => ({value: p.uuid,
        label: p.name + (p.active ? " · connected" : "")}))
    function load(uuid) {
        const profile = profiles.find(p => p.uuid === uuid);
        draft = profile ? JSON.parse(JSON.stringify(profile)) : null;
        dirty = false;
    }
    function change(key, value) {
        const next = Object.assign({}, draft);
        next[key] = value;
        draft = next;
        dirty = true;
    }
    Claim {
        active: page.visible && Settings.panelOpen
        onClaimed: {
            page.load((page.profiles[0] || {}).uuid);
            page.service.acquire();
        }
        onReleased: { page.service.release(); page.draft = null; page.dirty = false; }
    }
    Connections {
        target: page.service
        function onSnapshotChanged() {
            if (!page.dirty && !page.service.preview)
                page.load(page.draft ? page.draft.uuid : (page.profiles[0] || {}).uuid);
        }
        function onCompleted(result) {
            if (result.success && !result.checkpoint)
                page.dirty = false;
        }
    }
    Timer {
        interval: 500
        running: page.service.preview !== null
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            if (!page.service.preview) return;
            page.secondsLeft = Math.max(0, Math.ceil(page.service.preview.expires - Date.now() / 1000));
            if (page.secondsLeft === 0 && !page.service.busy) {
                page.service.preview = null;
                page.service.message = "The trial expired; NetworkManager is restoring the previous settings.";
                page.dirty = false;
                page.service.refresh();
            }
        }
    }
    Column {
        width: parent.width
        spacing: Theme.settingsGroupSpacing
        SystemServiceStatus { width: parent.width; service: page.service }
        SettingsGroup {
            width: parent.width
            title: "Connections"
            SettingsHint {
                width: parent.width
                text: (page.service.snapshot.devices || []).map(d => d.name).join(" · ") || "No physical network adapters"
            }
            Flow {
                width: parent.width
                spacing: Theme.controlSpacing
                SettingsAction { text: "Connect to Wi-Fi"; onTriggered: { Settings.closePanel(); Popouts.openPanel("wifi", "right"); } }
                SettingsAction { text: "Advanced connection editor"; onTriggered: SystemSettings.openExternal("network") }
            }
            SettingsHint {
                width: parent.width
                text: "VPN, enterprise certificates, bridges and routing are available in the advanced editor."
            }
            SystemChoice {
                width: parent.width
                label: "Saved connection"
                choices: page.editableProfiles
                current: page.draft ? page.draft.uuid : ""
                enabled: !page.service.busy && !page.service.preview && !page.dirty
                onPicked: value => page.load(value)
            }
        }
        SettingsGroup {
            width: parent.width
            visible: page.service.preview !== null
            title: "Keep these network settings?"
            SettingsHint { width: parent.width; text: "Automatic restore in " + page.secondsLeft + " seconds. Closing this page restores the previous settings." }
            Flow {
                width: parent.width
                enabled: !page.service.busy
                SettingsAction {
                    text: "Keep changes"
                    onTriggered: page.service.run(Object.assign({}, page.service.preview, {action: "confirm"}))
                }
                SettingsAction {
                    text: "Revert now"
                    onTriggered: page.service.run({action: "rollback", checkpoint: page.service.preview.checkpoint})
                }
            }
        }
        Column {
            width: parent.width
            spacing: Theme.settingsGroupSpacing
            visible: page.draft !== null
            enabled: !page.service.busy && !page.service.preview && !!page.draft && page.draft.supported
            SettingsHint { width: parent.width; text: page.draft && !page.draft.supported ? "This profile needs the advanced connection editor." : "Changes apply only to the selected connection." }
            SwitchRow {
                width: parent.width
                label: "Autoconnect"
                checked: page.draft ? page.draft.autoconnect : false
                onToggled: value => page.change("autoconnect", value)
            }
            PickerRow {
                width: parent.width
                label: "Metered connection"
                model: [{value: 0, label: "Automatic"}, {value: 1, label: "Yes"}, {value: 2, label: "No"}]
                current: page.draft ? page.draft.metered : 0
                onPicked: value => page.change("metered", value)
            }
            IpSettings {
                width: parent.width; title: "IPv4"
                config: page.draft ? page.draft.ipv4 : ({method: "auto", addresses: "", gateway: "", dns: "", autoDns: true})
                onEdited: value => page.change("ipv4", value)
            }
            IpSettings {
                width: parent.width; title: "IPv6"
                config: page.draft ? page.draft.ipv6 : ({method: "auto", addresses: "", gateway: "", dns: "", autoDns: true})
                onEdited: value => page.change("ipv6", value)
            }
            Flow {
                width: parent.width
                SettingsAction {
                    text: "Apply changes"
                    enabled: page.dirty
                    onTriggered: page.service.run(Object.assign({}, page.draft, {action: "apply"}))
                }
                SettingsAction {
                    text: "Discard edits and reload"
                    onTriggered: { page.load(page.draft.uuid); page.service.refresh(); }
                }
            }
        }
    }
}
