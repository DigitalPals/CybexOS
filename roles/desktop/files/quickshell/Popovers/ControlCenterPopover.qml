pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import "../Common"

// Control Panel: the machine's three readings, the filled sliders, the two
// radio rows, one grid of quick toggles over a capture track, session
// controls and the shell-settings footer.
//
// The panel is ordered by what you open it for. CPU, RAM and temperature lead
// as three cards rather than a hairline strip at the foot, and brightness and
// volume — the two controls reached most often — sit above the radios.
//
// Three things this panel used to carry live elsewhere now. The battery
// reading belongs to its own menubar widget and BatteryPopover, which also
// owns the power profile; Tailscale keeps its detail view, reachable from
// `qs ipc call popouts toggle tailscale`, but no longer holds a cell here.
// What is left is one shape per idea: a card, a full-width row, a grid tile,
// a segmented track, separated by the SectionLabel the rest of the shell
// already draws.
//
// The Fedora button opens this dashboard; the four status widgets open their
// dedicated detail views directly.
Surface {
    id: root

    implicitWidth: availableWidth > 0
        ? Math.min(Theme.popWidth, availableWidth) : Theme.popWidth
    padding: Theme.surfacePadding
    spacing: Theme.panelSectionSpacing
    focus: visible

    Keys.onEscapePressed: event => {
        if (pendingSessionKey !== "") {
            clearSessionConfirmation();
            event.accepted = true;
        } else {
            Popouts.close();
        }
    }

    function moveFocus(item, forward) {
        const next = item.nextItemInFocusChain(forward);
        if (next)
            next.forceActiveFocus();
    }

    function focusInitial() {
        if (visible) {
            Qt.callLater(() => {
                const target = brightnessSlider.ready ? brightnessSlider : outputButton;
                target.forceActiveFocus();
            });
        }
    }

    Component.onCompleted: focusInitial()
    onVisibleChanged: {
        focusInitial();
        if (!visible && pendingSessionKey !== "")
            clearSessionConfirmation();
    }

    readonly property string binDir: Quickshell.env("HOME") + "/.local/bin/"
    readonly property var btConnected: BluetoothState.devices.filter(d => d.connected)

    readonly property real contentWidth: Math.max(0, root.width - 2 * root.padding)
    // Eight quick actions in one 4x2 grid. At this cell width every label
    // fits on one line; the old five-wide row gave each 73px, which elided
    // "Idle inhibit" and left the three capture chips as a second, narrower
    // geometry underneath.
    readonly property int tileSpacing: 8
    readonly property real tileWidth:
        Math.max(0, (contentWidth - 3 * tileSpacing) / 4)
    readonly property int tileHeight: 58
    // Between the 34px list row and the 48px panel tile: the icon lane plus
    // two lines of copy, which is what moves the status off the right edge.
    // A long SSID gets ~300px here against ~240px when it shared the row.
    readonly property int radioRowHeight: 44
    // The three machine readings, as cards across one row. The strip these
    // replace shared hairlines at the foot of the panel; a card carries the
    // same label, reading and meter where the panel opens.
    readonly property int cardSpacing: 8
    readonly property real cardWidth:
        Math.max(0, (contentWidth - 2 * cardSpacing) / 3)
    readonly property int cardHeight: 68
    readonly property int sessionSpacing: 6
    readonly property int sessionActionHeight: 52
    readonly property real sessionActionWidth:
        Math.max(0, (contentWidth - 4 * sessionSpacing) / 5)
    readonly property var sessionActions: [
        { key: "lock", glyph: "lock", label: "Lock" },
        { key: "suspend", glyph: "bedtime", label: "Suspend" },
        { key: "logout", glyph: "logout", label: "Log out" },
        { key: "restart", glyph: "restart_alt", label: "Restart" },
        { key: "shutdown", glyph: "power_settings_new", label: "Shut down" }
    ]
    property string pendingSessionKey: ""
    property string sessionAnnouncement: ""

    function sessionActionLabel(key) {
        switch (key) {
        case "logout": return "log out";
        case "reboot": return "restart";
        case "shutdown": return "shut down";
        default: return key;
        }
    }

    function clearSessionConfirmation() {
        sessionConfirmTimer.stop();
        pendingSessionKey = "";
        sessionAnnouncement = "Session action cancelled.";
    }

    function requestSession(key) {
        const guarded = ["logout", "reboot", "shutdown"].indexOf(key) !== -1;
        if (guarded && pendingSessionKey !== key) {
            pendingSessionKey = key;
            sessionAnnouncement = "Press " + sessionActionLabel(key)
                + " again within five seconds to confirm.";
            sessionConfirmTimer.restart();
            return;
        }
        sessionConfirmTimer.stop();
        pendingSessionKey = "";
        triggerSession(key);
    }

    // The stat cards are live only while this panel is on screen, so it says
    // so rather than the singletons guessing from Popouts. Keyed on
    // `visible`, not construction: this panel is latched.
    Claim {
        active: root.visible
        onClaimed: {
            SysInfo.acquire();
            EthernetState.acquire();
        }
        onReleased: {
            SysInfo.release();
            EthernetState.release();
        }
    }

    function run(cmd) {
        Quickshell.execDetached(["sh", "-c", cmd]);
        Popouts.close();
    }

    // The capture track's three actions. One-shot every one of them, so the
    // track never holds a selection the way the profile track it replaces did.
    function runCapture(key) {
        switch (key) {
        case "shot": root.run(root.binDir + "screenshot region"); break;
        case "ocr": root.run(root.binDir + "screen-ocr"); break;
        case "record":
            Recorder.toggle();
            Popouts.close();
            break;
        }
    }

    function triggerSession(key) {
        // Release the panel's focus grab before a command locks, suspends or
        // ends the session. Session owns the command and its final cleanup.
        Popouts.close();
        switch (key) {
        case "lock": Session.lock(); break;
        case "suspend": Session.suspend(); break;
        case "logout": Session.logout(); break;
        case "restart": Session.reboot(); break;
        case "shutdown": Session.shutdown(); break;
        }
    }

    Timer {
        id: sessionConfirmTimer
        interval: 5000
        onTriggered: root.clearSessionConfirmation()
    }

    // Radio row: mark, name, live status underneath, and the chevron into the
    // detail panel. Two lines because the status used to compete with the
    // title for right-aligned space in a 34px row.
    //
    // One activation, not two. The row used to separate left-click from
    // right-click and from a chevron hit area, and all three called
    // openPanel() with the same arguments — three targets for one outcome.
    component RadioRow: Rectangle {
        id: radio

        property string glyph: ""
        property string title
        property string sub
        property bool on: false
        signal activated

        width: parent ? parent.width : 0
        height: root.radioRowHeight
        radius: Theme.chipRadius
        color: radioMouse.containsMouse || activeFocus ? Theme.chip : "transparent"
        scale: radioMouse.pressed ? 0.99 : 1
        activeFocusOnTab: true
        border.width: activeFocus ? 1 : 0
        border.color: Theme.accentText

        Accessible.role: Accessible.Button
        Accessible.name: radio.title
        Accessible.description: radio.sub
        Accessible.onPressAction: radio.activated()

        Keys.onPressed: event => {
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                    || event.key === Qt.Key_Space) {
                radio.activated();
                event.accepted = true;
            } else if (event.key === Qt.Key_Right || event.key === Qt.Key_Down) {
                root.moveFocus(radio, true);
                event.accepted = true;
            } else if (event.key === Qt.Key_Left || event.key === Qt.Key_Up) {
                root.moveFocus(radio, false);
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
            id: radioMark
            x: 6
            anchors.verticalCenter: parent.verticalCenter
            width: 28
            height: 28

            Sym {
                anchors.centerIn: parent
                name: radio.glyph
                size: Theme.iconLarge
                fill: radio.on ? 1 : 0
                color: radio.on ? Theme.accentText : Theme.icon
            }
        }

        Column {
            anchors.left: radioMark.right
            anchors.leftMargin: 10
            anchors.right: radioChevron.left
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2

            Text {
                text: radio.title
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.control
                font.weight: Theme.weightMedium
                color: Theme.textHi
            }

            Text {
                width: parent.width
                text: radio.sub
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.secondary
                color: Theme.textDim
                elide: Text.ElideRight
            }
        }

        Item {
            id: radioChevron
            anchors.right: parent.right
            anchors.rightMargin: 4
            anchors.verticalCenter: parent.verticalCenter
            width: 28
            height: 28

            Sym {
                anchors.centerIn: parent
                name: "chevron_right"
                size: Theme.iconMedium
                symWeight: 450
                color: radioMouse.containsMouse ? Theme.textHi : Theme.textFaint
            }
        }

        MouseArea {
            id: radioMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                radio.forceActiveFocus();
                radio.activated();
            }
        }
    }

    // One quick toggle: its mark over its label, in a grid cell. The cell
    // lights on the full accent when the toggle is on, which is the
    // whole rule for reading this grid — and the reason the three capture
    // actions moved out of it, since a one-shot action never lights.
    component QuickTile: Rectangle {
        id: tile

        property string glyph: ""
        property string title
        // `on` is persisted intent. Process-backed toggles provide the
        // separately observed state so the tile never claims success merely
        // because the preference was written.
        property bool on: false
        property bool effective: on
        property bool pending: false
        property string error: ""
        property bool showStatus: false
        property string statusOverride: ""
        readonly property string statusLabel: statusOverride !== "" ? statusOverride
            : error !== "" ? "Error"
            : pending ? (on ? "Starting…" : "Stopping…")
            : effective ? "Active" : on ? "Not active" : "Off"
        readonly property string statusDescription: error !== "" ? error
            : title + " is " + statusLabel.toLowerCase()
        readonly property color mark: tile.effective
            ? Theme.accentFg
            : tileMouse.containsMouse || tile.activeFocus ? Theme.textHi : Theme.icon
        readonly property color copy: tile.effective ? Theme.accentFg
            : tileMouse.containsMouse || tile.activeFocus ? Theme.textMid : Theme.textFaint
        signal toggled

        width: root.tileWidth
        height: root.tileHeight
        radius: Theme.chipRadius
        color: tile.effective ? Theme.accent
            : tileMouse.containsMouse || activeFocus ? Theme.chipHover : Theme.chip
        scale: tileMouse.pressed ? 0.95 : 1
        activeFocusOnTab: true
        border.width: activeFocus || pending || error !== "" ? 1 : 0
        border.color: error !== "" ? Theme.red
            : pending ? Theme.amber : tile.effective ? Theme.accentFg : Theme.accent

        Accessible.role: Accessible.CheckBox
        Accessible.name: tile.title
        Accessible.description: tile.statusDescription
        Accessible.checked: tile.effective
        Accessible.onPressAction: tile.toggled()

        Keys.onPressed: event => {
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                    || event.key === Qt.Key_Space) {
                tile.toggled();
                event.accepted = true;
            } else if (event.key === Qt.Key_Right || event.key === Qt.Key_Down) {
                root.moveFocus(tile, true);
                event.accepted = true;
            } else if (event.key === Qt.Key_Left || event.key === Qt.Key_Up) {
                root.moveFocus(tile, false);
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

        Column {
            anchors.centerIn: parent
            spacing: tile.showStatus ? 2 : 7

            Item {
                anchors.horizontalCenter: parent.horizontalCenter
                width: Theme.iconLarge
                height: Theme.iconLarge

                Sym {
                    anchors.centerIn: parent
                    name: tile.glyph
                    size: Theme.iconLarge
                    fill: tile.effective ? 1 : 0
                    color: tile.mark
                }
            }

            Text {
                // 3px either side, not more: "Idle inhibit" is the longest
                // label and needs 80 of the cell's 88.
                width: Math.max(0, tile.width - 6)
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
                text: tile.title
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.control
                font.weight: Theme.weightMedium
                color: tile.copy
            }

            Text {
                visible: tile.showStatus
                width: Math.max(0, tile.width - 6)
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
                text: tile.statusLabel
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.secondary
                color: tile.error !== "" ? Theme.redText
                    : tile.pending ? Theme.amber : tile.copy
                Accessible.role: Accessible.StaticText
                Accessible.name: tile.statusDescription
            }
        }

        MouseArea {
            id: tileMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                tile.forceActiveFocus();
                tile.toggled();
            }
        }
    }

    // One of the five equal session controls. They share the same neutral chip
    // ladder; the action label carries the distinction without a danger fill.
    component SessionAction: Rectangle {
        id: action

        property string glyph: ""
        property string label: ""
        property string actionKey: ""
        readonly property bool armed: root.pendingSessionKey === actionKey
        readonly property string visibleLabel: armed ? "Confirm" : label
        signal triggered

        width: root.sessionActionWidth
        height: root.sessionActionHeight
        radius: Theme.chipRadius
        color: armed ? Theme.amberBg
            : actionMouse.containsMouse ? Theme.chipHover : Theme.chip
        border.width: activeFocus || armed ? 1 : 0
        border.color: armed ? Theme.amber : Theme.accentText
        scale: actionMouse.pressed ? 0.95 : 1
        activeFocusOnTab: true

        Accessible.role: Accessible.Button
        Accessible.name: armed ? "Confirm " + root.sessionActionLabel(actionKey) : label
        Accessible.description: armed ? "This action ends the current session state." : ""
        Accessible.onPressAction: action.triggered()

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

        Keys.onPressed: event => {
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                    || event.key === Qt.Key_Space) {
                action.triggered();
                event.accepted = true;
            } else if (event.key === Qt.Key_Right || event.key === Qt.Key_Down) {
                root.moveFocus(action, true);
                event.accepted = true;
            } else if (event.key === Qt.Key_Left || event.key === Qt.Key_Up) {
                root.moveFocus(action, false);
                event.accepted = true;
            }
        }

        Column {
            anchors.centerIn: parent
            spacing: 4

            Sym {
                anchors.horizontalCenter: parent.horizontalCenter
                name: action.glyph
                size: Theme.iconMedium
                fill: 0
                color: action.armed ? Theme.amber : Theme.icon
            }

            Text {
                width: action.width - 4
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
                text: action.visibleLabel
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.control
                font.weight: Theme.weightMedium
                color: action.armed ? Theme.amber : Theme.textLow
            }
        }

        MouseArea {
            id: actionMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                action.forceActiveFocus();
                action.triggered();
            }
        }
    }

    // One machine reading as a card: the label, the reading on its own line
    // beneath it, and the meter along the bottom. The strip this replaces put
    // three columns behind shared hairlines in a 34px band at the foot of the
    // panel, where a number you opened the panel to read was the last thing
    // you reached.
    component StatCard: Rectangle {
        id: card

        property string label
        property string display
        property real fraction: 0
        property color tone: Theme.textHi
        property color barTone: Theme.accent

        width: root.cardWidth
        height: root.cardHeight
        radius: Theme.chipRadius
        color: Theme.chip

        Accessible.role: Accessible.ProgressBar
        Accessible.name: card.label
        Accessible.description: card.display

        Text {
            id: cardLabel
            x: 10
            y: 9
            text: card.label
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.section
            font.weight: Theme.weightSemibold
            font.letterSpacing: 1
            color: Theme.textFaint
        }

        Text {
            anchors.left: cardLabel.left
            anchors.top: cardLabel.bottom
            anchors.topMargin: 1
            text: card.display
            font.family: Theme.fontMono
            font.pixelSize: Theme.typography.title
            font.weight: Theme.weightSemibold
            font.features: Theme.tabularNumberFeatures
            color: card.tone
        }

        BlockMeter {
            anchors.left: parent.left
            anchors.leftMargin: 10
            anchors.right: parent.right
            anchors.rightMargin: 10
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 9
            height: 6
            blockWidth: 3
            gap: 2
            value: card.fraction
            fillColor: card.barTone
        }
    }

    // ---- Machine ---------------------------------------------------------
    // What the panel opens on. Three readings across one row, each carrying
    // its own label, value and meter.
    Column {
        width: parent.width
        spacing: 0

        SectionLabel {
            text: "MACHINE"
        }

        Row {
            width: parent.width
            spacing: root.cardSpacing

            StatCard {
                label: "CPU"
                display: Math.round(SysInfo.cpuUsage) + "%"
                fraction: SysInfo.cpuUsage / 100
            }

            StatCard {
                label: "RAM"
                display: Math.round(SysInfo.memUsage) + "%"
                fraction: SysInfo.memUsage / 100
            }

            StatCard {
                label: "TEMP"
                display: SysInfo.cpuTemp + "\u00b0"
                fraction: SysInfo.cpuTemp / 100
                tone: SysInfo.cpuTemp >= 80 ? Theme.redText
                    : SysInfo.cpuTemp >= 65 ? Theme.amber : Theme.textHi
                barTone: SysInfo.cpuTemp >= 80 ? Theme.red
                    : SysInfo.cpuTemp >= 65 ? Theme.amber : Theme.accent
            }
        }
    }

    // ---- Brightness / volume ---------------------------------------------
    Column {
        width: parent.width
        spacing: 0

        SectionLabel {
            text: "DISPLAY & SOUND"
        }

        Column {
            width: parent.width
            spacing: 6

            FillSlider {
                id: brightnessSlider
                width: parent.width
                glyph: "sunny"
                accessibleName: "Brightness"
                value: Math.max(0, SysInfo.brightness) / 100
                ready: SysInfo.brightness >= 0
                label: (SysInfo.brightness >= 0 ? SysInfo.brightness : "--") + "%"
                onMoved: v => SysInfo.setBrightness(v * 100)
            }

            Row {
                width: parent.width
                spacing: 8

                FillSlider {
                    width: parent.width - outputButton.width - parent.spacing
                    glyph: Audio.muted || Audio.level === 0 ? "volume_off"
                        : Audio.level < 0.5 ? "volume_down" : "volume_up"
                    glyphIsButton: true
                    glyphAccessibleName: Audio.muted ? "Unmute volume" : "Mute volume"
                    accessibleName: "Volume"
                    value: Audio.muted ? 0 : Audio.level
                    ready: Audio.ready
                    label: Math.round((Audio.muted ? 0 : Audio.level) * 100) + "%"
                    onMoved: v => {
                        if (Audio.muted)
                            Audio.toggleMuted();
                        Audio.setVolume(v);
                    }
                    onGlyphClicked: Audio.toggleMuted()
                }

                // Squared off against the slider it sits beside; it used to be
                // a 26px chip top-aligned against a 34px track.
                Rectangle {
                    id: outputButton

                    width: Theme.listRowHeight
                    height: Theme.listRowHeight
                    radius: Theme.chipRadius
                    color: outputMouse.containsMouse || activeFocus ? Theme.chipHover : Theme.chip
                    activeFocusOnTab: true
                    Accessible.role: Accessible.Button
                    Accessible.name: "Choose audio output"
                    Accessible.description: Audio.outputName
                    Accessible.onPressAction: Popouts.openPanel("audio", "right")
                    border.width: activeFocus ? 1 : 0
                    border.color: Theme.accentText

                    Behavior on color {
                        ColorAnimation { duration: Theme.chipFadeDuration }
                    }

                    Keys.onPressed: event => {
                        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                                || event.key === Qt.Key_Space) {
                            Popouts.openPanel("audio", "right");
                            event.accepted = true;
                        }
                    }

                    Sym {
                        anchors.centerIn: parent
                        name: "chevron_right"
                        size: Theme.iconMedium
                        color: Theme.icon
                    }

                    MouseArea {
                        id: outputMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            outputButton.forceActiveFocus();
                            Popouts.openPanel("audio", "right");
                        }
                    }
                }
            }
        }
    }

    // ---- Radios ----------------------------------------------------------
    Column {
        width: parent.width
        spacing: 0

        SectionLabel {
            text: "CONNECTIVITY"
        }

        Column {
            width: parent.width
            spacing: Theme.panelRowSpacing

            RadioRow {
                glyph: EthernetState.connected ? "lan"
                    : WifiState.enabled ? "wifi" : "wifi_off"
                title: "Internet"
                sub: EthernetState.connected && WifiState.connected ? "Ethernet + Wi-Fi"
                    : EthernetState.connected ? "Ethernet"
                    : WifiState.connected ? WifiState.name
                    : WifiState.enabled ? "No connection" : "Offline"
                on: EthernetState.connected || WifiState.connected
                onActivated: Popouts.openPanel("wifi", "right")
            }

            RadioRow {
                glyph: "bluetooth"
                title: "Bluetooth"
                sub: {
                    if (!BluetoothState.enabled)
                        return "Off";
                    if (root.btConnected.length === 0)
                        return "On";
                    return root.btConnected[0].deviceName
                        + (root.btConnected.length > 1 ? " +" + (root.btConnected.length - 1) : "");
                }
                on: BluetoothState.enabled
                onActivated: Popouts.openPanel("bluetooth", "right")
            }
        }
    }

    // ---- Quick actions ---------------------------------------------------
    // Four toggles in one row, and the three capture actions as a segmented
    // track beneath them. All seven shared an eight-cell grid until Tailscale
    // left it — but a grid whose reading rule is "state lights the cell" was
    // always the wrong home for three actions that can never light, and the
    // hole Tailscale left is what made that worth fixing.
    Column {
        width: parent.width
        spacing: 0

        SectionLabel {
            text: "QUICK ACTIONS"
        }

        Column {
            width: parent.width
            spacing: 8

            Grid {
                width: parent.width
                columns: 4
                spacing: root.tileSpacing

                QuickTile {
                    glyph: "dark_mode"
                    title: "Dark mode"
                    on: Theme.dark
                    onToggled: Settings.set("themeMode", Theme.dark ? "light" : "dark")
                }

                QuickTile {
                    glyph: "do_not_disturb_on"
                    title: "Focus"
                    on: Notifs.dnd
                    onToggled: Notifs.setDnd(!Notifs.dnd)
                }

                QuickTile {
                    glyph: "nightlight"
                    title: "Night light"
                    on: SysInfo.nightLight
                    effective: SysInfo.nightLightEffective
                    pending: SysInfo.nightLightPending
                    error: SysInfo.nightLightError
                    showStatus: true
                    onToggled: SysInfo.toggleNightLight()
                }

                QuickTile {
                    glyph: "coffee"
                    title: "Idle inhibit"
                    on: SysInfo.idleInhibited
                    effective: SysInfo.idleInhibitEffective
                    pending: SysInfo.idleInhibitPending
                    error: SysInfo.idleInhibitError
                    showStatus: true
                    statusOverride: SysInfo.idleInhibitStatus
                    onToggled: SysInfo.toggleIdleInhibited()
                }
            }

            Text {
                visible: SysInfo.nightLightError !== ""
                    || SysInfo.idleInhibitError !== ""
                width: parent.width
                text: (SysInfo.nightLightError !== ""
                        ? "Night light: " + SysInfo.nightLightError : "")
                    + (SysInfo.nightLightError !== "" && SysInfo.idleInhibitError !== ""
                        ? "\n" : "")
                    + (SysInfo.idleInhibitError !== ""
                        ? "Idle inhibit: " + SysInfo.idleInhibitError : "")
                wrapMode: Text.WordWrap
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.secondary
                color: Theme.redText
                Accessible.role: Accessible.StaticText
                Accessible.name: text
            }

            // One control, equal segments, a 3px inset — the shape the power
            // profile used to draw in this panel, now that the profile itself
            // lives in BatteryPopover. Nothing is ever selected here.
            Rectangle {
                width: parent.width
                height: Theme.listRowHeight
                radius: Theme.chipRadius
                color: Theme.chip

                Row {
                    id: captureRow
                    anchors.fill: parent
                    anchors.margins: 3
                    spacing: 4

                    Repeater {
                        model: [
                            { key: "shot", glyph: "photo_camera", label: "Screenshot" },
                            { key: "record", glyph: "", label: "" },
                            { key: "ocr", glyph: "document_scanner", label: "OCR" }
                        ]

                        delegate: Rectangle {
                            id: capture

                            required property var modelData
                            readonly property bool isRecord: capture.modelData.key === "record"
                            readonly property bool recording: capture.isRecord && Recorder.active
                            readonly property string glyph: capture.isRecord
                                ? (Recorder.active ? "stop_circle" : "radio_button_checked")
                                : capture.modelData.glyph
                            readonly property string label: capture.isRecord
                                ? (Recorder.active ? "Stop" : "Record")
                                : capture.modelData.label
                            readonly property color copy: capture.recording ? Theme.redText
                                : captureMouse.containsMouse ? Theme.textHi : Theme.textLow
                            // A running capture owns the red field. At rest the
                            // record dot stays red where the other two marks
                            // take the panel's normal copy tone.
                            readonly property color mark: capture.recording ? Theme.redText
                                : capture.isRecord ? Theme.red : capture.copy

                            width: (captureRow.width - captureRow.spacing * 2) / 3
                            height: captureRow.height
                            radius: Theme.chipRadius - 2
                            color: capture.recording ? Theme.redBg
                                : captureMouse.containsMouse || activeFocus ? Theme.tile : "transparent"
                            activeFocusOnTab: true
                            border.width: activeFocus ? 1 : 0
                            border.color: Theme.accentText

                            Accessible.role: Accessible.Button
                            Accessible.name: capture.label
                            Accessible.onPressAction: root.runCapture(capture.modelData.key)

                            Keys.onPressed: event => {
                                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                                        || event.key === Qt.Key_Space) {
                                    root.runCapture(capture.modelData.key);
                                    event.accepted = true;
                                } else if (event.key === Qt.Key_Right || event.key === Qt.Key_Down) {
                                    root.moveFocus(capture, true);
                                    event.accepted = true;
                                } else if (event.key === Qt.Key_Left || event.key === Qt.Key_Up) {
                                    root.moveFocus(capture, false);
                                    event.accepted = true;
                                }
                            }

                            Behavior on color {
                                ColorAnimation { duration: Theme.chipFadeDuration }
                            }

                            Row {
                                anchors.centerIn: parent
                                spacing: 6

                                Sym {
                                    anchors.verticalCenter: parent.verticalCenter
                                    name: capture.glyph
                                    size: Theme.iconSmall + 2
                                    fill: capture.recording ? 1 : 0
                                    color: capture.mark
                                }

                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: capture.label
                                    font.family: Theme.fontMenu
                                    font.pixelSize: Theme.typography.control
                                    font.weight: Theme.weightMedium
                                    font.letterSpacing: 0.2
                                    color: capture.copy
                                }
                            }

                            MouseArea {
                                id: captureMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    capture.forceActiveFocus();
                                    root.runCapture(capture.modelData.key);
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // ---- Session ---------------------------------------------------------
    Column {
        width: parent.width
        spacing: 0

        SectionLabel {
            text: "SESSION"
        }

        Row {
            width: parent.width
            spacing: root.sessionSpacing

            Repeater {
                model: root.sessionActions

                delegate: SessionAction {
                    required property var modelData

                    glyph: modelData.glyph
                    label: modelData.label
                    actionKey: modelData.key
                    onTriggered: root.requestSession(modelData.key)
                }
            }
        }

        Text {
            visible: root.sessionAnnouncement !== ""
            width: parent.width
            topPadding: 6
            text: root.sessionAnnouncement
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.secondary
            color: root.pendingSessionKey !== "" ? Theme.amber : Theme.textDim
            Accessible.role: Accessible.AlertMessage
            Accessible.name: text
        }
    }

    // ---- Footer ----------------------------------------------------------
    // The two actions bookend the panel instead of crowding its left corner.
    Item {
        width: parent.width
        height: Theme.chipHeight

        Rectangle {
            id: settingsButton
            anchors.top: parent.top
            width: settingsLabel.x + settingsLabel.implicitWidth + 9
            height: Theme.chipHeight
            radius: Theme.chipRadius
            color: settingsMouse.containsMouse || activeFocus ? Theme.chip : "transparent"
            activeFocusOnTab: true
            border.width: activeFocus ? 1 : 0
            border.color: Theme.accentText
            Accessible.role: Accessible.Button
            Accessible.name: "Open shell settings"
            Accessible.onPressAction: Settings.showPanel()

            Keys.onPressed: event => {
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                        || event.key === Qt.Key_Space) {
                    Settings.showPanel();
                    event.accepted = true;
                }
            }

            Behavior on color {
                ColorAnimation { duration: Theme.chipFadeDuration }
            }

            Sym {
                id: settingsMark
                x: 7
                anchors.verticalCenter: parent.verticalCenter
                name: "settings"
                size: Theme.iconSmall
                symWeight: 450
                color: settingsMouse.containsMouse ? Theme.textHi : Theme.icon
            }

            Text {
                id: settingsLabel
                anchors.left: settingsMark.right
                anchors.leftMargin: 7
                anchors.verticalCenter: parent.verticalCenter
                text: "Settings"
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.control
                font.weight: Theme.weightMedium
                color: settingsMouse.containsMouse ? Theme.textHi : Theme.textLow
            }

            MouseArea {
                id: settingsMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    settingsButton.forceActiveFocus();
                    Settings.showPanel();
                }
            }
        }

        Rectangle {
            id: shortcutsButton
            anchors.right: parent.right
            width: Theme.chipHeight
            height: Theme.chipHeight
            radius: Theme.chipRadius
            color: keysMouse.containsMouse || activeFocus ? Theme.chip : "transparent"
            activeFocusOnTab: true
            border.width: activeFocus ? 1 : 0
            border.color: Theme.accentText

            Accessible.role: Accessible.Button
            Accessible.name: "Keyboard shortcuts"
            Accessible.onPressAction: Session.openKeys()

            Keys.onPressed: event => {
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                        || event.key === Qt.Key_Space) {
                    Session.openKeys();
                    event.accepted = true;
                }
            }

            Behavior on color {
                ColorAnimation { duration: Theme.chipFadeDuration }
            }

            Sym {
                anchors.centerIn: parent
                name: "keyboard"
                size: Theme.iconSmall
                color: keysMouse.containsMouse ? Theme.textHi : Theme.icon
            }

            MouseArea {
                id: keysMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    shortcutsButton.forceActiveFocus();
                    Session.openKeys();
                }
            }
        }
    }
}
