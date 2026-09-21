pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import "../../Common"
import "../../Common/BatteryViewHelpers.js" as BatteryView

// The drawer's Power tab: the charge reading and its meter, the power
// profile, battery preservation and stay-awake.
Column {
    id: root

    readonly property var displayDevice: Battery.device
    readonly property int level: Math.round(Battery.percent)
    readonly property bool discharging: !Battery.pluggedIn
    readonly property bool critical: discharging
        && level <= Settings.modOpts.batt.critAt
    readonly property bool warning: discharging
        && level <= Settings.modOpts.batt.warnAt
    readonly property color levelColor: critical ? Theme.red
        : warning ? Theme.amber : Theme.accent
    readonly property real estimateSeconds: !displayDevice ? 0
        : Battery.charging ? displayDevice.timeToFull
        : discharging ? displayDevice.timeToEmpty : 0
    readonly property string statusLine: {
        const parts = [Battery.full ? "Fully charged"
            : Battery.charging ? "Charging" : "On battery"];
        if (estimateSeconds > 0)
            parts.push(BatteryView.formatDuration(estimateSeconds));
        if (displayDevice && displayDevice.changeRate > 0)
            parts.push(BatteryView.formatW(displayDevice.changeRate));
        return parts.join(" · ");
    }

    property string cycleCountText: BatteryView.MISSING

    width: parent ? parent.width : 0
    spacing: Theme.scaled(14)

    Claim {
        active: root.visible
        onClaimed: {
            BatteryHealth.acquire();
            cycleCountProcess.running = true;
        }
        onReleased: BatteryHealth.release()
    }

    // cycle_count is not exposed by UPower; read the packs directly, the way
    // the old battery popover did.
    Process {
        id: cycleCountProcess
        command: ["sh", "-c",
            "printf '%s\\n' /sys/class/power_supply/BAT*/cycle_count | LC_ALL=C sort | while IFS= read -r file; do [ -e \"$file\" ] || continue; value=; IFS= read -r value < \"$file\"; printf '%s\\n' \"$value\"; done"]
        stdout: StdioCollector {
            onStreamFinished: root.cycleCountText = BatteryView.parseCycleCounts(text)
        }
    }

    // ---- charge ----------------------------------------------------------
    Item {
        width: parent.width
        height: 56

        Column {
            anchors.left: parent.left
            anchors.leftMargin: 4
            anchors.right: heroGlyph.left
            anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            spacing: 5

            Row {
                spacing: 2

                Text {
                    text: Battery.isLaptop ? String(root.level) : "--"
                    font.family: Theme.fontNumeric
                    font.pixelSize: Theme.typography.displayLarge
                    font.weight: Theme.weightSemibold
                    font.letterSpacing: -1.5
                    font.features: Theme.tabularNumberFeatures
                    color: Theme.textHi
                }

                Text {
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: 5
                    text: "%"
                    font.family: Theme.fontNumeric
                    font.pixelSize: Theme.typography.subtitle
                    color: Theme.textFaint
                }
            }

            Text {
                text: root.statusLine
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.secondary
                color: Theme.textFaint
            }
        }

        Sym {
            id: heroGlyph
            anchors.right: parent.right
            anchors.rightMargin: 6
            anchors.verticalCenter: parent.verticalCenter
            name: Battery.charging ? "battery_charging_full"
                : root.critical ? "battery_alert"
                : root.level >= 95 ? "battery_full"
                : root.level >= 80 ? "battery_6_bar"
                : root.level >= 65 ? "battery_5_bar"
                : root.level >= 50 ? "battery_4_bar"
                : root.level >= 35 ? "battery_3_bar"
                : root.level >= 20 ? "battery_2_bar" : "battery_1_bar"
            size: 30
            fill: 1
            rotation: 90
            color: Theme.textMid
        }
    }

    Rectangle {
        width: parent.width - 8
        x: 4
        height: 8
        radius: 4
        color: Qt.rgba(1, 1, 1, 0.10)

        Rectangle {
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: parent.width * Math.max(0, Math.min(100, root.level)) / 100
            radius: 4
            color: root.levelColor
        }
    }

    // ---- power profile ---------------------------------------------------
    Rectangle {
        width: parent.width
        height: 38
        radius: 10
        color: Theme.chip

        Row {
            anchors.fill: parent
            anchors.margins: 3
            spacing: 3

            Repeater {
                model: PowerProfiles.hasPerformanceProfile
                    ? [
                        { profile: PowerProfile.PowerSaver, glyph: "eco", label: "Saver" },
                        { profile: PowerProfile.Balanced, glyph: "balance", label: "Balanced" },
                        { profile: PowerProfile.Performance, glyph: "speed", label: "Perf" }
                    ]
                    : [
                        { profile: PowerProfile.PowerSaver, glyph: "eco", label: "Saver" },
                        { profile: PowerProfile.Balanced, glyph: "balance", label: "Balanced" }
                    ]

                delegate: Rectangle {
                    id: profileChoice

                    required property var modelData
                    readonly property bool on:
                        PowerProfiles.profile === modelData.profile

                    width: (parent.width - 3 * 2) / (PowerProfiles.hasPerformanceProfile ? 3 : 2)
                    height: parent.height
                    radius: 8
                    color: on ? Theme.chipHover : "transparent"

                    Behavior on color {
                        ColorAnimation { duration: Theme.chipFadeDuration }
                    }

                    Row {
                        anchors.centerIn: parent
                        spacing: 6

                        Sym {
                            anchors.verticalCenter: parent.verticalCenter
                            name: profileChoice.modelData.glyph
                            size: 16
                            fill: profileChoice.on ? 1 : 0
                            color: profileChoice.on ? Theme.textHi : Theme.textFaint
                        }

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: profileChoice.modelData.label
                            font.family: Theme.fontMenu
                            font.pixelSize: Theme.typography.secondary
                            font.weight: profileChoice.on
                                ? Theme.weightSemibold : Theme.weightMedium
                            color: profileChoice.on ? Theme.textHi : Theme.textFaint
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: PowerProfiles.profile = profileChoice.modelData.profile
                    }

                    Accessible.role: Accessible.RadioButton
                    Accessible.checked: profileChoice.on
                    Accessible.name: profileChoice.modelData.label + " power profile"
                }
            }
        }
    }

    // ---- switches --------------------------------------------------------
    Column {
        width: parent.width
        spacing: 2

        Item {
            visible: BatteryHealth.supported || !BatteryHealth.known
            width: parent.width
            height: 40

            Sym {
                id: healthMark
                anchors.left: parent.left
                anchors.leftMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                name: "battery_saver"
                size: 18
                fill: BatteryHealth.enabled ? 1 : 0
                color: BatteryHealth.enabled ? Theme.accent : Theme.textMid
            }

            Column {
                anchors.left: healthMark.right
                anchors.leftMargin: 12
                anchors.right: healthToggle.left
                anchors.rightMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                spacing: 1

                Text {
                    width: parent.width
                    text: "Preserve battery health"
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.control
                    font.weight: Theme.weightMedium
                    color: Theme.textHi
                    elide: Text.ElideRight
                }

                Text {
                    width: parent.width
                    text: {
                        const parts = [];
                        if (BatteryHealth.error !== "")
                            parts.push(BatteryHealth.error);
                        else
                            parts.push(BatteryHealth.enabled
                                ? BatteryHealth.limitText : "Charge to 100%");
                        if (root.cycleCountText !== BatteryView.MISSING)
                            parts.push(root.cycleCountText + " cycles");
                        return parts.join(" · ");
                    }
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.metadata
                    color: BatteryHealth.error !== ""
                        ? Theme.redText : Theme.textFaint
                    elide: Text.ElideRight
                }
            }

            Toggle {
                id: healthToggle
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                metrics: Theme.switchCompact
                checked: BatteryHealth.enabled
                enabled: BatteryHealth.known && BatteryHealth.supported
                    && !BatteryHealth.busy
                accessibleName: "Preserve battery health"
                onToggled: value => BatteryHealth.setEnabled(value)
            }
        }

        Item {
            width: parent.width
            height: 40

            Sym {
                id: awakeMark
                anchors.left: parent.left
                anchors.leftMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                name: "coffee"
                size: 18
                fill: SysInfo.idleInhibited ? 1 : 0
                color: SysInfo.idleInhibited ? Theme.accent : Theme.textMid
            }

            Column {
                anchors.left: awakeMark.right
                anchors.leftMargin: 12
                anchors.right: awakeToggle.left
                anchors.rightMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                spacing: 1

                Text {
                    width: parent.width
                    text: "Stay awake"
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.control
                    font.weight: Theme.weightMedium
                    color: Theme.textHi
                    elide: Text.ElideRight
                }

                Text {
                    width: parent.width
                    text: SysInfo.idleInhibitError !== ""
                        ? SysInfo.idleInhibitError
                        : "Idle inhibit " + SysInfo.idleInhibitStatus.toLowerCase()
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.metadata
                    color: SysInfo.idleInhibitError !== ""
                        ? Theme.redText : Theme.textFaint
                    elide: Text.ElideRight
                }
            }

            Toggle {
                id: awakeToggle
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                metrics: Theme.switchCompact
                checked: SysInfo.idleInhibited
                accessibleName: "Stay awake"
                onToggled: SysInfo.toggleIdleInhibited()
            }
        }
    }

    DrawerFooter {
        info: {
            const parts = [];
            if (root.displayDevice && root.displayDevice.energyCapacity > 0)
                parts.push(BatteryView.formatWh(root.displayDevice.energyCapacity));
            if (root.cycleCountText !== BatteryView.MISSING)
                parts.push(root.cycleCountText + " cycles");
            return parts.join(" · ");
        }
        actionText: "Power settings"
        onActionClicked: {
            Popouts.close();
            Quickshell.execDetached(["gnome-control-center", "power"]);
        }
    }
}
