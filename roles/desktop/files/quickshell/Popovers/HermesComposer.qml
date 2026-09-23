import QtQuick
import "../Common"

// Persistent per-conversation composer. Enter sends, Shift/Ctrl+Enter adds a line,
// slash commands travel through Hermes' slash worker/dispatcher pipeline, and a live turn swaps the
// primary action to Stop without discarding the next draft.
Rectangle {
    id: root

    required property string conversationId
    readonly property var conversation: conversationId === ""
        ? HermesConversations.newConversation
        : HermesConversations.conversationById(conversationId)
    readonly property bool working: conversation !== null && conversation.status === "working"
    readonly property bool blocked: conversation !== null && conversation.status === "attention"
    readonly property bool sending: Hermes.actionPending("prompt", conversationId, "")
        || conversationId === ""
            && Hermes.actionPending("conversation-create", "", "")
        || Hermes.actionKindPending("command", conversationId)
    readonly property bool stopping: Hermes.actionPending("interrupt", conversationId, "")
    readonly property bool steering: Hermes.actionPending("steer", conversationId, "")
    readonly property bool editable: Hermes.canOperate && conversation !== null
        && conversation.readOnly !== true && !sending
    readonly property bool overLimit: promptEdit.text.length > 120000
    readonly property var modelSelection: Hermes.modelSelection(conversationId)
    readonly property var reasoningState: Hermes.reasoningState(conversationId)
    readonly property var reasoningOptions: Hermes.reasoningOptions(conversationId)
    readonly property var stagedAttachments: Hermes.attachments(conversationId)
    readonly property bool selectorsEnabled: editable && !working && !sending
    // The model picker opens past the composer's lower edge. Its owner passes
    // this extent up to the popout host, which grows a transparent input tail
    // instead of forcing the menu back over the conversation.
    readonly property real modelPickerOverflowHeight: modelSelect.expanded
        ? modelSelect.popupHeight + 6 : 0
    readonly property Item modelPickerOverflowItem: modelSelect.expanded
        ? modelSelect.popupItem : null

    width: parent ? parent.width : 0
    height: composerContent.implicitHeight + 20
    radius: HermesTheme.composerRadius
    color: HermesTheme.composerGlass
    border.width: 1
    border.color: overLimit ? HermesTheme.redBorder
        : promptEdit.activeFocus ? HermesTheme.focus : HermesTheme.borderStrong

    Behavior on border.color {
        ColorAnimation { duration: HermesTheme.fastDuration }
    }

    function syncDraft() {
        const next = Hermes.draft(conversationId);
        if (promptEdit.text === next)
            return;
        promptEdit.syncing = true;
        promptEdit.text = next;
        promptEdit.cursorPosition = next.length;
        promptEdit.syncing = false;
    }

    function insertNewline() {
        const start = promptEdit.selectionStart;
        const end = promptEdit.selectionEnd;
        if (start !== end) {
            promptEdit.remove(start, end);
            promptEdit.cursorPosition = start;
        }
        const position = promptEdit.cursorPosition;
        promptEdit.insert(position, "\n");
        promptEdit.cursorPosition = position + 1;
    }

    function send() {
        if (!editable || working || overLimit || (promptEdit.text.trim() === ""
                && stagedAttachments.length === 0))
            return;
        Hermes.submit(conversationId, promptEdit.text);
    }

    // The picker runs in the Hermes singleton so a selection survives this
    // popover closing while the dialog has focus; the staged files come back
    // through Hermes.attachments(conversationId).
    function chooseAttachments() {
        if (!editable || working || Hermes.attachmentPickerRunning
                || Hermes.capabilities.attachments !== true)
            return;
        Hermes.pickAttachments(conversationId);
    }

    function steer() {
        if (!root.working || root.steering || promptEdit.text.trim() === "")
            return;
        Hermes.steer(conversationId, promptEdit.text);
    }

    function focusPrompt() {
        promptEdit.forceActiveFocus();
        promptEdit.cursorPosition = promptEdit.text.length;
    }

    onConversationIdChanged: {
        syncDraft();
        Hermes.loadReasoning(conversationId, false);
    }
    Component.onCompleted: {
        syncDraft();
        Hermes.loadReasoning(conversationId, false);
    }
    Component.onDestruction: Hermes.flushDrafts()

    Connections {
        target: HermesConversations
        function onDraftsChanged() { root.syncDraft(); }
    }

    Column {
        id: composerContent
        x: 10
        y: 10
        width: parent.width - 20
        spacing: 7

        Item {
            width: parent.width
            height: Math.max(58, Math.min(118, promptEdit.contentHeight + 8))

            Flickable {
                id: promptFlick
                anchors.fill: parent
                contentWidth: width
                contentHeight: Math.max(height, promptEdit.contentHeight)
                clip: true
                boundsBehavior: Flickable.StopAtBounds

                TextEdit {
                    id: promptEdit
                    property bool syncing: false

                    width: promptFlick.width
                    height: Math.max(promptFlick.height, contentHeight)
                    enabled: root.editable
                    wrapMode: TextEdit.Wrap
                    selectByMouse: true
                    Accessible.name: "Message Hermes in "
                        + (root.conversation?.title ?? "new chat")
                    Accessible.description: root.working
                        ? "Enter steers the active turn. Shift Enter inserts a newline."
                        : "Enter sends. Shift Enter inserts a newline."
                    font.family: HermesTheme.fontUi
                    font.pixelSize: Theme.typography.control
                    color: HermesTheme.textPrimary
                    selectionColor: HermesTheme.accentSoft
                    selectedTextColor: HermesTheme.textPrimary
                    onTextChanged: {
                        if (!syncing && activeFocus)
                            Hermes.setDraft(root.conversationId, text);
                    }
                    onCursorRectangleChanged: {
                        if (cursorRectangle.y + cursorRectangle.height
                                > promptFlick.contentY + promptFlick.height)
                            promptFlick.contentY = cursorRectangle.y
                                + cursorRectangle.height - promptFlick.height;
                        else if (cursorRectangle.y < promptFlick.contentY)
                            promptFlick.contentY = cursorRectangle.y;
                    }

                    Keys.onPressed: event => {
                        if (event.key !== Qt.Key_Return && event.key !== Qt.Key_Enter)
                            return;
                        if (event.modifiers & Qt.ShiftModifier
                                || event.modifiers & Qt.ControlModifier)
                            root.insertNewline();
                        else if (root.working)
                            root.steer();
                        else
                            root.send();
                        event.accepted = true;
                    }

                    Text {
                        visible: promptEdit.text === ""
                        text: root.conversation?.readOnly === true
                            ? "This conversation is read-only"
                            : root.blocked ? "Answer Hermes above…"
                            : root.working ? "Steer Hermes while it works…"
                            : !Hermes.connected ? "Hermes bridge is offline"
                                : !Hermes.bridgeReady ? "Waiting for Hermes…"
                                    : root.conversationId === ""
                                        ? "Message Hermes…"
                                        : "Continue this conversation…"
                        font.family: HermesTheme.fontUi
                        font.pixelSize: Theme.typography.primary
                        color: HermesTheme.textFaint
                    }
                }
            }
        }

        Flickable {
            id: attachmentTray
            visible: root.stagedAttachments.length > 0
            width: parent.width
            height: visible ? 28 : 0
            contentWidth: attachmentRow.implicitWidth
            contentHeight: height
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            Row {
                id: attachmentRow
                height: parent.height
                spacing: 5

                Repeater {
                    model: root.stagedAttachments.map(item => Object.assign({}, item, {
                        conversationId: root.conversationId,
                        canRemove: root.editable && !root.working
                    }))

                    delegate: Rectangle {
                        id: attachmentChip
                        required property var modelData

                        width: Math.min(190, attachmentName.implicitWidth + 38)
                        height: 26
                        radius: HermesTheme.controlRadius
                        color: Theme.chip
                        border.width: 1
                        border.color: HermesTheme.border

                        Sym {
                            id: attachmentGlyph
                            x: 7
                            anchors.verticalCenter: parent.verticalCenter
                            name: "attach_file"
                            size: Theme.iconSmall
                            color: HermesTheme.accent
                        }

                        Text {
                            id: attachmentName
                            anchors.left: attachmentGlyph.right
                            anchors.leftMargin: 5
                            anchors.right: removeAttachment.left
                            anchors.rightMargin: 3
                            anchors.verticalCenter: parent.verticalCenter
                            text: attachmentChip.modelData.name
                            elide: Text.ElideMiddle
                            font.family: HermesTheme.fontUi
                            font.pixelSize: Theme.typography.metadata
                            color: HermesTheme.textSecondary
                        }

                        IconButton {
                            id: removeAttachment
                            anchors.right: parent.right
                            anchors.rightMargin: 2
                            anchors.verticalCenter: parent.verticalCenter
                            controlSize: 22
                            symbol: "close"
                            accessibleName: "Remove " + attachmentChip.modelData.name
                            tint: HermesTheme.textFaint
                            enabled: attachmentChip.modelData.canRemove
                            onTriggered: Hermes.removeAttachment(
                                attachmentChip.modelData.conversationId,
                                attachmentChip.modelData.path)
                        }
                    }
                }
            }
        }

        Item {
            id: actionRow
            width: parent.width
            height: Theme.inlineActionHeight
            readonly property real trailingWidth: primaryButton.width
                + (steerButton.visible ? steerButton.width + 5 : 0)
                + (workingIndicator.visible ? workingIndicator.width + 8 : 0)

            Row {
                id: inlineSettings
                anchors.left: parent.left
                anchors.leftMargin: -6
                anchors.verticalCenter: parent.verticalCenter
                spacing: 3

                IconButton {
                    id: attachmentButton
                    visible: Hermes.capabilities.attachments === true
                    controlSize: 28
                    symbol: Hermes.attachmentPickerRunning
                        ? "progress_activity" : "attach_file"
                    accessibleName: "Attach files to Hermes"
                    tint: root.stagedAttachments.length > 0
                        ? HermesTheme.accent : HermesTheme.textMuted
                    enabled: root.editable && !root.working
                        && !Hermes.attachmentPickerRunning
                        && root.stagedAttachments.length < 20
                    onTriggered: root.chooseAttachments()
                }

                HermesModelPicker {
                    id: modelSelect
                    conversationId: root.conversationId
                    provider: root.modelSelection.provider
                    model: root.modelSelection.model
                    label: Hermes.modelLabel(provider, model)
                    openUpward: false
                    maxWidth: Math.max(92, actionRow.width - actionRow.trailingWidth
                        - (attachmentButton.visible ? attachmentButton.width + 4 : 0)
                        - (effortSelect.visible ? effortSelect.implicitWidth + 18 : 0))
                    enabled: root.selectorsEnabled && Hermes.modelGroups.length > 0
                    onSelected: (provider, model) =>
                        Hermes.setModel(root.conversationId, provider, model)
                }

                Item {
                    visible: effortSelect.visible
                    width: visible ? 11 : 0
                    height: 26

                    Rectangle {
                        anchors.centerIn: parent
                        width: 1
                        height: 14
                        color: HermesTheme.border
                    }
                }

                HermesInlineSelect {
                    id: effortSelect
                    visible: root.reasoningOptions.length > 1
                    text: "Reasoning"
                    symbol: "psychology"
                    value: String(root.reasoningState.effort ?? "")
                    options: root.reasoningOptions
                    menuWidth: 168
                    maxWidth: 96
                    enabled: root.selectorsEnabled
                    onSelected: value =>
                        Hermes.setReasoningEffort(root.conversationId, value)
                }
            }

            Sym {
                id: workingIndicator
                visible: root.working || root.sending
                anchors.right: steerButton.visible ? steerButton.left
                    : primaryButton.left
                anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                name: "progress_activity"
                size: Theme.iconLarge
                symWeight: 400
                color: HermesTheme.textFaint

                RotationAnimation on rotation {
                    running: workingIndicator.visible && !Theme.reducedMotion
                    from: 0
                    to: 360
                    duration: 1100
                    loops: Animation.Infinite
                }
            }

            ActionButton {
                id: steerButton
                visible: root.working && promptEdit.text.trim() !== ""
                anchors.right: primaryButton.left
                anchors.rightMargin: 5
                anchors.verticalCenter: parent.verticalCenter
                label: root.steering ? "Steering…" : "Steer"
                enabled: !root.steering
                fontFamily: HermesTheme.fontUi
                focusColor: HermesTheme.focus
                buttonRadius: HermesTheme.controlRadius
                tint: HermesTheme.accent
                fill: HermesTheme.accentSubtle
                onTriggered: root.steer()
            }

            Rectangle {
                id: primaryButton
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                width: Theme.inlineActionHeight
                height: width
                radius: width / 2
                color: root.working
                    ? (primaryMouse.containsMouse ? HermesTheme.dangerHover
                        : HermesTheme.danger)
                    : !primaryMouse.enabled ? Theme.accentAlpha(0.35)
                    : primaryMouse.containsMouse ? HermesTheme.accentHover
                        : HermesTheme.accent
                activeFocusOnTab: primaryMouse.enabled
                border.width: activeFocus ? 1 : 0
                border.color: HermesTheme.focus
                Accessible.role: Accessible.Button
                Accessible.name: root.working ? "Stop Hermes" : "Send to Hermes"
                Accessible.onPressAction: {
                    if (root.working)
                        Hermes.interrupt(root.conversationId);
                    else
                        root.send();
                }

                Keys.onPressed: event => {
                    if (!primaryMouse.enabled)
                        return;
                    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                            || event.key === Qt.Key_Space) {
                        if (root.working)
                            Hermes.interrupt(root.conversationId);
                        else
                            root.send();
                        event.accepted = true;
                    }
                }

                Sym {
                    visible: !root.working
                    anchors.centerIn: parent
                    name: root.sending ? "more_horiz" : "arrow_upward"
                    size: Theme.iconMedium
                    symWeight: 520
                    color: "white"
                }

                Rectangle {
                    visible: root.working && !root.stopping
                    anchors.centerIn: parent
                    width: 8
                    height: 8
                    radius: 2
                    color: HermesTheme.dangerForeground
                }

                Sym {
                    visible: root.working && root.stopping
                    anchors.centerIn: parent
                    name: "more_horiz"
                    size: Theme.iconMedium
                    color: HermesTheme.dangerForeground
                }

                MouseArea {
                    id: primaryMouse
                    anchors.fill: parent
                    enabled: root.working ? !root.stopping
                        : root.editable && !root.overLimit
                            && (promptEdit.text.trim() !== ""
                                || root.stagedAttachments.length > 0)
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        if (root.working)
                            Hermes.interrupt(root.conversationId);
                        else
                            root.send();
                    }
                }
            }
        }

        Text {
            visible: root.overLimit || promptEdit.text.startsWith("/")
            width: parent.width
            text: root.overLimit ? promptEdit.text.length + "/120000"
                : "Slash command"
            font.family: root.overLimit ? HermesTheme.fontMono : HermesTheme.fontUi
            font.pixelSize: Theme.typography.metadata
            color: root.overLimit ? HermesTheme.red : HermesTheme.accent
        }
    }
}
