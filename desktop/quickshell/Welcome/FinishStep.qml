pragma ComponentBehavior: Bound
import QtQuick
import "../Common"

// Ready, as the installer's done screen: the mark, the headline, three
// numbered cards that recap the choices, what the system check found, and
// the optional extras as pills. Each extra opens its Settings page and the
// guide steps aside; a tick shows what the live backends report as done.
Item {
    id: root
    readonly property var labels: ({webapps: I18n.tr("Web apps"),
        fingerprint: I18n.tr("Fingerprint"), security: I18n.tr("Security keys"), backup: I18n.tr("Backups"),
        accounts: I18n.tr("Online accounts")})
    readonly property var glyphs: ({webapps: "web", fingerprint: "passkey", security: "key",
        backup: "archive", accounts: "account_circle"})
    readonly property string colours: Settings.paletteMode === "wallpaper" ? I18n.tr("wallpaper colours")
        : Themes.current.value !== "" && !Themes.current.modified ? I18n.format("%1 theme", [Themes.current.label])
        : I18n.tr("your own accent")
    readonly property string textSize: Settings.textScale === "large" ? I18n.tr("Large text")
        : Settings.textScale === "larger" ? I18n.tr("Larger text") : I18n.tr("Default text")
    Component.onCompleted: { Backup.refresh(); Doctor.refreshIfStale(); if (!Themes.loaded) Themes.refresh(); }
    Claim { active: root.visible; onClaimed: SystemSettings.security.acquire(); onReleased: SystemSettings.security.release() }
    Claim { active: root.visible; onClaimed: SystemSettings.accounts.acquire(); onReleased: SystemSettings.accounts.release() }

    component Recap: KioskCard {
        id: recap
        property string number: ""
        property string title: ""
        property string detail: ""
        default property alias visual: visualSlot.data
        readonly property real contentHeight: texts.implicitHeight + Kiosk.px(44)
        width: (summary.width - Kiosk.px(28)) / 3
        height: summary.cardHeight
        Column {
            id: texts
            anchors.left: parent.left
            anchors.leftMargin: Kiosk.px(22)
            anchors.right: visualSlot.left
            anchors.rightMargin: Kiosk.px(14)
            anchors.verticalCenter: parent.verticalCenter
            KioskText { width: parent.width; text: recap.number; mono: true; size: 13; font.weight: Font.DemiBold; tone: "accent"; elide: Text.ElideRight }
            Item { width: 1; height: Kiosk.px(8) }
            KioskText { width: parent.width; text: recap.title; size: 18; font.weight: Font.Bold; wrapMode: Text.WordWrap; maximumLineCount: 2; elide: Text.ElideRight }
            Item { width: 1; height: Kiosk.px(4) }
            KioskText { width: parent.width; text: recap.detail; size: 14.5; tone: "fog"; wrapMode: Text.WordWrap; maximumLineCount: 2; elide: Text.ElideRight }
        }
        Item {
            id: visualSlot
            anchors.right: parent.right
            anchors.rightMargin: Kiosk.px(22)
            anchors.verticalCenter: parent.verticalCenter
            width: childrenRect.width
            height: childrenRect.height
        }
    }

    Column {
        anchors.horizontalCenter: parent.horizontalCenter
        y: Kiosk.px(40)
        width: Kiosk.px(1000)
        spacing: 0
        Image {
            anchors.horizontalCenter: parent.horizontalCenter
            height: Kiosk.px(52)
            width: height
            source: "../assets/cybexos.svg"
            sourceSize.height: Math.ceil(height * 2)
            fillMode: Image.PreserveAspectFit
        }
        Item { width: 1; height: Kiosk.px(22) }
        KioskText {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: I18n.format("You’re all set, %1.", [Welcome.firstName])
            size: 50
            font.weight: Font.Bold
            font.letterSpacing: -Kiosk.px(1.2)
            elide: Text.ElideRight
            Accessible.role: Accessible.Heading
        }
        Item { width: 1; height: Kiosk.px(12) }
        KioskText {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: I18n.tr("Your choices are live. You will find every one of them again in Settings.")
            size: 19
            tone: "fog"
            wrapMode: Text.WordWrap
        }
        Item { width: 1; height: Kiosk.px(26) }
        Row {
            id: summary
            // The three cards share the tallest card's height.
            readonly property real cardHeight: Math.max(Kiosk.px(116), wallpaperRecap.contentHeight,
                styleRecap.contentHeight, shortcutsRecap.contentHeight)
            width: parent.width
            spacing: Kiosk.px(14)
            Recap {
                id: wallpaperRecap
                number: I18n.format("%1 · %2", ["01", I18n.tr("Wallpaper")])
                title: Welcome.wallpaperName
                detail: Welcome.wallpaperSource === "wallhaven" ? I18n.tr("From Wallhaven")
                    : Welcome.wallpaperSource === "collection" ? I18n.tr("Cybex OS collection") : I18n.tr("From your pictures")
                Rectangle {
                    width: Kiosk.px(76)
                    height: Kiosk.px(50)
                    radius: Kiosk.px(9)
                    color: Kiosk.bgDeep
                    clip: true
                    Image {
                        anchors.fill: parent
                        source: Wallpaper.current
                        asynchronous: true
                        fillMode: Image.PreserveAspectCrop
                        sourceSize.width: 200
                    }
                    Rectangle {
                        anchors.fill: parent
                        radius: parent.radius
                        color: "transparent"
                        border.width: Math.max(1, Kiosk.px(1))
                        border.color: Kiosk.line2
                    }
                }
            }
            Recap {
                id: styleRecap
                number: I18n.format("%1 · %2", ["02", I18n.tr("Style")])
                title: I18n.format("%1, %2", [Settings.themeMode === "light" ? I18n.tr("Light") : I18n.tr("Dark"), root.colours])
                detail: I18n.format("%1 · glass %2", [root.textSize, Settings.glassEnabled && !Settings.highContrast ? I18n.tr("on") : I18n.tr("off")])
                Rectangle {
                    width: Kiosk.px(34)
                    height: width
                    radius: width / 2
                    color: Theme.accent
                    border.width: Math.max(1, Kiosk.px(1))
                    border.color: "#24ffffff"
                }
            }
            Recap {
                id: shortcutsRecap
                number: I18n.format("%1 · %2", ["03", I18n.tr("Shortcuts")])
                title: I18n.tr("Super + K shows them all")
                detail: I18n.tr("Change any in Settings")
                KioskKeycap { text: "K" } // i18n: untranslated (key name)
            }
        }
        Item { width: 1; height: Kiosk.px(14) }
        // What the system check found, in the shell's own words, so it reads
        // the same without an AI account. The assistant explains it and
        // offers fixes; the guide steps aside while it works.
        KioskCard {
            id: check
            readonly property bool waiting: Doctor.running || (Doctor.report === null && Doctor.error === "")
            readonly property int count: Doctor.attention.length
            readonly property var lines: Doctor.attention.map(item => Doctor.sentence(item))
            width: parent.width
            height: Kiosk.px(80)
            Accessible.role: Accessible.Grouping
            Accessible.name: I18n.tr("System check")
            Rectangle {
                id: checkMark
                x: Kiosk.px(22)
                anchors.verticalCenter: parent.verticalCenter
                width: Kiosk.px(40)
                height: width
                radius: width / 2
                color: check.count > 0 ? Kiosk.amberTint : Kiosk.accentTint
                KioskIcon {
                    anchors.centerIn: parent
                    designSize: 20
                    name: check.waiting ? "progress_activity" : Doctor.report === null ? "computer"
                        : check.count > 0 ? "warning" : "check"
                    color: check.count > 0 ? Kiosk.amber : Kiosk.accent
                }
            }
            Column {
                anchors.left: checkMark.right
                anchors.leftMargin: Kiosk.px(16)
                anchors.right: checkAction.left
                anchors.rightMargin: Kiosk.px(16)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Kiosk.px(2)
                KioskText {
                    width: parent.width
                    text: check.waiting ? I18n.tr("Checking this computer…")
                        : Doctor.report === null ? I18n.tr("The system check could not run")
                        : check.count === 0 ? I18n.tr("This computer looks good")
                        : check.count === 1 ? I18n.tr("1 thing to look at")
                        : I18n.format("%1 things to look at", [check.count])
                    size: 17
                    font.weight: Font.Bold
                    elide: Text.ElideRight
                }
                KioskText {
                    width: parent.width
                    text: check.waiting ? I18n.tr("Drivers, services, sound, storage and firmware.")
                        : Doctor.report === null ? Doctor.error
                        : check.count === 0 ? I18n.tr("Drivers, services, sound, storage and firmware were checked.")
                        : check.count > 2 ? I18n.format("%1 and %2 more", [check.lines.slice(0, 2).join(" · "), check.count - 2])
                        : check.lines.join(" · ")
                    size: 14
                    tone: "fog"
                    elide: Text.ElideRight
                }
            }
            Item {
                id: checkAction
                anchors.right: parent.right
                anchors.rightMargin: Kiosk.px(20)
                anchors.verticalCenter: parent.verticalCenter
                width: childrenRect.width
                height: childrenRect.height
                KioskButton {
                    objectName: "readyAskAssistant"
                    visible: Assistant.agentReady && !(Doctor.report === null && !check.waiting)
                    small: true
                    kind: check.count > 0 ? "primary" : "ghost"
                    icon: "sparkles"
                    text: I18n.tr("Ask the assistant")
                    enabled: !Assistant.busy
                    onClicked: {
                        Welcome.stepAside(false);
                        Assistant.checkSystem();
                    }
                }
                KioskLink {
                    objectName: "readyConnectAssistant"
                    visible: Assistant.available && !Assistant.agentReady && !(Doctor.report === null && !check.waiting)
                    text: I18n.tr("Connect the assistant")
                    onClicked: Welcome.leave("connect")
                }
                KioskLink {
                    visible: Doctor.report === null && !check.waiting
                    text: I18n.tr("Try again")
                    onClicked: Doctor.refresh()
                }
            }
        }
        Item { width: 1; height: Kiosk.px(26) }
        KioskKicker {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: I18n.tr("Whenever you like · optional")
        }
        Item { width: 1; height: Kiosk.px(14) }
        // Up to five extras in one centred row, more in two balanced rows.
        Column {
            id: extras
            readonly property var items: Welcome.checklist
            readonly property int split: items.length <= 5 ? items.length : Math.ceil(items.length / 2)
            width: parent.width
            spacing: Kiosk.px(10)
            Repeater {
                model: extras.split < extras.items.length ? [extras.items.slice(0, extras.split), extras.items.slice(extras.split)]
                    : [extras.items]
                delegate: Row {
                    id: extraRow
                    required property var modelData
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: Kiosk.px(10)
                    Repeater {
                        model: extraRow.modelData
                        delegate: KioskChip {
                            required property var modelData
                            large: true
                            icon: root.glyphs[modelData.id] || "circle"
                            text: root.labels[modelData.id] || modelData.id
                            done: modelData.done === true
                            Accessible.name: done ? I18n.format("%1: %2", [text, I18n.tr("Done")]) : text
                            onClicked: {
                                Welcome.stepAside(false);
                                Settings.showPanel(modelData.page);
                            }
                        }
                    }
                }
            }
        }
        Item { width: 1; height: Kiosk.px(10) }
        KioskText {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: I18n.tr("Each one opens its page in Settings. The guide steps aside while you are there.")
            size: 14
            tone: "faint"
            wrapMode: Text.WordWrap
        }
        Item { width: 1; height: Kiosk.px(28) }
        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Kiosk.px(14)
            KioskButton {
                text: I18n.tr("Back")
                onClicked: Welcome.move(-1)
            }
            KioskButton {
                kind: "primary"
                text: I18n.tr("Start using Cybex OS")
                icon: "chevron_right"
                iconRight: true
                onClicked: Welcome.finish()
            }
        }
        Item { width: 1; height: Kiosk.px(14) }
        KioskText {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            visible: text !== ""
            text: Welcome.error
            size: 14
            tone: "red"
            wrapMode: Text.WordWrap
        }
    }
}
