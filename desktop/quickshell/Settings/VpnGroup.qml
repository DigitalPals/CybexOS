pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import "../Common"
import "../Common/NetworkHelpers.js" as NetworkHelpers

// Settings -> Network -> VPN: the NetworkManager VPN and WireGuard profiles,
// each with a switch that connects or disconnects it. Connecting runs
// network-tool.py, whose short-lived secret agent opens the VPN plugin's own
// sign-in dialog when NetworkManager asks for a password; no secret reaches
// the shell. Import hands an OpenVPN or WireGuard file to `nmcli connection
// import`, removal asks first, and anything more goes to the advanced editor.
//
// Requests share the Network page's one request channel, so its busy state
// covers them. A failure is shown on the row it concerns (an import's under
// the group) instead of as the page's status line.
SettingsGroup {
    id: root

    required property SystemSettingsBackend service
    readonly property var vpns: service.snapshot.vpns || []
    readonly property var request: service.busy && service.request.action === "vpn" ? service.request : ({})
    // The last failure and which VPN it belongs to ("" for an import).
    property string failedUuid: ""
    property string failure: ""
    property string notice: ""
    property string removing: ""

    title: I18n.tr("VPN")

    function run(op, extra) {
        failure = "";
        failedUuid = "";
        notice = "";
        return service.run(Object.assign({action: "vpn", op: op}, extra || {}));
    }

    function pendingFor(uuid) {
        return root.request.uuid === uuid ? String(root.request.op || "") : "";
    }

    Connections {
        target: root.service
        function onCompleted(result) {
            const request = root.service.request;
            if (request.action !== "vpn")
                return;
            if (!result.success) {
                root.failedUuid = String(request.uuid || "");
                root.failure = root.service.error;
                root.service.error = "";
            } else if (request.op === "import" || request.op === "remove") {
                root.notice = result.message || "";
            }
        }
    }

    Repeater {
        model: ScriptModel {
            values: root.vpns.map(vpn => vpn.uuid)
        }
        delegate: RowCluster {
            id: entry
            required property string modelData
            readonly property var vpn: root.vpns.find(item => item.uuid === entry.modelData)
                || ({uuid: "", name: "", label: I18n.tr("VPN"), state: ""})
            readonly property string pending: root.pendingFor(entry.modelData)
            readonly property string error: root.failedUuid === entry.modelData ? root.failure : ""
            readonly property bool confirming: root.removing === entry.modelData
            width: parent ? parent.width : 0

            ValueRow {
                width: parent.width
                label: entry.vpn.name
                hint: entry.error !== "" ? entry.error
                    : NetworkHelpers.vpnLabel(entry.vpn) + " · " + NetworkHelpers.vpnStateText(entry.vpn, entry.pending)
                hintTone: entry.error !== "" ? "error" : entry.vpn.state === "activated" ? "active" : "info"

                SettingsAction {
                    visible: !entry.confirming
                    anchors.verticalCenter: parent.verticalCenter
                    compact: true
                    text: "Remove " + entry.vpn.name + "…"
                    tooltip: I18n.tr("Remove…")
                    glyph: "delete"
                    danger: true
                    enabled: !root.service.busy
                    onTriggered: root.removing = entry.modelData
                }
                Toggle {
                    anchors.verticalCenter: parent.verticalCenter
                    metrics: Theme.switchRow
                    checked: entry.pending !== "" ? entry.pending === "connect" : NetworkHelpers.isVpnActive(entry.vpn)
                    enabled: !root.service.busy
                    accessibleName: "Connect " + entry.vpn.name
                    onToggled: value => root.run(value ? "connect" : "disconnect", {uuid: entry.modelData})
                }
            }
            ValueRow {
                width: parent.width
                divider: false
                visible: entry.confirming
                label: "Remove " + entry.vpn.name + "?"
                hint: I18n.tr("Its settings and saved sign-in are deleted from this computer.")
                hintTone: "warning"

                SettingsAction {
                    text: I18n.tr("Remove")
                    danger: true
                    enabled: !root.service.busy
                    onTriggered: {
                        root.run("remove", {uuid: entry.modelData, confirmed: true});
                        root.removing = "";
                    }
                }
                SettingsAction {
                    text: I18n.tr("Cancel")
                    onTriggered: root.removing = ""
                }
            }
        }
    }
    SettingsHint {
        width: parent.width
        text: !root.service.loaded || root.vpns.length > 0 ? ""
            : root.service.snapshot.extrasError ? "NetworkManager's VPN connections could not be read."
            : "No VPN connections yet. Import a configuration file from your VPN provider."
        tone: root.service.snapshot.extrasError ? "warning" : "info"
    }
    // An import's failure, or what the last import or removal did.
    SettingsHint {
        readonly property bool failed: root.failure !== "" && root.failedUuid === ""
        width: parent.width
        text: failed ? root.failure : root.notice
        tone: failed ? "error" : "info"
    }
    ActionRow {
        width: parent.width
        hint: I18n.tr("OpenVPN (.ovpn) and WireGuard (.conf) files. Other VPN types and detailed settings are in the advanced editor.")

        SettingsAction {
            text: root.request.op === "import" ? "Importing…" : "Import VPN…"
            glyph: "add"
            enabled: !root.service.busy
            onTriggered: importDialog.openAt("~/Downloads")
        }
        SettingsAction {
            text: I18n.tr("Advanced editor")
            glyph: "open_in_new"
            enabled: !SystemSettings.externalBusy
            onTriggered: SystemSettings.openExternal("network")
        }
    }

    FolderDialog {
        id: importDialog
        title: I18n.tr("Import VPN")
        chooseFile: true
        nameFilters: ["*.ovpn", "*.conf"]
        onFileChosen: path => root.run("import", {path: path})
    }
}
