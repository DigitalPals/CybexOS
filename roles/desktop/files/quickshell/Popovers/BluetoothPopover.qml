pragma ComponentBehavior: Bound
import QtQuick
import Quickshell.Bluetooth
import "../Common"

Surface {
    id: root

    readonly property var devices: BluetoothState.devices
    property string announcement: ""
    focus: visible

    Keys.onEscapePressed: Popouts.close()

    function focusInitial() {
        if (visible)
            Qt.callLater(() => bluetoothToggle.forceActiveFocus());
    }

    Component.onCompleted: focusInitial()
    onVisibleChanged: focusInitial()

    // Header + toggle
    Item {
        width: parent.width
        height: Theme.listRowHeight

        Text {
            x: 10
            anchors.verticalCenter: parent.verticalCenter
            text: "Bluetooth"
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.primary
            font.weight: Theme.weightSemibold
            color: Theme.textHi
        }

        Toggle {
            id: bluetoothToggle
            anchors.right: parent.right
            anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            checked: BluetoothState.enabled
            accessibleName: "Bluetooth"
            onToggled: v => {
                BluetoothState.setEnabled(v);
            }
        }
    }

    Text {
        visible: !BluetoothState.enabled
        width: parent.width
        topPadding: 12
        bottomPadding: 14
        text: BluetoothState.adapter === null ? "No Bluetooth adapter" : "Bluetooth is off"
        horizontalAlignment: Text.AlignHCenter
        font.family: Theme.fontMenu
        font.pixelSize: Theme.typography.secondary
        color: Theme.textDim
    }

    Text {
        visible: BluetoothState.enabled && root.devices.length === 0
        width: parent.width
        topPadding: 12
        bottomPadding: 14
        text: "No paired devices"
        horizontalAlignment: Text.AlignHCenter
        font.family: Theme.fontMenu
        font.pixelSize: Theme.typography.secondary
        color: Theme.textDim
    }

    Repeater {
        model: root.devices

        delegate: Rectangle {
            id: dev

            required property var modelData
            readonly property bool busy: modelData.state === BluetoothDeviceState.Connecting || modelData.state === BluetoothDeviceState.Disconnecting
            readonly property string actionName: modelData.connected
                ? "Disconnect " + modelData.deviceName
                : "Connect " + modelData.deviceName

            function activate() {
                if (dev.busy)
                    return;
                root.announcement = dev.actionName;
                if (dev.modelData.connected)
                    dev.modelData.disconnect();
                else
                    dev.modelData.connect();
            }

            width: parent.width - 4
            x: 2
            height: modelData.connected ? Theme.panelTileHeight : Theme.listRowHeight
            radius: Theme.rowRadius
            color: modelData.connected ? Theme.chip
                : btMouse.containsMouse || activeFocus ? Theme.chipHover : "transparent"
            opacity: modelData.connected || btMouse.containsMouse || activeFocus ? 1 : 0.75
            enabled: !busy
            activeFocusOnTab: enabled
            border.width: activeFocus ? 1 : 0
            border.color: Theme.accentText
            Accessible.role: Accessible.Button
            Accessible.name: actionName
            Accessible.description: busy ? "Bluetooth action in progress"
                : modelData.connected ? "Connected" : modelData.paired ? "Paired" : "Not connected"
            Accessible.onPressAction: dev.activate()

            Keys.onPressed: event => {
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                        || event.key === Qt.Key_Space) {
                    dev.activate();
                    event.accepted = true;
                } else if (event.key === Qt.Key_Down || event.key === Qt.Key_Right) {
                    const next = dev.nextItemInFocusChain(true);
                    if (next)
                        next.forceActiveFocus();
                    event.accepted = true;
                } else if (event.key === Qt.Key_Up || event.key === Qt.Key_Left) {
                    const previous = dev.nextItemInFocusChain(false);
                    if (previous)
                        previous.forceActiveFocus();
                    event.accepted = true;
                }
            }

            Row {
                anchors.verticalCenter: parent.verticalCenter
                x: 10
                spacing: 10

                Sym {
                    anchors.verticalCenter: parent.verticalCenter
                    width: 18
                    horizontalAlignment: Text.AlignHCenter
                    name: {
                        const icon = dev.modelData.icon || "";
                        if (icon.includes("headset") || icon.includes("headphone") || icon.includes("audio"))
                            return "headphones";
                        if (icon.includes("input-gaming"))
                            return "sports_esports";
                        if (icon.includes("mouse"))
                            return "mouse";
                        if (icon.includes("keyboard"))
                            return "keyboard";
                        if (icon.includes("phone"))
                            return "devices";
                        return "bluetooth";
                    }
                    size: Theme.fontBody
                    color: dev.modelData.connected ? Theme.accentText : Theme.textMid
                }

                Column {
                    anchors.verticalCenter: parent.verticalCenter
                    width: root.width - 130
                    spacing: 1

                    Text {
                        width: parent.width
                        text: dev.modelData.deviceName
                        font.family: Theme.fontMenu
                        font.pixelSize: Theme.typography.primary
                        font.weight: dev.modelData.connected ? Theme.weightMedium : Theme.weightRegular
                        color: dev.modelData.connected ? Theme.textHi : Theme.textMid
                        elide: Text.ElideRight
                    }

                    Text {
                        visible: dev.modelData.connected
                        width: parent.width
                        text: "Connected" + (dev.modelData.batteryAvailable ? " · " + Math.round(dev.modelData.battery * 100) + "%" : "")
                        font.family: Theme.fontMenu
                        font.pixelSize: Theme.typography.secondary
                        color: Theme.textLow
                    }
                }
            }

            Text {
                anchors.right: parent.right
                anchors.rightMargin: 12
                anchors.verticalCenter: parent.verticalCenter
                text: dev.busy ? "…" : dev.modelData.connected ? "Disconnect" : dev.modelData.paired ? "Paired" : "Not connected"
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.control
                font.weight: dev.modelData.connected ? Theme.weightMedium : Theme.weightRegular
                color: dev.modelData.connected && (btMouse.containsMouse || dev.activeFocus)
                    ? Theme.red : Theme.textDim
            }

            MouseArea {
                id: btMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    dev.forceActiveFocus();
                    dev.activate();
                }
            }
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
