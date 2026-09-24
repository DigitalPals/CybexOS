pragma ComponentBehavior: Bound
import QtQuick
import "../Common"
import "../Common/NetworkHelpers.js" as NetworkHelpers

// Stable filename, module id and panel route: externally this is still
// `wifi`; visibly it is the complete, transport-neutral Network view.
Surface {
    id: root

    implicitWidth: Math.min(600, availableWidth > 0 ? availableWidth : 600)

    readonly property real bodyLimit: Math.max(280, availableHeight - padding * 2)
    readonly property var primary: NetworkDetails.primary
    readonly property var activeWifi: NetworkDetails.activeWifi
    readonly property var activeWifiSecurity: {
        const profile = NetworkDetails.activeWifiProfile;
        const profileSecurity = profile && profile.security
            ? profile.security + (profile.certificateEnterprise ? " TLS" : "") : "";
        const profileInfo = NetworkHelpers.classifySecurity(profileSecurity);
        return profileInfo.kind === "enterprise-certificate" ? profileInfo
            : NetworkHelpers.classifySecurity(activeWifi && activeWifi.security
                ? activeWifi.security : profileSecurity);
    }

    property string credentialSsid: ""
    property string credentialSecurity: ""
    property string credentialUuid: ""
    property string credentialPassword: ""
    property string credentialIdentity: ""
    property string credentialInputError: ""
    property bool wifiNetworksOpen: false
    property string pendingConnectKey: ""
    property bool customDnsOpen: false
    property string customDnsText: ""
    property string customDnsError: ""

    readonly property var connectedWifiNetwork: NetworkDetails.activeWifiNetwork
    readonly property string connectedWifiName: connectedWifiNetwork
        && connectedWifiNetwork.ssid ? connectedWifiNetwork.ssid
        : activeWifi && activeWifi.ssid ? activeWifi.ssid : ""
    readonly property real connectedWifiSignal: connectedWifiNetwork
        ? Number(connectedWifiNetwork.signal)
        : activeWifi ? Number(activeWifi.signal) : -1
    readonly property int wifiNetworkCount: Math.max(
        NetworkDetails.knownNetworks.length + NetworkDetails.otherNetworks.length,
        connectedWifiName !== "" ? 1 : 0)
    readonly property string connectedWifiGlyph: connectedWifiName === "" ? "wifi_off"
        : connectedWifiSignal >= 66 ? "wifi"
        : connectedWifiSignal >= 33 ? "network_wifi_2_bar" : "network_wifi_1_bar"
    readonly property string tailscaleDetail: {
        if (!Tailscale.statusKnown)
            return "Checking status…";
        if (Tailscale.statusError !== "")
            return "Status unavailable · " + Tailscale.statusError;
        if (!Tailscale.running)
            return Tailscale.statusText + " · open details";
        if (!Tailscale.connected)
            return "Connecting…";
        const parts = ["Connected"];
        if (Tailscale.host !== "")
            parts.push(Tailscale.host);
        if (Tailscale.net !== "")
            parts.push(Tailscale.net);
        if (Tailscale.ip !== "")
            parts.push(Tailscale.ip);
        if (Tailscale.exitNode)
            parts.push("exit node active");
        return parts.join(" · ");
    }

    readonly property string heroTitle: primary
        ? (NetworkHelpers.physicalType(primary) === "ethernet" ? "Ethernet" : "Wi-Fi")
        : "Offline"
    readonly property string heroName: primary
        ? (primary.ssid || primary.connection || primary.interface) : "No physical connection"
    readonly property string heroStatus: {
        if (!primary)
            return WifiState.enabled ? "No default physical route" : "Wi-Fi is off";
        const parts = [primary.interface];
        if (NetworkHelpers.physicalType(primary) === "wifi") {
            if (Number(primary.signal) >= 0)
                parts.push(Math.round(primary.signal) + "% signal");
            const band = NetworkHelpers.bandForFrequency(primary.frequency);
            if (band !== "")
                parts.push(band + " GHz");
        } else if (primary.speed) {
            parts.push(primary.speed);
        }
        return parts.join(" · ");
    }

    // WifiState.others remains the radio-backed fallback model in
    // NetworkDetails (`model: WifiState.others` in the legacy contract), but
    // the visible rows use its unlimited, deduplicated richer grouping.

    Claim {
        active: root.visible
        onClaimed: {
            EthernetState.acquire();
            NetworkDetails.acquire();
            Tailscale.acquire();
        }
        onReleased: {
            EthernetState.release();
            NetworkDetails.release();
            Tailscale.release();
            root.wifiNetworksOpen = false;
            root.pendingConnectKey = "";
            root.clearCredentials();
        }
    }

    onVisibleChanged: {
        if (!visible) {
            clearCredentials();
            wifiNetworksOpen = false;
            pendingConnectKey = "";
            customDnsOpen = false;
            customDnsText = "";
            customDnsError = "";
        }
    }

    Component.onDestruction: clearCredentials()

    function handleEscape(): bool {
        if (credentialSsid !== "") {
            clearCredentials();
            return true;
        }
        if (customDnsOpen) {
            customDnsOpen = false;
            customDnsText = "";
            customDnsError = "";
            return true;
        }
        if (wifiNetworksOpen) {
            collapseWifiNetworks();
            return true;
        }
        return false;
    }

    function clearCredentials() {
        credentialSsid = "";
        credentialSecurity = "";
        credentialUuid = "";
        credentialPassword = "";
        credentialIdentity = "";
        credentialInputError = "";
    }

    function openSettings() {
        Settings.showPanel("network");
        Popouts.close();
    }

    function ensureVisible(item) {
        if (!item || !networkFlick || networkFlick.contentHeight <= networkFlick.height)
            return;
        const point = item.mapToItem(networkContent, 0, 0);
        const margin = 8;
        const top = point.y - margin;
        const bottom = point.y + item.height + margin;
        const viewTop = networkFlick.contentY;
        const viewBottom = viewTop + networkFlick.height;
        const maximum = Math.max(0, networkFlick.contentHeight - networkFlick.height);
        if (top < viewTop)
            networkFlick.contentY = Math.max(0, top);
        else if (bottom > viewBottom)
            networkFlick.contentY = Math.min(maximum, bottom - networkFlick.height);
    }

    function collapseWifiNetworks() {
        clearCredentials();
        if (wifiPicker && wifiPicker.visible)
            wifiPicker.forceActiveFocus();
        wifiNetworksOpen = false;
    }

    function toggleWifiNetworks() {
        if (!WifiState.enabled || WifiState.device === null)
            return;
        if (wifiNetworksOpen)
            collapseWifiNetworks();
        else
            wifiNetworksOpen = true;
    }

    function setWifiEnabled(value) {
        if (!value)
            collapseWifiNetworks();
        WifiState.setEnabled(value);
    }

    function runConnectRequest(request) {
        const accepted = NetworkDetails.runWifiAction(request);
        if (accepted)
            pendingConnectKey = request.ssid || request.uuid || "wifi";
        return accepted;
    }

    function beginConnect(network) {
        const security = network.securityInfo
            || NetworkHelpers.classifySecurity(network.profileSecurity || network.security);
        if (!security.supported) {
            openSettings();
            return;
        }
        if (network.profileUuid && ((!security.password && !security.identity)
                || NetworkDetails.wifiError(network.ssid) === "")) {
            runConnectRequest({
                action: "connect",
                ssid: network.ssid,
                uuid: network.profileUuid,
                interface: NetworkDetails.snapshot.wifi.interface,
                security: network.profileSecurity || network.security,
                saved: true
            });
            return;
        }
        if (!security.password && !security.identity) {
            runConnectRequest({
                action: "connect",
                ssid: network.ssid,
                interface: NetworkDetails.snapshot.wifi.interface,
                security: network.security,
                hidden: Boolean(network.hidden)
            });
            return;
        }
        credentialSsid = network.ssid;
        credentialSecurity = network.security;
        credentialUuid = network.profileUuid || "";
        credentialPassword = "";
        credentialIdentity = "";
        credentialInputError = "";
    }

    function submitCredentials() {
        const security = NetworkHelpers.classifySecurity(credentialSecurity);
        if (security.identity && credentialIdentity.trim() === "") {
            credentialInputError = "Enter your network identity.";
            return;
        }
        if (security.password && credentialPassword === "") {
            credentialInputError = "Enter the network password.";
            return;
        }
        const request = {
            action: "connect",
            ssid: credentialSsid,
            uuid: credentialUuid,
            interface: NetworkDetails.snapshot.wifi.interface,
            security: credentialSecurity,
            identity: credentialIdentity,
            password: credentialPassword
        };
        if (runConnectRequest(request))
            clearCredentials();
    }

    Connections {
        target: NetworkDetails

        function onWifiActionFinished(key, success, reason) {
            if (key !== root.pendingConnectKey)
                return;
            root.pendingConnectKey = "";
            if (success && root.visible)
                root.collapseWifiNetworks();
        }
    }

    function chooseDns(provider) {
        customDnsError = "";
        if (provider === "Custom") {
            customDnsOpen = true;
            customDnsText = NetworkDetails.dnsProvider === "Custom"
                ? NetworkDetails.dnsServers.join(", ") : "";
            return;
        }
        customDnsOpen = false;
        customDnsText = "";
        NetworkDetails.setDns(provider, []);
    }

    function applyCustomDns() {
        const validation = NetworkHelpers.validateDnsServers(customDnsText);
        if (!validation.valid) {
            customDnsError = validation.error;
            return;
        }
        if (NetworkDetails.setDns("Custom", validation.servers)) {
            customDnsOpen = false;
            customDnsText = "";
            customDnsError = "";
        }
    }

    function overlayScreen() {
        return Screens.byName(Popouts.hostScreenName) ?? Screens.focused;
    }

    component MetricTile: Rectangle {
        id: metric

        property string label: ""
        property string value: "--"
        property string symbol: ""

        height: 58
        radius: Theme.rowRadius
        color: Theme.chip
        Accessible.role: Accessible.StaticText
        Accessible.name: label
        Accessible.description: value

        Sym {
            x: 10
            y: 9
            name: metric.symbol
            size: Theme.fontCaption
            color: Theme.textDim
        }

        Text {
            x: 30
            y: 8
            width: parent.width - 38
            text: metric.label
            elide: Text.ElideRight
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.metadata
            color: Theme.textDim
        }

        Text {
            x: 10
            y: 30
            width: parent.width - 20
            text: metric.value
            elide: Text.ElideRight
            font.family: Theme.fontMono
            font.pixelSize: Theme.typography.secondary
            font.weight: Theme.weightSemibold
            color: Theme.textHi
        }
    }

    component Pill: Rectangle {
        id: pill

        property string label: ""
        property bool selected: false
        signal triggered()

        width: labelText.implicitWidth + 22
        height: 30
        radius: 9
        color: selected ? Theme.accent : Theme.chip
        opacity: enabled ? 1 : 0.4
        activeFocusOnTab: enabled && visible
        Accessible.role: Accessible.Button
        Accessible.name: label
        Accessible.description: selected ? "Selected" : ""
        Accessible.onPressAction: pill.triggered()
        border.width: activeFocus ? 1 : 0
        border.color: selected ? Theme.accentFg : Theme.accentText

        Keys.onPressed: event => {
            if (enabled && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                    || event.key === Qt.Key_Space)) {
                pill.triggered();
                event.accepted = true;
            }
        }

        Text {
            id: labelText
            anchors.centerIn: parent
            text: pill.label
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.control
            font.weight: Theme.weightSemibold
            color: pill.selected ? Theme.accentFg : Theme.textMid
        }

        MouseArea {
            anchors.fill: parent
            enabled: pill.enabled
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: pill.triggered()
        }
    }

    component HeroAction: Rectangle {
        id: action

        property string symbol: ""
        property string accessibleName: ""
        signal triggered()

        width: 36
        height: 36
        radius: 10
        color: actionMouse.containsMouse ? Theme.hoverFill : Theme.chip
        activeFocusOnTab: enabled && visible
        Accessible.role: Accessible.Button
        Accessible.name: accessibleName
        Accessible.onPressAction: action.triggered()
        border.width: activeFocus ? 1 : 0
        border.color: Theme.accentText

        Keys.onPressed: event => {
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                    || event.key === Qt.Key_Space) {
                action.triggered();
                event.accepted = true;
            }
        }

        Sym {
            anchors.centerIn: parent
            name: action.symbol
            size: Theme.iconMedium
            color: Theme.textMid
        }

        MouseArea {
            id: actionMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: action.triggered()
        }
    }

    component TailscaleSummary: Rectangle {
        id: summary

        width: parent ? parent.width : 0
        height: 48
        radius: Theme.rowRadius
        color: summaryMouse.containsMouse ? Theme.chipHover
            : Tailscale.connected ? Theme.chip : "transparent"
        scale: summaryMouse.pressed ? 0.99 : 1
        activeFocusOnTab: true
        border.width: activeFocus ? 1 : 0
        border.color: Theme.accentText

        Accessible.role: Accessible.Button
        Accessible.name: "Tailscale"
        Accessible.description: root.tailscaleDetail
        Accessible.onPressAction: summary.openDetails()

        function openDetails() {
            Popouts.openPanel("tailscale", "right");
        }

        onActiveFocusChanged: if (activeFocus) root.ensureVisible(summary)

        Keys.onPressed: event => {
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                    || event.key === Qt.Key_Space) {
                summary.openDetails();
                event.accepted = true;
            }
        }

        Behavior on color {
            ColorAnimation { duration: Theme.surfaceDuration }
        }

        Behavior on scale {
            NumberAnimation {
                duration: Theme.pressDuration
                easing.type: Easing.BezierSpline
                easing.bezierCurve: Theme.springCurve
            }
        }

        Item {
            x: 10
            anchors.verticalCenter: parent.verticalCenter
            width: 20
            height: 20

            BrandIcon {
                anchors.centerIn: parent
                width: 14
                height: 14
                name: "tailscale"
                colorized: true
                tint: Tailscale.connected ? Theme.accent : Theme.textDim
                opacity: Tailscale.connected ? 1 : 0.55
            }
        }

        Column {
            x: 40
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - x - 42
            spacing: 1

            Text {
                width: parent.width
                text: "Tailscale"
                elide: Text.ElideRight
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.primary
                font.weight: Tailscale.connected
                    ? Theme.weightSemibold : Theme.weightMedium
                color: Theme.textHi
            }

            Text {
                width: parent.width
                text: root.tailscaleDetail
                elide: Text.ElideRight
                font.family: Theme.fontMono
                font.pixelSize: Theme.typography.secondary
                color: Tailscale.statusError !== "" ? Theme.red : Theme.textDim
            }
        }

        Sym {
            anchors.right: parent.right
            anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            name: "chevron_right"
            size: Theme.iconSmall
            color: summaryMouse.containsMouse ? Theme.textHi : Theme.textFaint
        }

        MouseArea {
            id: summaryMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                summary.forceActiveFocus();
                summary.openDetails();
            }
        }
    }

    // Match the audio output selector: the active route is the compact,
    // always-visible control and the complete scan result expands inline.
    component WifiNetworkPicker: Rectangle {
        id: picker

        property string currentLabel: "No Wi-Fi connected"
        property string detailText: "No networks available"
        property string glyph: "wifi_off"
        property bool expanded: false
        property bool ready: true
        signal activated
        signal collapseRequested

        width: parent ? parent.width : 0
        height: 48
        radius: Theme.rowRadius
        color: pickerMouse.containsMouse && picker.ready
            ? Theme.chipHover : Theme.chip
        enabled: ready
        opacity: ready ? 1 : 0.55
        activeFocusOnTab: ready && visible
        Accessible.role: Accessible.Button
        Accessible.name: "Wi-Fi network, " + currentLabel
        Accessible.description: detailText + ". "
            + (expanded ? "Network list expanded" : "Network list collapsed")
        Accessible.onPressAction: picker.activated()
        border.width: activeFocus || expanded ? 1 : 0
        border.color: Theme.accentText

        onActiveFocusChanged: if (activeFocus) root.ensureVisible(picker)

        Keys.onPressed: event => {
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                    || event.key === Qt.Key_Space) {
                pickerState.pulseCenter();
                picker.activated();
                event.accepted = true;
            } else if (event.key === Qt.Key_Escape && picker.expanded) {
                picker.collapseRequested();
                event.accepted = true;
            }
        }

        StateLayer {
            id: pickerState
            anchors.fill: parent
            radius: parent.radius
            hovered: pickerMouse.containsMouse
            pressed: pickerMouse.pressed
            focused: picker.activeFocus
            tint: Theme.textHi
            pressPoint: Qt.point(pickerMouse.mouseX, pickerMouse.mouseY)
        }

        Sym {
            id: pickerIcon
            anchors.left: parent.left
            anchors.leftMargin: 11
            anchors.verticalCenter: parent.verticalCenter
            width: 22
            name: picker.glyph
            size: Theme.iconMedium
            color: picker.ready ? Theme.accentText : Theme.textDim
        }

        Column {
            anchors.left: pickerIcon.right
            anchors.leftMargin: 10
            anchors.right: pickerChevron.left
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            spacing: 1

            Text {
                width: parent.width
                text: picker.currentLabel
                elide: Text.ElideRight
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.primary
                font.weight: Theme.weightSemibold
                color: picker.ready ? Theme.textHi : Theme.textDim
            }

            Text {
                width: parent.width
                text: picker.detailText
                elide: Text.ElideRight
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.secondary
                font.weight: Theme.weightMedium
                color: Theme.textDim
            }
        }

        Sym {
            id: pickerChevron
            anchors.right: parent.right
            anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            width: 18
            name: picker.expanded ? "expand_less" : "expand_more"
            size: Theme.iconSmall
            color: picker.ready ? Theme.textLow : Theme.textDim
        }

        MouseArea {
            id: pickerMouse
            anchors.fill: parent
            enabled: picker.ready
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                picker.forceActiveFocus();
                picker.activated();
            }
        }
    }

    component NetworkRow: Rectangle {
        id: row

        required property var network
        readonly property var securityInfo: network.securityInfo
            || NetworkHelpers.classifySecurity(network.profileSecurity || network.security)
        readonly property bool expanded: root.credentialSsid === network.ssid
        readonly property bool working: NetworkDetails.actionKey === network.ssid
            && NetworkDetails.wifiBusy
        readonly property string actionError: NetworkDetails.wifiError(network.ssid)

        width: parent ? parent.width : 0
        height: 48 + (expanded ? credentialEditor.height + 8 : 0)
            + (actionError !== "" ? errorLabel.implicitHeight + 8 : 0)
        radius: Theme.rowRadius
        color: network.connected ? Theme.chip : rowMouse.containsMouse ? Theme.hoverFill : "transparent"
        border.width: activeFocus ? 1 : 0
        border.color: Theme.accentText
        activeFocusOnTab: true
        Accessible.role: Accessible.Button
        Accessible.name: network.ssid
        Accessible.description: (network.connected ? "Connected. " : "")
            + securityInfo.label + ". Signal " + network.signal + " percent"
        Accessible.onPressAction: row.activate()

        onActiveFocusChanged: if (activeFocus) root.ensureVisible(row)

        function activate() {
            if (working || NetworkDetails.wifiBusy)
                return;
            if (network.connected) {
                NetworkDetails.runWifiAction({ action: "disconnect",
                    ssid: network.ssid, interface: NetworkDetails.activeWifiInterface });
            } else {
                root.beginConnect(network);
            }
        }

        Keys.onPressed: event => {
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                    || event.key === Qt.Key_Space) {
                row.activate();
                event.accepted = true;
            } else if (event.key === Qt.Key_Escape) {
                root.collapseWifiNetworks();
                event.accepted = true;
            }
        }

        Item {
            id: topRow
            width: parent.width
            height: 48

            Sym {
                id: signalGlyph
                x: 10
                anchors.verticalCenter: parent.verticalCenter
                name: row.working ? "progress_activity"
                    : row.network.signal >= 66 ? "wifi"
                    : row.network.signal >= 33 ? "network_wifi_2_bar" : "network_wifi_1_bar"
                size: Theme.fontBody
                color: row.network.connected ? Theme.accentText : Theme.textMid

                // Gated on visibility: a hidden panel must not keep spinning.
                // A stopped value source keeps its angle, and the signal bars
                // that replace the arc must not inherit the tilt.
                RotationAnimation on rotation {
                    running: row.working && signalGlyph.visible && !Theme.reducedMotion
                    from: 0
                    to: 360
                    duration: 950
                    loops: Animation.Infinite
                    onRunningChanged: if (!running) signalGlyph.rotation = 0
                }
            }

            Column {
                x: 40
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - 102
                spacing: 1

                Text {
                    width: parent.width
                    text: row.network.ssid
                    elide: Text.ElideRight
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.primary
                    font.weight: row.network.connected ? Theme.weightSemibold : Theme.weightMedium
                    color: Theme.textHi
                }

                Text {
                    width: parent.width
                    text: row.working
                        ? (NetworkDetails.actionKind === "forget" ? "Forgetting…"
                            : NetworkDetails.actionKind === "disconnect" ? "Disconnecting…" : "Connecting…")
                        : (row.network.connected ? "Connected · " : "")
                            + row.securityInfo.label + " · " + row.network.signal + "%"
                    elide: Text.ElideRight
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.secondary
                    color: Theme.textDim
                }
            }

            Sym {
                visible: (!row.securityInfo.shareable && row.securityInfo.kind !== "open")
                    || row.securityInfo.password
                anchors.right: forgetButton.visible ? forgetButton.left : parent.right
                anchors.rightMargin: 12
                anchors.verticalCenter: parent.verticalCenter
                name: "lock"
                size: Theme.fontCaption
                color: Theme.textDim
            }

            Rectangle {
                id: forgetButton
                visible: row.network.known && !row.network.connected && Boolean(row.network.profileUuid)
                anchors.right: parent.right
                anchors.rightMargin: 6
                anchors.verticalCenter: parent.verticalCenter
                width: 32
                height: 32
                radius: 8
                color: forgetMouse.containsMouse ? Theme.hoverFill : "transparent"
                activeFocusOnTab: visible
                Accessible.role: Accessible.Button
                Accessible.name: "Forget " + row.network.ssid
                Accessible.onPressAction: NetworkDetails.runWifiAction({ action: "forget",
                    ssid: row.network.ssid, uuid: row.network.profileUuid })

                Sym {
                    anchors.centerIn: parent
                    name: "delete"
                    size: Theme.fontBody
                    color: Theme.textDim
                }

                MouseArea {
                    id: forgetMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: NetworkDetails.runWifiAction({ action: "forget",
                        ssid: row.network.ssid, uuid: row.network.profileUuid })
                }
            }

            MouseArea {
                id: rowMouse
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                anchors.right: forgetButton.visible ? forgetButton.left : parent.right
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: row.activate()
            }
        }

        Column {
            id: credentialEditor
            visible: row.expanded
            x: 40
            y: 48
            width: parent.width - 50
            height: visible ? implicitHeight : 0
            spacing: 8

            Rectangle {
                visible: row.securityInfo.identity
                width: parent.width
                height: visible ? 38 : 0
                radius: 8
                color: identityInput.activeFocus ? Theme.chipHover : Theme.tile
                border.width: identityInput.activeFocus ? 1 : 0
                border.color: Theme.accentText

                TextInput {
                    id: identityInput
                    anchors.fill: parent
                    anchors.leftMargin: 12
                    anchors.rightMargin: 12
                    verticalAlignment: TextInput.AlignVCenter
                    text: root.credentialIdentity
                    onTextEdited: root.credentialIdentity = text
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.control
                    color: Theme.textHi
                    selectionColor: Theme.accent
                    selectedTextColor: Theme.accentFg
                    Accessible.name: "Enterprise identity"

                    Text {
                        visible: identityInput.text === "" && !identityInput.activeFocus
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Identity"
                        font: identityInput.font
                        color: Theme.textDim
                    }
                }
            }

            Rectangle {
                width: parent.width
                height: 38
                radius: 8
                color: passwordInput.activeFocus ? Theme.chipHover : Theme.tile
                border.width: passwordInput.activeFocus ? 1 : 0
                border.color: Theme.accentText

                TextInput {
                    id: passwordInput
                    anchors.fill: parent
                    anchors.leftMargin: 12
                    anchors.rightMargin: 12
                    verticalAlignment: TextInput.AlignVCenter
                    text: root.credentialPassword
                    onTextEdited: root.credentialPassword = text
                    echoMode: TextInput.Password
                    passwordCharacter: "•"
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.control
                    color: Theme.textHi
                    selectionColor: Theme.accent
                    selectedTextColor: Theme.accentFg
                    Accessible.name: "Network password"
                    Keys.onReturnPressed: root.submitCredentials()
                    Keys.onEnterPressed: root.submitCredentials()

                    Text {
                        visible: passwordInput.text === "" && !passwordInput.activeFocus
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Password"
                        font: passwordInput.font
                        color: Theme.textDim
                    }
                }
            }

            Text {
                visible: root.credentialInputError !== ""
                width: parent.width
                text: root.credentialInputError
                wrapMode: Text.Wrap
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.secondary
                color: Theme.red
            }

            Row {
                spacing: 8

                Pill {
                    label: "Connect"
                    selected: true
                    onTriggered: root.submitCredentials()
                }

                Pill {
                    label: "Cancel"
                    onTriggered: root.clearCredentials()
                }

                LinkText {
                    visible: row.securityInfo.identity
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Certificates? Network Settings"
                    onClicked: root.openSettings()
                }
            }
        }

        Text {
            id: errorLabel
            visible: row.actionError !== ""
            x: 40
            y: 48 + (row.expanded ? credentialEditor.height + 8 : 0)
            width: parent.width - 50
            text: row.actionError
            wrapMode: Text.Wrap
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.secondary
            color: Theme.red
        }
    }

    Item {
        id: viewport
        width: parent.width
        height: Math.min(networkContent.implicitHeight, root.bodyLimit)

        Flickable {
            id: networkFlick
            anchors.fill: parent
            contentWidth: width
            contentHeight: networkContent.implicitHeight
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height
            clip: true
            flickDeceleration: 3000

            Column {
                id: networkContent
                width: networkFlick.width - 7
                spacing: 10

                Item {
                    width: parent.width
                    height: 38

                    Text {
                        x: 2
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Network"
                        font.family: Theme.fontMenu
                        font.pixelSize: Theme.typography.heading
                        font.weight: Theme.weightSemibold
                        color: Theme.textHi
                    }

                    HeroAction {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        symbol: "settings"
                        accessibleName: "Open Network Settings"
                        onTriggered: root.openSettings()
                    }
                }

                Rectangle {
                    width: parent.width
                    height: 102
                    radius: Theme.rowRadius + 2
                    color: Theme.chip
                    border.width: 1
                    border.color: Theme.hairlineSoft

                    Rectangle {
                        x: 12
                        anchors.verticalCenter: parent.verticalCenter
                        width: 58
                        height: 58
                        radius: 18
                        color: Theme.hoverFill

                        Sym {
                            anchors.centerIn: parent
                            name: !root.primary ? "wifi_off"
                                : NetworkHelpers.physicalType(root.primary) === "ethernet" ? "lan" : "wifi"
                            size: Theme.fontHero
                            color: root.primary ? Theme.accentText : Theme.textDim
                        }
                    }

                    Column {
                        x: 82
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - x - heroActions.width - 18
                        spacing: 3

                        Text {
                            width: parent.width
                            text: root.heroTitle
                            elide: Text.ElideRight
                            font.family: Theme.fontMenu
                            font.pixelSize: Theme.typography.metadata
                            font.weight: Theme.weightBold
                            font.letterSpacing: 1
                            color: Theme.accentText
                        }

                        Text {
                            width: parent.width
                            text: root.heroName
                            elide: Text.ElideRight
                            font.family: Theme.fontMenu
                            font.pixelSize: Theme.typography.title
                            font.weight: Theme.weightSemibold
                            color: Theme.textHi
                        }

                        Text {
                            width: parent.width
                            text: root.heroStatus
                            elide: Text.ElideRight
                            font.family: Theme.fontMenu
                            font.pixelSize: Theme.typography.secondary
                            color: Theme.textLow
                        }
                    }

                    Row {
                        id: heroActions
                        anchors.right: parent.right
                        anchors.rightMargin: 12
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 7

                        HeroAction {
                            visible: root.activeWifi !== null && root.activeWifiSecurity.shareable
                            symbol: "qr_code_2"
                            accessibleName: "Share connected Wi-Fi"
                            onTriggered: NetworkOverlayState.openQr(root.overlayScreen(),
                                NetworkDetails.activeWifiInterface)
                        }

                        HeroAction {
                            visible: root.primary !== null
                            symbol: "speed"
                            accessibleName: "Run Internet speed test"
                            onTriggered: NetworkOverlayState.openSpeedTest(root.overlayScreen(),
                                NetworkDetails.primaryInterface)
                        }

                        Toggle {
                            visible: WifiState.device !== null
                            anchors.verticalCenter: parent.verticalCenter
                            checked: WifiState.enabled
                            accessibleName: "Wi-Fi"
                            onToggled: value => root.setWifiEnabled(value)
                        }
                    }
                }

                Grid {
                    width: parent.width
                    columns: 4
                    columnSpacing: 7
                    rowSpacing: 7

                    MetricTile {
                        width: (parent.width - parent.columnSpacing * 3) / 4
                        label: "Ping"
                        symbol: "network_ping"
                        value: NetworkHelpers.formatLatency(NetworkDetails.internetPing.latency)
                    }
                    MetricTile {
                        width: (parent.width - parent.columnSpacing * 3) / 4
                        label: "Packet loss"
                        symbol: "signal_disconnected"
                        value: NetworkDetails.internetPing.samples > 0
                            ? NetworkDetails.internetPing.loss + "%" : "--"
                    }
                    MetricTile {
                        width: (parent.width - parent.columnSpacing * 3) / 4
                        label: "Receive"
                        symbol: "download"
                        value: NetworkHelpers.formatRate(NetworkDetails.downloadRate)
                    }
                    MetricTile {
                        width: (parent.width - parent.columnSpacing * 3) / 4
                        label: "Send"
                        symbol: "upload"
                        value: NetworkHelpers.formatRate(NetworkDetails.uploadRate)
                    }
                    MetricTile {
                        width: (parent.width - parent.columnSpacing * 3) / 4
                        label: "Downloaded"
                        symbol: "data_usage"
                        value: root.primary ? NetworkHelpers.formatBytes(root.primary.rxBytes) : "--"
                    }
                    MetricTile {
                        width: (parent.width - parent.columnSpacing * 3) / 4
                        label: "Uploaded"
                        symbol: "data_usage"
                        value: root.primary ? NetworkHelpers.formatBytes(root.primary.txBytes) : "--"
                    }
                    MetricTile {
                        width: (parent.width - parent.columnSpacing * 3) / 4
                        label: "IPv4 address"
                        symbol: "language"
                        value: root.primary && root.primary.ipv4 ? root.primary.ipv4 : "--"
                    }
                    MetricTile {
                        width: (parent.width - parent.columnSpacing * 3) / 4
                        label: "Gateway"
                        symbol: "router"
                        value: root.primary && root.primary.gateway ? root.primary.gateway : "--"
                    }
                }

                Column {
                    width: parent.width
                    spacing: 7

                    SectionLabel {
                        width: parent.width
                        text: "TAILSCALE"
                    }

                    TailscaleSummary {}
                }

                Column {
                    width: parent.width
                    spacing: 7

                    Row {
                        width: parent.width

                        SectionLabel {
                            width: parent.width - dnsState.implicitWidth
                            text: "DNS"
                        }

                        Text {
                            id: dnsState
                            anchors.verticalCenter: parent.verticalCenter
                            text: NetworkDetails.dnsBusy ? "Applying…" : NetworkDetails.dnsProvider
                            font.family: Theme.fontMenu
                            font.pixelSize: Theme.typography.secondary
                            color: NetworkDetails.dnsMixed ? Theme.red : Theme.textDim
                        }
                    }

                    Row {
                        spacing: 7

                        Repeater {
                            model: ["Automatic", "Cloudflare", "Google", "Custom"]

                            Pill {
                                required property string modelData
                                label: modelData
                                selected: NetworkDetails.dnsProvider === modelData
                                    && !NetworkDetails.dnsMixed
                                enabled: !NetworkDetails.dnsBusy
                                onTriggered: root.chooseDns(modelData)
                            }
                        }
                    }

                    Row {
                        visible: root.customDnsOpen
                        width: parent.width
                        height: visible ? 38 : 0
                        spacing: 8

                        Rectangle {
                            width: parent.width - applyDns.width - parent.spacing
                            height: parent.height
                            radius: 8
                            color: customDnsInput.activeFocus ? Theme.chipHover : Theme.tile
                            border.width: customDnsInput.activeFocus ? 1 : 0
                            border.color: Theme.accentText

                            TextInput {
                                id: customDnsInput
                                anchors.fill: parent
                                anchors.leftMargin: 12
                                anchors.rightMargin: 12
                                verticalAlignment: TextInput.AlignVCenter
                                text: root.customDnsText
                                onTextEdited: root.customDnsText = text
                                font.family: Theme.fontMono
                                font.pixelSize: Theme.typography.control
                                color: Theme.textHi
                                selectionColor: Theme.accent
                                selectedTextColor: Theme.accentFg
                                Accessible.name: "Custom DNS servers"
                                Accessible.description: "Up to four IPv4 or IPv6 addresses"
                                Keys.onReturnPressed: root.applyCustomDns()
                                Keys.onEnterPressed: root.applyCustomDns()
                            }
                        }

                        Pill {
                            id: applyDns
                            label: "Apply"
                            selected: true
                            onTriggered: root.applyCustomDns()
                        }
                    }

                    Text {
                        visible: root.customDnsError !== "" || NetworkDetails.dnsError !== ""
                        width: parent.width
                        text: root.customDnsError || NetworkDetails.dnsError
                        wrapMode: Text.Wrap
                        font.family: Theme.fontMenu
                        font.pixelSize: Theme.typography.secondary
                        color: Theme.red
                    }

                    Text {
                        visible: NetworkDetails.dnsNotice !== ""
                        width: parent.width
                        text: NetworkDetails.dnsNotice
                        wrapMode: Text.Wrap
                        font.family: Theme.fontMenu
                        font.pixelSize: Theme.typography.secondary
                        color: Theme.textLow
                    }
                }

                HDivider { width: parent.width }

                SectionLabel {
                    width: parent.width
                    text: "ETHERNET"
                }

                Text {
                    visible: !EthernetState.known
                    width: parent.width
                    text: "Checking Ethernet…"
                    horizontalAlignment: Text.AlignHCenter
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.secondary
                    color: Theme.textDim
                }

                Text {
                    visible: EthernetState.error !== ""
                    width: parent.width
                    text: "Ethernet status unavailable\n" + EthernetState.error
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.Wrap
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.secondary
                    color: Theme.red
                }

                Text {
                    visible: EthernetState.known && EthernetState.error === ""
                        && EthernetState.devices.length === 0
                    width: parent.width
                    text: "No Ethernet ports"
                    horizontalAlignment: Text.AlignHCenter
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.secondary
                    color: Theme.textDim
                }

                Repeater {
                    model: EthernetState.devices

                    Rectangle {
                        id: ethernetRow
                        required property var modelData
                        width: networkContent.width
                        height: 46
                        radius: Theme.rowRadius
                        color: modelData.connected ? Theme.chip : "transparent"

                        Sym {
                            x: 10
                            anchors.verticalCenter: parent.verticalCenter
                            name: "lan"
                            size: Theme.fontBody
                            color: ethernetRow.modelData.connected ? Theme.accentText : Theme.textDim
                        }

                        Column {
                            x: 40
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width - 50
                            spacing: 1

                            Text {
                                width: parent.width
                                text: ethernetRow.modelData.connection || "No active profile"
                                elide: Text.ElideRight
                                font.family: Theme.fontMenu
                                font.pixelSize: Theme.typography.primary
                                font.weight: Theme.weightMedium
                                color: Theme.textHi
                            }

                            Text {
                                width: parent.width
                                text: ethernetRow.modelData.device + " · "
                                    + ethernetRow.modelData.status
                                    + (ethernetRow.modelData.ipv4
                                        ? " · " + ethernetRow.modelData.ipv4 : "")
                                elide: Text.ElideRight
                                font.family: Theme.fontMono
                                font.pixelSize: Theme.typography.secondary
                                color: Theme.textDim
                            }
                        }
                    }
                }

                HDivider { width: parent.width }

                Item {
                    width: parent.width
                    height: 36

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Wi-Fi networks"
                        font.family: Theme.fontMenu
                        font.pixelSize: Theme.typography.primary
                        font.weight: Theme.weightSemibold
                        color: Theme.textHi
                    }

                    Text {
                        anchors.right: wifiToggle.left
                        anchors.rightMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        text: WifiState.enabled && WifiState.scanning ? "Scanning…" : ""
                        font.family: Theme.fontMenu
                        font.pixelSize: Theme.typography.secondary
                        color: Theme.textDim
                    }

                    Toggle {
                        id: wifiToggle
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        checked: WifiState.enabled
                        accessibleName: "Wi-Fi"
                        onToggled: value => root.setWifiEnabled(value)
                    }
                }

                Text {
                    visible: !WifiState.enabled || WifiState.device === null
                    width: parent.width
                    topPadding: 8
                    bottomPadding: 8
                    text: !WifiState.enabled ? "Wi-Fi is off" : "No Wi-Fi adapter"
                    horizontalAlignment: Text.AlignHCenter
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.secondary
                    color: Theme.textDim
                }

                WifiNetworkPicker {
                    id: wifiPicker

                    visible: WifiState.enabled && WifiState.device !== null
                    width: parent.width
                    currentLabel: root.connectedWifiName !== ""
                        ? root.connectedWifiName : "No Wi-Fi connected"
                    detailText: {
                        const count = root.wifiNetworkCount;
                        if (count === 0)
                            return WifiState.scanning
                                ? "Scanning for networks…" : "No networks available";
                        const countText = count + " network" + (count === 1 ? "" : "s");
                        if (root.wifiNetworksOpen)
                            return "Choose network · " + countText;
                        if (root.connectedWifiName === "")
                            return "Choose a network · " + countText;
                        const signal = root.connectedWifiSignal >= 0
                            ? Math.round(root.connectedWifiSignal) + "% · " : "";
                        return "Current network · " + signal + countText;
                    }
                    glyph: root.connectedWifiGlyph
                    ready: root.wifiNetworkCount > 0
                        || root.connectedWifiName !== ""
                        || WifiState.scanning
                    expanded: root.wifiNetworksOpen
                    onActivated: root.toggleWifiNetworks()
                    onCollapseRequested: root.collapseWifiNetworks()
                }

                Column {
                    id: wifiNetworkList

                    visible: root.wifiNetworksOpen
                    width: parent.width
                    spacing: 4

                    SectionLabel {
                        visible: NetworkDetails.knownNetworks.length > 0
                        width: parent.width
                        text: "KNOWN NETWORKS"
                    }

                    Repeater {
                        model: root.wifiNetworksOpen && WifiState.enabled
                            ? NetworkDetails.knownNetworks : []
                        NetworkRow { required property var modelData; network: modelData }
                    }

                    SectionLabel {
                        visible: NetworkDetails.otherNetworks.length > 0
                        width: parent.width
                        text: "OTHER NETWORKS"
                    }

                    Repeater {
                        model: root.wifiNetworksOpen && WifiState.enabled
                            ? NetworkDetails.otherNetworks : []
                        NetworkRow { required property var modelData; network: modelData }
                    }

                    Text {
                        visible: NetworkDetails.knownNetworks.length === 0
                            && NetworkDetails.otherNetworks.length === 0
                        width: parent.width
                        topPadding: 8
                        bottomPadding: 8
                        text: NetworkDetails.error !== ""
                            ? NetworkDetails.error : "No networks found"
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.Wrap
                        font.family: Theme.fontMenu
                        font.pixelSize: Theme.typography.secondary
                        color: Theme.textDim
                    }
                }

                HDivider { width: parent.width }

                Item {
                    width: parent.width
                    height: 32

                    Text {
                        x: 2
                        anchors.verticalCenter: parent.verticalCenter
                        text: NetworkDetails.known && NetworkDetails.error === ""
                            ? NetworkDetails.pollCadenceText : ""
                        font.family: Theme.fontMenu
                        font.pixelSize: Theme.typography.secondary
                        color: Theme.textDim
                    }

                    LinkText {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Network settings"
                        onClicked: root.openSettings()
                    }
                }
            }
        }

        ScrollChrome {
            anchors.fill: parent
            target: networkFlick
        }
    }
}
