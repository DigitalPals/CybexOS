pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import "../Common"

Item {
    id: root

    required property string threadId
    property int maxHeight: 720
    property int visibleMessages: 10
    property bool confirmStop: false
    property bool snoozeOpen: false
    property bool menuOpen: false
    property bool followTail: true
    property bool changesExpanded: false
    property string expandedCheckpointRef: ""
    property bool gitSuccessVisible: false
    property string dismissedTaskProgressKey: ""
    signal backRequested()
    signal newPlanRequested(var plan)

    readonly property var thread: T3Code.projectedThread(threadId)
    readonly property var history: T3Code.historyPage(T3Code.detailMessages, visibleMessages)
    // The rows historyModel holds, mirrored so each sync can diff against
    // them without reading the model back. Nothing binds to it.
    property var historyRows: []
    // "Show more" per message id. It lives here rather than on the card so
    // it survives a card being rebuilt when the visible page shifts.
    property var expandedMessages: ({})
    readonly property bool backgroundWorking: thread !== null && thread.cls === "running"
        && !thread.foregroundWorking && thread.backgroundLiveness === "working"
    readonly property bool working: thread !== null && thread.cls === "running"
        && !backgroundWorking
    readonly property bool monitoring: thread !== null && thread.cls === "monitoring"
    readonly property int liveAgentCount: backgroundWorking ? T3Code.detailLiveAgentCount : 0
    readonly property var taskProgress: T3Code.detailTaskProgress
    readonly property bool showTaskProgress: taskProgress !== null
        && taskProgress.key !== dismissedTaskProgressKey
        && (taskProgress.completedCount < taskProgress.total || working
            || backgroundWorking || monitoring)
    readonly property string backgroundStatus: monitoring ? "Monitoring in the background"
        : liveAgentCount > 0 ? liveAgentCount + " "
            + (liveAgentCount === 1 ? "agent" : "agents") + " working in the background"
        : "Background work running"
    readonly property string workingTime: working
        ? T3Code.workingTimerLabel(thread.workingStartedAt) : ""
    readonly property bool hasRequests: thread !== null && (thread.pendingApprovals || thread.pendingInput
        || T3Code.detailApprovals.length > 0 || T3Code.detailPendingInputs.length > 0)
    readonly property bool composerIdle: thread !== null && thread.lifecycle === "active"
        && thread.canLifecycle && !hasRequests && !T3Code.detailLoading
    readonly property bool canCompose: composerIdle
        && (!thread.planReady || T3Code.threadDraft(threadId).interactionMode === "plan")
    readonly property var plan: T3Code.detailActionablePlan
    readonly property bool planTooLong: plan
        && T3Code.maxPromptChars < ("PLEASE IMPLEMENT THIS PLAN:\n" + plan.planMarkdown.trim()).length
    readonly property var checkpoint: T3Code.detailCheckpointSummary
    readonly property bool hasCheckpointChanges: checkpoint !== null
        && checkpoint.fileCount > 0
    readonly property string checkpointRef: checkpoint
        ? String(checkpoint.checkpointRef ?? "") : ""
    readonly property var vcs: T3Code.detailVcs.status
    readonly property var git: T3Code.detailGit
    readonly property bool gitPending: T3Code.actionPending("git", threadId, "")
    readonly property string prUrl: git.prUrl !== "" ? git.prUrl
        : vcs && vcs.pr ? vcs.pr.url : ""
    readonly property bool showCommit: T3Code.canOperate
        && (T3Code.gitActionApplies("commit_push")
            || gitPending && git.action === "commit_push")
    readonly property bool showPush: T3Code.canOperate
        && (T3Code.gitActionApplies("push")
            || gitPending && git.action === "push")
    readonly property bool hasGitMenuItems: showCommit || showPush || prUrl !== ""
    readonly property bool activityFailed: T3Code.detailLatestActivity !== null
        && T3Code.detailLatestActivity.tone === "error"
    readonly property string gitFeedbackText: gitPending
        ? (git.label !== "" ? git.label : "Git action in progress…")
        : git.error !== "" ? git.error
        : T3Code.detailVcs.error !== "" ? T3Code.detailVcs.error
        : gitSuccessVisible ? git.summary : ""
    readonly property bool gitFeedbackFailed: !gitPending
        && (git.error !== "" || T3Code.detailVcs.error !== "")
    readonly property bool fullDiffCopyPending:
        T3Code.actionPending("diff-copy", threadId, "")
    readonly property string fullDiffCopyError:
        T3Code.actionError("diff-copy", threadId, "")
    // Rebound whenever the projection refreshes because `thread` is a dep.
    readonly property string copyPath: thread !== null ? T3Code.threadPath(threadId) : ""
    readonly property string copyBranch: thread !== null && thread.branch ? thread.branch : ""

    property int spacing: 5
    readonly property real naturalHeight: header.height
        + (gitFeedback.visible ? spacing + gitFeedback.height : 0)
        + spacing * 2 + timeline.implicitHeight + bottomDock.implicitHeight
    implicitHeight: Math.min(maxHeight, Math.max(1, naturalHeight))

    function scrollToEnd() {
        if (!followTail)
            return;
        Qt.callLater(() => {
            if (root.followTail)
                flick.contentY = Math.max(0, flick.contentHeight - flick.height);
        });
    }

    function showEarlier() {
        followTail = false;
        const previousHeight = flick.contentHeight;
        visibleMessages += 10;
        Qt.callLater(() => {
            flick.contentY = Math.max(0, flick.contentY + flick.contentHeight - previousHeight);
        });
    }

    function toggleChanges() {
        if (!hasCheckpointChanges)
            return;
        if (changesExpanded && expandedCheckpointRef === checkpointRef) {
            changesExpanded = false;
            return;
        }
        changesExpanded = true;
        expandedCheckpointRef = checkpointRef;
        const loadedCurrent = T3Code.detailDiff.checkpointRef === checkpointRef;
        if (!loadedCurrent || T3Code.detailDiff.error !== ""
                || T3Code.detailDiff.text === "" && !T3Code.detailDiff.loading)
            T3Code.loadFullThreadDiff(threadId, checkpoint);
    }

    function beginGitAction(action) {
        menuOpen = false;
        gitSuccessVisible = false;
        gitSuccessTimer.stop();
        T3Code.runGitAction(threadId, action);
    }

    // Bring historyModel in line with the visible page. A streamed token
    // becomes one setProperty on one row, so only that card re-lays its text;
    // every other card, its Markdown and its keyboard focus stay put.
    function syncHistory() {
        const update = T3Code.historyRowOps(historyRows, history.items);
        for (const op of update.ops) {
            if (op.op === "remove") {
                historyModel.remove(op.index, op.count);
            } else if (op.op === "insert") {
                historyModel.insert(op.index, op.row);
            } else {
                for (const field in op.changes)
                    historyModel.setProperty(op.index, field, op.changes[field]);
            }
        }
        historyRows = update.rows;
    }

    function toggleExpanded(messageId) {
        const next = Object.assign({}, expandedMessages);
        if (next[messageId] === true)
            delete next[messageId];
        else
            next[messageId] = true;
        expandedMessages = next;
    }

    onHistoryChanged: syncHistory()

    ListModel {
        id: historyModel
    }

    function openMessageLink(link) {
        T3Code.openExternalUrl(link);
    }

    function themedMarkdown(markdown) {
        return T3Code.styleMarkdownLinks(markdown, T3Theme.link.toString());
    }

    function closeOpenLayer(): bool {
        if (menuOpen) {
            menuOpen = false;
            confirmStop = false;
            return true;
        }
        if (snoozeOpen) {
            snoozeOpen = false;
            return true;
        }
        return composer.closeOpenLayer();
    }

    // Tightest pill: the thread page packs several of these per row.
    component Action: ActionButton {
        hPadding: 14
        fontFamily: T3Theme.fontUi
        focusColor: T3Theme.focus
        buttonRadius: T3Theme.controlRadius
        tint: T3Theme.textMuted
        fill: T3Theme.hover
    }

    component T3Status: StatusPlaceholder {
        fontFamily: T3Theme.fontUi
        accentColor: T3Theme.accent
        accentFill: T3Theme.accentSubtle
        outlineColor: T3Theme.border
        primaryTextColor: T3Theme.textSecondary
        secondaryTextColor: T3Theme.textFaint
        errorColor: T3Theme.red
        errorFill: T3Theme.redSoft
        errorOutline: T3Theme.redBorder
        transitionDuration: T3Theme.normalDuration
        fadeDuration: T3Theme.fastDuration
    }

    component InfoCard: Rectangle {
        id: card
        property string heading: ""
        property string body: ""
        property color headingColor: T3Theme.textFaint
        property color fill: T3Theme.surfaceRaised
        property color outline: T3Theme.border

        width: parent ? parent.width : 0
        height: cardColumn.implicitHeight + 14
        radius: T3Theme.panelRadius
        color: fill
        border.width: 1
        border.color: outline

        Column {
            id: cardColumn
            x: 7
            y: 7
            width: parent.width - 14
            spacing: 3

            Text {
                width: parent.width
                text: card.heading
                font.family: T3Theme.fontUi
                font.pixelSize: Theme.typography.secondary
                font.weight: Theme.weightSemibold
                font.letterSpacing: 0.1
                color: card.headingColor
            }

            Text {
                width: parent.width
                text: card.body
                wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                lineHeight: Theme.proseLineHeight
                maximumLineCount: 5
                elide: Text.ElideRight
                font.family: T3Theme.fontUi
                font.pixelSize: Theme.typography.primary
                color: T3Theme.textSecondary
            }
        }
    }

    // Every turn is plain copy in one reading column, opened by a speaker
    // label and closed by a hairline — the way the menubar separates one run
    // of modules from the next. The right-aligned bubble was the last card in
    // the transcript, and at 460px it cost a fifth of the measure to say
    // something the label already says. The label row also gives the hover
    // metadata a fixed home, so it no longer floats over the geometry.
    // Its properties are historyModel's roles (Helpers.historyRows).
    component MessageCard: Item {
        id: messageCard
        required property string messageId
        required property string speakerRole
        required property string body
        required property bool streaming
        required property string timestamp
        required property bool longMessage
        // A run of replies is one speaker talking, so it is named once. The
        // hairline and the timestamp still separate the turns; repeating the
        // label down a four-message run is the noise the bubble used to be.
        required property bool continuation
        readonly property bool expanded: root.expandedMessages[messageId] === true
        readonly property bool fromUser: speakerRole === "user"
        readonly property bool metadataVisible: messageHover.hovered || activeFocus
            || copyMessageButton.activeFocus
        // A message carries a role and its text, and no model of its own, so
        // the assistant side names the product rather than attributing a
        // historical turn to whatever the composer happens to be set to now.
        readonly property string speaker: fromUser ? "YOU" : "T3 CODE"

        width: parent ? parent.width : 0
        height: messageColumn.implicitHeight + 12
        activeFocusOnTab: true
        Accessible.role: Accessible.StaticText
        Accessible.name: (fromUser ? "You" : "T3 Code") + ": " + body

        HoverHandler { id: messageHover }

        Rectangle {
            anchors.top: parent.top
            x: 2
            width: parent.width - 4
            height: 1
            color: T3Theme.border
        }

        Column {
            id: messageColumn
            x: 2
            y: 8
            width: parent.width - 4
            spacing: 5

            Item {
                width: parent.width
                height: Theme.sectionHeaderHeight

                Text {
                    id: speakerLabel
                    visible: !messageCard.continuation
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: messageCard.speaker
                    elide: Text.ElideRight
                    width: Math.min(implicitWidth, parent.width - 90)
                    font.family: T3Theme.fontUi
                    font.pixelSize: Theme.typography.metadata
                    font.weight: Theme.weightSemibold
                    font.letterSpacing: 1
                    color: T3Theme.textFaint
                }

                IconButton {
                    id: copyMessageButton
                    anchors.right: messageTime.left
                    anchors.rightMargin: 2
                    anchors.verticalCenter: parent.verticalCenter
                    visible: messageCard.metadataVisible
                    controlSize: Theme.chipInnerHeight
                    symbol: "content_copy"
                    accessibleName: "Copy message"
                    tint: T3Theme.textFaint
                    onTriggered: Quickshell.clipboardText = messageCard.body
                }

                Text {
                    id: messageTime
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: messageCard.streaming ? "streaming…"
                        : T3Code.relTime(messageCard.timestamp)
                    font.family: T3Theme.fontUi
                    font.pixelSize: Theme.typography.metadata
                    font.features: T3Theme.tabularNumberFeatures
                    color: T3Theme.textFaint
                }
            }

            Text {
                width: parent.width
                text: messageCard.fromUser ? messageCard.body
                    : root.themedMarkdown(messageCard.body)
                textFormat: messageCard.fromUser ? Text.PlainText : Text.MarkdownText
                wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                lineHeight: Theme.proseLineHeight
                maximumLineCount: messageCard.expanded ? 100000 : 12
                elide: messageCard.expanded ? Text.ElideNone : Text.ElideRight
                font.family: T3Theme.fontUi
                font.pixelSize: Theme.typography.secondary
                color: messageCard.fromUser ? T3Theme.textPrimary : T3Theme.textSecondary
                onLinkActivated: link => root.openMessageLink(link)
            }

            Item {
                visible: messageCard.longMessage
                width: parent.width
                height: visible ? 24 : 0

                Action {
                    visible: messageCard.longMessage
                    anchors.left: parent.left
                    label: messageCard.expanded ? "Show less" : "Show more"
                    onTriggered: root.toggleExpanded(messageCard.messageId)
                }

            }
        }
    }

    component MenuEntry: Rectangle {
        id: menuEntry
        property string label: ""
        property color tint: T3Theme.textSecondary
        signal triggered()

        Accessible.role: Accessible.Button
        Accessible.name: menuEntry.label
        Accessible.onPressAction: menuEntry.triggered()

        width: parent ? parent.width : 0
        height: Theme.controlHeight
        radius: T3Theme.controlRadius
        color: entryMouse.containsMouse && enabled ? T3Theme.hoverStrong : "transparent"
        opacity: enabled ? 1 : 0.4
        activeFocusOnTab: enabled && visible
        border.width: activeFocus ? 1 : 0
        border.color: T3Theme.focus

        Keys.onPressed: event => {
            if (!menuEntry.enabled)
                return;
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                    || event.key === Qt.Key_Space) {
                menuEntry.triggered();
                event.accepted = true;
            }
        }

        Text {
            anchors.left: parent.left
            anchors.leftMargin: 9
            anchors.right: parent.right
            anchors.rightMargin: 9
            anchors.verticalCenter: parent.verticalCenter
            text: menuEntry.label
            elide: Text.ElideRight
            font.family: T3Theme.fontUi
            font.pixelSize: Theme.typography.secondary
            font.weight: Theme.weightMedium
            color: menuEntry.tint
        }

        MouseArea {
            id: entryMouse
            anchors.fill: parent
            enabled: menuEntry.enabled
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: menuEntry.triggered()
        }
    }

    component MenuDivider: Rectangle {
        width: parent ? parent.width - 10 : 0
        height: 1
        x: 5
        color: T3Theme.border
    }

    // Left-aligned header; Stop / Snooze / Settle live behind the overflow menu so the
    // always-on row is just navigation (design 5c).
    Item {
        id: header
        z: 10
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: headerColumn.implicitHeight

        readonly property bool sessionLive: T3Code.detailSession !== null
            && T3Code.detailSession.status !== "stopped"
        readonly property bool canSnoozeHere: root.thread !== null
            && root.thread.lifecycle === "active" && T3Code.supportsSnooze
        readonly property bool canWakeHere: root.thread !== null
            && root.thread.lifecycle === "snoozed" && T3Code.supportsSnooze
        readonly property bool canSettleHere: root.thread !== null
            && root.thread.lifecycle === "active" && T3Code.supportsSettlement
        readonly property bool canUnsettleHere: root.thread !== null
            && root.thread.lifecycle === "settled" && T3Code.supportsSettlement
        readonly property bool canPinHere: root.thread !== null && T3Code.supportsPinning
        readonly property bool hasLifecycleMenuItems: sessionLive || canPinHere
            || canSnoozeHere || canWakeHere || canSettleHere || canUnsettleHere
        readonly property bool hasCopyMenuItems: root.copyPath !== "" || root.copyBranch !== ""
        readonly property bool hasMenuItems: root.hasGitMenuItems || hasLifecycleMenuItems
            || hasCopyMenuItems

        Column {
            id: headerColumn
            width: parent.width
            spacing: 5

            Item {
                width: parent.width
                height: Theme.controlHeight

                IconButton {
                    id: backButton
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    symbol: "arrow_back"
                    accessibleName: "Back to inbox"
                    onTriggered: root.backRequested()
                }

                Column {
                    anchors.left: backButton.right
                    anchors.leftMargin: 9
                    anchors.right: openButton.left
                    anchors.rightMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2

                    Text {
                        width: parent.width
                        text: root.thread ? root.thread.title : "Thread"
                        elide: Text.ElideRight
                        font.family: T3Theme.fontUi
                        font.pixelSize: Theme.typography.primary
                        font.weight: Theme.weightSemibold
                        color: T3Theme.textPrimary
                    }

                    Row {
                        id: threadMetadata
                        width: parent.width
                        spacing: 5

                        readonly property string projectName: root.thread
                            ? String(root.thread.project ?? "") : ""
                        readonly property string providerGlyph:
                            T3Code.threadProviderIcon(root.threadId)
                        readonly property int visibleItemCount:
                            (projectName !== "" ? 2 : 0)
                            + (providerGlyph !== "" ? 1 : 0)
                            + (projectName !== "" && providerGlyph !== "" ? 1 : 0)
                        readonly property real fixedWidth:
                            (projectFolder.visible ? projectFolder.implicitWidth : 0)
                            + (metadataSeparator.visible ? metadataSeparator.implicitWidth : 0)
                            + (providerIcon.visible ? providerIcon.width : 0)
                            + Math.max(0, visibleItemCount - 1) * spacing

                        Sym {
                            id: projectFolder
                            visible: threadMetadata.projectName !== ""
                            anchors.verticalCenter: parent.verticalCenter
                            name: "folder"
                            size: Theme.iconTiny
                            symWeight: 450
                            color: T3Theme.textFaint
                        }

                        Text {
                            id: projectName
                            visible: threadMetadata.projectName !== ""
                            anchors.verticalCenter: parent.verticalCenter
                            width: Math.min(implicitWidth,
                                Math.max(0, threadMetadata.width - threadMetadata.fixedWidth))
                            text: threadMetadata.projectName
                            elide: Text.ElideRight
                            font.family: T3Theme.fontUi
                            font.pixelSize: Theme.typography.secondary
                            color: T3Theme.textFaint
                        }

                        Text {
                            id: metadataSeparator
                            visible: threadMetadata.projectName !== ""
                                && threadMetadata.providerGlyph !== ""
                            anchors.verticalCenter: parent.verticalCenter
                            text: "·"
                            font.family: T3Theme.fontUi
                            font.pixelSize: Theme.typography.secondary
                            color: T3Theme.textFaint
                        }

                        BrandIcon {
                            id: providerIcon
                            visible: threadMetadata.providerGlyph !== ""
                            anchors.verticalCenter: parent.verticalCenter
                            width: 13
                            height: 13
                            name: threadMetadata.providerGlyph
                            opacity: 0.92
                        }
                    }
                }

                IconButton {
                    id: openButton
                    anchors.right: menuButton.visible ? menuButton.left : parent.right
                    anchors.rightMargin: menuButton.visible ? 6 : 0
                    anchors.verticalCenter: parent.verticalCenter
                    symbol: "open_in_new"
                    accessibleName: "Open in browser"
                    tint: T3Theme.accent
                    onTriggered: {
                        if (T3Code.openExternalUrl(T3Code.threadUrl(root.threadId)))
                            Popouts.close();
                    }
                }

                IconButton {
                    id: menuButton
                    visible: header.hasMenuItems
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    symbol: "more_horiz"
                    accessibleName: "Thread menu"
                    tint: root.menuOpen ? T3Theme.accent : T3Theme.textMuted
                    onTriggered: root.menuOpen = !root.menuOpen
                }
            }

            Row {
                visible: root.snoozeOpen
                width: parent.width
                spacing: 4

                Repeater {
                    model: T3Code.snoozePresets()
                    delegate: Action {
                        required property var modelData
                        label: modelData.label
                        enabled: T3Code.canDispatch && root.thread !== null && root.thread.canLifecycle
                        onTriggered: {
                            T3Code.snooze(root.threadId, modelData.snoozedUntil);
                            root.snoozeOpen = false;
                        }
                    }
                }
            }
        }

        Rectangle {
            id: overflowMenu
            visible: root.menuOpen && header.hasMenuItems
            z: 100
            anchors.right: parent.right
            y: 32
            width: 190
            height: menuColumn.implicitHeight + 10
            radius: T3Theme.panelRadius
            color: T3Theme.overlay
            border.width: 1
            border.color: T3Theme.borderStrong

            Column {
                id: menuColumn
                x: 5
                y: 5
                width: parent.width - 10

                MenuEntry {
                    visible: root.showCommit
                    label: root.gitPending && root.git.action === "commit_push"
                        && root.git.label !== "" ? root.git.label : "Commit & Push"
                    tint: T3Theme.accent
                    enabled: T3Code.canDispatch && !root.gitPending
                    onTriggered: root.beginGitAction("commit_push")
                }

                MenuEntry {
                    visible: root.showPush
                    label: root.gitPending && root.git.action === "push"
                        && root.git.label !== "" ? root.git.label : "Push"
                    tint: T3Theme.accent
                    enabled: T3Code.canDispatch && !root.gitPending
                    onTriggered: root.beginGitAction("push")
                }

                MenuEntry {
                    visible: root.prUrl !== ""
                    label: "View pull request"
                    tint: T3Theme.accent
                    onTriggered: {
                        root.menuOpen = false;
                        if (T3Code.openExternalUrl(root.prUrl))
                            Popouts.close();
                    }
                }

                MenuDivider {
                    visible: root.hasGitMenuItems && header.hasLifecycleMenuItems
                }

                // The reference client lists pin above the other lifecycle
                // actions in its thread menu.
                MenuEntry {
                    visible: header.canPinHere
                    label: {
                        const kind = root.thread !== null && root.thread.pinned ? "unpin" : "pin";
                        if (T3Code.actionPending(kind, root.threadId, ""))
                            return kind === "unpin" ? "Unpinning…" : "Pinning…";
                        return kind === "unpin" ? "Unpin thread" : "Pin thread";
                    }
                    enabled: T3Code.canDispatch
                        && !T3Code.actionPending("pin", root.threadId, "")
                        && !T3Code.actionPending("unpin", root.threadId, "")
                    onTriggered: {
                        root.menuOpen = false;
                        if (root.thread !== null && root.thread.pinned)
                            T3Code.unpin(root.threadId);
                        else
                            T3Code.pin(root.threadId);
                    }
                }

                MenuEntry {
                    visible: header.sessionLive
                    label: root.confirmStop ? "Confirm stop session"
                        : T3Code.actionPending("session-stop", root.threadId, "")
                            ? "Stopping…" : "Stop session"
                    tint: root.confirmStop ? T3Theme.red : T3Theme.textSecondary
                    enabled: T3Code.canDispatch
                        && !T3Code.actionPending("session-stop", root.threadId, "")
                    onTriggered: {
                        if (!root.confirmStop) {
                            root.confirmStop = true;
                            stopConfirmTimer.restart();
                        } else {
                            root.confirmStop = false;
                            root.menuOpen = false;
                            T3Code.stopSession(root.threadId);
                        }
                    }
                }

                MenuEntry {
                    visible: header.canSnoozeHere
                    label: "Snooze…"
                    enabled: T3Code.canDispatch && root.thread !== null && root.thread.canLifecycle
                    onTriggered: {
                        root.menuOpen = false;
                        root.snoozeOpen = true;
                    }
                }

                MenuEntry {
                    visible: header.canWakeHere
                    label: T3Code.actionPending("unsnooze", root.threadId, "")
                        ? "Waking…" : "Wake now"
                    tint: T3Theme.accent
                    enabled: T3Code.canDispatch
                        && !T3Code.actionPending("unsnooze", root.threadId, "")
                    onTriggered: {
                        root.menuOpen = false;
                        T3Code.unsnooze(root.threadId);
                    }
                }

                MenuEntry {
                    visible: header.canSettleHere
                    label: T3Code.actionPending("settle", root.threadId, "")
                        ? "Settling…" : "Settle"
                    tint: T3Theme.accent
                    enabled: T3Code.canDispatch && root.thread !== null && root.thread.canLifecycle
                        && !T3Code.actionPending("settle", root.threadId, "")
                    onTriggered: {
                        root.menuOpen = false;
                        T3Code.settle(root.threadId);
                    }
                }

                MenuEntry {
                    visible: header.canUnsettleHere
                    label: T3Code.actionPending("unsettle", root.threadId, "")
                        ? "Unsettling…" : "Unsettle"
                    tint: T3Theme.accent
                    enabled: T3Code.canDispatch
                        && !T3Code.actionPending("unsettle", root.threadId, "")
                    onTriggered: {
                        root.menuOpen = false;
                        T3Code.unsettle(root.threadId);
                    }
                }

                MenuDivider {
                    visible: header.hasCopyMenuItems
                        && (root.hasGitMenuItems || header.hasLifecycleMenuItems)
                }

                MenuEntry {
                    visible: root.copyPath !== ""
                    label: "Copy path"
                    onTriggered: {
                        root.menuOpen = false;
                        Quickshell.clipboardText = root.copyPath;
                    }
                }

                MenuEntry {
                    visible: root.copyBranch !== ""
                    label: "Copy branch"
                    onTriggered: {
                        root.menuOpen = false;
                        Quickshell.clipboardText = root.copyBranch;
                    }
                }
            }
        }
    }

    Timer {
        id: stopConfirmTimer
        interval: 5000
        onTriggered: root.confirmStop = false
    }

    Timer {
        id: gitSuccessTimer
        interval: 6000
        onTriggered: root.gitSuccessVisible = false
    }

    Item {
        id: gitFeedback
        visible: root.gitFeedbackText !== ""
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: header.bottom
        anchors.topMargin: visible ? root.spacing : 0
        height: visible ? Math.max(22, gitFeedbackText.implicitHeight + 6) : 0

        Rectangle {
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: 2
            radius: 1
            color: root.gitFeedbackFailed ? T3Theme.red : T3Theme.accent
        }

        Text {
            id: gitFeedbackText
            anchors.left: parent.left
            anchors.leftMargin: 9
            anchors.right: gitRetry.visible ? gitRetry.left : parent.right
            anchors.rightMargin: gitRetry.visible ? 6 : 0
            anchors.verticalCenter: parent.verticalCenter
            text: root.gitFeedbackText
            elide: Text.ElideRight
            maximumLineCount: 2
            wrapMode: Text.WrapAtWordBoundaryOrAnywhere
            lineHeight: Theme.proseLineHeight
            font.family: T3Theme.fontUi
            font.pixelSize: Theme.typography.secondary
            color: root.gitFeedbackFailed ? T3Theme.red : T3Theme.textMuted
        }

        Action {
            id: gitRetry
            visible: T3Code.detailVcs.error !== "" && !root.gitPending
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            label: "Retry"
            tint: T3Theme.accent
            onTriggered: T3Code.refreshVcsStatus(root.threadId, true)
        }
    }

    Item {
        id: viewport
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: gitFeedback.bottom
        anchors.topMargin: root.spacing
        anchors.bottom: bottomDock.top
        anchors.bottomMargin: root.spacing

        Flickable {
            id: flick
            anchors.fill: parent
            contentWidth: width
            contentHeight: timeline.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height
            activeFocusOnTab: interactive
            onContentHeightChanged: root.scrollToEnd()
            onHeightChanged: root.scrollToEnd()
            onMovementStarted: root.followTail = false
            onMovementEnded: root.followTail = contentY >= Math.max(0,
                contentHeight - height - 2)

            Column {
                id: timeline
                width: flick.width - (flick.contentHeight > flick.height ? 5 : 0)
                spacing: 6

                T3Status {
                    shown: T3Code.detailLoading
                    width: parent.width
                    kind: "loading"
                    title: "Loading conversation…"
                }

                InfoCard {
                    visible: T3Code.detailError !== ""
                    heading: "Thread unavailable"
                    body: T3Code.detailError
                    headingColor: T3Theme.red
                    fill: T3Theme.redSoft
                    outline: T3Theme.redBorder
                }

                Action {
                    visible: root.history.hasEarlier
                    anchors.horizontalCenter: parent.horizontalCenter
                    label: "Show " + Math.min(10, root.history.hiddenCount) + " earlier"
                    onTriggered: root.showEarlier()
                }

                Repeater {
                    model: historyModel
                    delegate: MessageCard {}
                }

                Item {
                    visible: root.working
                    width: parent.width
                    height: Theme.controlHeight

                    Row {
                        x: 7
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 7

                        Sym {
                            id: workingGlyph
                            anchors.verticalCenter: parent.verticalCenter
                            name: "progress_activity"
                            size: Theme.iconSmall
                            symWeight: 500
                            color: T3Theme.accent

                            // The arc only reads as activity while it turns;
                            // parked, it is an ambiguous half-ring.
                            RotationAnimation on rotation {
                                running: root.working && workingGlyph.visible
                                    && !Theme.reducedMotion
                                from: 0
                                to: 360
                                duration: 1100
                                loops: Animation.Infinite
                            }
                        }

                        Text {
                            text: root.workingTime !== ""
                                ? "Working for " + root.workingTime : "Working…"
                            font.family: T3Theme.fontUi
                            font.pixelSize: Theme.typography.secondary
                            font.weight: Theme.weightMedium
                            font.features: T3Theme.tabularNumberFeatures
                            color: T3Theme.textMuted
                        }
                    }
                }

                T3Status {
                    shown: !root.working && !root.backgroundWorking && !root.monitoring
                        && !T3Code.detailLoading
                        && T3Code.detailMessages.length === 0
                    width: parent.width
                    glyph: "chat"
                    title: "No messages yet"
                }

                Item {
                    visible: root.activityFailed
                    width: parent.width
                    height: activityErrorText.implicitHeight + 8

                    Rectangle {
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        width: 2
                        radius: 1
                        color: T3Theme.red
                    }

                    Text {
                        id: activityErrorText
                        x: 9
                        y: 4
                        width: parent.width - 9
                        text: root.activityFailed ? T3Code.detailLatestActivity.summary : ""
                        wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                        lineHeight: Theme.proseLineHeight
                        maximumLineCount: 3
                        elide: Text.ElideRight
                        font.family: T3Theme.fontUi
                        font.pixelSize: Theme.typography.secondary
                        color: T3Theme.red
                    }
                }

                Rectangle {
                    id: changesRow
                    visible: root.hasCheckpointChanges
                    Accessible.role: Accessible.Button
                    Accessible.name: root.changesExpanded
                        ? "Hide changed files" : "Show changed files"
                    width: parent.width
                    height: Theme.controlHeight
                    radius: 6
                    color: changesMouse.containsMouse ? T3Theme.hoverStrong : "transparent"
                    activeFocusOnTab: visible
                    border.width: activeFocus ? 1 : 0
                    border.color: T3Theme.focus

                    Keys.onPressed: event => {
                        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                                || event.key === Qt.Key_Space) {
                            root.toggleChanges();
                            event.accepted = true;
                        }
                    }

                    Sym {
                        anchors.left: parent.left
                        anchors.leftMargin: 7
                        anchors.verticalCenter: parent.verticalCenter
                        name: root.changesExpanded ? "expand_more" : "chevron_right"
                        size: Theme.iconSmall
                        symWeight: 450
                        color: root.changesExpanded ? T3Theme.accent : T3Theme.textMuted
                    }

                    Text {
                        anchors.left: parent.left
                        anchors.leftMargin: 24
                        anchors.right: changesState.left
                        anchors.rightMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.checkpoint ? root.checkpoint.fileCount + " changed file"
                            + (root.checkpoint.fileCount === 1 ? "" : "s") + " · +"
                            + root.checkpoint.additions + " −" + root.checkpoint.deletions : ""
                        elide: Text.ElideRight
                        font.family: T3Theme.fontUi
                        font.pixelSize: Theme.typography.secondary
                        font.weight: Theme.weightSemibold
                        color: T3Theme.textSecondary
                    }

                    Text {
                        id: changesState
                        anchors.right: parent.right
                        anchors.rightMargin: 7
                        anchors.verticalCenter: parent.verticalCenter
                        text: T3Code.detailDiff.loading && root.changesExpanded ? "Loading…"
                            : root.changesExpanded ? "Hide diff" : "View diff"
                        font.family: T3Theme.fontUi
                        font.pixelSize: Theme.typography.secondary
                        color: T3Theme.textFaint
                    }

                    MouseArea {
                        id: changesMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            changesRow.forceActiveFocus();
                            root.toggleChanges();
                        }
                    }
                }

                Column {
                    visible: root.changesExpanded && root.hasCheckpointChanges
                        && root.expandedCheckpointRef === root.checkpointRef
                    width: parent.width
                    spacing: 5

                    Text {
                        visible: root.checkpoint && root.checkpoint.filenames.length > 0
                        width: parent.width
                        text: root.checkpoint ? root.checkpoint.filenames.join(" · ") : ""
                        elide: Text.ElideMiddle
                        font.family: T3Theme.fontMono
                        font.pixelSize: Theme.typography.secondary
                        color: T3Theme.textSecondary
                    }

                    Rectangle {
                        visible: T3Code.detailDiff.text !== ""
                        width: parent.width
                        height: 260
                        radius: 6
                        color: Qt.rgba(0, 0, 0, 0.28)
                        border.width: 1
                        border.color: T3Theme.border

                        Flickable {
                            anchors.fill: parent
                            anchors.margins: 7
                            contentWidth: Math.max(width, patchText.implicitWidth)
                            contentHeight: Math.max(height, patchText.implicitHeight)
                            clip: true
                            boundsBehavior: Flickable.StopAtBounds

                            Text {
                                id: patchText
                                text: T3Code.detailDiff.text
                                textFormat: Text.PlainText
                                wrapMode: Text.NoWrap
                                font.family: T3Theme.fontMono
                                font.pixelSize: Theme.typography.secondary
                                color: T3Theme.textMuted
                            }
                        }
                    }

                    Flow {
                        visible: T3Code.detailDiff.text !== "" || T3Code.detailDiff.error !== ""
                        width: parent.width
                        spacing: 4

                        Action {
                            visible: T3Code.detailDiff.text !== ""
                            label: T3Code.detailDiff.truncated ? "Copy preview" : "Copy patch"
                            onTriggered: Quickshell.clipboardText = T3Code.detailDiff.text
                        }

                        Action {
                            visible: T3Code.detailDiff.error !== ""
                            label: "Retry diff"
                            tint: T3Theme.accent
                            onTriggered: T3Code.loadFullThreadDiff(root.threadId, root.checkpoint)
                        }

                        Text {
                            visible: T3Code.detailDiff.truncated
                            text: "Preview truncated at 100,000 characters / 2,000 lines"
                            font.family: T3Theme.fontUi
                            font.pixelSize: Theme.typography.secondary
                            color: T3Theme.amber
                        }

                        Action {
                            visible: T3Code.detailDiff.truncated
                            enabled: !root.fullDiffCopyPending
                            label: root.fullDiffCopyPending ? "Copying full patch…" : "Copy full patch"
                            tint: T3Theme.accent
                            onTriggered: T3Code.copyFullThreadDiff(root.threadId, root.checkpoint)
                        }

                        Action {
                            visible: T3Code.detailDiff.truncated
                            label: "Open T3 Code"
                            tint: T3Theme.accent
                            onTriggered: {
                                if (T3Code.openExternalUrl(T3Code.threadUrl(root.threadId)))
                                    Popouts.close();
                            }
                        }
                    }

                    Text {
                        visible: root.fullDiffCopyError !== ""
                        width: parent.width
                        text: root.fullDiffCopyError
                        wrapMode: Text.WordWrap
                        lineHeight: Theme.proseLineHeight
                        font.family: T3Theme.fontUi
                        font.pixelSize: Theme.typography.secondary
                        color: T3Theme.red
                    }

                    Text {
                        visible: T3Code.detailDiff.error !== ""
                        width: parent.width
                        text: T3Code.detailDiff.error
                        wrapMode: Text.WordWrap
                        lineHeight: Theme.proseLineHeight
                        font.family: T3Theme.fontUi
                        font.pixelSize: Theme.typography.secondary
                        color: T3Theme.red
                    }
                }
            }
        }

        ScrollChrome {
            anchors.fill: parent
            target: flick
            edgeColor: T3Theme.canvas
            thumbColor: T3Theme.accent
        }
    }

    Column {
        id: bottomDock
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        spacing: root.spacing

    Rectangle {
        id: backgroundBanner

        visible: root.backgroundWorking || root.monitoring
        width: parent.width
        height: visible ? Theme.controlHeight + 8 : 0
        radius: T3Theme.panelRadius
        color: T3Theme.surfaceRaised
        border.width: 1
        border.color: T3Theme.border

        Sym {
            id: backgroundGlyph
            anchors.left: parent.left
            anchors.leftMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            name: root.monitoring ? "visibility" : "progress_activity"
            size: Theme.iconSmall
            symWeight: 500
            color: T3Theme.accent

            // Only the activity arc turns; the watching eye is a state, not
            // a process, and spinning it would say the wrong thing.
            RotationAnimation on rotation {
                running: backgroundBanner.visible && !root.monitoring
                    && !Theme.reducedMotion
                from: 0
                to: 360
                duration: 1100
                loops: Animation.Infinite
                // Stopping a value source leaves the property where it
                // landed, which would tilt the eye it hands over to.
                onRunningChanged: if (!running) backgroundGlyph.rotation = 0
            }
        }

        Action {
            id: stopBackgroundButton

            anchors.right: parent.right
            anchors.rightMargin: 5
            anchors.verticalCenter: parent.verticalCenter
            label: T3Code.actionPending("session-stop", root.threadId, "")
                ? "Stopping…" : "Stop"
            enabled: T3Code.canDispatch
                && !T3Code.actionPending("session-stop", root.threadId, "")
            onTriggered: T3Code.stopSession(root.threadId)
        }

        Text {
            anchors.left: parent.left
            anchors.leftMargin: 32
            anchors.right: stopBackgroundButton.left
            anchors.rightMargin: 7
            anchors.verticalCenter: parent.verticalCenter
            text: root.backgroundStatus
            elide: Text.ElideRight
            font.family: T3Theme.fontUi
            font.pixelSize: Theme.typography.primary
            font.weight: Theme.weightMedium
            color: T3Theme.textSecondary
        }
    }

    // Response UI belongs at the point of response. Requests and ready plans
    // attach directly to the composer instead of interrupting transcript flow.
    Item {
        id: composerAttachmentsViewport
        width: parent.width
        visible: composerAttachments.implicitHeight > 0
        height: visible ? Math.min(300, composerAttachments.implicitHeight,
            Math.max(80, root.height - header.height - gitFeedback.height
                - backgroundBanner.height - composerDock.implicitHeight
                - composerError.implicitHeight - root.spacing * 5 - 140)) : 0

        Flickable {
            id: attachmentsFlick
            anchors.fill: parent
            contentWidth: width
            contentHeight: composerAttachments.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height
            activeFocusOnTab: interactive

            Column {
                id: composerAttachments
                width: attachmentsFlick.width
                    - (attachmentsFlick.contentHeight > attachmentsFlick.height ? 5 : 0)
                spacing: 4

                T3RequestCard {
            visible: T3Code.detailPendingInputs.length > 0
            threadId: root.threadId
            kind: "input"
            request: T3Code.detailPendingInputs.length > 0
                ? T3Code.detailPendingInputs[0] : ({ requestId: "", questions: [] })
            queuedCount: Math.max(0, T3Code.detailPendingInputs.length - 1)
        }

                Repeater {
            model: T3Code.detailApprovals
            delegate: T3RequestCard {
                required property var modelData
                threadId: root.threadId
                kind: "approval"
                request: modelData
            }
        }

                InfoCard {
            visible: root.thread !== null && root.thread.pendingInput
                && !T3Code.detailLoading && T3Code.detailPendingInputs.length === 0
            heading: "Question"
            body: "This question needs the full T3 Code client."
            headingColor: T3Theme.amber
            fill: T3Theme.amberSoft
            outline: T3Theme.amberBorder
        }

                InfoCard {
            visible: root.thread !== null && root.thread.pendingApprovals
                && !T3Code.detailLoading && T3Code.detailApprovals.length === 0
            heading: "Approval"
            body: "This approval needs the full T3 Code client."
            headingColor: T3Theme.amber
            fill: T3Theme.amberSoft
            outline: T3Theme.amberBorder
        }

                Rectangle {
            visible: root.plan !== null
            width: parent.width
            height: attachedPlanColumn.implicitHeight + 16
            radius: T3Theme.panelRadius
            color: T3Theme.surfaceRaised
            border.width: 1
            border.color: T3Theme.borderStrong

            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                height: 2
                radius: 1
                color: T3Theme.accent
            }

            Column {
                id: attachedPlanColumn
                x: 8
                y: 8
                width: parent.width - 16
                spacing: 6

                Row {
                    spacing: 6

                    Sym {
                        anchors.verticalCenter: parent.verticalCenter
                        name: "description"
                        size: Theme.iconSmall
                        color: T3Theme.accent
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Ready plan"
                        font.family: T3Theme.fontUi
                        font.pixelSize: Theme.typography.secondary
                        font.weight: Theme.weightSemibold
                        color: T3Theme.accent
                    }
                }

                Text {
                    width: parent.width
                    text: root.themedMarkdown(root.plan ? root.plan.planMarkdown : "")
                    textFormat: Text.MarkdownText
                    wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                    lineHeight: Theme.proseLineHeight
                    maximumLineCount: 12
                    elide: Text.ElideRight
                    font.family: T3Theme.fontUi
                    font.pixelSize: Theme.typography.primary
                    color: T3Theme.textSecondary
                }

                Flow {
                    width: parent.width
                    spacing: 4

                    Action {
                        label: T3Code.actionPending("prompt", root.threadId, "")
                            ? "Starting…" : "Implement here"
                        enabled: T3Code.canDispatch && root.composerIdle && !root.planTooLong
                            && !T3Code.actionPending("prompt", root.threadId, "")
                        tint: T3Theme.accentForeground
                        fill: T3Theme.accent
                        onTriggered: T3Code.implementPlanHere(root.threadId, root.plan)
                    }

                    Action {
                        label: "Refine"
                        enabled: T3Code.canDispatch && root.composerIdle
                        tint: T3Theme.accent
                        fill: T3Theme.accentSoft
                        onTriggered: {
                            T3Code.refinePlan(root.threadId);
                            composer.focusPrompt();
                        }
                    }

                    Action {
                        label: "New thread"
                        enabled: T3Code.canDispatch && T3Code.hasReadyProvider
                            && T3Code.hasProjects && !root.planTooLong
                        onTriggered: root.newPlanRequested(root.plan)
                    }

                    Action {
                        visible: root.planTooLong
                        label: "Open T3 Code"
                        tint: T3Theme.accent
                        onTriggered: {
                            if (T3Code.openExternalUrl(T3Code.threadUrl(root.threadId)))
                                Popouts.close();
                        }
                    }
                }
            }
                }
            }
        }

        ScrollChrome {
            anchors.fill: parent
            target: attachmentsFlick
            edgeColor: T3Theme.canvas
            thumbColor: T3Theme.accent
        }
    }

    // The plan docks to the composer rather than floating above the
    // transcript: a strip narrower than the glass shell below it, sliding in
    // behind its top edge so the two read as one object. They share this
    // wrapper because the page Column's spacing would otherwise open a gap
    // between them, and clipping is what squares off the strip's bottom
    // corners — it really is taller than its box, and the part you cannot see
    // is the part the composer covers.
    Item {
        id: composerDock
        width: parent.width
        implicitHeight: taskProgressCard.height + composer.implicitHeight

        Item {
            id: taskProgressCard
            visible: root.showTaskProgress
            width: parent.width
            height: visible ? 32 : 0
            clip: true
            Accessible.name: root.taskProgress
                ? "Tasks, " + root.taskProgress.activeStep + ", "
                    + root.taskProgress.completedCount + " of " + root.taskProgress.total
                    + " completed" : ""

            Rectangle {
                id: taskProgressStrip
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.top: parent.top
                width: Math.max(0, parent.width - 36)
                height: parent.height + T3Theme.panelRadius
                radius: T3Theme.panelRadius
                color: T3Theme.surfaceRaised
                border.width: 1
                border.color: T3Theme.border

                Sym {
                    id: taskProgressGlyph
                    anchors.left: parent.left
                    anchors.leftMargin: 10
                    anchors.top: parent.top
                    anchors.topMargin: (taskProgressCard.height - height) / 2
                    name: "checklist"
                    size: Theme.iconSmall
                    symWeight: 500
                    color: T3Theme.textMuted
                }

                Text {
                    id: taskProgressLabel
                    anchors.left: taskProgressGlyph.right
                    anchors.leftMargin: 6
                    anchors.verticalCenter: taskProgressGlyph.verticalCenter
                    text: "Tasks"
                    font.family: T3Theme.fontUi
                    font.pixelSize: Theme.typography.secondary
                    font.weight: Theme.weightSemibold
                    color: T3Theme.textMuted
                }

                Text {
                    id: taskProgressTitle
                    anchors.left: taskProgressLabel.right
                    anchors.leftMargin: 9
                    anchors.right: taskProgressCount.left
                    anchors.rightMargin: 9
                    anchors.verticalCenter: taskProgressGlyph.verticalCenter
                    text: root.taskProgress ? root.taskProgress.activeStep : ""
                    elide: Text.ElideRight
                    font.family: T3Theme.fontUi
                    font.pixelSize: Theme.typography.secondary
                    font.weight: Theme.weightMedium
                    color: T3Theme.textPrimary
                }

                Text {
                    id: taskProgressCount
                    anchors.right: taskProgressSegments.left
                    anchors.rightMargin: 8
                    anchors.verticalCenter: taskProgressGlyph.verticalCenter
                    text: root.taskProgress ? root.taskProgress.completedCount + "/"
                        + root.taskProgress.total : ""
                    font.family: T3Theme.fontUi
                    font.pixelSize: Theme.typography.secondary
                    font.weight: Theme.weightMedium
                    font.features: T3Theme.tabularNumberFeatures
                    color: T3Theme.textFaint
                }

                // One tick per step, in order, on the same line as the count it
                // spells out. A bar spanning the whole strip would claim the plan
                // is the subject here; it is the composer's footnote.
                Row {
                    id: taskProgressSegments
                    anchors.right: dismissTaskProgress.left
                    anchors.rightMargin: 8
                    anchors.verticalCenter: taskProgressGlyph.verticalCenter
                    height: 4
                    spacing: 3

                    Repeater {
                        id: taskProgressRepeater
                        model: root.taskProgress ? root.taskProgress.items : []

                        delegate: Rectangle {
                            required property var modelData
                            width: Math.max(4, Math.min(20, (72
                                - Math.max(0, taskProgressRepeater.count - 1)
                                    * taskProgressSegments.spacing)
                                / Math.max(1, taskProgressRepeater.count)))
                            height: taskProgressSegments.height
                            radius: height / 2
                            color: modelData.status === "completed" ? T3Theme.success
                                : modelData.status === "inProgress" ? T3Theme.accent
                                : T3Theme.borderStrong
                        }
                    }
                }

                IconButton {
                    id: dismissTaskProgress
                    anchors.right: parent.right
                    anchors.rightMargin: 4
                    anchors.top: parent.top
                    anchors.topMargin: (taskProgressCard.height - height) / 2
                    controlSize: 24
                    symbol: "close"
                    accessibleName: "Dismiss task progress"
                    tint: T3Theme.textFaint
                    onTriggered: {
                        if (root.taskProgress)
                            root.dismissedTaskProgressKey = root.taskProgress.key;
                    }
                }
            }
        }

        T3Composer {
            id: composer
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: taskProgressCard.bottom
            threadId: root.threadId
            newThread: false
            editable: root.composerIdle && T3Code.canDispatch
            sendEnabled: root.canCompose && T3Code.canDispatch
            // Background work already carries its own Stop in the banner
            // above, so only the foreground turn borrows the composer's
            // action slot.
            stoppable: root.working
            popupBoundsItem: root
            onSendRequested: T3Code.submitExisting(root.threadId, undefined, undefined,
                null, true)
            onStopRequested: T3Code.interrupt(root.threadId)
        }
    }

    Text {
        id: composerError
        visible: text !== ""
        width: parent.width
        text: {
            for (const kind of ["prompt", "interrupt", "session-stop", "settle", "unsettle",
                    "snooze", "unsnooze", "pin", "unpin"]) {
                const error = T3Code.actionError(kind, root.threadId, "");
                if (error !== "")
                    return error;
            }
            return "";
        }
        wrapMode: Text.WordWrap
        lineHeight: Theme.proseLineHeight
        maximumLineCount: 3
        elide: Text.ElideRight
        font.family: T3Theme.fontUi
        font.pixelSize: Theme.typography.secondary
        color: T3Theme.red
    }
    }

    onThreadIdChanged: {
        visibleMessages = 10;
        followTail = true;
        menuOpen = false;
        snoozeOpen = false;
        confirmStop = false;
        changesExpanded = false;
        expandedCheckpointRef = "";
        gitSuccessVisible = false;
        dismissedTaskProgressKey = "";
        gitSuccessTimer.stop();
        T3Code.ensureThreadDraft(threadId);
        if (T3Code.state === "connected")
            T3Code.openDetail(threadId);
    }

    Connections {
        target: T3Code
        function onDetailThreadIdChanged() {
            root.expandedMessages = ({});
            root.visibleMessages = 10;
            root.followTail = true;
            root.scrollToEnd();
        }
        function onDetailMessagesChanged() { root.scrollToEnd(); }
        function onDetailCheckpointSummaryChanged() {
            if (root.expandedCheckpointRef !== root.checkpointRef)
                root.changesExpanded = false;
        }
        function onDetailDiffChanged() {
            if (root.changesExpanded)
                root.scrollToEnd();
        }
        function onDetailGitChanged() {
            if (T3Code.detailGit.summary !== "" && T3Code.detailGit.error === ""
                    && !root.gitPending) {
                root.gitSuccessVisible = true;
                gitSuccessTimer.restart();
            } else if (T3Code.detailGit.summary === "" || T3Code.detailGit.error !== "") {
                root.gitSuccessVisible = false;
                gitSuccessTimer.stop();
            }
        }
        function onDetailLoadingChanged() {
            if (!T3Code.detailLoading)
                root.scrollToEnd();
        }
    }

    Component.onCompleted: {
        syncHistory();
        followTail = true;
        changesExpanded = false;
        expandedCheckpointRef = "";
        gitSuccessVisible = false;
        T3Code.ensureThreadDraft(threadId);
        if (T3Code.state === "connected")
            T3Code.openDetail(threadId);
        scrollToEnd();
    }
    Component.onDestruction: T3Code.closeDetail()
}
