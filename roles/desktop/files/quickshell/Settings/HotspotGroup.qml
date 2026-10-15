pragma ComponentBehavior: Bound
import QtQuick
import "../Common"
import "../Common/NetworkHelpers.js" as NetworkHelpers

// Settings -> Network -> Hotspot, shown only on a computer with Wi-Fi: one
// switch, the network name, and the join card. network-tool.py keeps one
// NetworkManager access-point profile in shared mode with autoconnect off,
// so the hotspot never starts at boot, and generates its password the first
// time it starts. The password is never in this page: the join card (the
// network overlay's QR page) fetches and shows it while it is open.
SettingsGroup {
    id: root

    required property SystemSettingsBackend service
    readonly property var status: service.snapshot.hotspot || ({available: false})
    readonly property var view: NetworkHelpers.hotspotView(status)
    readonly property var request: service.busy && service.request.action === "hotspot" ? service.request : ({})
    readonly property string name: nameRow.text.trim()
    readonly property string nameProblem: NetworkHelpers.ssidProblem(root.name)
    property string failure: ""

    visible: view.visible
    title: I18n.tr("Hotspot")

    function run(op) {
        failure = "";
        return service.run({action: "hotspot", op: op, ssid: root.name});
    }

    function rename() {
        if (root.name !== "" && root.nameProblem === "" && root.name !== root.status.ssid
                && !root.service.busy)
            root.run("rename");
    }

    // The field follows the saved name until someone types in it.
    property string shownName: ""
    function follow() {
        if (nameRow.text === root.shownName || nameRow.text === "")
            nameRow.text = root.status.ssid || "";
        root.shownName = root.status.ssid || "";
    }
    onStatusChanged: follow()
    Component.onCompleted: follow()

    Connections {
        target: root.service
        function onCompleted(result) {
            if (root.service.request.action !== "hotspot")
                return;
            if (!result.success) {
                root.failure = root.service.error;
                root.service.error = "";
            }
        }
    }

    SwitchRow {
        width: parent.width
        label: I18n.tr("Hotspot")
        // NetworkManager owns the state; there is no shell default to reset.
        dirty: false
        resetKeys: []
        checked: root.request.op === "start" || root.request.op === "stop" ? root.request.op === "start"
            : root.status.state === "activated" || root.status.state === "activating"
        description: root.failure !== "" ? root.failure : root.view.description
        hintTone: root.failure !== "" ? "error" : root.status.active === true ? "active" : "info"
        disabledReason: root.view.disabledReason !== "" ? root.view.disabledReason
            : root.request.op === "start" ? "Starting…"
            : root.request.op === "stop" ? "Stopping…"
            : root.service.busy ? "Updating…" : ""
        onToggled: value => {
            if (!value || root.nameProblem === "")
                root.run(value ? "start" : "stop");
        }
    }
    SettingsHint {
        width: parent.width
        text: root.view.warning
        tone: "warning"
    }
    FieldRow {
        id: nameRow
        width: parent.width
        visible: root.status.supported === true
        label: I18n.tr("Network name")
        placeholder: root.status.ssid || ""
        hint: root.nameProblem !== "" ? root.nameProblem : "What devices see when they look for Wi-Fi"
        hintTone: root.nameProblem !== "" ? "error" : "info"
        onAccepted: root.rename()

        SettingsAction {
            visible: root.name !== "" && root.name !== root.status.ssid
            text: root.request.op === "rename" ? "Saving…" : "Save"
            enabled: !root.service.busy && root.nameProblem === ""
            onTriggered: root.rename()
        }
    }
    ActionRow {
        width: parent.width
        visible: root.status.active === true
        hint: I18n.tr("Devices join with the hotspot's name and password, or by scanning its QR code.")

        SettingsAction {
            text: I18n.tr("Show password and QR code")
            glyph: "qr_code_2"
            onTriggered: NetworkOverlayState.openHotspot(null, root.status.ssid, root.status.uuid)
        }
    }
}
