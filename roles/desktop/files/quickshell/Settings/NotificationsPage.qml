import QtQuick
import "../Common"
import "../Common/SettingsHelpers.js" as SettingsHelpers

// Pop-ups, quiet hours and the on-screen display. The toast preview heads
// the Style group, in the same column as its rows rather than a second
// column beside them, so every row keeps the page's full control lane
// (2026-09 redesign).
SettingsPage {
    id: page
    pageReset: true

    readonly property var quietRange: SettingsHelpers.quietRange(Settings.notifQuiet,
        Settings.notifQuietStart, Settings.notifQuietEnd)
    property real previewProgress: 1
    readonly property string densityLabel: Settings.notifDensity.charAt(0).toUpperCase()
        + Settings.notifDensity.slice(1)
    readonly property string positionLabel: {
        const text = Settings.notifPosition.replace("-", " ");
        return text.charAt(0).toUpperCase() + text.slice(1);
    }

    function sendTest() {
        Notifs.send({ appName: "CybexOS Settings", appIcon: "preferences-system-notifications",
            summary: I18n.tr("Test notification"),
            body: I18n.tr("Toasts use your current position, duration, and style settings.") });
    }

    function sendGroupedPreview() {
        for (let i = 1; i <= 4; i++)
            Notifs.send({ appName: "CybexOS Settings", summary: I18n.tr("Grouped popups"), body: "Preview " + i });
    }

    function sendVerificationPreview() {
        Notifs.send({ appName: "CybexOS Settings", summary: I18n.tr("Send verification preview"),
            body: "Your verification code is 482913. https://example.com/" });
    }

    Column {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Theme.settingsGroupSpacing

        SettingsGroup {
            width: parent.width
            title: I18n.tr("Behavior")

            SwitchRow {
                width: parent.width
                label: I18n.tr("Do Not Disturb")
                description: I18n.tr("Mutes pop-ups; notifications still collect in the center")
                checked: Notifs.dnd
                dirty: Settings.notifDnd !== Settings.defaults.notifDnd
                    || Settings.notifDndUntilMs !== Settings.defaults.notifDndUntilMs
                onToggled: value => Notifs.setDnd(value)
                onResetRequested: Notifs.setDnd(Settings.defaults.notifDnd)
            }
            PickerRow {
                width: parent.width
                label: I18n.tr("Quiet hours")
                settingKey: "notifQuiet"
                resetKeys: ["notifQuiet", "notifQuietStart", "notifQuietEnd"]
                model: [
                    { value: "off", label: I18n.tr("Off") },
                    { value: "nights", label: I18n.tr("Nights") },
                    { value: "custom", label: I18n.tr("Custom") }
                ]
                caption: page.quietRange
                    ? SettingsHelpers.formatMinutes(page.quietRange.start) + " – "
                        + SettingsHelpers.formatMinutes(page.quietRange.end) : ""
            }

            // Custom only: the two times sit directly under Quiet hours, as
            // the options it revealed.
            Revealer {
                id: quietReveal
                width: parent.width
                reveal: Settings.notifQuiet === "custom"
                Column {
                    width: quietReveal.width
                    spacing: Theme.settingsRowSpacing
                    TimeRow {
                        width: parent.width
                        label: I18n.tr("Quiet from")
                        settingKey: "notifQuietStart"
                        resetLabel: "Quiet hours start"
                    }
                    TimeRow {
                        width: parent.width
                        label: I18n.tr("Quiet until")
                        settingKey: "notifQuietEnd"
                        resetLabel: "Quiet hours end"
                        note: Settings.notifQuietEnd < Settings.notifQuietStart
                            ? "Ends the next day" : ""
                    }
                }
            }

            SliderRow {
                width: parent.width
                label: I18n.tr("Duration")
                settingKey: "notifDuration"
                resetLabel: "Toast duration"
                min: 4; max: 20; step: 1; unit: "s"
                hint: I18n.tr("Critical alerts ignore the timer and stay until dismissed")
            }
            CornerPickerRow {
                width: parent.width
                label: I18n.tr("Position")
                settingKey: "notifPosition"
                resetLabel: "Toast position"
            }
        }

        SettingsGroup {
            width: parent.width
            title: I18n.tr("Style")

            // The one preview that stays (turn-3 design): a toast is not
            // otherwise on screen, so the style rows keep a live sample card.
            // It heads the group as a block in the row grid, from the label
            // lane to at most a toast's width, with Send test at its foot to
            // show the real thing.
            Item {
                id: previewBlock
                readonly property real laneWidth: Math.max(0,
                    width - Theme.settingsMarkInset - Theme.chipHeight)
                width: parent.width
                height: previewColumn.implicitHeight + Theme.scaled(4) * 2

                Column {
                    id: previewColumn
                    x: Theme.settingsMarkInset
                    y: Theme.scaled(4)
                    width: Math.min(previewBlock.laneWidth, Theme.scaled(360))
                    spacing: Theme.settingsContentSpacing

                    Rectangle {
                        id: sampleToast
                        // The toast's own density padding (NotificationToasts).
                        readonly property int padV: Theme.scaled(Settings.notifDensity === "compact" ? 8
                            : Settings.notifDensity === "roomy" ? 15 : 11)
                        readonly property int padH: Theme.scaled(Settings.notifDensity === "compact" ? 10
                            : Settings.notifDensity === "roomy" ? 16 : 12)
                        width: parent.width
                        height: sampleContent.implicitHeight + padV * 2
                            + (Settings.notifProgress ? padV / 2 : 0)
                        radius: Math.min(Theme.panelRadius, Theme.scaled(16))
                        color: Theme.cardFill
                        border.width: Math.max(1, Theme.surfaceBorderWidth)
                        border.color: Theme.surfaceBorderWidth > 0
                            ? Theme.surfaceBorderColor : Theme.hairlineSoft
                        Accessible.role: Accessible.StaticText
                        Accessible.name: I18n.tr("Preview: a toast from WhatsApp, Sarah Jansen")

                        Row {
                            id: sampleContent
                            x: sampleToast.padH
                            y: sampleToast.padV
                            width: parent.width - sampleToast.padH * 2
                            spacing: Theme.scaled(10)

                            Rectangle {
                                id: sampleIcon
                                visible: Settings.notifIcons
                                width: Theme.scaled(34); height: width
                                radius: Theme.chipRadius + Theme.scaled(2)
                                color: Theme.chip

                                BrandIcon {
                                    anchors.centerIn: parent
                                    width: Theme.scaled(20, Theme.typeScale); height: width
                                    name: "whatsapp"
                                }
                            }

                            Column {
                                width: sampleContent.width - (sampleIcon.visible
                                    ? sampleIcon.width + sampleContent.spacing : 0)
                                spacing: Theme.scaled(2)

                                Item {
                                    width: parent.width
                                    height: Math.max(sampleApp.implicitHeight,
                                        sampleTime.implicitHeight)
                                    Text {
                                        id: sampleApp
                                        anchors.left: parent.left
                                        width: Math.max(0, parent.width - sampleTime.width - Theme.iconTextSpacing)
                                        text: I18n.tr("WhatsApp")
                                        font.family: Theme.fontMenu
                                        font.pixelSize: Theme.typography.metadata
                                        font.weight: Theme.weightMedium
                                        color: Theme.textDim
                                        elide: Text.ElideRight
                                    }
                                    Text {
                                        id: sampleTime
                                        anchors.right: parent.right
                                        text: "now"
                                        font.family: Theme.fontMono
                                        font.pixelSize: Theme.typography.metadata
                                        color: Theme.textFaint
                                    }
                                }
                                Text {
                                    width: parent.width
                                    text: I18n.tr("Sarah Jansen")
                                    font.family: Theme.fontMenu
                                    font.pixelSize: Theme.typography.notification
                                    font.weight: Theme.weightSemibold
                                    color: Theme.textHi
                                    elide: Text.ElideRight
                                }
                                Text {
                                    visible: Settings.notifBodyLines > 0
                                    width: parent.width
                                    text: I18n.tr("Sure, see you at 12:30 tomorrow then! I'll bring the plans, the paint samples and the measurements for the kitchen.")
                                    font.family: Theme.fontMenu
                                    font.pixelSize: Theme.typography.notification
                                    color: Theme.textMid
                                    wrapMode: Text.Wrap
                                    maximumLineCount: Math.max(1, Settings.notifBodyLines)
                                    elide: Text.ElideRight
                                }
                            }
                        }

                        Rectangle {
                            visible: Settings.notifProgress
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.bottom: parent.bottom
                            anchors.leftMargin: sampleToast.padH
                            anchors.rightMargin: sampleToast.padH
                            anchors.bottomMargin: sampleToast.padV / 2
                            height: 2
                            radius: 1
                            color: Theme.activeFill

                            Rectangle {
                                height: parent.height
                                width: parent.width * page.previewProgress
                                radius: 1
                                color: Theme.accent
                            }
                        }
                    }

                    Item {
                        width: parent.width
                        height: Math.max(Theme.chipHeight, previewSummary.implicitHeight)

                        Text {
                            id: previewSummary
                            anchors.left: parent.left
                            anchors.right: sendTest.left
                            anchors.rightMargin: Theme.controlSpacing
                            anchors.verticalCenter: parent.verticalCenter
                            text: page.positionLabel + " · " + Settings.notifDuration + " s · "
                                + page.densityLabel
                            font.family: Theme.fontMenu
                            font.pixelSize: Theme.typography.secondary
                            color: Theme.textFaint
                            elide: Text.ElideRight
                        }

                        SettingsAction {
                            id: sendTest
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            text: I18n.tr("Send test")
                            glyph: "notifications"
                            Accessible.name: Notifs.toastsSuppressed
                                ? "Send test notification; toasts are silenced, it lands in the center"
                                : "Send test notification"
                            onTriggered: page.sendTest()
                        }
                    }

                    // Said on screen, not only to a screen reader: a test sent
                    // now makes no pop-up.
                    SettingsHint {
                        width: parent.width
                        inset: false
                        visible: Notifs.toastsSuppressed
                        text: Notifs.dnd
                            ? "Do Not Disturb is on, so a test only collects in the center"
                            : "Quiet hours are on, so a test only collects in the center"
                    }
                }
            }

            PickerRow {
                width: parent.width
                label: I18n.tr("Density")
                settingKey: "notifDensity"
                resetLabel: "Toast density"
                model: [
                    { value: "compact", label: I18n.tr("Compact") },
                    { value: "default", label: I18n.tr("Default") },
                    { value: "roomy", label: I18n.tr("Roomy") }
                ]
            }
            SwitchRow {
                width: parent.width
                label: I18n.tr("App icons")
                settingKey: "notifIcons"
                description: I18n.tr("Show the sender's icon on each card")
            }
            SwitchRow {
                width: parent.width
                label: I18n.tr("Timeout progress")
                settingKey: "notifProgress"
                description: I18n.tr("A thin bar counts down the time a toast has left")
            }
            // Four stops (the store keeps 0–3 lines) read better as choices
            // than as a slider with four detents.
            PickerRow {
                width: parent.width
                label: I18n.tr("Body preview")
                settingKey: "notifBodyLines"
                model: [
                    { value: 0, label: I18n.tr("Off") },
                    { value: 1, label: I18n.tr("1 line") },
                    { value: 2, label: I18n.tr("2 lines") },
                    { value: 3, label: I18n.tr("3 lines") }
                ]
            }
        }

        SettingsGroup {
            width: parent.width
            title: I18n.tr("Grouped popups")
            PickerRow {
                width: parent.width
                label: I18n.tr("Fullscreen notifications")
                settingKey: "notifFullscreen"
                model: [
                    { value: "away", label: I18n.tr("Use another display or history") },
                    { value: "show", label: I18n.tr("Show over fullscreen") }
                ]
            }
            SliderRow {
                width: parent.width
                label: I18n.tr("Burst limit")
                settingKey: "notifBurstLimit"
                min: 1; max: 20; step: 1; unit: ""
                hint: I18n.tr("Extra notifications collect in the center")
            }
            Flow {
                width: parent.width
                spacing: Theme.controlSpacing
                SettingsAction {
                    text: I18n.tr("Send grouped preview")
                    onTriggered: page.sendGroupedPreview()
                }
                SettingsAction {
                    text: I18n.tr("Send verification preview")
                    onTriggered: page.sendVerificationPreview()
                }
            }
        }

        SettingsGroup {
            width: parent.width
            title: I18n.tr("Notification history")
            SwitchRow {
                width: parent.width
                label: I18n.tr("Remember notification history")
                settingKey: "notifHistoryPersist"
                description: I18n.tr("Store private history across shell restarts and logins")
            }
            PickerRow {
                width: parent.width
                label: I18n.tr("Retention")
                settingKey: "notifHistoryHours"
                model: [
                    { value: 1, label: I18n.tr("1 hour") },
                    { value: 24, label: I18n.tr("24 hours") },
                    { value: 168, label: I18n.tr("7 days") }
                ]
            }
            SliderRow {
                width: parent.width
                label: I18n.tr("History limit")
                settingKey: "notifHistoryCount"
                min: 10; max: 200; step: 10; unit: ""
            }
            SettingsAction {
                text: I18n.tr("Clear notification history")
                onTriggered: Notifs.clearAll()
            }
            SettingsHint {
                width: parent.width
                visible: Notifs.historyError
                text: I18n.tr("History storage unavailable")
            }
        }

        SettingsGroup {
            width: parent.width
            title: I18n.tr("Source snoozes")
            SettingsHint {
                width: parent.width
                visible: Notifs.snoozes.length === 0
                text: I18n.tr("No sources snoozed")
            }
            NotifSnoozes { width: parent.width }
        }

        SettingsGroup {
            width: parent.width
            title: I18n.tr("On-screen display")

            PickerRow {
                width: parent.width
                label: I18n.tr("Placement")
                settingKey: "osd"
                resetLabel: "OSD placement"
                model: [
                    { value: "top", label: I18n.tr("Top center") },
                    { value: "bottom", label: I18n.tr("Bottom center") }
                ]
                hint: I18n.tr("Where the volume and brightness pop-up appears")
            }
        }
    }

    NumberAnimation {
        id: previewAnim
        target: page
        property: "previewProgress"
        from: 1; to: 0
        duration: Settings.notifDuration * 1000
        loops: Animation.Infinite
        running: Settings.notifProgress && page.visible
    }

    Connections {
        target: Settings
        function onNotifDurationChanged() {
            previewAnim.restart();
        }
    }
}
