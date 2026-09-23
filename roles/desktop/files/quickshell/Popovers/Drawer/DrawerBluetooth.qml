pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Bluetooth
import "../../Common"
import "../../Common/BluetoothHelpers.js" as BluetoothHelpers
import ".."

Column {
    id: root

    width: parent ? parent.width : 0
    spacing: Theme.scaled(14)

    readonly property var adapter: BluetoothState.adapter
    readonly property bool powered: BluetoothState.enabled
    readonly property bool blocked: adapter !== null && adapter.state === BluetoothAdapterState.Blocked
    readonly property bool powerBusy: adapter !== null && (adapter.state === BluetoothAdapterState.Enabling
        || adapter.state === BluetoothAdapterState.Disabling)
    readonly property var devices: powered && adapter ? adapter.devices.values : []
    readonly property var deviceGroups: BluetoothHelpers.groupDevices(devices)
    readonly property var connectedDevices: deviceGroups.connected
    readonly property var pairedDevices: deviceGroups.paired
    readonly property var nearbyDevices: deviceGroups.nearby
    property bool ready: false
    property bool scanning: false
    property bool scanBusy: false
    property bool showNearby: false
    property string busyDevice: ""
    property string busyName: ""
    property string action: ""
    property string error: ""
    property string announcement: ""
    property var prompt: null
    readonly property bool inputPrompt: prompt !== null
        && (prompt.kind === "RequestPinCode" || prompt.kind === "RequestPasskey")
    readonly property bool displayPrompt: prompt !== null
        && (prompt.kind === "DisplayPinCode" || prompt.kind === "DisplayPasskey")

    function startBackend() {
        ready = false;
        error = "";
        backend.command = ["python3", Quickshell.shellDir + "/scripts/bluetooth-tool.py", adapter.dbusPath];
        backend.running = true;
    }

    // A replacement default adapter needs a new application-scoped session.
    onAdapterChanged: {
        if (backend.running && adapter && backend.command[2] !== adapter.dbusPath)
            backend.running = false;
    }

    function send(message) {
        if (!ready)
            return;
        error = "";
        backend.write(JSON.stringify(message) + "\n");
    }

    function activate(device) {
        if (!ready || busyDevice !== "")
            return;
        busyDevice = device.dbusPath;
        busyName = BluetoothHelpers.deviceLabel(device) || device.address;
        action = device.connected ? "disconnect" : device.paired ? "connect" : "pair";
        announcement = (action === "pair" ? "Pairing with "
            : action === "connect" ? "Connecting to " : "Disconnecting ") + busyName;
        send({ action: action, device: busyDevice });
    }

    function reply(accept) {
        send({ action: "reply", accept: accept, value: pin.text });
    }

    function receive(data) {
        let event;
        try { event = JSON.parse(data); } catch (_) { return; }
        if (event.ready !== undefined) {
            ready = event.ready;
            // Each visible, powered session discovers immediately, including
            // returning to the tab or turning Bluetooth on while it is open.
            if (ready && visible && powered) {
                showNearby = true;
                scanBusy = true;
                send({ action: "scan", enabled: true });
            }
        }
        if (event.scanning !== undefined) scanning = event.scanning;
        if (event.scanBusy !== undefined) scanBusy = event.scanBusy;
        if (event.busy !== undefined) {
            busyDevice = event.busy;
            if (busyDevice === "") announcement = event.error || "Bluetooth action completed";
        }
        if (event.error !== undefined) error = event.error;
        if (event.prompt !== undefined) {
            prompt = event.prompt;
            pin.text = "";
            if (prompt !== null) {
                announcement = promptText.text;
                Qt.callLater(() => {
                    if (root.inputPrompt) pin.forceActiveFocus();
                    else if (!root.displayPrompt) acceptLink.forceActiveFocus();
                    else cancelLink.forceActiveFocus();
                });
            }
        }
    }

    Claim {
        active: root.visible && root.powered && root.adapter !== null
        onClaimed: root.startBackend()
        onReleased: {
            backend.running = false;
            root.ready = false;
            root.scanning = false;
            root.scanBusy = false;
            root.showNearby = false;
            root.busyDevice = "";
            root.prompt = null;
        }
    }

    Process {
        id: backend
        stdinEnabled: true
        stdout: SplitParser { onRead: data => root.receive(data) }
        stderr: StdioCollector {}
        onExited: (code, status) => {
            root.ready = false;
            root.scanning = false;
            root.scanBusy = false;
            root.busyDevice = "";
            root.prompt = null;
            if (root.visible && root.powered && root.adapter && backend.command[2] !== root.adapter.dbusPath) {
                Qt.callLater(() => {
                    if (root.visible && root.powered && root.adapter && !backend.running)
                        root.startBackend();
                });
                return;
            }
            if (root.visible && root.powered && root.error === "")
                root.error = "Bluetooth controls stopped. Reopen this tab to retry.";
        }
    }

    Item {
        width: parent.width
        height: 40
        Column {
            anchors.left: parent.left
            anchors.leftMargin: 4
            anchors.right: bluetoothToggle.left
            anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2
            Text {
                text: "Bluetooth"
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.title
                font.weight: Theme.weightSemibold
                color: Theme.textHi
            }
            Text {
                width: parent.width
                text: !root.adapter ? "No Bluetooth adapter"
                    : root.blocked ? "Blocked by hardware switch"
                    : root.powerBusy ? "Changing power…"
                    : !root.powered ? "Bluetooth is off"
                    : root.connectedDevices.length > 0 ? root.connectedDevices.length + " connected"
                    : "Not connected"
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.secondary
                color: Theme.textFaint
                elide: Text.ElideRight
            }
        }
        Toggle {
            id: bluetoothToggle
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            metrics: Theme.switchCompact
            checked: root.powered
            enabled: root.adapter !== null && !root.blocked && !root.powerBusy
            accessibleName: "Bluetooth"
            onToggled: value => BluetoothState.setEnabled(value)
        }
    }

    // Fixed sections, and rows diffed by device identity. An array literal of
    // the live lists was a new model on every BlueZ add, rename or expiry —
    // continuous during the automatic discovery — and rebuilt every row, which
    // dropped keyboard focus and any click that straddled the rebuild. Now a
    // section only gains or loses the rows that changed.
    Repeater {
        model: ["connected", "paired", "nearby"]
        delegate: Column {
            id: section
            required property string modelData
            readonly property var devices: modelData === "connected" ? root.connectedDevices
                : modelData === "paired" ? root.pairedDevices : root.nearbyDevices
            width: root.width
            spacing: 2
            visible: root.powered
                && (modelData === "nearby" ? root.showNearby : devices.length > 0)
            Text {
                x: 8
                text: section.modelData === "connected" ? "Connected devices"
                    : section.modelData === "paired" ? "Paired devices" : "Nearby devices"
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.metadata
                color: Theme.textFaint
                bottomPadding: 4
            }
            Repeater {
                model: ScriptModel {
                    values: section.devices
                }
                delegate: Rectangle {
                    id: deviceRow
                    required property var modelData
                    readonly property bool busy: root.busyDevice === modelData.dbusPath
                        || modelData.pairing || modelData.state === BluetoothDeviceState.Connecting
                        || modelData.state === BluetoothDeviceState.Disconnecting
                    readonly property string actionLabel: busy ? "Working…"
                        : modelData.connected ? "Disconnect" : modelData.paired ? "Connect" : "Pair"
                    width: section.width
                    height: Theme.scaled(44)
                    radius: Theme.rowRadius
                    color: modelData.connected || mouse.containsMouse || activeFocus ? Theme.chip : "transparent"
                    border.width: activeFocus ? 1 : 0
                    border.color: Theme.accentText
                    enabled: root.ready && root.busyDevice === "" && !busy
                    activeFocusOnTab: enabled
                    Accessible.role: Accessible.Button
                    Accessible.name: actionLabel + " " + (BluetoothHelpers.deviceLabel(modelData) || modelData.address)
                    Accessible.description: modelData.connected ? "Connected" : modelData.paired ? "Paired" : "Nearby device"
                    Accessible.onPressAction: root.activate(modelData)
                    Keys.onPressed: event => {
                        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                            root.activate(modelData);
                            event.accepted = true;
                        } else if (event.key === Qt.Key_Down || event.key === Qt.Key_Up) {
                            const next = nextItemInFocusChain(event.key === Qt.Key_Down);
                            if (next) next.forceActiveFocus();
                            event.accepted = true;
                        }
                    }
                    Sym {
                        id: deviceIcon
                        anchors.left: parent.left
                        anchors.leftMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        name: {
                            const icon = deviceRow.modelData.icon || "";
                            if (/headset|headphone|audio/.test(icon)) return "headphones";
                            if (icon.includes("gaming")) return "sports_esports";
                            if (icon.includes("mouse")) return "mouse";
                            if (icon.includes("keyboard")) return "keyboard";
                            if (icon.includes("phone")) return "devices";
                            return "bluetooth";
                        }
                        size: 16
                        color: deviceRow.modelData.connected ? Theme.accentText : Theme.textMid
                    }
                    Column {
                        anchors.left: deviceIcon.right
                        anchors.leftMargin: 12
                        anchors.right: deviceAction.left
                        anchors.rightMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 2
                        Text {
                            width: parent.width
                            text: BluetoothHelpers.deviceLabel(deviceRow.modelData) || "Unknown device"
                            elide: Text.ElideRight
                            font.family: Theme.fontMenu
                            font.pixelSize: Theme.typography.primary
                            font.weight: deviceRow.modelData.connected ? Theme.weightSemibold : Theme.weightMedium
                            color: deviceRow.modelData.connected ? Theme.textHi : Theme.textMid
                        }
                        Text {
                            width: parent.width
                            text: (deviceRow.modelData.connected ? "Connected" : deviceRow.modelData.paired ? "Paired" : deviceRow.modelData.address)
                                + (deviceRow.modelData.batteryAvailable ? " · " + Math.round(deviceRow.modelData.battery * 100) + "%" : "")
                            elide: Text.ElideRight
                            font.family: Theme.fontMenu
                            font.pixelSize: Theme.typography.metadata
                            color: Theme.textFaint
                        }
                    }
                    Text {
                        id: deviceAction
                        anchors.right: parent.right
                        anchors.rightMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        text: deviceRow.actionLabel
                        font.family: Theme.fontMenu
                        font.pixelSize: Theme.typography.metadata
                        color: Theme.textFaint
                    }
                    MouseArea {
                        id: mouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: { deviceRow.forceActiveFocus(); root.activate(deviceRow.modelData); }
                    }
                }
            }
            Text {
                visible: section.devices.length === 0
                width: parent.width
                text: root.scanning ? "Searching… Put your device in pairing mode."
                    : "No nearby devices found. Try scanning again."
                wrapMode: Text.WordWrap
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.secondary
                color: Theme.textFaint
            }
        }
    }

    Text {
        visible: root.powered && root.connectedDevices.length === 0 && root.pairedDevices.length === 0 && !root.showNearby
        width: parent.width
        text: "Preparing Bluetooth controls…"
        wrapMode: Text.WordWrap
        font.family: Theme.fontMenu
        font.pixelSize: Theme.typography.secondary
        color: Theme.textFaint
    }

    Rectangle {
        visible: root.prompt !== null || (root.busyDevice !== "" && root.action === "pair")
        width: parent.width
        height: pairingContent.implicitHeight + 24
        radius: Theme.rowRadius
        color: Theme.chip
        Column {
            id: pairingContent
            x: 12
            y: 12
            width: parent.width - 24
            spacing: 10
            Text {
                id: promptText
                width: parent.width
                text: {
                    const p = root.prompt;
                    if (!p) return "Pairing with " + root.busyName + "…";
                    if (p.kind === "RequestConfirmation") return "Confirm that " + root.busyName + " shows this code: " + p.code;
                    if (p.kind === "DisplayPinCode" || p.kind === "DisplayPasskey")
                        return "Enter " + p.code + " on " + root.busyName + ", then press Enter."
                            + (p.kind === "DisplayPasskey" ? " (" + p.entered + " digits entered)" : "");
                    if (root.inputPrompt) return "Enter the " + (p.kind === "RequestPinCode" ? "PIN" : "passkey") + " for " + root.busyName + ".";
                    if (p.kind === "AuthorizeService") return "Allow " + root.busyName + " to use service " + p.service + "?";
                    return "Allow pairing with " + root.busyName + "?";
                }
                wrapMode: Text.WordWrap
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.secondary
                color: Theme.textHi
            }
            Rectangle {
                visible: root.inputPrompt
                width: parent.width
                height: 36
                radius: Theme.rowRadius
                color: Theme.chipHover
                border.width: pin.activeFocus ? 1 : 0
                border.color: Theme.accentText
                TextInput {
                    id: pin
                    anchors.fill: parent
                    anchors.margins: 8
                    clip: true
                    maximumLength: root.prompt && root.prompt.kind === "RequestPasskey" ? 6 : 16
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.control
                    color: Theme.textHi
                    selectByMouse: true
                    activeFocusOnTab: true
                    Accessible.role: Accessible.EditableText
                    Accessible.name: "Bluetooth PIN or passkey"
                    onAccepted: root.reply(true)
                }
            }
            Row {
                spacing: 16
                LinkText {
                    id: acceptLink
                    visible: root.prompt !== null && !root.displayPrompt
                    text: root.inputPrompt ? "Submit" : "Confirm"
                    onClicked: root.reply(true)
                }
                LinkText {
                    id: cancelLink
                    text: "Cancel"
                    onClicked: root.send({ action: "cancel" })
                }
            }
        }
    }

    Text {
        visible: root.error !== ""
        width: parent.width
        text: root.error
        wrapMode: Text.WordWrap
        font.family: Theme.fontMenu
        font.pixelSize: Theme.typography.secondary
        color: Theme.redText
        Accessible.role: Accessible.AlertMessage
        Accessible.name: text
    }

    DrawerFooter {
        info: root.scanning ? "Searching for devices…" : root.adapter ? root.adapter.name : "Bluetooth unavailable"
        actionText: !root.powered || !root.ready || root.scanBusy ? ""
            : root.scanning ? "Stop scan" : "Scan again"
        onActionClicked: {
            root.showNearby = true;
            root.send({ action: "scan", enabled: !root.scanning });
        }
    }

    Item {
        width: 1
        height: 1
        opacity: 0
        Accessible.role: Accessible.AlertMessage
        Accessible.name: root.announcement
    }
}
