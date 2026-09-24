pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import "../Common"
import "../Popovers/Drawer"

SettingsPage {
    id: page
    readonly property SystemSettingsBackend service: SystemSettings.sound
    property var pendingBalance: null
    Claim {
        active: page.visible && Settings.panelOpen
        onClaimed: page.service.acquire()
        onReleased: { page.pendingBalance = null; page.service.release(); }
    }
    Timer {
        id: balanceDelay
        interval: 180
        onTriggered: {
            if (!page.pendingBalance) return;
            if (page.service.busy) { restart(); return; }
            page.service.run(page.pendingBalance);
            page.pendingBalance = null;
        }
    }
    Column {
        width: parent.width
        spacing: Theme.settingsGroupSpacing
        SystemServiceStatus { width: parent.width; service: page.service }
        SettingsGroup {
            width: parent.width
            title: "Devices and applications"
            DrawerSound { width: parent.width; showSettingsAction: false }
        }
        SettingsGroup {
            width: parent.width
            title: "Hardware profiles"
            Repeater {
                model: ScriptModel { values: (page.service.snapshot.cards || []).map(c => c.name) }
                delegate: SystemChoice {
                    required property string modelData
                    readonly property var card: (page.service.snapshot.cards || []).find(c => c.name === modelData)
                        || {label: "", profiles: [], profile: "", name: ""}
                    width: parent.width
                    label: card.label
                    choices: card.profiles
                    current: card.profile
                    enabled: !page.service.busy
                    onPicked: value => page.service.run({action: "profile", name: card.name, value: value})
                }
            }
        }
        Repeater {
            model: ["sinks", "sources"]
            delegate: SettingsGroup {
                id: devices
                required property string modelData
                width: parent.width
                title: modelData === "sinks" ? "Output ports and balance" : "Input ports and balance"
                Repeater {
                    model: ScriptModel { values: (page.service.snapshot[devices.modelData] || []).map(d => d.name) }
                    delegate: Column {
                        id: device
                        required property string modelData
                        readonly property var info: (page.service.snapshot[devices.modelData] || []).find(d => d.name === modelData)
                            || {ports: [], stereo: false, label: "", port: "", name: "", balance: 0}
                        width: parent.width
                        visible: info.ports.length > 0 || info.stereo
                        SystemChoice {
                            width: parent.width
                            visible: device.info.ports.length > 0
                            label: device.info.label
                            choices: device.info.ports
                            current: device.info.port
                            enabled: !page.service.busy
                            onPicked: value => page.service.run({action: "port", kind: devices.modelData,
                                name: device.info.name, value: value})
                        }
                        SliderRow {
                            width: parent.width
                            visible: device.info.stereo
                            label: "Balance"
                            hint: device.info.label + " · left −1 / center 0 / right +1"
                            value: device.info.balance
                            min: -1; max: 1; step: 0.05; decimals: 2
                            onMoved: value => {
                                page.pendingBalance = {action: "balance", kind: devices.modelData,
                                    name: device.info.name, value: value};
                                balanceDelay.restart();
                            }
                        }
                    }
                }
            }
        }
        SettingsGroup {
            width: parent.width
            title: "Application routing"
            Repeater {
                model: ScriptModel { values: (page.service.snapshot.streams || []).map(s => s.serial) }
                delegate: Column {
                    id: stream
                    required property string modelData
                    readonly property var info: (page.service.snapshot.streams || []).find(s => s.serial === modelData)
                        || {kind: "sink-inputs", label: "", muted: false, serial: "", index: -1, target: -1}
                    readonly property var destinations: page.service.snapshot[info.kind === "sink-inputs" ? "sinks" : "sources"] || []
                    width: parent.width
                    enabled: !page.service.busy
                    SystemChoice {
                        width: parent.width
                        label: stream.info.label + (stream.info.kind === "sink-inputs" ? " · playback" : " · recording")
                        choices: stream.destinations.map(d => ({value: d.name, label: d.label}))
                        current: (stream.destinations.find(d => d.index === stream.info.target) || {}).name || ""
                        onPicked: value => page.service.run({action: "route", kind: stream.info.kind,
                            index: stream.info.index, serial: stream.info.serial, value: value})
                    }
                    SwitchRow {
                        width: parent.width
                        label: "Mute application"
                        checked: stream.info.muted
                        onToggled: value => page.service.run({action: "mute", kind: stream.info.kind,
                            index: stream.info.index, serial: stream.info.serial, value: value})
                    }
                }
            }
        }
        SettingsAction {
            text: "Advanced audio controls"
            onTriggered: SystemSettings.openExternal("sound")
        }
    }
}
