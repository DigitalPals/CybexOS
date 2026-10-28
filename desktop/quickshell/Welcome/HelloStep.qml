pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import "../Common"

// Hello, in the installer's welcome-screen composition: the kicker, the
// headline and the lead on the left with what comes next, and a card on the
// right listing what the installer already set, read from the live backends,
// so nothing is asked twice. Change opens an installer-style sheet, or steps
// aside to Settings for the network.
Item {
    id: root
    readonly property var region: SystemSettings.region.snapshot
    readonly property var layouts: (SystemSettings.input.snapshot.keyboard || {}).layouts || []
    readonly property var catalog: SystemSettings.input.snapshot.catalog || []
    readonly property var ethernet: EthernetState.connectedDevices.length > 0 ? EthernetState.connectedDevices[0] : null
    readonly property bool online: EthernetState.connected || WifiState.connected || NetworkStatus.online
    property string hostName: ""
    // xkb's own descriptions ("English (US)"); a layout missing from the
    // catalog keeps its code.
    function layoutName(entry) {
        const layout = root.catalog.find(choice => choice.value === entry.layout);
        const variant = layout && entry.variant ? (layout.variants || []).find(choice => choice.value === entry.variant) : null;
        return variant ? variant.label : layout ? layout.label : entry.layout + (entry.variant ? " · " + entry.variant : "");
    }
    function city(zone) { return String(zone || "").split("/").pop().replace(/_/g, " "); }
    readonly property var rows: [
        {label: I18n.tr("Language"), value: region.locale ? I18n.localeName(region.locale) : I18n.tr("Not available"),
            detail: region.locale || "", sheet: "language"},
        {label: I18n.tr("Keyboard"), value: layouts.map(entry => root.layoutName(entry)).join(", ") || I18n.tr("Not available"),
            detail: layouts.map(entry => entry.layout + (entry.variant ? " · " + entry.variant : "")).join(", "), sheet: "keyboard"},
        {label: I18n.tr("Time zone"), value: region.timezone ? root.city(region.timezone) + " · " + Qt.formatTime(clock.date, "HH:mm") : I18n.tr("Not available"),
            detail: region.timezone || "", sheet: "timezone"},
        {label: I18n.tr("Network"), value: EthernetState.connected ? I18n.tr("Ethernet · connected")
                : WifiState.connected ? I18n.format("%1 · connected", [WifiState.name]) : online ? I18n.tr("Connected") : I18n.tr("Not connected"),
            detail: ethernet ? [ethernet.device, ethernet.ipv4].filter(Boolean).join(" · ") : online ? "" : I18n.tr("You can explore offline, too."),
            settings: "network", warn: !online},
        {label: I18n.tr("Account"), value: Welcome.fullName !== "" ? Welcome.fullName + " · " + Welcome.userName : Welcome.userName,
            detail: Quickshell.env("HOME") || "", mono: Welcome.fullName === ""},
        {label: I18n.tr("Computer"), value: root.hostName || I18n.tr("Not available"),
            detail: I18n.format("Cybex OS %1", [Welcome.version]), mono: true}
    ]
    Claim { active: root.visible; onClaimed: EthernetState.acquire(); onReleased: EthernetState.release() }
    SystemClock { id: clock; precision: SystemClock.Minutes; enabled: root.visible }
    FileView {
        path: "/etc/hostname"
        printErrors: false
        blockLoading: true
        onLoaded: root.hostName = text().trim()
    }

    Column {
        x: Kiosk.px(64)
        y: Kiosk.px(60)
        width: Kiosk.px(618)
        KioskKicker {
            width: parent.width
            text: I18n.format("Welcome guide · Cybex OS %1", [Welcome.version])
            tone: "accent"
            elide: Text.ElideRight
        }
        Item { width: 1; height: Kiosk.px(14) }
        KioskText {
            width: parent.width
            text: I18n.format("Welcome home,\n%1.", [Welcome.firstName])
            size: 50
            font.weight: Font.Bold
            font.letterSpacing: -Kiosk.px(1.2)
            // The installer's 1.04 line height, on the face's em rather
            // than its tall default line spacing.
            lineHeightMode: Text.FixedHeight
            lineHeight: Kiosk.px(52)
            wrapMode: Text.WordWrap
            Accessible.role: Accessible.Heading
        }
        Item { width: 1; height: Kiosk.px(14) }
        KioskText {
            width: parent.width
            text: I18n.tr("A few quick steps make this desktop yours. Each choice applies the moment you pick it.")
            size: 19
            tone: "fog"
            wrapMode: Text.WordWrap
        }
        Item { width: 1; height: Kiosk.px(24) }
        Repeater {
            model: (Welcome.connectAvailable ? [[I18n.tr("Connect"), Welcome.passwordAvailable && Assistant.available
                    ? I18n.tr("1Password and your AI assistant") : Assistant.available ? I18n.tr("your AI assistant")
                    : I18n.tr("1Password, if you use it")]] : [])
                .concat([[I18n.tr("Wallpaper"), I18n.tr("from Wallhaven, our collection or your pictures")],
                [I18n.tr("Style"), I18n.tr("light or dark, colours and text size")],
                [I18n.tr("Shortcuts"), I18n.tr("the keys that make Cybex OS fast")]])
            delegate: Row {
                id: next
                required property var modelData
                required property int index
                width: parent.width
                height: Kiosk.px(42)
                spacing: Kiosk.px(14)
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: Kiosk.px(26)
                    height: width
                    radius: width / 2
                    color: Kiosk.accentTint
                    KioskText {
                        anchors.centerIn: parent
                        text: String(next.index + 1)
                        mono: true
                        size: 13
                        font.weight: Font.DemiBold
                        tone: "accent"
                    }
                }
                KioskText {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - Kiosk.px(40)
                    elide: Text.ElideRight
                    textFormat: Text.StyledText
                    // The step name, then its gist in the lead colour.
                    text: next.modelData[0] + " <font color=\"" + Kiosk.fog + "\">· "
                        + next.modelData[1].replace(/&/g, "&amp;").replace(/</g, "&lt;") + "</font>" // i18n: untranslated (markup)
                    size: 17
                    Accessible.name: next.modelData[0] + ": " + next.modelData[1]
                }
            }
        }
        Item { width: 1; height: Kiosk.px(28) }
        Row {
            spacing: Kiosk.px(14)
            KioskButton {
                kind: "primary"
                text: I18n.tr("Get started")
                icon: "chevron_right"
                iconRight: true
                onClicked: Welcome.move(1)
            }
            KioskButton {
                text: I18n.tr("Not now")
                onClicked: Welcome.dismiss()
            }
        }
        Item { width: 1; height: Kiosk.px(18) }
        KioskText {
            width: parent.width
            text: I18n.tr("About 5 minutes. Everything here is also in Settings.")
            size: 14
            tone: "faint"
            wrapMode: Text.WordWrap
        }
    }

    KioskCard {
        x: Kiosk.px(746)
        y: Kiosk.px(60)
        width: Kiosk.px(470)
        height: card.implicitHeight
        Column {
            id: card
            x: Kiosk.px(24)
            width: parent.width - Kiosk.px(48)
            Item {
                width: parent.width
                height: Kiosk.px(50)
                KioskKicker {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.verticalCenterOffset: Kiosk.px(4)
                    text: I18n.tr("Set during installation")
                }
                KioskText {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.verticalCenterOffset: Kiosk.px(4)
                    text: I18n.tr("nothing to redo")
                    mono: true
                    size: 12
                    tone: "faint"
                }
            }
            Repeater {
                model: root.rows
                delegate: Item {
                    id: row
                    required property var modelData
                    width: card.width
                    height: Math.max(Kiosk.px(64), values.implicitHeight + Kiosk.px(26))
                    Rectangle { width: parent.width; height: Math.max(1, Kiosk.px(1)); color: Kiosk.line }
                    Rectangle {
                        id: mark
                        anchors.verticalCenter: parent.verticalCenter
                        width: Kiosk.px(24)
                        height: width
                        radius: width / 2
                        color: row.modelData.warn ? Kiosk.amberTint : Kiosk.accentTint
                        KioskIcon {
                            anchors.centerIn: parent
                            name: row.modelData.warn ? "wifi_off" : "check"
                            designSize: 14
                            color: row.modelData.warn ? Kiosk.amber : Kiosk.accent
                        }
                    }
                    KioskText {
                        id: label
                        x: mark.width + Kiosk.px(14)
                        width: Kiosk.px(100)
                        anchors.verticalCenter: parent.verticalCenter
                        text: row.modelData.label
                        size: 15
                        tone: "fog"
                        elide: Text.ElideRight
                    }
                    Column {
                        id: values
                        anchors.left: label.right
                        anchors.leftMargin: Kiosk.px(14)
                        anchors.right: change.visible ? change.left : parent.right
                        anchors.rightMargin: change.visible ? Kiosk.px(12) : 0
                        anchors.verticalCenter: parent.verticalCenter
                        KioskText {
                            width: parent.width
                            text: row.modelData.value
                            size: 15
                            elide: Text.ElideRight
                        }
                        KioskText {
                            width: parent.width
                            visible: text !== ""
                            text: row.modelData.detail
                            size: 13
                            mono: !!row.modelData.mono
                            tone: "faint"
                            elide: Text.ElideRight
                        }
                    }
                    KioskLink {
                        id: change
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        visible: !!row.modelData.sheet || !!row.modelData.settings
                        text: row.modelData.warn ? I18n.tr("Connect") : I18n.tr("Change")
                        Accessible.name: I18n.format("Change %1", [row.modelData.label])
                        onClicked: {
                            if (row.modelData.sheet) {
                                Welcome.openSheet(row.modelData.sheet);
                            } else {
                                Welcome.stepAside(false);
                                Settings.showPanel(row.modelData.settings);
                            }
                        }
                    }
                }
            }
            Item {
                width: parent.width
                height: Kiosk.px(50)
                Rectangle { width: parent.width; height: Math.max(1, Kiosk.px(1)); color: Kiosk.line }
                KioskText {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width
                    text: I18n.tr("Change any of these now, or later in Settings.")
                    size: 13
                    tone: "faint"
                    elide: Text.ElideRight
                }
            }
        }
    }
}
