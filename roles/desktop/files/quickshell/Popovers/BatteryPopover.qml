pragma ComponentBehavior: Bound
import QtQuick
import Quickshell.Io
import Quickshell.Services.UPower
import "../Common"
import "../Common/BatteryViewHelpers.js" as BatteryView

// The dedicated battery view follows one stable hierarchy: level and state,
// a blocked charge meter, aggregate telemetry, battery health, then the
// profile radio.
// The bar module and Control Panel intentionally keep their own compact forms.
Surface {
    id: root

    readonly property var displayDevice: UPower.displayDevice
    readonly property int level: Math.round(Battery.percent)
    readonly property real chargeFraction: Math.max(0,
        Math.min(1, Battery.percent / 100))
    readonly property bool discharging: !Battery.pluggedIn
    readonly property bool critical: discharging
        && Battery.percent <= Settings.modOpts.batt.critAt
    readonly property bool warning: discharging && !critical
        && Battery.percent <= Settings.modOpts.batt.warnAt
    readonly property color batteryTone: critical ? Theme.red
        : warning ? Theme.amber : Theme.accent
    readonly property string statusText: Battery.statusText
    readonly property string batteryGlyph: critical ? "battery_alert"
        : level >= 95 ? "battery_full"
        : level >= 80 ? "battery_6_bar"
        : level >= 65 ? "battery_5_bar"
        : level >= 50 ? "battery_4_bar"
        : level >= 35 ? "battery_3_bar"
        : level >= 20 ? "battery_2_bar" : "battery_1_bar"
    readonly property string estimateLabel: Battery.charging ? "Time to full"
        : discharging ? "Time remaining" : "Charge estimate"
    readonly property real estimateSeconds: !displayDevice ? 0
        : Battery.charging ? displayDevice.timeToFull
        : discharging ? displayDevice.timeToEmpty : 0
    readonly property string rateLabel: discharging ? "Discharge rate" : "Charge rate"
    readonly property string healthDetail: BatteryHealth.busy ? "Updating…"
        : BatteryHealth.error !== "" ? BatteryHealth.error
        : BatteryHealth.mixed ? "Battery limits differ"
        : BatteryHealth.enabled ? BatteryHealth.limitText : "Charge to 100%"
    readonly property int availableProfileCount:
        PowerProfiles.hasPerformanceProfile ? 3 : 2
    readonly property bool knownProfile:
        PowerProfiles.profile === PowerProfile.PowerSaver
        || PowerProfiles.profile === PowerProfile.Balanced
        || (PowerProfiles.hasPerformanceProfile
            && PowerProfiles.profile === PowerProfile.Performance)

    property string cycleCountText: BatteryView.MISSING

    Claim {
        active: root.visible
        onClaimed: BatteryHealth.acquire()
        onReleased: BatteryHealth.release()
    }

    function pickProfile(index) {
        const segment = profileRepeater.itemAt(index);
        if (!segment || !segment.visible)
            return;
        // Focus before the pick: see Settings/PillRow.
        segment.forceActiveFocus();
        PowerProfiles.profile = profileRepeater.model[index].profile;
    }

    component TelemetryPair: Item {
        id: pair

        property string label: ""
        property string value: BatteryView.MISSING

        width: parent ? parent.width : 0
        height: Theme.panelRowHeight

        Text {
            anchors.left: parent.left
            anchors.right: pairValue.left
            anchors.rightMargin: 6
            anchors.verticalCenter: parent.verticalCenter
            text: pair.label
            elide: Text.ElideRight
            font.family: Theme.fontMenu
            font.pixelSize: Theme.typography.metadata
            font.weight: Theme.weightMedium
            color: Theme.textLow
        }

        Text {
            id: pairValue
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: pair.value
            font.family: Theme.fontMono
            font.pixelSize: Theme.typography.secondary
            font.weight: Theme.weightSemibold
            font.features: Theme.tabularNumberFeatures
            color: Theme.textHi
        }
    }

    // cycle_count is not exposed by UPower. Read each physical pack once when
    // this view is instantiated; the explicit C-locale sort fixes BAT order.
    Process {
        id: cycleCountProcess

        command: ["sh", "-c",
            "printf '%s\\n' /sys/class/power_supply/BAT*/cycle_count | LC_ALL=C sort | while IFS= read -r file; do [ -e \"$file\" ] || continue; value=; IFS= read -r value < \"$file\"; printf '%s\\n' \"$value\"; done"]
        running: true

        stdout: StdioCollector {
            onStreamFinished: root.cycleCountText = BatteryView.parseCycleCounts(text)
        }
    }

    // Hero: a level-aware mark, fixed state language, and the primary reading.
    Item {
        id: hero

        width: parent.width
        height: 68

        Item {
            id: heroGlyphBox

            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: 62
            height: 62

            Sym {
                id: heroGlyph

                anchors.centerIn: parent
                name: root.batteryGlyph
                size: Theme.fontHero + 12
                color: root.batteryTone

                Behavior on color {
                    ColorAnimation { duration: Theme.chipFadeDuration }
                }
            }
        }

        Column {
            id: heroLabels

            anchors.left: heroGlyphBox.right
            anchors.leftMargin: 12
            anchors.right: heroPercentage.left
            anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            spacing: 3

            Text {
                width: parent.width
                text: "Battery"
                elide: Text.ElideRight
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.heading
                font.weight: Theme.weightSemibold
                color: Theme.textHi
            }

            Row {
                spacing: 5

                Sym {
                    visible: Battery.charging
                    anchors.verticalCenter: parent.verticalCenter
                    name: "bolt"
                    size: Theme.iconSmall
                    color: Theme.accentText
                }

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.statusText
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.secondary
                    font.weight: Theme.weightMedium
                    color: root.critical || root.warning
                        ? root.batteryTone : Theme.textLow
                }
            }
        }

        Item {
            id: heroPercentage

            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: heroNumber.implicitWidth + heroUnit.implicitWidth + 1
            height: heroNumber.implicitHeight

            Text {
                id: heroNumber

                anchors.left: parent.left
                anchors.top: parent.top
                text: root.level
                font.family: Theme.fontMono
                font.pixelSize: Theme.typography.displayLarge
                font.weight: Theme.weightBold
                font.features: Theme.tabularNumberFeatures
                color: root.critical || root.warning
                    ? root.batteryTone : Theme.textHi
            }

            Text {
                id: heroUnit

                anchors.left: heroNumber.right
                anchors.leftMargin: 1
                anchors.baseline: heroNumber.baseline
                text: "%"
                font.family: Theme.fontMono
                font.pixelSize: Theme.typography.primary
                font.weight: Theme.weightMedium
                color: root.critical || root.warning
                    ? root.batteryTone : Theme.textLow
            }
        }
    }

    // Only a discharging battery enters warning
    // colours; active charging adds a low-amplitude pulse over the accent.
    BlockMeter {
        id: chargeMeter

        width: parent.width
        height: 10
        value: root.chargeFraction
        fillColor: root.batteryTone

        Behavior on value {
            NumberAnimation {
                duration: Theme.reducedMotion ? 0 : 320
                easing.type: Easing.OutCubic
            }
        }

        Behavior on fillColor {
            ColorAnimation { duration: Theme.chipFadeDuration }
        }

        SequentialAnimation on opacity {
            running: Battery.charging && !Theme.reducedMotion
            loops: Animation.Infinite
            NumberAnimation {
                from: 1
                to: 0.72
                duration: 900
                easing.type: Easing.InOutSine
            }
            NumberAnimation {
                from: 0.72
                to: 1
                duration: 900
                easing.type: Easing.InOutSine
            }
        }
    }

    SectionLabel {
        text: "BATTERY TELEMETRY"
    }

    Row {
        id: telemetryGrid

        width: parent.width
        spacing: 24

        Column {
            width: (telemetryGrid.width - telemetryGrid.spacing) / 2
            spacing: Theme.panelRowSpacing

            TelemetryPair {
                label: "Capacity"
                value: BatteryView.formatWh(root.displayDevice
                    ? root.displayDevice.energyCapacity : undefined)
            }

            TelemetryPair {
                label: "Cycles"
                value: root.cycleCountText
            }
        }

        Column {
            width: (telemetryGrid.width - telemetryGrid.spacing) / 2
            spacing: Theme.panelRowSpacing

            TelemetryPair {
                label: root.estimateLabel
                value: BatteryView.formatDuration(root.estimateSeconds)
            }

            TelemetryPair {
                label: root.rateLabel
                value: BatteryView.formatW(root.displayDevice
                    ? root.displayDevice.changeRate : undefined)
            }
        }
    }

    // UPower exposes this only on physical battery objects, not its aggregate
    // display device. Unsupported laptops omit the whole section; there is no
    // software approximation that can safely enforce an 80% firmware limit.
    Column {
        id: batteryHealthSection

        visible: BatteryHealth.known && BatteryHealth.supported
        width: parent.width
        spacing: Theme.panelSectionSpacing

        SectionLabel {
            width: parent.width
            text: "BATTERY HEALTH"
        }

        Rectangle {
            id: healthRow

            width: parent.width
            height: Theme.panelTileHeight
            radius: Theme.rowRadius
            color: Theme.chip

            Sym {
                id: healthGlyph

                anchors.left: parent.left
                anchors.leftMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                name: "battery_saver"
                size: Theme.iconMedium
                color: BatteryHealth.enabled ? Theme.accentText : Theme.textLow
            }

            Column {
                anchors.left: healthGlyph.right
                anchors.leftMargin: 10
                anchors.right: healthToggle.left
                anchors.rightMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                spacing: 2

                Text {
                    width: parent.width
                    text: "Preserve battery health"
                    elide: Text.ElideRight
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.primary
                    font.weight: Theme.weightMedium
                    color: Theme.textHi
                }

                Text {
                    width: parent.width
                    text: root.healthDetail
                    elide: Text.ElideRight
                    font.family: Theme.fontMenu
                    font.pixelSize: Theme.typography.secondary
                    color: BatteryHealth.error !== "" ? Theme.red : Theme.textLow
                }
            }

            Toggle {
                id: healthToggle

                anchors.right: parent.right
                anchors.rightMargin: 6
                anchors.verticalCenter: parent.verticalCenter
                enabled: !BatteryHealth.busy
                opacity: enabled ? 1 : 0.5
                checked: BatteryHealth.enabled
                accessibleName: "Preserve battery health"
                onToggled: value => BatteryHealth.setEnabled(value)
            }
        }
    }

    SectionLabel {
        text: "POWER PROFILE"
    }

    // A single segmented radio. Saver and Balanced retain their existing
    // availability; Performance joins them only when the service exposes it.
    Rectangle {
        id: profileTrack

        width: parent.width
        height: Theme.controlHeight
        radius: Theme.chipRadius
        color: Theme.chip

        Row {
            id: profileRow

            anchors.fill: parent
            anchors.margins: 3
            spacing: 4

            Repeater {
                id: profileRepeater

                model: [
                    { label: "Saver", glyph: "eco", profile: PowerProfile.PowerSaver,
                        available: true },
                    { label: "Balanced", glyph: "balance", profile: PowerProfile.Balanced,
                        available: true },
                    { label: "Performance", glyph: "speed", profile: PowerProfile.Performance,
                        available: PowerProfiles.hasPerformanceProfile }
                ]

                delegate: Rectangle {
                    id: profileSegment

                    required property var modelData
                    required property int index
                    readonly property bool current:
                        PowerProfiles.profile === modelData.profile

                    visible: modelData.available
                    width: (profileRow.width
                        - profileRow.spacing * (root.availableProfileCount - 1))
                        / root.availableProfileCount
                    height: profileRow.height
                    radius: Theme.chipRadius - 2
                    color: current ? Theme.chipHover
                        : profileMouse.containsMouse ? Theme.tile : "transparent"
                    border.width: activeFocus || current ? 1 : 0
                    border.color: activeFocus ? Theme.accentText : Theme.stroke
                    activeFocusOnTab: visible && (current
                        || (!root.knownProfile && index === 0))

                    Accessible.role: Accessible.RadioButton
                    Accessible.name: modelData.label + " power profile"
                    Accessible.checked: current
                    Accessible.onPressAction: {
                        profileState.pulseCenter();
                        root.pickProfile(index);
                    }

                    Behavior on color {
                        ColorAnimation { duration: Theme.chipFadeDuration }
                    }

                    Keys.onPressed: event => {
                        let next = -1;
                        if (event.key === Qt.Key_Left || event.key === Qt.Key_Up)
                            next = Math.max(0, index - 1);
                        else if (event.key === Qt.Key_Right || event.key === Qt.Key_Down)
                            next = Math.min(root.availableProfileCount - 1, index + 1);
                        else if (event.key === Qt.Key_Home)
                            next = 0;
                        else if (event.key === Qt.Key_End)
                            next = root.availableProfileCount - 1;
                        else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                                || event.key === Qt.Key_Space) {
                            profileState.pulseCenter();
                            PowerProfiles.profile = modelData.profile;
                            event.accepted = true;
                            return;
                        }
                        if (next >= 0) {
                            root.pickProfile(next);
                            event.accepted = true;
                        }
                    }

                    StateLayer {
                        id: profileState

                        anchors.fill: parent
                        radius: parent.radius
                        hovered: profileMouse.containsMouse
                        pressed: profileMouse.pressed
                        focused: profileSegment.activeFocus
                        tint: profileSegment.current ? Theme.accent : Theme.textHi
                        pressPoint: Qt.point(profileMouse.mouseX, profileMouse.mouseY)
                    }

                    Row {
                        anchors.centerIn: parent
                        spacing: 6

                        Sym {
                            anchors.verticalCenter: parent.verticalCenter
                            name: profileSegment.modelData.glyph
                            size: Theme.iconMedium
                            color: profileSegment.current
                                ? Theme.textHi : Theme.textLow
                        }

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: profileSegment.modelData.label
                            font.family: Theme.fontMenu
                            font.pixelSize: Theme.typography.secondary
                            font.weight: profileSegment.current
                                ? Theme.weightSemibold : Theme.weightMedium
                            color: profileSegment.current
                                ? Theme.textHi : Theme.textLow
                        }
                    }

                    MouseArea {
                        id: profileMouse

                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            profileState.pulseAt(mouseX, mouseY);
                            root.pickProfile(profileSegment.index);
                        }
                    }
                }
            }
        }
    }
}
