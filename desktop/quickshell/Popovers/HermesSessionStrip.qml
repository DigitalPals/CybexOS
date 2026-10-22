import QtQuick
import "../Common"

// Session context docks to the composer like T3's task strip: useful state is
// close to the next action without becoming a second header above the transcript.
Item {
    id: root

    required property string conversationId
    property bool expanded: false
    property bool forceCompact: false
    signal focusFallbackRequested()
    readonly property var sessionState:
        HermesConversations.sessionStateFor(conversationId)
    readonly property bool hasState: sessionState.warning !== ""
        || sessionState.goalMessage !== "" || sessionState.todos.length > 0
        || sessionState.pendingSteer !== "" || sessionState.background !== ""
        || sessionState.reasoning !== ""
        || Object.keys(sessionState.context).length > 0
        || Object.keys(sessionState.usage).length > 0
    readonly property bool expandable: sessionState.reasoning !== ""
        && !forceCompact

    width: parent ? parent.width : 0
    height: hasState ? strip.height : 0
    visible: hasState

    onForceCompactChanged: if (forceCompact) expanded = false
    onExpandableChanged: if (!expandable && strip.activeFocus)
        focusFallbackRequested()

    function compactNumber(value) {
        const amount = Number(value) || 0;
        if (amount >= 1000000)
            return (amount / 1000000).toFixed(amount >= 10000000 ? 0 : 1) + "m";
        if (amount >= 1000)
            return (amount / 1000).toFixed(amount >= 10000 ? 0 : 1) + "k";
        return String(Math.max(0, Math.round(amount)));
    }

    function summary() {
        if (sessionState.warning !== "")
            return sessionState.warning;
        if (sessionState.pendingSteer !== "")
            return "Steering saved for the next turn";
        if (sessionState.goalMessage !== "")
            return sessionState.goalMessage;
        const todo = sessionState.todoSummary ?? ({});
        const total = Number(todo.total) || sessionState.todos.length;
        if (total > 0)
            return String(Number(todo.completed) || 0) + " of " + total
                + " tasks complete";
        const context = sessionState.context ?? ({});
        const used = Number(context.lastPromptTokens ?? context.last_prompt_tokens) || 0;
        const length = Number(context.contextLength ?? context.context_length) || 0;
        if (used > 0 && length > 0)
            return "Context " + Math.min(100, Math.round(used / length * 100)) + "%";
        const usage = sessionState.usage ?? ({});
        const tokens = Number(usage.total_tokens)
            || Number(usage.input_tokens) + Number(usage.output_tokens);
        if (tokens > 0)
            return compactNumber(tokens) + " tokens this turn";
        if (sessionState.reasoningActive)
            return "Hermes is reasoning…";
        if (sessionState.reasoning !== "")
            return "Reasoning available";
        return sessionState.background;
    }

    Rectangle {
        id: strip
        anchors.horizontalCenter: parent.horizontalCenter
        width: Math.max(0, parent.width - 36)
        height: stripColumn.implicitHeight + 10
        radius: HermesTheme.panelRadius
        color: root.sessionState.warning !== "" ? HermesTheme.redSoft
            : HermesTheme.surfaceRaised
        border.width: 1
        border.color: activeFocus ? HermesTheme.focus
            : root.sessionState.warning !== "" ? HermesTheme.redBorder
            : HermesTheme.border
        activeFocusOnTab: root.expandable
        Accessible.role: root.expandable ? Accessible.Button
            : Accessible.StaticText
        Accessible.name: root.summary()
        Accessible.onPressAction: if (root.expandable) root.expanded = !root.expanded

        Keys.onPressed: event => {
            if (!root.expandable)
                return;
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                    || event.key === Qt.Key_Space) {
                root.expanded = !root.expanded;
                event.accepted = true;
            }
        }

        Column {
            id: stripColumn
            x: 8
            y: 5
            width: parent.width - 16
            spacing: 5

            Row {
                width: parent.width
                spacing: 7

                Sym {
                    name: root.sessionState.warning !== "" ? "warning"
                        : root.sessionState.goalMessage !== "" ? "flag"
                            : root.sessionState.todos.length > 0 ? "checklist"
                                : root.sessionState.reasoningActive
                                    ? "psychology" : "info"
                    size: Theme.iconSmall
                    color: root.sessionState.warning !== "" ? HermesTheme.red
                        : HermesTheme.accent
                }

                Text {
                    width: parent.width - 40
                    text: root.summary()
                    elide: Text.ElideRight
                    font.family: HermesTheme.fontUi
                    font.pixelSize: Theme.typography.secondary
                    color: root.sessionState.warning !== "" ? HermesTheme.red
                        : HermesTheme.textSecondary
                }

                Sym {
                    visible: root.expandable
                    name: root.expanded ? "expand_less" : "expand_more"
                    size: Theme.iconSmall
                    color: HermesTheme.textFaint
                }
            }

            Text {
                visible: root.expanded && root.expandable
                width: parent.width
                text: root.sessionState.reasoning
                textFormat: Text.PlainText
                wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                maximumLineCount: 10
                elide: Text.ElideRight
                font.family: HermesTheme.fontMono
                font.pixelSize: Theme.typography.metadata
                color: HermesTheme.textFaint
            }
        }

        MouseArea {
            anchors.fill: parent
            enabled: root.expandable
            cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: root.expanded = !root.expanded
        }
    }
}
