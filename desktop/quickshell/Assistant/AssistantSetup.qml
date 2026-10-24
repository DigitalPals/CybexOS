pragma ComponentBehavior: Bound
import QtQuick
import "../Common"
import "../Common/AssistantHelpers.js" as AssistantHelpers

Column {
    id: root
    spacing: Theme.scaled(10)

    Text {
        width: parent.width
        text: I18n.tr("Let’s connect your assistant")
        color: Theme.textHi
        font.family: Theme.fontMenu
        font.pixelSize: Theme.typography.control
        font.weight: Theme.weightSemibold
        wrapMode: Text.Wrap
    }

    Text {
        width: parent.width
        text: Assistant.signingIn !== ""
            ? I18n.tr("Finish signing in in the terminal and browser. This box will update when you’re connected.")
            : I18n.tr("Choose Claude Code or Codex and sign in to your account. Then you can ask your first question.")
        color: Theme.textMid
        font.family: Theme.fontMenu
        font.pixelSize: Theme.typography.secondary
        wrapMode: Text.Wrap
    }

    Repeater {
        model: AssistantHelpers.AGENT_IDS
        delegate: Column {
            id: account
            required property string modelData
            readonly property var agent: Assistant.agents[modelData] || ({})
            width: root.width
            spacing: Theme.scaled(4)

            AssistantButton {
                label: account.agent.auth === "ready"
                    ? I18n.format("Use %1", [AssistantHelpers.AGENT_LABELS[account.modelData]])
                    : I18n.format("Sign in to %1", [AssistantHelpers.AGENT_LABELS[account.modelData]])
                primary: Assistant.agent === account.modelData
                enabled: account.agent.available === true && !Assistant.authChecking
                    && Assistant.signingIn === ""
                onTriggered: {
                    if (account.agent.auth === "ready")
                        Settings.set("assistantAgent", account.modelData);
                    else
                        Assistant.signIn(account.modelData);
                }
            }

            Text {
                width: parent.width
                visible: account.agent.available !== true || account.agent.auth === "unknown"
                text: account.agent.available !== true ? I18n.tr("Not installed. Add it in Software.")
                    : I18n.tr("Sign-in status could not be checked. Try again.")
                color: Theme.textLow
                font.family: Theme.fontMenu
                font.pixelSize: Theme.typography.metadata
                wrapMode: Text.Wrap
            }
        }
    }

    Flow {
        width: parent.width
        spacing: Theme.scaled(6)

        AssistantButton {
            label: Assistant.authChecking ? I18n.tr("Checking sign-in…") : I18n.tr("Check sign-in")
            enabled: !Assistant.authChecking
            onTriggered: Assistant.refreshAuth()
        }
        AssistantButton {
            visible: !AssistantHelpers.anyAgent(Assistant.agents)
            label: I18n.tr("Open Software")
            onTriggered: Software.show()
        }
        AssistantButton {
            label: I18n.tr("Close")
            onTriggered: Assistant.closeComposer()
        }
    }

    Text {
        width: parent.width
        visible: Assistant.notice !== "" || Assistant.draft.trim() !== ""
        text: Assistant.notice || I18n.tr("Your question is kept here until you’re signed in.")
        color: Theme.textLow
        font.family: Theme.fontMenu
        font.pixelSize: Theme.typography.metadata
        wrapMode: Text.Wrap
        textFormat: Text.PlainText
    }
}
