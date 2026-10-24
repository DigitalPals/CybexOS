pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import "../Common"
import "../Common/AssistantHelpers.js" as AssistantHelpers

// Assistant: who answers, what it may see and hear, and how it looks
// (docs/assistant.md). The agents keep their own sign-in and settings; this
// page only chooses between them. Screen context and spoken replies are off
// until switched on here.
SettingsPage {
    id: page
    pageReset: true

    readonly property bool claudeInstalled: !!(Assistant.agents.claude && Assistant.agents.claude.available)
    readonly property bool codexInstalled: !!(Assistant.agents.codex && Assistant.agents.codex.available)

    function installedLabel(installed) {
        return !Assistant.connected ? "" : installed ? I18n.tr("installed") : I18n.tr("not installed");
    }

    Column {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Theme.settingsGroupSpacing

        SettingsGroup {
            width: parent.width
            title: I18n.tr("Assistant")

            ValueRow {
                width: parent.width
                label: I18n.tr("Status")
                value: !Settings.assistantConfigured ? I18n.tr("Not part of this installation")
                    : Assistant.connected && Assistant.setupRequired ? I18n.tr("Sign in to set up the assistant")
                    : Assistant.connected ? (Settings.assistantShown ? I18n.tr("Ready, on screen") : I18n.tr("Ready, hidden"))
                    : I18n.tr("The assistant service is not running")
                dotColor: Assistant.connected ? Theme.ok : Theme.textFaint

                SettingsAction {
                    visible: Settings.assistantConfigured && Assistant.connected
                    text: Settings.assistantShown ? I18n.tr("Hide") : I18n.tr("Show")
                    onTriggered: Assistant.toggleShown(Settings.panelScreenName)
                }
                SettingsAction {
                    visible: Settings.assistantConfigured && !Assistant.connected
                    text: I18n.tr("Start")
                    onTriggered: Quickshell.execDetached(["systemctl", "--user", "start", "nerdos-assistant.service"])
                }
            }
            SettingsHint {
                width: parent.width
                text: I18n.tr("Hover the character or tap Super+I to type. Hold Super+I to talk, and release to send.")
            }
        }

        SettingsGroup {
            width: parent.width
            title: I18n.tr("Agent")

            PickerRow {
                width: parent.width
                label: I18n.tr("Answered by")
                settingKey: "assistantAgent"
                model: [
                    { value: "auto", label: I18n.tr("Automatic") },
                    { value: "claude", label: "Claude Code" },
                    { value: "codex", label: "Codex" }
                ]
                caption: Settings.assistantAgent === "auto" && Assistant.connected
                    ? I18n.format("Now %1", [AssistantHelpers.AGENT_LABELS[Assistant.agent]]) : ""
                captionMono: false
            }
            SettingsHint {
                width: parent.width
                text: I18n.tr("Automatic follows your nerd agent default, then whichever is installed. Sign-in and permissions stay with the agent itself.")
            }
            ValueRow {
                width: parent.width
                label: I18n.tr("Sign-in")
                value: Assistant.authChecking ? I18n.tr("Checking sign-in…")
                    : Assistant.agentReady ? I18n.tr("Signed in") : I18n.tr("Sign-in required")
                SettingsAction {
                    text: Assistant.agentReady ? I18n.tr("Check sign-in") : I18n.tr("Sign in")
                    enabled: Assistant.connected && !Assistant.authChecking && !Assistant.busy
                    onTriggered: {
                        if (Assistant.agentReady)
                            Assistant.refreshAuth();
                        else {
                            Assistant.openComposer(true);
                            Assistant.refreshAuth();
                        }
                    }
                }
            }
            SelectRow {
                width: parent.width
                label: I18n.tr("Claude Code model")
                settingKey: "assistantClaudeModel"
                model: [{ value: "default", label: I18n.tr("Claude Code's default") },
                    { value: "fable", label: "Fable" }, { value: "sonnet", label: "Sonnet" },
                    { value: "opus", label: "Opus" }]
                hint: page.installedLabel(page.claudeInstalled)
            }
            SelectRow {
                width: parent.width
                label: I18n.tr("Codex model")
                settingKey: "assistantCodexModel"
                model: [{ value: "default", label: I18n.tr("Codex's default") },
                    { value: "gpt-5.6-luna", label: "Luna" }, { value: "gpt-5.6-terra", label: "Terra" },
                    { value: "gpt-5.6-sol", label: "Sol" }]
                hint: page.installedLabel(page.codexInstalled)
            }
        }

        SettingsGroup {
            width: parent.width
            title: I18n.tr("Voice and screen")

            SwitchRow {
                width: parent.width
                label: I18n.tr("Speak replies")
                settingKey: "assistantSpeak"
                description: Assistant.connected && !Assistant.speechAvailable
                    ? I18n.tr("Speech is unavailable: speech-dispatcher is not running.")
                    : I18n.tr("Reads each reply aloud and asks the agent to keep it short.")
            }
            SwitchRow {
                width: parent.width
                label: I18n.tr("Screen context")
                settingKey: "assistantScreenContext"
                description: I18n.tr("Adds a screen button to the box. It sends one screenshot of the display the assistant is on, without the assistant, with that question only, and deletes it afterwards.")
            }
            ValueRow {
                width: parent.width
                label: I18n.tr("Talking")
                value: Assistant.voiceAvailable ? I18n.tr("Voxtype, on this computer") : I18n.tr("Voxtype is not running")
                SettingsAction {
                    text: I18n.tr("Dictation settings")
                    onTriggered: Settings.openWidgetSettings("indicators")
                }
            }
        }

        SettingsGroup {
            width: parent.width
            title: I18n.tr("Character")

            PickerRow {
                width: parent.width
                label: I18n.tr("Look")
                settingKey: "assistantCharacter"
                model: [
                    { value: "mascot", label: I18n.tr("Mascot") },
                    { value: "mark", label: I18n.tr("Logo only") }
                ]
            }
            SettingsHint {
                width: parent.width
                text: Settings.assistantCharacter === "mark"
                    ? I18n.tr("The NerdOS glasses as they are; the ring around them shows what the assistant is doing.")
                    : I18n.tr("The glasses with eyes behind the lenses, which follow what the assistant is doing.")
            }
        }
    }
}
