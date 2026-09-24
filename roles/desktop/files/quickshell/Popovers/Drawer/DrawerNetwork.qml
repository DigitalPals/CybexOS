pragma ComponentBehavior: Bound
import QtQuick
import "../../Common"
import "../../Common/NetworkHelpers.js" as NetworkHelpers
import ".."

// The drawer's Network tab: the active Wi-Fi connection and its vitals, the
// in-range networks, the Tailscale row, the DNS selector, and
// the live throughput metrics. Share and Speed test hand off to the network
// overlay, which already owns those two flows.
Column {
    id: root

    readonly property var networks: NetworkDetails.groupedNetworks.all
    // Every network snapshot (on NetworkManager events, scan changes and a
    // 10 s safety poll) regroups the list into a fresh array. Handing that to
    // the Repeater rebuilt every row each time — wiping a half-typed password
    // and its focus — so the rows are keyed by SSID instead: a string property
    // only notifies when the six visible networks or their order really
    // change, and each row reads its live entry from `networks`.
    readonly property string networkKey: NetworkHelpers.networkListKey(networks, 6)
    readonly property var networkSsids: NetworkHelpers.networkListIds(networkKey)
    readonly property var activeNetwork: NetworkDetails.activeWifiNetwork
    readonly property var internetPing: NetworkDetails.internetPing
    // The SSID whose credential entry is unfolded, "" while none is.
    property string credentialSsid: ""
    property string credentialSecurity: ""
    property string credentialError: ""
    // What has been typed for credentialSsid. Held here rather than only in
    // the row's field, because a reorder still rebuilds rows.
    property string credentialPassword: ""

    width: parent ? parent.width : 0
    spacing: Theme.scaled(14)

    Claim {
        active: root.visible
        onClaimed: {
            NetworkDetails.acquire();
            EthernetState.acquire();
            Tailscale.acquireLive();
        }
        onReleased: {
            NetworkDetails.release();
            EthernetState.release();
            Tailscale.releaseLive();
        }
    }

    function beginConnect(network) {
        credentialError = "";
        // A row outliving its scan entry has no security to act on.
        if (network.missing)
            return;
        const security = NetworkHelpers.classifySecurity(
            network.profileSecurity || network.security);
        if (!security.supported)
            return;
        const iface = NetworkDetails.snapshot && NetworkDetails.snapshot.wifi
            ? NetworkDetails.snapshot.wifi.interface : "";
        if (network.profileUuid) {
            NetworkDetails.runWifiAction({
                action: "connect", ssid: network.ssid, uuid: network.profileUuid,
                interface: iface,
                security: network.profileSecurity || network.security, saved: true
            });
            foldCredentials();
            return;
        }
        if (!security.password && !security.identity) {
            NetworkDetails.runWifiAction({
                action: "connect", ssid: network.ssid, interface: iface,
                security: network.security
            });
            foldCredentials();
            return;
        }
        credentialPassword = "";
        credentialSsid = network.ssid;
        credentialSecurity = network.security;
    }

    function foldCredentials() {
        credentialSsid = "";
        credentialPassword = "";
    }

    function submitPassword(password) {
        if (password === "") {
            credentialError = "Enter the network password.";
            return;
        }
        const iface = NetworkDetails.snapshot && NetworkDetails.snapshot.wifi
            ? NetworkDetails.snapshot.wifi.interface : "";
        const accepted = NetworkDetails.runWifiAction({
            action: "connect", ssid: credentialSsid, interface: iface,
            security: credentialSecurity, password: password
        });
        if (accepted) {
            foldCredentials();
            credentialError = "";
        }
    }

    function metricValue(label) {
        const ping = internetPing;
        switch (label) {
        case "Ping":
            return ping && ping.latency >= 0 ? Math.round(ping.latency) + " ms" : "--";
        case "Loss":
            return ping ? ping.loss + "%" : "--";
        case "Down":
            return NetworkHelpers.formatRate(NetworkDetails.downloadRate);
        case "Up":
            return NetworkHelpers.formatRate(NetworkDetails.uploadRate);
        }
        return "--";
    }

    // ---- header ----------------------------------------------------------
    Item {
        width: parent.width
        height: 40

        Column {
            anchors.left: parent.left
            anchors.leftMargin: 4
            anchors.right: wifiToggle.left
            anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2

            Text {
                width: parent.width
                text: EthernetState.connected ? "Ethernet"
                    : !WifiState.enabled ? "Wi-Fi off"
                    : WifiState.connected ? WifiState.name : "Not connected"
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.title
                font.weight: Theme.weightSemibold
                color: Theme.textHi
                elide: Text.ElideRight
            }

            Text {
                width: parent.width
                text: {
                    const parts = [];
                    if (WifiState.connected && WifiState.signal >= 0)
                        parts.push(WifiState.signal + "%");
                    const band = root.activeNetwork
                        ? NetworkHelpers.bandForFrequency(
                            root.activeNetwork.frequency) : "";
                    if (band !== "")
                        parts.push(band + " GHz");
                    if (root.internetPing && root.internetPing.latency >= 0)
                        parts.push(Math.round(root.internetPing.latency) + " ms");
                    parts.push("↓" + NetworkHelpers.formatRate(
                        NetworkDetails.downloadRate));
                    return parts.join(" · ");
                }
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.secondary
                color: Theme.textFaint
                elide: Text.ElideRight
            }
        }

        Toggle {
            id: wifiToggle
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            metrics: Theme.switchCompact
            checked: WifiState.enabled
            accessibleName: "Wi-Fi"
            onToggled: value => WifiState.setEnabled(value)
        }
    }

    // ---- networks --------------------------------------------------------
    Column {
        visible: WifiState.enabled
        width: parent.width
        spacing: 2

        Repeater {
            model: root.networkSsids

            delegate: Column {
                id: netEntry

                // The SSID; everything else is read live from root.networks.
                required property string modelData
                readonly property var network:
                    NetworkHelpers.networkBySsid(root.networks, modelData)
                readonly property bool current: network.connected === true
                readonly property bool unfolded:
                    root.credentialSsid === modelData
                readonly property string failure:
                    NetworkDetails.wifiError(modelData)

                // A fresh field starts from what was already typed.
                onUnfoldedChanged: {
                    if (unfolded)
                        passwordInput.text = root.credentialPassword;
                }

                width: parent ? parent.width : 0
                spacing: 2

                Rectangle {
                    id: netRow
                    width: parent.width
                    height: 36
                    radius: Theme.rowRadius
                    color: netEntry.current || netMouse.containsMouse
                        ? Theme.chip : "transparent"

                    Behavior on color {
                        ColorAnimation { duration: Theme.chipFadeDuration }
                    }

                    Sym {
                        id: netMark
                        anchors.left: parent.left
                        anchors.leftMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        name: netEntry.network.signal >= 66 ? "wifi"
                            : netEntry.network.signal >= 33
                            ? "network_wifi_2_bar" : "network_wifi_1_bar"
                        size: 16
                        color: netEntry.current ? Theme.accentText : Theme.textMid
                    }

                    Text {
                        anchors.left: netMark.right
                        anchors.leftMargin: 12
                        anchors.right: netSecurity.left
                        anchors.rightMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        text: netEntry.network.ssid
                        font.family: Theme.fontMenu
                        font.pixelSize: Theme.typography.primary
                        font.weight: netEntry.current
                            ? Theme.weightSemibold : Theme.weightMedium
                        color: netEntry.current ? Theme.textHi : Theme.textMid
                        elide: Text.ElideRight
                    }

                    Text {
                        id: netSecurity
                        anchors.right: netLock.visible ? netLock.left : parent.right
                        anchors.rightMargin: netLock.visible ? 6 : 10
                        anchors.verticalCenter: parent.verticalCenter
                        text: netEntry.current ? "Connected"
                            : netEntry.network.known ? "Saved"
                            : NetworkHelpers.classifySecurity(
                                netEntry.network.security).label
                        font.family: Theme.fontMenu
                        font.pixelSize: Theme.typography.metadata
                        color: Theme.textFaint
                    }

                    Sym {
                        id: netLock
                        anchors.right: parent.right
                        anchors.rightMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        visible: !netEntry.current
                            && (netEntry.network.security || "") !== ""
                            && (netEntry.network.security || "") !== "--"
                        name: "lock"
                        size: 13
                        color: Theme.textFaint
                    }

                    MouseArea {
                        id: netMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (netEntry.current)
                                return;
                            if (netEntry.unfolded)
                                root.foldCredentials();
                            else
                                root.beginConnect(netEntry.network);
                        }
                    }

                    Accessible.role: Accessible.Button
                    Accessible.name: (netEntry.current ? "Connected to "
                        : "Connect to ") + netEntry.network.ssid
                }

                // Inline credential entry for a secured network the shell has
                // no profile for.
                Rectangle {
                    visible: netEntry.unfolded
                    width: parent.width
                    height: 36
                    radius: Theme.rowRadius
                    color: Theme.chip

                    TextInput {
                        id: passwordInput
                        anchors.left: parent.left
                        anchors.leftMargin: 12
                        anchors.right: connectLink.left
                        anchors.rightMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        font.family: Theme.fontMenu
                        font.pixelSize: Theme.typography.control
                        color: Theme.textHi
                        echoMode: TextInput.Password
                        clip: true
                        focus: netEntry.unfolded
                        onAccepted: root.submitPassword(text)
                        onTextChanged: {
                            if (netEntry.unfolded)
                                root.credentialPassword = text;
                        }
                        // A reorder while the entry is open recreates this
                        // row: carry the typed text and the keyboard across.
                        Component.onCompleted: {
                            if (!netEntry.unfolded)
                                return;
                            text = root.credentialPassword;
                            cursorPosition = text.length;
                            forceActiveFocus();
                        }

                        Text {
                            visible: passwordInput.text === ""
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Password"
                            font.family: Theme.fontMenu
                            font.pixelSize: Theme.typography.control
                            color: Theme.textFaint
                        }
                    }

                    LinkText {
                        id: connectLink
                        anchors.right: parent.right
                        anchors.rightMargin: 12
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Connect"
                        onClicked: root.submitPassword(passwordInput.text)
                    }
                }

                Text {
                    visible: (netEntry.failure !== "" && !netEntry.current)
                        || (netEntry.unfolded && root.credentialError !== "")
                    width: parent.width - 16
                    x: 8
                    text: netEntry.unfolded && root.credentialError !== ""
                        ? root.credentialError : netEntry.failure
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.metadata
                    color: Theme.redText
                    wrapMode: Text.WordWrap
                }
            }
        }
    }

    // ---- tailscale · dns ------------------------------------
    Column {
        width: parent.width
        spacing: 2

        Item {
            width: parent.width
            height: 40

            BrandIcon {
                id: tsMark
                anchors.left: parent.left
                anchors.leftMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                width: 14
                height: 14
                name: "tailscale"
            }

            Text {
                id: tsLabel
                anchors.left: tsMark.right
                anchors.leftMargin: 12
                anchors.verticalCenter: parent.verticalCenter
                text: "Tailscale"
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.control
                font.weight: Theme.weightMedium
                color: Theme.textHi
            }

            Text {
                anchors.left: tsLabel.right
                anchors.leftMargin: 10
                anchors.right: tsToggle.left
                anchors.rightMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                horizontalAlignment: Text.AlignRight
                text: Tailscale.connected
                    ? [Tailscale.host, Tailscale.ip].filter(s => s !== "").join(" · ")
                    : Tailscale.statusText
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.secondary
                color: Theme.textFaint
                elide: Text.ElideRight
            }

            Toggle {
                id: tsToggle
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                metrics: Theme.switchCompact
                checked: Tailscale.running
                enabled: !Tailscale.busy
                accessibleName: "Tailscale"
                onToggled: value => Tailscale.setRunning(value)
            }
        }

        LinkText {
            visible: !Tailscale.connected
            text: Tailscale.needsApproval ? "View approval status"
                : Tailscale.authPending ? "Continue sign-in"
                : Tailscale.needsLogin ? "Sign in to Tailscale" : "Tailscale connection details"
            onClicked: Tailscale.showSetup()
        }

        Item {
            width: parent.width
            height: 40

            Sym {
                id: dnsMark
                anchors.left: parent.left
                anchors.leftMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                name: "dns"
                size: 16
                color: Theme.textMid
            }

            Text {
                anchors.left: dnsMark.right
                anchors.leftMargin: 12
                anchors.verticalCenter: parent.verticalCenter
                text: "DNS"
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.control
                font.weight: Theme.weightMedium
                color: Theme.textHi
            }

            Rectangle {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                width: dnsRow.implicitWidth + 4
                height: 26
                radius: 7
                color: Theme.chip
                opacity: NetworkDetails.dnsBusy ? 0.5 : 1

                Row {
                    id: dnsRow
                    anchors.centerIn: parent
                    spacing: 2

                    Repeater {
                        model: ["Automatic", "Cloudflare", "Google"]

                        delegate: Rectangle {
                            id: dnsChoice

                            required property string modelData
                            readonly property bool on:
                                NetworkDetails.dnsProvider === modelData

                            width: dnsChoiceText.implicitWidth + 14
                            height: 22
                            radius: 5
                            color: on ? Theme.chipHover : "transparent"

                            Text {
                                id: dnsChoiceText
                                anchors.centerIn: parent
                                text: dnsChoice.modelData === "Automatic"
                                    ? "Auto" : dnsChoice.modelData
                                font.family: Theme.fontMenu
                                font.pixelSize: Theme.typography.control
                                font.weight: Theme.weightSemibold
                                color: dnsChoice.on ? Theme.textHi : Theme.textFaint
                            }

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    if (!dnsChoice.on)
                                        NetworkDetails.setDns(
                                            dnsChoice.modelData, []);
                                }
                            }

                            Accessible.role: Accessible.RadioButton
                            Accessible.checked: dnsChoice.on
                            Accessible.name: "DNS " + dnsChoice.modelData
                        }
                    }
                }
            }
        }
    }

    // ---- metrics ---------------------------------------------------------
    Grid {
        id: metricsGrid
        width: parent.width
        columns: 2
        columnSpacing: 6
        rowSpacing: 6

        readonly property real cellWidth: (width - columnSpacing) / 2

        // A fixed model: an array literal of live values was a new model on
        // every sample, and rebuilt all four cells each time.
        Repeater {
            model: ["Ping", "Loss", "Down", "Up"]

            delegate: Rectangle {
                id: metricCell

                required property string modelData

                width: metricsGrid.cellWidth
                height: 36
                radius: 10
                color: Theme.chip

                Text {
                    anchors.left: parent.left
                    anchors.leftMargin: 12
                    anchors.verticalCenter: parent.verticalCenter
                    text: metricCell.modelData
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.metadata
                    color: Theme.textFaint
                }

                Text {
                    anchors.right: parent.right
                    anchors.rightMargin: 12
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.metricValue(metricCell.modelData)
                    font.family: Theme.fontNumeric
                    font.pixelSize: Theme.typography.secondary
                    font.weight: Theme.weightSemibold
                    font.features: Theme.tabularNumberFeatures
                    color: Theme.textHi
                }
            }
        }
    }

    DrawerFooter {
        info: {
            const primary = NetworkDetails.primary;
            const raw = primary && primary.ipv4 ? String(primary.ipv4) : "";
            const address = raw.split("/")[0];
            const wired = EthernetState.connected ? "Ethernet" : "no Ethernet";
            return address !== "" ? address + " · " + wired : wired;
        }
        secondaryText: "Share"
        actionText: "Speed test"
        onSecondaryClicked: {
            const iface = NetworkDetails.activeWifiInterface;
            Popouts.close();
            NetworkOverlayState.openQr(Screens.byName(Popouts.hostScreenName), iface);
        }
        onActionClicked: {
            const iface = NetworkDetails.primaryInterface;
            Popouts.close();
            NetworkOverlayState.openSpeedTest(
                Screens.byName(Popouts.hostScreenName), iface);
        }
    }
}
