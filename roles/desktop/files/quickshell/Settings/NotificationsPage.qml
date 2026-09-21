import QtQuick
import Quickshell
import "../Common"
import "../Common/SettingsHelpers.js" as SettingsHelpers

SettingsPage {
    id: page

    readonly property var quietRange: SettingsHelpers.quietRange(Settings.notifQuiet,
        Settings.notifQuietStart, Settings.notifQuietEnd)
    readonly property int footnotePad: width < Theme.settingsNarrowWidth ? 0
        : Theme.settingsMarkInset + Theme.settingsLabelWidth + 10
    property real previewProgress: 1

    function sendTest() {
        Quickshell.execDetached(["notify-send", "-a", "Shell settings",
            "-i", "preferences-system-notifications", "Test notification",
            "Toasts use your current position, duration, and style settings."]);
    }

    Column {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Theme.settingsGroupSpacing

        SettingsGroup {
            width: parent.width
            title: "Behavior"
            dirty: Settings.notifDnd !== Settings.defaults.notifDnd
                || Settings.notifDndUntilMs !== Settings.defaults.notifDndUntilMs
                || Settings.notifQuiet !== Settings.defaults.notifQuiet
                || Settings.notifQuietStart !== Settings.defaults.notifQuietStart
                || Settings.notifQuietEnd !== Settings.defaults.notifQuietEnd
                || Settings.notifDuration !== Settings.defaults.notifDuration
                || Settings.notifPosition !== Settings.defaults.notifPosition
            onResetRequested: Settings.resetKeys(["notifDnd", "notifDndUntilMs", "notifQuiet",
                "notifQuietStart", "notifQuietEnd", "notifDuration", "notifPosition"],
                "Notification behavior")

            SwitchRow {
                width: parent.width
                label: "Do Not Disturb"
                description: "Silence toasts — everything still lands in the center"
                checked: Notifs.dnd
                dirty: Settings.notifDnd !== Settings.defaults.notifDnd
                    || Settings.notifDndUntilMs !== Settings.defaults.notifDndUntilMs
                onToggled: value => Notifs.setDnd(value)
                onResetRequested: Notifs.setDnd(Settings.defaults.notifDnd)
            }
            PickerRow {
                width: parent.width
                label: "Quiet hours"
                settingKey: "notifQuiet"
                resetKeys: ["notifQuiet", "notifQuietStart", "notifQuietEnd"]
                model: [
                    { value: "off", label: "Off" },
                    { value: "nights", label: "Nights" },
                    { value: "custom", label: "Custom" }
                ]
                caption: page.quietRange
                    ? SettingsHelpers.formatMinutes(page.quietRange.start) + " – "
                        + SettingsHelpers.formatMinutes(page.quietRange.end) : ""
            }

            Revealer {
                id: quietReveal
                width: parent.width
                reveal: Settings.notifQuiet === "custom"
                Column {
                    width: quietReveal.width
                    spacing: 4
                    SliderRow {
                        width: parent.width
                        label: "Quiet from"
                        settingKey: "notifQuietStart"
                        resetLabel: "Quiet hours start"
                        min: 0; max: 1425; step: 15
                        valueLabel: SettingsHelpers.formatMinutes(Settings.notifQuietStart)
                    }
                    SliderRow {
                        width: parent.width
                        label: "Quiet until"
                        settingKey: "notifQuietEnd"
                        resetLabel: "Quiet hours end"
                        min: 0; max: 1425; step: 15
                        valueLabel: SettingsHelpers.formatMinutes(Settings.notifQuietEnd)
                    }
                }
            }

            SliderRow {
                width: parent.width
                label: "Duration"
                settingKey: "notifDuration"
                resetLabel: "Toast duration"
                min: 4; max: 20; step: 1; unit: "s"
            }
            Text {
                width: parent.width
                leftPadding: page.footnotePad
                text: "Critical alerts ignore the timer and stay until dismissed"
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.secondary
                color: Theme.textDim
                wrapMode: Text.Wrap
                maximumLineCount: 2
                elide: Text.ElideRight
            }
            PickerRow {
                width: parent.width
                label: "Position"
                settingKey: "notifPosition"
                resetLabel: "Toast position"
                model: [
                    { value: "top-left", label: "Top left" },
                    { value: "top-right", label: "Top right" },
                    { value: "bottom-left", label: "Bottom left" },
                    { value: "bottom-right", label: "Bottom right" }
                ]
            }
        }

        SettingsGroup {
            width: parent.width
            title: "Style"
            dirty: Settings.notifDensity !== Settings.defaults.notifDensity
                || Settings.notifIcons !== Settings.defaults.notifIcons
                || Settings.notifProgress !== Settings.defaults.notifProgress
                || Settings.notifBodyLines !== Settings.defaults.notifBodyLines
            onResetRequested: Settings.resetKeys(["notifDensity", "notifIcons",
                "notifProgress", "notifBodyLines"], "Notification style")

            // The one preview that stays (turn-3 design): a toast is not
            // otherwise on screen, so the style rows keep a live sample card
            // beside them. Below the side-by-side breakpoint it drops under
            // the rows instead.
            Item {
                width: parent.width
                readonly property bool sideBySide: width >= 640
                height: sideBySide
                    ? Math.max(styleRows.implicitHeight, previewColumn.implicitHeight)
                    : styleRows.implicitHeight + 10 + previewColumn.implicitHeight

                Column {
                    id: styleRows
                    x: 0
                    y: 0
                    width: parent.sideBySide ? parent.width - 284 : parent.width
                    spacing: Theme.panelRowSpacing

                    PickerRow {
                        width: parent.width
                        label: "Density"
                        settingKey: "notifDensity"
                        resetLabel: "Toast density"
                        model: [
                            { value: "compact", label: "Compact" },
                            { value: "default", label: "Default" },
                            { value: "roomy", label: "Roomy" }
                        ]
                    }
                    SwitchRow {
                        width: parent.width
                        label: "App icons"
                        settingKey: "notifIcons"
                        description: "Show the sender's icon on each card"
                    }
                    SwitchRow {
                        width: parent.width
                        label: "Timeout progress"
                        settingKey: "notifProgress"
                        description: "Thin bar counting down a toast's remaining time"
                    }
                    SliderRow {
                        width: parent.width
                        label: "Body preview"
                        settingKey: "notifBodyLines"
                        min: 0; max: 3; step: 1
                        valueLabel: Settings.notifBodyLines === 0 ? "hidden"
                            : Settings.notifBodyLines === 1 ? "1 line"
                            : Settings.notifBodyLines + " lines"
                        valueWidth: 52
                    }
                }

                Column {
                    id: previewColumn
                    x: parent.sideBySide ? parent.width - width : 0
                    y: parent.sideBySide ? 0 : styleRows.implicitHeight + 10
                    width: parent.sideBySide ? 264 : Math.min(300, parent.width)
                    spacing: 8

                    Rectangle {
                        id: sampleToast
                        readonly property int pad: Settings.notifDensity === "compact" ? 8
                            : Settings.notifDensity === "roomy" ? 14 : 11
                        width: parent.width
                        height: sampleContent.implicitHeight + pad * 2 + 6
                        radius: 12
                        color: Theme.cardFill
                        border.width: 1
                        border.color: Theme.hairlineSoft

                        Row {
                            id: sampleContent
                            x: sampleToast.pad
                            y: sampleToast.pad
                            width: parent.width - sampleToast.pad * 2
                            spacing: 9

                            Rectangle {
                                id: sampleIcon
                                visible: Settings.notifIcons
                                width: 30; height: 30
                                radius: 9
                                color: Theme.chip

                                BrandIcon {
                                    anchors.centerIn: parent
                                    width: 17; height: 17
                                    name: "whatsapp"
                                }
                            }

                            Column {
                                width: sampleContent.width - (sampleIcon.visible
                                    ? sampleIcon.width + sampleContent.spacing : 0)
                                spacing: 2

                                Item {
                                    width: parent.width
                                    height: Math.max(sampleApp.implicitHeight,
                                        sampleTime.implicitHeight)
                                    Text {
                                        id: sampleApp
                                        anchors.left: parent.left
                                        width: Math.max(0, parent.width - sampleTime.width - 6)
                                        text: "WhatsApp"
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
                                    text: "Sarah Jansen"
                                    font.family: Theme.fontMenu
                                    font.pixelSize: Theme.typography.notification
                                    font.weight: Theme.weightSemibold
                                    color: Theme.textHi
                                    elide: Text.ElideRight
                                }
                                Text {
                                    visible: Settings.notifBodyLines > 0
                                    width: parent.width
                                    text: "Sure, see you at 12:30 tomorrow then! I'll bring the plans."
                                    font.family: Theme.fontMenu
                                    font.pixelSize: Theme.typography.notification
                                    color: Theme.textMid
                                    wrapMode: Text.Wrap
                                    maximumLineCount: Settings.notifBodyLines
                                    elide: Text.ElideRight
                                }
                            }
                        }

                        Rectangle {
                            visible: Settings.notifProgress
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.bottom: parent.bottom
                            anchors.leftMargin: sampleToast.pad
                            anchors.rightMargin: sampleToast.pad
                            anchors.bottomMargin: 5
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
                        height: Theme.chipHeight

                        Text {
                            anchors.left: parent.left
                            anchors.right: sendTest.left
                            anchors.rightMargin: 8
                            anchors.verticalCenter: parent.verticalCenter
                            text: Settings.notifPosition.replace("-", " ") + " · "
                                + Settings.notifDuration + " s · " + Settings.notifDensity
                            font.family: Theme.fontMenu
                            font.pixelSize: Theme.typography.metadata
                            color: Theme.textFaint
                            elide: Text.ElideRight
                        }

                        SettingsAction {
                            id: sendTest
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Send test"
                            glyph: "notifications"
                            Accessible.name: Notifs.toastsSuppressed
                                ? "Send test notification; toasts are silenced, it lands in the tab"
                                : "Send test notification"
                            onTriggered: page.sendTest()
                        }
                    }
                }
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
