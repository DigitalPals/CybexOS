pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import "Common"
import "Common/Format.js" as Format
import "Common/NetworkHelpers.js" as NetworkHelpers

// The Network panel's one shell-wide modal surface.  Its Loader is inactive
// when closed, so dismissing QR destroys every object that ever held a secret,
// and dismissing the speed page destroys (and explicitly terminates) its
// helper and curl workers.
PanelWindow {
    id: root

    readonly property Item loadedPage: pageLoader.item as Item

    readonly property string helper: Quickshell.shellDir + "/scripts/network-tool.py"
    readonly property string speedHelper: Quickshell.shellDir + "/scripts/network-speedtest.py"
    readonly property bool qrPageActive: NetworkOverlayState.page === "qr"

    visible: NetworkOverlayState.open || scrim.opacity > 0.001
    screen: NetworkOverlayState.screen ?? Screens.focused
    anchors { top: true; left: true; right: true; bottom: true }
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"

    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "qs-network-overlay"
    WlrLayershell.keyboardFocus: NetworkOverlayState.open
        ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    HyprlandFocusGrab {
        active: NetworkOverlayState.open
        windows: [root]
        onCleared: NetworkOverlayState.close()
    }

    Rectangle {
        id: scrim
        anchors.fill: parent
        color: Theme.scrim
        opacity: NetworkOverlayState.open ? 1 : 0

        Behavior on opacity {
            NumberAnimation { duration: Theme.panelFadeDuration; easing.type: Easing.OutCubic }
        }

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: NetworkOverlayState.close()
        }
    }

    FocusScope {
        anchors.fill: parent
        focus: NetworkOverlayState.open
        Keys.onEscapePressed: NetworkOverlayState.close()

        Rectangle {
            id: card

            anchors.centerIn: parent
            width: Math.min(620, root.width - 32)
            height: Math.min(root.height - 32, root.loadedPage
                ? root.loadedPage.implicitHeight + 88 : 260)
            radius: Theme.popRadius
            color: Theme.panelSurface
            border.width: 1
            border.color: Theme.stroke
            opacity: scrim.opacity
            scale: NetworkOverlayState.open ? 1 : 0.96

            Behavior on scale {
                NumberAnimation {
                    duration: Theme.panelMotionDuration
                    easing.type: Easing.BezierSpline
                    easing.bezierCurve: Theme.springCurve
                }
            }

            MouseArea { anchors.fill: parent }

            Row {
                x: 24
                y: 18
                width: parent.width - 48
                height: 34
                spacing: 10

                Sym {
                    anchors.verticalCenter: parent.verticalCenter
                    name: root.qrPageActive ? "qr_code_2"
                        : NetworkOverlayState.page === "tailscale" ? "vpn_key" : "speed"
                    size: Theme.iconLarge
                    color: Theme.accentText
                }

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - closeButton.width - 38
                    text: NetworkOverlayState.page === "qr" ? "Share Wi-Fi"
                        : NetworkOverlayState.page === "tailscale" ? "Connect to Tailscale" : "Internet speed"
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.heading
                    font.weight: Theme.weightSemibold
                    color: Theme.textHi
                }

                Rectangle {
                    id: closeButton
                    anchors.verticalCenter: parent.verticalCenter
                    width: 30
                    height: 30
                    radius: 8
                    color: closeMouse.containsMouse ? Theme.hoverFill : "transparent"
                    activeFocusOnTab: true
                    Accessible.role: Accessible.Button
                    Accessible.name: "Close network dialog"
                    Accessible.onPressAction: NetworkOverlayState.close()
                    border.width: activeFocus ? 1 : 0
                    border.color: Theme.accentText

                    Keys.onPressed: event => {
                        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                                || event.key === Qt.Key_Space) {
                            NetworkOverlayState.close();
                            event.accepted = true;
                        }
                    }

                    Sym {
                        anchors.centerIn: parent
                        name: "close"
                        size: Theme.iconMedium
                        color: Theme.textMid
                    }

                    MouseArea {
                        id: closeMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: NetworkOverlayState.close()
                    }
                }
            }

            Rectangle {
                x: 24
                y: 62
                width: parent.width - 48
                height: 1
                color: Theme.hairlineSoft
            }

            Loader {
                id: pageLoader
                active: NetworkOverlayState.open
                x: 24
                y: 72
                width: parent.width - 48
                sourceComponent: NetworkOverlayState.page === "qr" ? qrPage
                    : NetworkOverlayState.page === "tailscale" ? tailscalePage : speedPage
            }
        }
    }

    Component {
        id: tailscalePage

        Column {
            id: tailscaleSetup
            spacing: 18
            property bool copied: false

            Claim {
                active: true
                onClaimed: Tailscale.acquireLive()
                onReleased: Tailscale.releaseLive()
            }

            Text {
                width: parent.width
                text: Tailscale.connected ? "This device is connected"
                    : Tailscale.needsApproval ? "Waiting for administrator approval"
                    : Tailscale.authPending ? Tailscale.statusText
                    : "Connect this device to Tailscale"
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.heading
                font.weight: Theme.weightSemibold
                color: Theme.textHi
                wrapMode: Text.WordWrap
            }

            Text {
                width: parent.width
                text: Tailscale.connected
                    ? [Tailscale.host, Tailscale.net, Tailscale.ip].filter(s => s !== "").join(" · ")
                    : Tailscale.needsApproval
                        ? "Your organization needs to approve this device. Ask your Tailscale administrator to approve it; the connection will update automatically."
                    : Tailscale.authPending
                        ? "Finish signing in and approving this device in your browser. You can close this dialog while you finish."
                        : "Sign in to add this computer to your private network. Your browser will open Tailscale’s sign-in page."
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.primary
                color: Theme.textMid
                wrapMode: Text.WordWrap
            }

            Text {
                visible: Tailscale.actionError !== "" || Tailscale.statusError !== "" || Tailscale.missing
                width: parent.width
                text: Tailscale.actionError || Tailscale.statusText
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.secondary
                color: Theme.redText
                wrapMode: Text.WordWrap
                textFormat: Text.PlainText
            }

            Flow {
                width: parent.width
                spacing: 10

                ModalButton {
                    visible: !Tailscale.connected && !Tailscale.needsApproval
                    primary: true
                    label: Tailscale.authUrl !== "" ? "Open browser again"
                        : Tailscale.busy ? "Preparing sign-in…"
                        : Tailscale.actionError !== "" ? "Try again" : "Continue in browser"
                    enabled: (!Tailscale.busy || Tailscale.authUrl !== "") && !Tailscale.missing
                    onTriggered: Tailscale.signIn()
                }

                ModalButton {
                    visible: Tailscale.authUrl !== ""
                    label: tailscaleSetup.copied ? "Copied" : "Copy sign-in link"
                    onTriggered: {
                        Tailscale.copySignInLink();
                        tailscaleSetup.copied = true;
                    }
                }

                ModalButton {
                    visible: Tailscale.authPending && !Tailscale.busy
                    label: "Stop connecting"
                    onTriggered: Tailscale.startAction(false)
                }

                ModalButton {
                    label: Tailscale.connected ? "Done"
                        : Tailscale.authPending || Tailscale.needsApproval ? "Close" : "Cancel"
                    onTriggered: NetworkOverlayState.close()
                }
            }
        }
    }

    component ModalButton: Rectangle {
        id: button

        property string label: ""
        property bool primary: false
        signal triggered()

        width: labelText.implicitWidth + 30
        height: 34
        radius: 9
        color: primary ? Theme.accent : Theme.chip
        opacity: enabled ? 1 : 0.4
        activeFocusOnTab: enabled
        Accessible.role: Accessible.Button
        Accessible.name: label
        Accessible.onPressAction: button.triggered()
        border.width: activeFocus ? 1 : 0
        border.color: primary ? Theme.accentFg : Theme.accentText

        Keys.onPressed: event => {
            if (button.enabled && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                    || event.key === Qt.Key_Space)) {
                button.triggered();
                event.accepted = true;
            }
        }

        Text {
            id: labelText
            anchors.centerIn: parent
            text: button.label
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.control
            font.weight: Theme.weightSemibold
            color: button.primary ? Theme.accentFg : Theme.textMid
        }

        MouseArea {
            anchors.fill: parent
            enabled: button.enabled
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: button.triggered()
        }
    }

    Component {
        id: qrPage

        FocusScope {
            id: qr

            property var info: NetworkOverlayState.qrInfo
            readonly property var securityInfo: NetworkHelpers.classifySecurity(info.security)
            property var matrix: []
            property string error: ""
            property var pendingQrRequest: ({})
            readonly property bool working: qrProc.running

            implicitHeight: Math.min(560, content.implicitHeight + 10)

            function startQr() {
                if (qrProc.running)
                    return;
                pendingQrRequest = {
                    uuid: info.uuid,
                    ssid: info.ssid,
                    security: info.security,
                    hidden: Boolean(info.hidden)
                };
                qrProc.running = true;
            }

            function openSettings() {
                Settings.showPanel("network");
                NetworkOverlayState.close();
            }

            Component.onCompleted: {
                if (!info.ssid) {
                    error = "The Wi-Fi connection is no longer active.";
                } else if (!securityInfo.supported || !securityInfo.shareable) {
                    error = "Enterprise and certificate-based networks cannot be shared here.";
                } else
                    startQr();
            }

            Component.onDestruction: {
                if (qrProc.running)
                    qrProc.signal(15);
                matrix = [];
                pendingQrRequest = {};
                error = "";
            }

            Flickable {
                anchors.fill: parent
                contentWidth: width
                contentHeight: content.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds

                Column {
                    id: content
                    width: qr.width
                    spacing: 14

                    Column {
                        width: parent.width
                        spacing: 3

                        Text {
                            width: parent.width
                            text: qr.info.ssid || "No active Wi-Fi"
                            horizontalAlignment: Text.AlignHCenter
                            elide: Text.ElideRight
                            font.family: Theme.fontMenu
                            font.pixelSize: Theme.typography.title
                            font.weight: Theme.weightSemibold
                            color: Theme.textHi
                        }

                        Text {
                            width: parent.width
                            text: qr.securityInfo.label
                                + (qr.info.hidden ? " · hidden network" : "")
                            horizontalAlignment: Text.AlignHCenter
                            font.family: Theme.fontMenu
                            font.pixelSize: Theme.typography.secondary
                            color: Theme.textLow
                        }
                    }

                    Item {
                        visible: qr.matrix.length > 0
                        width: parent.width
                        height: visible ? Math.min(320, qr.width - 24) : 0

                        Rectangle {
                            anchors.centerIn: parent
                            width: Math.min(parent.height, parent.width)
                            height: width
                            radius: 10
                            color: "white"

                            // Painted once per matrix rather than built as a
                            // Rectangle (and binding) per module — a Wi-Fi QR
                            // is well over a thousand of them.
                            Canvas {
                                id: qrGrid
                                anchors.centerIn: parent
                                readonly property var matrix: qr.matrix
                                readonly property int columns: matrix.length > 0
                                    ? matrix[0].length : 1
                                readonly property real cell: matrix.length > 0
                                    ? Math.max(1, Math.floor((parent.width - 16) / columns)) : 1
                                width: cell * columns
                                height: cell * Math.max(1, matrix.length)
                                // Hard module edges: antialiased neighbours
                                // leave hairline seams at fractional scales.
                                antialiasing: false
                                onMatrixChanged: requestPaint()
                                onCellChanged: requestPaint()
                                onPaint: {
                                    const context = getContext("2d");
                                    context.reset();
                                    context.fillStyle = "white";
                                    context.fillRect(0, 0, width, height);
                                    context.fillStyle = "#111111";
                                    for (let row = 0; row < matrix.length; row++) {
                                        const line = matrix[row];
                                        for (let column = 0; column < line.length; column++) {
                                            if (line.charAt(column) === "1")
                                                context.fillRect(column * cell, row * cell,
                                                    cell, cell);
                                        }
                                    }
                                }
                            }
                        }
                    }

                    Text {
                        visible: qr.error !== ""
                        width: parent.width
                        text: qr.error
                        wrapMode: Text.Wrap
                        horizontalAlignment: Text.AlignHCenter
                        font.family: Theme.fontMenu
                        font.pixelSize: Theme.typography.secondary
                        color: Theme.red
                    }

                    Text {
                        visible: qr.working
                        width: parent.width
                        text: "Building QR code…"
                        horizontalAlignment: Text.AlignHCenter
                        font.family: Theme.fontMenu
                        font.pixelSize: Theme.typography.secondary
                        color: Theme.textDim
                    }

                    Row {
                        anchors.horizontalCenter: parent.horizontalCenter
                        spacing: 10

                        ModalButton {
                            visible: !qr.securityInfo.shareable
                            label: "Open Network Settings"
                            onTriggered: qr.openSettings()
                        }

                        ModalButton {
                            label: "Close"
                            onTriggered: NetworkOverlayState.close()
                        }
                    }
                }
            }

            Process {
                id: qrProc
                property string body: ""
                property bool exitedNormally: false
                property int lastExit: -1

                command: ["python3", root.helper, "qr"]
                stdinEnabled: true
                stdout: StdioCollector { onStreamFinished: qrProc.body = text }
                stderr: StdioCollector {}
                onStarted: {
                    qrProc.write(JSON.stringify(qr.pendingQrRequest) + "\n");
                    qr.pendingQrRequest = {};
                }
                onExited: (exitCode, exitStatus) => {
                    qrProc.exitedNormally = true;
                    qrProc.lastExit = exitCode;
                }
                onRunningChanged: {
                    if (running) {
                        body = "";
                        exitedNormally = false;
                        lastExit = -1;
                        return;
                    }
                    if (!NetworkOverlayState.open || NetworkOverlayState.page !== "qr")
                        return;
                    const result = root.parseOverlayResult(body, "QR generation");
                    if (!exitedNormally || lastExit !== 0 || !result.success) {
                        qr.error = result.error || "The QR code could not be generated.";
                        return;
                    }
                    qr.matrix = Array.isArray(result.matrix) ? result.matrix : [];
                    qr.error = qr.matrix.length > 0 ? "" : "The QR code was empty.";
                }
            }
        }
    }

    component SpeedDial: Item {
        id: dial

        property string label: ""
        property real value: 0
        property bool active: false

        width: 250
        height: 184
        Accessible.role: Accessible.StaticText
        Accessible.name: label
        Accessible.description: value.toFixed(value < 10 ? 1 : 0) + " megabits per second"

        onValueChanged: gauge.requestPaint()
        onWidthChanged: gauge.requestPaint()
        onHeightChanged: gauge.requestPaint()

        Canvas {
            id: gauge
            anchors.fill: parent
            onPaint: {
                const context = getContext("2d");
                context.reset();
                const radius = Math.min(width, height * 1.35) * 0.38;
                const cx = width / 2;
                const cy = height * 0.62;
                const start = Math.PI * 0.75;
                const span = Math.PI * 1.5;
                context.lineWidth = 12;
                context.lineCap = "round";
                context.strokeStyle = Theme.hairline.toString();
                context.beginPath();
                context.arc(cx, cy, radius, start, start + span);
                context.stroke();
                const progress = Format.clamp01(
                    Math.log(dial.value + 1) / Math.log(1001));
                context.strokeStyle = (dial.active ? Theme.accent : Theme.textLow).toString();
                context.beginPath();
                context.arc(cx, cy, radius, start, start + span * progress);
                context.stroke();
            }
        }

        Column {
            anchors.centerIn: parent
            anchors.verticalCenterOffset: 15
            spacing: 2

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: dial.value.toFixed(dial.value < 10 ? 1 : 0)
                font.family: Theme.fontMono
                font.pixelSize: Theme.typography.display
                font.weight: Theme.weightSemibold
                color: Theme.textHi
            }

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "Mbps"
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.secondary
                color: Theme.textDim
            }
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            text: dial.label
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.primary
            font.weight: Theme.weightSemibold
            color: dial.active ? Theme.accentText : Theme.textMid
        }
    }

    Component {
        id: speedPage

        FocusScope {
            id: speed

            property string phase: "starting"
            property real downloadMbps: 0
            property real uploadMbps: 0
            property string error: ""
            property bool completed: false
            property bool canceled: false
            property var devices: NetworkOverlayState.speedDevices
            property string selectedInterface: ""
            property string pendingInterface: ""
            property bool switching: false
            readonly property var selectedDevice: devices.find(device =>
                device.interfaceName === selectedInterface) ?? null

            implicitHeight: content.implicitHeight + 8

            function start() {
                if (speedProc.running || !selectedInterface)
                    return;
                forceActiveFocus();
                phase = "starting";
                downloadMbps = 0;
                uploadMbps = 0;
                error = "";
                completed = false;
                canceled = false;
                speedProc.running = true;
            }

            function chooseInterface(interfaceName) {
                if (!interfaceName || (interfaceName === selectedInterface
                        && pendingInterface === ""))
                    return;
                pendingInterface = interfaceName;
                error = "";
                canceled = false;
                if (speedProc.running) {
                    switching = true;
                    phase = "switching";
                    speedProc.signal(15);
                } else {
                    applyPendingInterface();
                }
            }

            function applyPendingInterface() {
                if (pendingInterface === "")
                    return;
                selectedInterface = pendingInterface;
                pendingInterface = "";
                switching = false;
                NetworkOverlayState.selectSpeedInterface(selectedInterface);
                Qt.callLater(speed.start);
            }

            function cancel() {
                if (!speedProc.running)
                    return;
                forceActiveFocus();
                pendingInterface = "";
                switching = false;
                canceled = true;
                phase = "canceled";
                speedProc.signal(15);
            }

            function applyLine(line) {
                let record = null;
                try {
                    record = JSON.parse(line);
                } catch (exception) {
                    error = "The speed test returned invalid progress.";
                    return;
                }
                if (record.type === "phase") {
                    phase = record.phase;
                } else if (record.type === "sample") {
                    phase = record.phase;
                    if (record.phase === "download")
                        downloadMbps = Number(record.mbps) || 0;
                    else if (record.phase === "upload")
                        uploadMbps = Number(record.mbps) || 0;
                } else if (record.type === "completion") {
                    forceActiveFocus();
                    downloadMbps = Number(record.downloadMbps) || 0;
                    uploadMbps = Number(record.uploadMbps) || 0;
                    phase = "complete";
                    completed = true;
                } else if (record.type === "error" && !canceled && !switching) {
                    forceActiveFocus();
                    phase = record.phase || "error";
                    error = record.error || "The speed test failed.";
                }
            }

            Component.onCompleted: {
                selectedInterface = NetworkOverlayState.interfaceName;
                if (!selectedInterface)
                    error = "There is no physical interface to test.";
                else
                    start();
            }

            Component.onDestruction: {
                pendingInterface = "";
                if (speedProc.running)
                    speedProc.signal(15);
            }

            Column {
                id: content
                width: speed.width
                spacing: 10

                Column {
                    visible: speed.devices.length > 0
                    width: parent.width
                    spacing: 7

                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: "TEST DEVICE"
                        font.family: Theme.fontMenu
                        font.pixelSize: Theme.typography.metadata
                        font.weight: Theme.weightSemibold
                        color: Theme.textDim
                    }

                    Row {
                        anchors.horizontalCenter: parent.horizontalCenter
                        spacing: 8

                        Repeater {
                            model: speed.devices

                            ModalButton {
                                required property var modelData
                                label: modelData.label
                                primary: speed.selectedInterface === modelData.interfaceName
                                onTriggered: speed.chooseInterface(modelData.interfaceName)
                            }
                        }
                    }
                }

                Text {
                    width: parent.width
                    text: speed.completed ? "Test complete"
                        : speed.canceled ? "Test canceled"
                        : speed.switching ? "Switching test device…"
                        : speed.phase === "upload" ? "Measuring upload…"
                        : speed.phase === "download" ? "Measuring download…"
                        : speed.error !== "" ? "Could not measure speed"
                        : "Finding the nearest test endpoint…"
                    horizontalAlignment: Text.AlignHCenter
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.secondary
                    color: Theme.textLow
                }

                Row {
                    width: parent.width
                    spacing: 12

                    SpeedDial {
                        width: (parent.width - parent.spacing) / 2
                        label: "Download"
                        value: speed.downloadMbps
                        active: speedProc.running && speed.phase === "download"
                    }

                    SpeedDial {
                        width: (parent.width - parent.spacing) / 2
                        label: "Upload"
                        value: speed.uploadMbps
                        active: speedProc.running && speed.phase === "upload"
                    }
                }

                Text {
                    visible: speed.error !== ""
                    width: parent.width
                    text: speed.error
                    wrapMode: Text.Wrap
                    horizontalAlignment: Text.AlignHCenter
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.secondary
                    color: Theme.red
                }

                Text {
                    width: parent.width
                    text: speed.selectedDevice ? speed.selectedDevice.detail
                        : speed.selectedInterface
                    horizontalAlignment: Text.AlignHCenter
                    font.family: Theme.fontMono
                    font.pixelSize: Theme.typography.secondary
                    color: Theme.textDim
                }

                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: 10

                    ModalButton {
                        label: speedProc.running ? "Cancel" : "Run Again"
                        primary: !speedProc.running
                        enabled: speedProc.running
                            || speed.selectedInterface !== ""
                        onTriggered: {
                            if (speedProc.running)
                                speed.cancel();
                            else
                                speed.start();
                        }
                    }

                    ModalButton {
                        label: "Close"
                        onTriggered: NetworkOverlayState.close()
                    }
                }
            }

            Process {
                id: speedProc
                property bool exitSeen: false
                property int lastExit: -1

                command: ["python3", root.speedHelper, "--interface",
                    speed.selectedInterface]
                stdout: SplitParser { onRead: line => speed.applyLine(line) }
                stderr: StdioCollector {}
                onExited: (exitCode, exitStatus) => {
                    speedProc.exitSeen = true;
                    speedProc.lastExit = exitCode;
                }
                onRunningChanged: {
                    if (running) {
                        exitSeen = false;
                        lastExit = -1;
                        return;
                    }
                    if (!NetworkOverlayState.open || NetworkOverlayState.page !== "speed")
                        return;
                    if (speed.pendingInterface !== "") {
                        speed.applyPendingInterface();
                        return;
                    }
                    speed.switching = false;
                    if (!speed.completed && !speed.canceled && speed.error === "")
                        speed.error = exitSeen && lastExit === 0
                            ? "The speed test ended without a result."
                            : "The speed test could not complete.";
                }
            }
        }
    }

    function parseOverlayResult(body, label) {
        try {
            const value = JSON.parse(body);
            if (value && typeof value === "object")
                return value;
        } catch (exception) {
            console.warn(label + " returned invalid JSON");
        }
        return { success: false, error: label + " returned unreadable output." };
    }
}
