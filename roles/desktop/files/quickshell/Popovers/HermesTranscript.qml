pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import "../Common"
import "../Common/HermesHelpers.js" as Helpers

// The transcript is prose-only. Tool protocol records are projected away from
// chat and collapsed into one ephemeral activity line that follows the newest
// call while Hermes is working.
Item {
    id: root

    required property string conversationId
    property int maxHeight: 390
    property int minHeight: 140
    property int visibleItems: 50
    property bool followTail: true
    property real pendingPrependHeight: -1
    signal errorHandled()

    readonly property var conversation: conversationId === ""
        ? HermesConversations.newConversation
        : HermesConversations.conversationById(conversationId)
    readonly property var allMessages: HermesConversations.messagesFor(conversationId)
    readonly property var allTools: HermesConversations.toolsFor(conversationId)
    readonly property var allItems: Helpers.transcriptItems(allMessages, [])
    readonly property int hiddenCount: Math.max(0, allItems.length - visibleItems)
    readonly property var shownItems: hiddenCount > 0
        ? allItems.slice(hiddenCount) : allItems
    readonly property var history: HermesConversations.historyFor(conversationId)
    readonly property var latestTool: allTools.length > 0
        ? allTools[allTools.length - 1] : null
    readonly property bool working: conversation !== null
        && conversation.status === "working"
    readonly property string latestAssistantId: {
        for (let index = allMessages.length - 1; index >= 0; index--)
            if (allMessages[index].role === "assistant")
                return String(allMessages[index].id ?? "");
        return "";
    }

    width: parent ? parent.width : 0
    height: Math.max(minHeight, Math.min(maxHeight, transcriptColumn.implicitHeight
        + errorBanner.height + (errorBanner.visible ? 5 : 0)))

    function scrollToEnd(force) {
        if (!followTail && force !== true)
            return;
        Qt.callLater(() => {
            if (root.followTail || force === true)
                transcriptFlick.contentY = Math.max(0,
                    transcriptFlick.contentHeight - transcriptFlick.height);
        });
    }

    function showEarlier() {
        followTail = false;
        if (hiddenCount > 0) {
            const oldHeight = transcriptFlick.contentHeight;
            visibleItems += 50;
            Qt.callLater(() => {
                transcriptFlick.contentY = Math.max(0, transcriptFlick.contentY
                    + transcriptFlick.contentHeight - oldHeight);
            });
            return;
        }
        if (history.hasMore === true && history.loadingEarlier !== true) {
            pendingPrependHeight = transcriptFlick.contentHeight;
            HermesConversations.loadEarlier(conversationId);
        }
    }

    onConversationIdChanged: {
        visibleItems = 50;
        followTail = true;
        pendingPrependHeight = -1;
        scrollToEnd(true);
    }
    onHeightChanged: scrollToEnd(false)

    Connections {
        target: HermesConversations
        function onTranscriptChanged(changedConversationId) {
            if (changedConversationId !== root.conversationId)
                return;
            if (root.pendingPrependHeight >= 0) {
                const oldHeight = root.pendingPrependHeight;
                root.pendingPrependHeight = -1;
                Qt.callLater(() => {
                    transcriptFlick.contentY = Math.max(0,
                        transcriptFlick.contentY + transcriptFlick.contentHeight - oldHeight);
                });
                return;
            }
            root.scrollToEnd(false);
        }
        function onToolsByConversationChanged() { root.scrollToEnd(false); }
    }

    Flickable {
        id: transcriptFlick
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: errorBanner.visible ? errorBanner.top : parent.bottom
        anchors.bottomMargin: errorBanner.visible ? 5 : 0
        contentWidth: width
        contentHeight: transcriptColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        onMovementEnded: root.followTail = contentY + height >= contentHeight - 36

        Column {
            id: transcriptColumn
            width: transcriptFlick.width
            spacing: 5

            ActionButton {
                visible: root.hiddenCount > 0 || root.history.hasMore === true
                    || root.history.loadingEarlier === true
                anchors.horizontalCenter: parent.horizontalCenter
                label: root.history.loadingEarlier ? "Loading earlier history…"
                    : root.hiddenCount > 0
                        ? "Show " + Math.min(50, root.hiddenCount) + " earlier"
                        : "Load earlier history"
                enabled: root.history.loadingEarlier !== true
                fontFamily: HermesTheme.fontUi
                focusColor: HermesTheme.focus
                buttonRadius: HermesTheme.controlRadius
                tint: HermesTheme.textMuted
                fill: HermesTheme.hover
                onTriggered: root.showEarlier()
            }

            Repeater {
                model: root.shownItems

                delegate: Item {
                    id: timelineRow
                    required property var modelData
                    required property int index

                    readonly property var message: modelData.message ?? ({})
                    readonly property string messageText: String(message.text ?? "")
                    readonly property bool fromUser: message.role === "user"
                    readonly property bool fromSystem: message.role === "system"
                    readonly property bool continuation: index > 0
                        && root.shownItems[index - 1].message.role === message.role
                    readonly property bool hovered: messageHover.hovered || activeFocus
                    readonly property bool longMessage: messageText.length > 1200
                        || messageText.split("\n").length > 12
                    readonly property bool writable: root.conversationId !== ""
                        && root.conversation?.readOnly !== true && !root.working
                        && !message.streaming
                    readonly property bool editPending: Hermes.actionPending("edit",
                        root.conversationId, String(message.id ?? ""))
                    readonly property bool regenerationPending:
                        Hermes.actionPending("regenerate", root.conversationId, "")
                    property bool expanded: false
                    property bool editing: false

                    function submitEdit() {
                        if (editPending || editArea.text.trim() === "")
                            return;
                        Hermes.editMessage(root.conversationId, message,
                            editArea.text, () => timelineRow.editing = false);
                    }

                    width: parent.width
                    height: messageColumn.implicitHeight + 12
                    activeFocusOnTab: true
                    Accessible.role: Accessible.StaticText
                    Accessible.name: (fromUser ? "You"
                        : fromSystem ? "System" : "Hermes") + ": "
                        + (messageText || "working")

                    HoverHandler { id: messageHover }

                    Rectangle {
                        anchors.top: parent.top
                        x: 2
                        width: parent.width - 4
                        height: 1
                        color: HermesTheme.border
                    }

                    Column {
                        id: messageColumn
                        x: 3
                        y: 8
                        width: parent.width - 6
                        spacing: 5

                        Item {
                            width: parent.width
                            height: Theme.sectionHeaderHeight

                            Text {
                                anchors.left: parent.left
                                anchors.verticalCenter: parent.verticalCenter
                                visible: !timelineRow.continuation
                                text: timelineRow.fromUser ? "YOU"
                                    : timelineRow.fromSystem ? "SYSTEM" : "HERMES"
                                font.family: HermesTheme.fontUi
                                font.pixelSize: Theme.typography.metadata
                                font.weight: Theme.weightSemibold
                                font.letterSpacing: 1
                                color: timelineRow.fromUser || timelineRow.fromSystem
                                    ? HermesTheme.textFaint : HermesTheme.accent
                            }

                            Row {
                                id: messageActions
                                visible: timelineRow.hovered || timelineRow.editing
                                anchors.right: messageTime.left
                                anchors.rightMargin: 2
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 0

                                IconButton {
                                    visible: timelineRow.fromUser
                                        && Hermes.capabilities.messageEditing === true
                                    controlSize: Theme.chipInnerHeight
                                    symbol: timelineRow.editPending
                                        ? "more_horiz" : "edit"
                                    accessibleName: "Edit and resend message"
                                    tint: HermesTheme.textFaint
                                    enabled: timelineRow.writable
                                        && !timelineRow.editPending
                                    onTriggered: {
                                        timelineRow.editing = true;
                                        editArea.text = timelineRow.messageText;
                                        Qt.callLater(() => {
                                            editArea.forceActiveFocus();
                                            editArea.cursorPosition = editArea.text.length;
                                        });
                                    }
                                }

                                IconButton {
                                    visible: !timelineRow.fromSystem
                                        && Hermes.capabilities.branches === true
                                    controlSize: Theme.chipInnerHeight
                                    symbol: "call_split"
                                    accessibleName: "Branch conversation from here"
                                    tint: HermesTheme.textFaint
                                    enabled: timelineRow.writable
                                        && Number(timelineRow.message.sourceIndex) >= 0
                                    onTriggered: Hermes.branchConversation(
                                        root.conversationId,
                                        Number(timelineRow.message.sourceIndex) + 1)
                                }

                                IconButton {
                                    visible: !timelineRow.fromUser
                                        && !timelineRow.fromSystem
                                        && String(timelineRow.message.id ?? "")
                                            === root.latestAssistantId
                                        && Hermes.capabilities.regeneration === true
                                    controlSize: Theme.chipInnerHeight
                                    symbol: timelineRow.regenerationPending
                                        ? "more_horiz" : "refresh"
                                    accessibleName: "Regenerate Hermes response"
                                    tint: HermesTheme.textFaint
                                    enabled: timelineRow.writable
                                        && !timelineRow.regenerationPending
                                    onTriggered: Hermes.regenerate(root.conversationId)
                                }

                                IconButton {
                                    controlSize: Theme.chipInnerHeight
                                    symbol: "content_copy"
                                    accessibleName: "Copy message"
                                    tint: HermesTheme.textFaint
                                    onTriggered: Quickshell.clipboardText =
                                        timelineRow.messageText
                                }
                            }

                            Text {
                                id: messageTime
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                text: timelineRow.message.streaming ? "streaming…"
                                    : Hermes.relativeTime(timelineRow.message.updatedAt
                                        || timelineRow.message.createdAt)
                                font.family: HermesTheme.fontUi
                                font.pixelSize: Theme.typography.metadata
                                font.features: HermesTheme.tabularNumberFeatures
                                color: HermesTheme.textFaint
                            }
                        }

                        Text {
                            id: messageBody
                            visible: !timelineRow.editing
                            width: parent.width
                            text: timelineRow.messageText !== ""
                                ? timelineRow.messageText
                                : timelineRow.message.streaming ? "Hermes is working…" : ""
                            textFormat: timelineRow.fromUser
                                ? Text.PlainText : Text.MarkdownText
                            wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                            lineHeight: Theme.proseLineHeight
                            maximumLineCount: timelineRow.expanded
                                || timelineRow.message.streaming ? 100000 : 14
                            elide: timelineRow.expanded || timelineRow.message.streaming
                                ? Text.ElideNone : Text.ElideRight
                            font.family: HermesTheme.fontUi
                            font.pixelSize: Theme.typography.secondary
                            color: timelineRow.message.error !== ""
                                ? HermesTheme.red
                                : timelineRow.fromUser ? HermesTheme.textPrimary
                                    : HermesTheme.textSecondary
                            onLinkActivated: link => Hermes.openExternalUrl(link)
                        }

                        Rectangle {
                            visible: timelineRow.editing
                            width: parent.width
                            height: visible ? Math.max(96,
                                Math.min(190, editArea.contentHeight + 45)) : 0
                            radius: HermesTheme.controlRadius
                            color: HermesTheme.composerGlass
                            border.width: 1
                            border.color: editArea.activeFocus
                                ? HermesTheme.focus : HermesTheme.borderStrong

                            Flickable {
                                id: editFlick
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.top: parent.top
                                anchors.bottom: editActions.top
                                anchors.margins: 7
                                contentWidth: width
                                contentHeight: Math.max(height, editArea.contentHeight)
                                clip: true
                                boundsBehavior: Flickable.StopAtBounds

                                TextEdit {
                                    id: editArea
                                    width: editFlick.width
                                    height: Math.max(editFlick.height, contentHeight)
                                    enabled: !timelineRow.editPending
                                    wrapMode: TextEdit.Wrap
                                    selectByMouse: true
                                    font.family: HermesTheme.fontUi
                                    font.pixelSize: Theme.typography.control
                                    color: HermesTheme.textPrimary
                                    selectionColor: HermesTheme.accentSoft
                                    selectedTextColor: HermesTheme.textPrimary
                                    Accessible.name: "Edited Hermes message"

                                    Keys.onPressed: event => {
                                        if (event.key === Qt.Key_Escape) {
                                            timelineRow.editing = false;
                                            event.accepted = true;
                                        } else if ((event.key === Qt.Key_Return
                                                || event.key === Qt.Key_Enter)
                                                && (event.modifiers
                                                    & Qt.ControlModifier)) {
                                            timelineRow.submitEdit();
                                            event.accepted = true;
                                        }
                                    }
                                }
                            }

                            Row {
                                id: editActions
                                anchors.right: parent.right
                                anchors.rightMargin: 6
                                anchors.bottom: parent.bottom
                                anchors.bottomMargin: 5
                                spacing: 5

                                ActionButton {
                                    label: "Cancel"
                                    hPadding: 12
                                    enabled: !timelineRow.editPending
                                    fontFamily: HermesTheme.fontUi
                                    focusColor: HermesTheme.focus
                                    buttonRadius: HermesTheme.controlRadius
                                    tint: HermesTheme.textMuted
                                    fill: HermesTheme.hover
                                    onTriggered: timelineRow.editing = false
                                }

                                ActionButton {
                                    id: saveEdit
                                    label: timelineRow.editPending
                                        ? "Sending…" : "Save & resend"
                                    hPadding: 12
                                    enabled: !timelineRow.editPending
                                        && editArea.text.trim() !== ""
                                    fontFamily: HermesTheme.fontUi
                                    focusColor: HermesTheme.focus
                                    buttonRadius: HermesTheme.controlRadius
                                    tint: HermesTheme.accent
                                    fill: HermesTheme.accentSubtle
                                    onTriggered: timelineRow.submitEdit()
                                }
                            }
                        }

                        Flickable {
                            visible: Array.isArray(timelineRow.message.attachments)
                                && timelineRow.message.attachments.length > 0
                            width: parent.width
                            height: visible ? 25 : 0
                            contentWidth: persistedAttachmentRow.implicitWidth
                            contentHeight: height
                            clip: true
                            boundsBehavior: Flickable.StopAtBounds

                            Row {
                                id: persistedAttachmentRow
                                height: parent.height
                                spacing: 5

                                Repeater {
                                    model: timelineRow.message.attachments ?? []

                                    delegate: Rectangle {
                                        id: persistedAttachment
                                        required property var modelData
                                        width: Math.min(190,
                                            persistedAttachmentLabel.implicitWidth + 26)
                                        height: 24
                                        radius: HermesTheme.controlRadius
                                        color: Theme.chip
                                        border.width: 1
                                        border.color: HermesTheme.border

                                        Sym {
                                            id: persistedAttachmentGlyph
                                            x: 6
                                            anchors.verticalCenter: parent.verticalCenter
                                            name: persistedAttachment.modelData.isImage
                                                ? "image" : "attach_file"
                                            size: Theme.iconSmall
                                            color: HermesTheme.accent
                                        }

                                        Text {
                                            id: persistedAttachmentLabel
                                            anchors.left: persistedAttachmentGlyph.right
                                            anchors.leftMargin: 4
                                            anchors.right: parent.right
                                            anchors.rightMargin: 6
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: persistedAttachment.modelData.name
                                            elide: Text.ElideMiddle
                                            font.family: HermesTheme.fontUi
                                            font.pixelSize: Theme.typography.metadata
                                            color: HermesTheme.textSecondary
                                        }
                                    }
                                }
                            }
                        }

                        ActionButton {
                            visible: timelineRow.longMessage
                                && !timelineRow.message.streaming
                            label: timelineRow.expanded ? "Show less" : "Show more"
                            hPadding: 14
                            fontFamily: HermesTheme.fontUi
                            focusColor: HermesTheme.focus
                            buttonRadius: HermesTheme.controlRadius
                            tint: HermesTheme.textMuted
                            fill: Theme.chip
                            onTriggered: timelineRow.expanded = !timelineRow.expanded
                        }
                    }
                }
            }

            HermesToolCard {
                id: toolActivity
                visible: root.working && root.latestTool !== null
                width: parent.width
                height: visible ? implicitHeight : 0
                tool: root.latestTool ?? ({})
            }

            Rectangle {
                id: workingCard
                visible: root.working && root.latestTool === null
                    && !root.allMessages.some(message => message.streaming)
                width: parent.width
                height: 34
                radius: HermesTheme.rowRadius
                color: Theme.chip
                border.width: 1
                border.color: HermesTheme.border

                Sym {
                    id: workingGlyph
                    x: 9
                    anchors.verticalCenter: parent.verticalCenter
                    name: "progress_activity"
                    size: Theme.iconSmall
                    symWeight: 430
                    color: HermesTheme.accent

                    RotationAnimation on rotation {
                        running: workingCard.visible && !Theme.reducedMotion
                        from: 0
                        to: 360
                        loops: Animation.Infinite
                        duration: 950
                    }
                }

                Text {
                    anchors.left: workingGlyph.right
                    anchors.leftMargin: 8
                    anchors.right: parent.right
                    anchors.rightMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.conversation?.statusText || "Hermes is working…"
                    elide: Text.ElideRight
                    font.family: HermesTheme.fontUi
                    font.pixelSize: Theme.typography.secondary
                    color: HermesTheme.textSecondary
                }
            }

            StatusPlaceholder {
                visible: root.allItems.length === 0 && !root.working
                width: parent.width
                kind: HermesConversations.selectedLoading ? "loading"
                    : Hermes.selectedError !== "" ? "error" : "empty"
                title: HermesConversations.selectedLoading ? "Loading conversation…"
                    : Hermes.selectedError !== "" ? "Hermes hit a problem"
                        : root.conversationId === "" ? "Start a new chat"
                            : "No messages yet"
                detail: HermesConversations.selectedLoading ? ""
                    : Hermes.selectedError !== ""
                        ? "Details and available recovery actions are below."
                        : root.conversationId === ""
                        ? "Your first message creates a fresh Hermes conversation."
                        : "Continue this historical conversation with its existing context."
                fontFamily: HermesTheme.fontUi
                accentColor: HermesTheme.accent
                accentFill: HermesTheme.accentSubtle
                outlineColor: HermesTheme.border
                primaryTextColor: HermesTheme.textSecondary
                secondaryTextColor: HermesTheme.textFaint
                errorColor: HermesTheme.red
                errorFill: HermesTheme.redSoft
                errorOutline: HermesTheme.redBorder
            }
        }
    }

    // This stays outside the transcript Flickable so a failure remains visible
    // with existing messages and while the reader is inspecting older history.
    // As HermesTranscript precedes requests and the composer, it is also the
    // final transcript element immediately above those interaction surfaces.
    Rectangle {
        id: errorBanner

        visible: Hermes.selectedError !== ""
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: visible ? Math.max(42, errorMessage.implicitHeight + 12) : 0
        radius: HermesTheme.rowRadius
        color: HermesTheme.redSoft
        border.width: 1
        border.color: HermesTheme.redBorder
        Accessible.role: Accessible.AlertMessage
        Accessible.name: "Hermes error: " + Hermes.selectedError

        Sym {
            id: errorGlyph
            x: 9
            anchors.verticalCenter: parent.verticalCenter
            name: "error"
            size: Theme.iconSmall
            symWeight: 500
            color: HermesTheme.red
        }

        IconButton {
            id: dismissError
            anchors.right: parent.right
            anchors.rightMargin: 4
            anchors.verticalCenter: parent.verticalCenter
            controlSize: 28
            symbol: "close"
            accessibleName: "Dismiss Hermes error"
            tint: HermesTheme.red
            onTriggered: {
                if (Hermes.dismissSelectedError())
                    root.errorHandled();
            }
        }

        ActionButton {
            id: retryError
            visible: Hermes.selectedErrorRetryable
            anchors.right: dismissError.left
            anchors.rightMargin: 3
            anchors.verticalCenter: parent.verticalCenter
            label: "Retry"
            revealed: visible
            enabled: Hermes.connected && !Hermes.selectedLoading
                && root.history.loadingEarlier !== true
            hPadding: 14
            fontFamily: HermesTheme.fontUi
            focusColor: HermesTheme.focus
            buttonRadius: HermesTheme.controlRadius
            tint: HermesTheme.red
            fill: "transparent"
            onTriggered: {
                if (Hermes.retrySelectedError())
                    root.errorHandled();
            }
        }

        Text {
            id: errorMessage
            anchors.left: errorGlyph.right
            anchors.leftMargin: 7
            anchors.right: retryError.visible ? retryError.left : dismissError.left
            anchors.rightMargin: 6
            anchors.verticalCenter: parent.verticalCenter
            text: Hermes.selectedError
            textFormat: Text.PlainText
            wrapMode: Text.WrapAtWordBoundaryOrAnywhere
            maximumLineCount: 3
            elide: Text.ElideRight
            lineHeight: Theme.proseLineHeight
            font.family: HermesTheme.fontUi
            font.pixelSize: Theme.typography.secondary
            color: HermesTheme.red
        }
    }

    ScrollChrome {
        anchors.fill: transcriptFlick
        target: transcriptFlick
        edgeColor: HermesTheme.canvas
        thumbColor: HermesTheme.accent
    }
}
