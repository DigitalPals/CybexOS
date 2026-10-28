pragma ComponentBehavior: Bound
import QtQuick
import "../Common"
import "../Common/AssistantHelpers.js" as AssistantHelpers

// Connect: two optional sign-ins as installer cards. 1Password comes first,
// when it is installed, so it can fill in the AI account's password in the
// browser; then the assistant, through Claude Code's or Codex's own sign-in.
// Both open windows, so the guide steps aside: it comes back once the agent
// reports it is signed in, or when the 1Password window is closed. Ticks
// come from live state only; nothing here can tell that 1Password is
// signed in, so its card never shows one.
Item {
    id: root
    readonly property bool online: EthernetState.connected || WifiState.connected || NetworkStatus.online
    readonly property bool both: Welcome.passwordAvailable && Assistant.available
    readonly property var installed: AssistantHelpers.AGENT_IDS.filter(id => (Assistant.agents[id] || {}).available === true)
    readonly property bool signingIn: Assistant.signingIn !== ""
    readonly property bool authUnknown: Assistant.agentInstalled && (Assistant.agents[Assistant.agent] || {}).auth === "unknown"
    Claim { active: root.visible; onClaimed: EthernetState.acquire(); onReleased: EthernetState.release() }
    Component.onCompleted: Assistant.refreshAuth()

    component ConnectCard: KioskCard {
        id: card
        property string kicker: ""
        property string title: ""
        property string body: ""
        property string glyph: ""
        property string status: ""
        // accent (done), amber (needs something) or fog (waiting).
        property string statusTone: "fog"
        property string statusGlyph: ""
        default property alias actions: actionRow.data
        readonly property real contentHeight: texts.implicitHeight + actionRow.height + Kiosk.px(28 * 2 + 24)
        Column {
            id: texts
            x: Kiosk.px(28)
            y: Kiosk.px(28)
            width: card.width - Kiosk.px(56)
            Row {
                width: parent.width
                spacing: Kiosk.px(16)
                Rectangle {
                    id: badge
                    width: Kiosk.px(48)
                    height: width
                    radius: Kiosk.px(14)
                    color: Kiosk.accentTint
                    KioskIcon { anchors.centerIn: parent; name: card.glyph; designSize: 24; color: Kiosk.accent }
                }
                Column {
                    width: parent.width - badge.width - parent.spacing
                    anchors.verticalCenter: parent.verticalCenter
                    KioskKicker { width: parent.width; text: card.kicker; elide: Text.ElideRight }
                    Item { width: 1; height: Kiosk.px(4) }
                    KioskText {
                        width: parent.width
                        text: card.title
                        size: 22
                        font.weight: Font.Bold
                        elide: Text.ElideRight
                        Accessible.role: Accessible.Heading
                    }
                }
            }
            Item { width: 1; height: Kiosk.px(18) }
            KioskText { width: parent.width; text: card.body; size: 16; tone: "fog"; wrapMode: Text.WordWrap }
            Item { width: 1; height: Kiosk.px(16); visible: card.status !== "" }
            Row {
                visible: card.status !== ""
                width: parent.width
                spacing: Kiosk.px(10)
                KioskIcon {
                    id: statusIcon
                    name: card.statusGlyph
                    designSize: 18
                    color: card.statusTone === "accent" ? Kiosk.accent : card.statusTone === "amber" ? Kiosk.amber : Kiosk.fog
                }
                KioskText {
                    width: parent.width - statusIcon.width - parent.spacing
                    text: card.status
                    size: 15
                    tone: card.statusTone === "fog" ? "ink" : card.statusTone
                    wrapMode: Text.WordWrap
                }
            }
        }
        Flow {
            id: actionRow
            x: Kiosk.px(28)
            anchors.bottom: parent.bottom
            anchors.bottomMargin: Kiosk.px(28)
            width: card.width - Kiosk.px(56)
            spacing: Kiosk.px(12)
        }
    }

    Column {
        id: heading
        x: Kiosk.px(64)
        y: Kiosk.px(34)
        width: parent.width - Kiosk.px(128)
        spacing: Kiosk.px(8)
        KioskText {
            width: parent.width
            text: I18n.tr("Connect your accounts.")
            size: 40
            font.weight: Font.Bold
            font.letterSpacing: -Kiosk.px(1)
            elide: Text.ElideRight
            Accessible.role: Accessible.Heading
        }
        KioskText {
            width: parent.width
            text: root.both ? I18n.tr("Both are optional. Start with 1Password, so it can fill in the password for your AI account.")
                : Assistant.available ? I18n.tr("Optional, and recommended: your assistant can then check this computer and help with what it finds.")
                : I18n.tr("Optional: sign in to 1Password if you use it.")
            size: 19
            tone: "fog"
            wrapMode: Text.WordWrap
        }
    }

    // Both sign-ins need the internet; say so before a button fails.
    Rectangle {
        id: offline
        x: Kiosk.px(64)
        anchors.top: heading.bottom
        anchors.topMargin: Kiosk.px(20)
        width: parent.width - Kiosk.px(128)
        height: root.online ? 0 : Kiosk.px(52)
        visible: !root.online
        radius: Kiosk.px(12)
        color: Kiosk.amberTint
        border.width: Math.max(1, Kiosk.px(1))
        border.color: Kiosk.amberLine
        Row {
            x: Kiosk.px(18)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Kiosk.px(12)
            KioskIcon { anchors.verticalCenter: parent.verticalCenter; name: "wifi_off"; color: Kiosk.amber }
            KioskText {
                anchors.verticalCenter: parent.verticalCenter
                text: I18n.tr("You are offline. Connect to a network to sign in.")
                size: 15
                tone: "amber"
            }
            KioskLink {
                anchors.verticalCenter: parent.verticalCenter
                text: I18n.tr("Connect")
                Accessible.name: I18n.tr("Connect to a network")
                onClicked: {
                    Welcome.stepAside(false);
                    Settings.showPanel("network");
                }
            }
        }
    }

    Row {
        id: cards
        // Both cards share the taller one's height, so their buttons line up.
        readonly property real cardHeight: Math.max(Kiosk.px(260), passwordCard.visible ? passwordCard.contentHeight : 0,
            assistantCard.visible ? assistantCard.contentHeight : 0)
        readonly property real cardWidth: root.both ? (root.width - Kiosk.px(128) - spacing) / 2 : Kiosk.px(720)
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: offline.bottom
        anchors.topMargin: Kiosk.px(root.online ? 8 : 24)
        spacing: Kiosk.px(24)

        ConnectCard {
            id: passwordCard
            visible: Welcome.passwordAvailable
            width: cards.cardWidth
            height: cards.cardHeight
            glyph: "lock"
            kicker: root.both ? I18n.format("%1 · %2", ["01", I18n.tr("Password manager")]) : I18n.tr("Password manager")
            title: "1Password" // i18n: untranslated (brand)
            body: I18n.tr("If you use 1Password, sign in first. It can then fill in your passwords for what follows, including your AI account.")
            status: Welcome.passwordOpened ? I18n.tr("1Password is open. Sign in there, then close its window to come back.") : ""
            statusGlyph: "open_in_new"
            KioskButton {
                objectName: "connectPassword"
                kind: Welcome.passwordOpened ? "ghost" : "primary"
                text: Welcome.passwordOpened ? I18n.tr("Open 1Password again") : I18n.tr("Open 1Password")
                onClicked: Welcome.openPassword()
            }
        }

        ConnectCard {
            id: assistantCard
            visible: Assistant.available
            width: cards.cardWidth
            height: cards.cardHeight
            glyph: "sparkles"
            kicker: root.both ? I18n.format("%1 · %2", ["02", I18n.tr("AI assistant · recommended")]) : I18n.tr("AI assistant · recommended")
            title: I18n.tr("Cybex OS Assistant")
            body: I18n.tr("Sign in with Claude Code or Codex. Your assistant can then check this computer for missing drivers and other problems, and fix what it finds once you agree.")
            status: !Assistant.connected ? I18n.tr("The assistant service is not running.")
                : root.installed.length === 0 ? I18n.tr("Claude Code and Codex are not installed. Add one in Software.")
                : Assistant.agentReady ? I18n.format("Connected with %1.", [Assistant.agentLabel])
                : root.signingIn ? I18n.tr("Finish signing in in the terminal and browser. The guide comes back by itself.")
                : root.authUnknown ? I18n.tr("Sign-in status could not be checked.")
                : ""
            statusTone: Assistant.connected && Assistant.agentReady ? "accent" : root.signingIn ? "fog" : "amber"
            statusGlyph: Assistant.connected && Assistant.agentReady ? "check" : root.signingIn ? "progress_activity" : "warning"

            KioskButton {
                visible: !Assistant.connected
                kind: "primary"
                text: I18n.tr("Start the assistant")
                onClicked: Assistant.fix("service")
            }
            KioskButton {
                visible: Assistant.connected && root.installed.length === 0
                text: I18n.tr("Open Software")
                onClicked: {
                    Welcome.stepAside(false);
                    Software.show();
                }
            }
            // One button per installed agent. The one in use when signed in
            // is not repeated; another signed-in agent can be chosen instead.
            Repeater {
                model: Assistant.connected ? root.installed : []
                delegate: KioskButton {
                    id: agentButton
                    required property string modelData
                    required property int index
                    readonly property bool ready: (Assistant.agents[modelData] || {}).auth === "ready"
                    readonly property string label: AssistantHelpers.AGENT_LABELS[modelData] || modelData
                    objectName: "connectAgent-" + modelData
                    visible: !(Assistant.agentReady && Assistant.agent === modelData)
                    kind: !Assistant.agentReady && index === 0 ? "primary" : "ghost"
                    enabled: !Assistant.authChecking && !root.signingIn && !Assistant.busy
                    text: ready ? I18n.format("Use %1", [label]) : I18n.format("Sign in to %1", [label])
                    onClicked: {
                        if (agentButton.ready)
                            Settings.set("assistantAgent", agentButton.modelData);
                        else
                            Welcome.signIn(agentButton.modelData);
                    }
                }
            }
            KioskButton {
                visible: Assistant.connected && (root.signingIn || root.authUnknown)
                small: true
                text: Assistant.authChecking ? I18n.tr("Checking sign-in…") : I18n.tr("Check sign-in")
                enabled: !Assistant.authChecking
                onClicked: Assistant.refreshAuth()
            }
        }
    }

    KioskText {
        anchors.top: cards.bottom
        anchors.topMargin: Kiosk.px(16)
        anchors.horizontalCenter: parent.horizontalCenter
        width: cards.width
        text: Assistant.available ? I18n.tr("Your sign-in stays with Claude Code or Codex; Cybex OS never stores it. A check sends what it finds to your AI provider only when you ask.")
            : I18n.tr("Your passwords stay in 1Password; Cybex OS never sees them.")
        size: 14
        tone: "faint"
        wrapMode: Text.WordWrap
    }

    KioskFooter {
        anchors.bottom: parent.bottom
        width: parent.width
        onNext: Welcome.move(1)
        KioskText {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            text: Welcome.error !== "" ? Welcome.error : I18n.tr("You can sign in later too, from the assistant’s menubar button.")
            size: 14
            tone: Welcome.error !== "" ? "red" : "faint"
            elide: Text.ElideRight
        }
    }
}
