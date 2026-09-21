pragma ComponentBehavior: Bound
import QtQuick
import "../Common"

// One full-width conversation surface. Native WebUI history is exposed from
// the header dropdown; the default selection is always the virtual new chat.
Item {
    id: root

    property int maxHeight: 650
    property bool workspaceExpanded: false
    property bool pickerOpen: false
    property bool actionsOpen: false
    property bool confirmDelete: false
    property string pickerQuery: ""
    property string respondingRequestId: ""
    property bool respondingRequestHadFocus: false
    signal setupRequested()
    signal workspaceToggleRequested()

    readonly property var conversation: Hermes.selectedConversation
    readonly property var requests: Hermes.selectedRequests
    readonly property var pickerRows: [HermesConversations.newConversation]
        .concat(Hermes.conversations.filter(conversation =>
            root.matchesPickerSearch(conversation)))
    readonly property bool showPickerSearch: Hermes.conversations.length > 6
        || pickerQuery !== ""
    readonly property var allPriorityConversations: priorityConversations()
    readonly property var priorityRows: allPriorityConversations.slice(0, 3)
    readonly property bool showPriorityHome: Hermes.isNewChat
        && priorityRows.length > 0 && Hermes.selectedError === ""
    readonly property int errorFloor: Hermes.selectedError !== "" ? 64 : 0
    readonly property int transcriptFloor: requests.length > 0 ? errorFloor
        : Math.max(60, Math.min(140, maxHeight - conversationHeader.height
            - composerDock.implicitHeight - content.spacing * 2))
    readonly property int requestFloor: errorFloor > 0 ? 40 : 72
    readonly property int requestMaxHeight: Math.max(requestFloor, maxHeight
        - conversationHeader.height - composerDock.implicitHeight
        - transcriptFloor - content.spacing * 3
        - (requests.length > 1 ? Theme.sectionHeaderHeight : 0))
    readonly property real detachedOverflowHeight:
        composer.modelPickerOverflowHeight
    readonly property Item detachedOverflowItem:
        composer.modelPickerOverflowItem

    width: parent ? parent.width : 0
    // Keep the conversation itself within its normal budget, then append only
    // the model menu's transparent overflow below it.
    implicitHeight: Math.min(maxHeight, content.implicitHeight)
        + detachedOverflowHeight
    height: implicitHeight

    function handleEscape(): bool {
        if (confirmDelete) {
            confirmDelete = false;
            return true;
        }
        if (actionsOpen) {
            closeActions(true);
            return true;
        }
        if (pickerOpen) {
            closePicker(true);
            return true;
        }
        return false;
    }

    function choose(conversationId) {
        closePicker(false);
        closeActions(false);
        Hermes.selectConversation(conversationId);
        Qt.callLater(() => pickerButton.forceActiveFocus());
    }

    function safeCount(value) {
        const count = Number(value);
        return isFinite(count) && count > 0 ? Math.floor(count) : 0;
    }

    function statusWord(conversation) {
        if (!conversation)
            return "";
        if (root.safeCount(conversation.requestCount) > 0
                || conversation.status === "attention")
            return "Needs you";
        if (conversation.status === "error")
            return "Failed";
        if (conversation.status === "working")
            return "Working";
        if (root.safeCount(conversation.unread) > 0)
            return "Unread";
        if (conversation.status === "done")
            return "Done";
        return conversation.status === "idle" ? "Ready"
            : String(conversation.status ?? "");
    }

    function connectionSummary() {
        if (!Hermes.connected)
            return Hermes.connectionError || "Bridge offline";
        if (!Hermes.bridgeReady)
            return Hermes.bridgeError || "Starting Hermes…";
        if (Hermes.remoteLoading)
            return "Checking remote session…";
        if (Hermes.remoteSessionExpired)
            return "Remote session expired";
        if (Hermes.remoteConnected)
            return "Remote · " + Hermes.remoteOrigin;
        if (Hermes.remoteConfigured && Hermes.remoteError !== "")
            return Hermes.remoteError;
        if (Hermes.localProviderReady)
            return "Local · " + Hermes.providerName + " · "
                + Hermes.providerModel;
        return Hermes.setupRequired ? "Connection setup required" : "Ready";
    }

    function connectionColor() {
        if (!Hermes.connected)
            return HermesTheme.red;
        if (!Hermes.bridgeReady || Hermes.remoteLoading || Hermes.remoteSessionExpired
                || Hermes.setupRequired)
            return HermesTheme.amber;
        return HermesTheme.success;
    }

    function priorityFor(conversation) {
        if (!conversation)
            return "";
        if (root.safeCount(conversation.requestCount) > 0
                || conversation.status === "attention")
            return "attention";
        if (conversation.status === "error")
            return "error";
        if (conversation.status === "working")
            return "working";
        if (root.safeCount(conversation.unread) > 0)
            return "unread";
        return "";
    }

    function priorityConversations() {
        const conversations = Array.isArray(Hermes.conversations)
            ? Hermes.conversations : [];
        const ordered = [];
        for (const priority of ["attention", "error", "working", "unread"])
            for (const conversation of conversations)
                if (root.priorityFor(conversation) === priority)
                    ordered.push(conversation);
        return ordered;
    }

    function priorityDetail(conversation) {
        const priority = root.priorityFor(conversation);
        const lead = root.statusWord(conversation);
        const detail = String(conversation?.statusText ?? "").trim();
        if (detail !== "" && detail.toLowerCase() !== lead.toLowerCase()
                && priority !== "unread")
            return lead + " · " + detail;
        return lead;
    }

    function conversationDetail(conversation) {
        if (!conversation || conversation.id === "")
            return "";
        const status = String(conversation.statusText ?? "").trim()
            || root.statusWord(conversation);
        return [conversation.model, conversation.source, status]
            .filter(value => String(value ?? "").trim() !== "")
            .join(" · ");
    }

    function matchesPickerSearch(conversation) {
        const query = pickerQuery.trim().toLowerCase();
        if (query === "")
            return true;
        return [conversation?.title, conversation?.model, conversation?.source,
            conversation?.status, conversation?.statusText,
            root.statusWord(conversation)]
            .some(value => String(value ?? "").toLowerCase().includes(query));
    }

    function focusPickerRow(index) {
        if (!pickerOpen || pickerRows.length === 0)
            return;
        const bounded = Math.max(0, Math.min(index, pickerRows.length - 1));
        pickerList.currentIndex = bounded;
        pickerList.positionViewAtIndex(bounded, ListView.Contain);
        Qt.callLater(() => {
            const item = pickerList.itemAtIndex(bounded);
            if (item)
                item.forceActiveFocus();
            else
                pickerList.forceActiveFocus();
        });
    }

    function openPicker() {
        actionsOpen = false;
        confirmDelete = false;
        pickerOpen = true;
        pickerList.currentIndex = 0;
        Qt.callLater(() => {
            if (!root.pickerOpen)
                return;
            if (root.showPickerSearch)
                pickerSearchInput.forceActiveFocus();
            else
                root.focusPickerRow(0);
        });
    }

    function closePicker(restoreFocus, restoreIfHidden) {
        pickerOpen = false;
        pickerQuery = "";
        if (restoreFocus === true)
            Qt.callLater(() => pickerButton.forceActiveFocus());
        else if (restoreIfHidden === true)
            restoreTriggerIfFocusHidden(pickerPopup, pickerButton);
    }

    function togglePicker() {
        if (pickerOpen)
            closePicker(true);
        else
            openPicker();
    }

    function openActions() {
        pickerOpen = false;
        pickerQuery = "";
        actionsOpen = true;
        Qt.callLater(() => {
            if (!root.actionsOpen)
                return;
            setupAction.forceActiveFocus();
        });
    }

    function closeActions(restoreFocus, restoreIfHidden) {
        actionsOpen = false;
        confirmDelete = false;
        if (restoreFocus === true)
            Qt.callLater(() => actionsButton.forceActiveFocus());
        else if (restoreIfHidden === true)
            restoreTriggerIfFocusHidden(actionsPopup, actionsButton);
    }

    function restoreConversationFocus() {
        Qt.callLater(() => {
            if (composer.editable)
                composer.focusPrompt();
            else
                pickerButton.forceActiveFocus();
        });
    }

    function trackRequestResponse(requestId) {
        respondingRequestId = requestId;
        const focused = root.Window.window?.activeFocusItem ?? null;
        respondingRequestHadFocus = root.itemBelongsTo(focused, requestArea);
    }

    function focusToolbar() {
        pickerButton.forceActiveFocus();
    }

    function toggleActions() {
        if (actionsOpen)
            closeActions(true);
        else
            openActions();
    }

    function focusAdjacentAction(item, delta) {
        const actions = [setupAction, refreshAction, branchAction,
            compressAction, deleteAction]
            .filter(action => action.visible && action.actionEnabled);
        if (actions.length === 0)
            return;
        let index = actions.indexOf(item);
        index = (index + delta + actions.length) % actions.length;
        actions[index].forceActiveFocus();
    }

    function containsItemPoint(target, item, x, y) {
        if (!target || !target.visible)
            return false;
        const point = target.mapFromItem(item, x, y);
        return point.x >= 0 && point.x <= target.width
            && point.y >= 0 && point.y <= target.height;
    }

    function containsOpenMenuPoint(item, x, y) {
        if (pickerOpen && (containsItemPoint(pickerButton, item, x, y)
                || containsItemPoint(pickerPopup, item, x, y)))
            return true;
        if (actionsOpen && (containsItemPoint(actionsButton, item, x, y)
                || containsItemPoint(actionsPopup, item, x, y)))
            return true;
        return false;
    }

    function itemBelongsTo(item, ancestor) {
        let current = item;
        while (current) {
            if (current === ancestor)
                return true;
            current = current.parent;
        }
        return false;
    }

    function restoreTriggerIfFocusHidden(popup, trigger) {
        Qt.callLater(() => {
            const focused = root.Window.window?.activeFocusItem ?? null;
            if (!focused || root.itemBelongsTo(focused, popup))
                trigger.forceActiveFocus();
        });
    }

    onShowPickerSearchChanged: {
        if (!pickerOpen || showPickerSearch)
            return;
        Qt.callLater(() => {
            const focused = root.Window.window?.activeFocusItem ?? null;
            if (root.itemBelongsTo(focused, pickerSearchBox))
                root.focusPickerRow(0);
        });
    }

    onRequestsChanged: {
        if (respondingRequestId === "" || requests.some(request =>
                String(request.id ?? "") === respondingRequestId))
            return;
        const focused = root.Window.window?.activeFocusItem ?? null;
        const restore = respondingRequestHadFocus
            && (!focused || root.itemBelongsTo(focused, requestArea));
        respondingRequestId = "";
        respondingRequestHadFocus = false;
        if (restore)
            restoreConversationFocus();
    }

    component CountBadge: Rectangle {
        id: badge
        property string label: ""
        property color tint: HermesTheme.textMuted
        property color fill: HermesTheme.hover
        property color outline: HermesTheme.border

        implicitWidth: badgeLabel.implicitWidth + 10
        implicitHeight: 18
        width: implicitWidth
        height: implicitHeight
        radius: height / 2
        color: fill
        border.width: 1
        border.color: outline
        Accessible.ignored: true

        Text {
            id: badgeLabel
            anchors.centerIn: parent
            text: badge.label
            font.family: HermesTheme.fontUi
            font.pixelSize: Theme.typography.metadata
            font.weight: Theme.weightSemibold
            font.features: HermesTheme.tabularNumberFeatures
            color: badge.tint
        }
    }

    component ActivityRow: Rectangle {
        id: activityRow
        required property var conversation
        required property int index

        readonly property string priority: root.priorityFor(conversation)
        readonly property int requestCount:
            root.safeCount(conversation.requestCount)
        readonly property int unreadCount: root.safeCount(conversation.unread)
        readonly property color statusColor: priority === "attention"
            ? HermesTheme.amber : priority === "error" ? HermesTheme.red
                : priority === "working" ? HermesTheme.success
                    : HermesTheme.accent
        readonly property string statusSymbol: priority === "attention" ? "help"
            : priority === "error" ? "error"
                : priority === "working" ? "progress_activity"
                    : "mark_chat_unread"

        width: parent ? parent.width : 0
        height: 40
        radius: HermesTheme.rowRadius
        color: activityMouse.containsMouse || activeFocus
            ? HermesTheme.hoverStrong
            : priority === "attention" ? HermesTheme.amberSoft
                : priority === "error" ? HermesTheme.redSoft : "transparent"
        border.width: activeFocus || priority === "attention"
            || priority === "error" ? 1 : 0
        border.color: activeFocus ? HermesTheme.focus
            : priority === "attention" ? HermesTheme.amberBorder
                : priority === "error" ? HermesTheme.redBorder
                    : HermesTheme.border
        activeFocusOnTab: true
        Accessible.role: Accessible.Button
        Accessible.name: String(conversation.title ?? "Conversation") + ", "
            + root.priorityDetail(conversation)
            + (requestCount > 0 ? ", " + requestCount
                + (requestCount === 1 ? " request" : " requests") : "")
            + (unreadCount > 0 ? ", " + unreadCount + " unread" : "")
        Accessible.onPressAction: root.choose(conversation.id)

        Keys.onPressed: event => {
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                    || event.key === Qt.Key_Space) {
                root.choose(activityRow.conversation.id);
                event.accepted = true;
            } else if (event.key === Qt.Key_Down && activityRow.index + 1
                    < activityRepeater.count) {
                activityRepeater.itemAt(activityRow.index + 1).forceActiveFocus();
                event.accepted = true;
            } else if (event.key === Qt.Key_Up && activityRow.index > 0) {
                activityRepeater.itemAt(activityRow.index - 1).forceActiveFocus();
                event.accepted = true;
            }
        }

        Sym {
            id: activityGlyph
            x: 9
            anchors.verticalCenter: parent.verticalCenter
            name: activityRow.statusSymbol
            size: Theme.iconSmall
            symWeight: 500
            color: activityRow.statusColor
        }

        Column {
            anchors.left: activityGlyph.right
            anchors.leftMargin: 8
            anchors.right: activitySide.left
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            spacing: 1

            Text {
                width: parent.width
                text: String(activityRow.conversation.title ?? "Conversation")
                elide: Text.ElideRight
                font.family: HermesTheme.fontUi
                font.pixelSize: Theme.typography.secondary
                font.weight: Theme.weightSemibold
                color: HermesTheme.textPrimary
            }

            Text {
                width: parent.width
                text: root.priorityDetail(activityRow.conversation)
                elide: Text.ElideRight
                font.family: HermesTheme.fontUi
                font.pixelSize: Theme.typography.metadata
                color: activityRow.statusColor
            }
        }

        Row {
            id: activitySide
            anchors.right: parent.right
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            spacing: 4

            CountBadge {
                visible: activityRow.requestCount > 0
                width: visible ? implicitWidth : 0
                label: activityRow.requestCount + " req"
                tint: HermesTheme.amber
                fill: HermesTheme.amberSoft
                outline: HermesTheme.amberBorder
            }

            CountBadge {
                visible: activityRow.unreadCount > 0
                width: visible ? implicitWidth : 0
                label: activityRow.unreadCount + " new"
                tint: HermesTheme.accent
                fill: HermesTheme.accentSubtle
                outline: HermesTheme.borderStrong
            }

            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: Hermes.relativeTime(activityRow.conversation.updatedAt)
                font.family: HermesTheme.fontUi
                font.pixelSize: Theme.typography.metadata
                font.features: HermesTheme.tabularNumberFeatures
                color: HermesTheme.textFaint
            }

            Sym {
                anchors.verticalCenter: parent.verticalCenter
                name: "chevron_right"
                size: Theme.iconTiny
                color: HermesTheme.textFaint
            }
        }

        MouseArea {
            id: activityMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                activityRow.forceActiveFocus();
                root.choose(activityRow.conversation.id);
            }
        }
    }

    TapHandler {
        enabled: root.pickerOpen || root.actionsOpen
        margin: root.Window.window
            ? Math.max(root.Window.window.width, root.Window.window.height) : 0
        onTapped: eventPoint => {
            if (root.containsOpenMenuPoint(root, eventPoint.position.x,
                    eventPoint.position.y))
                return;
            root.closePicker(false, true);
            root.closeActions(false, true);
        }
    }

    Column {
        id: content
        width: parent.width
        spacing: 5

        Rectangle {
            id: conversationHeader
            width: parent.width
            height: 42
            radius: 0
            color: "transparent"
            border.width: 0
            z: 600

            IconButton {
                id: backButton
                visible: !Hermes.isNewChat
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                controlSize: 32
                symbol: "arrow_back"
                accessibleName: "Back to new Hermes chat"
                onTriggered: root.choose("")
            }

            Rectangle {
                id: connectionDot
                anchors.left: backButton.visible ? backButton.right : parent.left
                anchors.leftMargin: backButton.visible ? 5 : 4
                anchors.verticalCenter: parent.verticalCenter
                width: 6
                height: 6
                radius: 3
                color: root.connectionColor()
                Accessible.ignored: true
            }

            Rectangle {
                id: pickerButton
                anchors.left: connectionDot.right
                anchors.leftMargin: 6
                anchors.right: headerActions.left
                anchors.rightMargin: 4
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                radius: HermesTheme.controlRadius
                color: pickerMouse.containsMouse || activeFocus
                    ? HermesTheme.hover : "transparent"
                activeFocusOnTab: true
                Accessible.role: Accessible.Button
                Accessible.name: "Hermes conversation: "
                    + (root.conversation?.title ?? "New chat")
                Accessible.description: "Open conversation history"
                Accessible.onPressAction: root.togglePicker()

                Keys.onPressed: event => {
                    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                            || event.key === Qt.Key_Space) {
                        root.togglePicker();
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Down) {
                        if (!root.pickerOpen)
                            root.openPicker();
                        else
                            root.focusPickerRow(0);
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Escape
                            && root.pickerOpen) {
                        root.closePicker(true);
                        event.accepted = true;
                    }
                }

                Column {
                    anchors.left: parent.left
                    anchors.leftMargin: 7
                    anchors.right: pickerChevron.left
                    anchors.rightMargin: 7
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2

                    Text {
                        width: parent.width
                        text: root.conversation?.title ?? "New chat"
                        elide: Text.ElideRight
                        font.family: HermesTheme.fontUi
                        font.pixelSize: Theme.typography.primary
                        font.weight: Theme.weightSemibold
                        color: HermesTheme.textPrimary
                    }

                    Text {
                        width: parent.width
                        text: {
                            if (Hermes.isNewChat)
                                return "Start a new Hermes conversation";
                            if (root.conversation?.readOnly === true)
                                return "Read-only history";
                            return root.conversation?.statusText
                                || root.conversation?.model || "Ready";
                        }
                        elide: Text.ElideRight
                        font.family: HermesTheme.fontUi
                        font.pixelSize: Theme.typography.secondary
                        color: root.conversation?.status === "attention"
                            ? HermesTheme.amber
                            : root.conversation?.status === "error"
                                ? HermesTheme.red : HermesTheme.textFaint
                    }
                }

                Sym {
                    id: pickerChevron
                    anchors.right: parent.right
                    anchors.rightMargin: 7
                    anchors.verticalCenter: parent.verticalCenter
                    name: root.pickerOpen ? "expand_less" : "expand_more"
                    size: Theme.iconSmall
                    symWeight: 500
                    color: root.pickerOpen ? HermesTheme.accent
                        : HermesTheme.textMuted
                }

                MouseArea {
                    id: pickerMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        pickerButton.forceActiveFocus();
                        root.togglePicker();
                    }
                }
            }

            Row {
                id: headerActions
                anchors.right: parent.right
                anchors.rightMargin: 4
                anchors.verticalCenter: parent.verticalCenter
                spacing: 1

                IconButton {
                    symbol: root.workspaceExpanded ? "close_fullscreen" : "open_in_full"
                    accessibleName: root.workspaceExpanded
                        ? "Use compact Hermes popover" : "Expand Hermes workspace"
                    accessibleDescription: root.workspaceExpanded
                        ? "Return to the glanceable view" : "Use more width and conversation height"
                    controlSize: 30
                    tint: root.workspaceExpanded ? HermesTheme.accent : HermesTheme.textMuted
                    onTriggered: root.workspaceToggleRequested()
                }

                IconButton {
                    id: actionsButton
                    symbol: "more_horiz"
                    accessibleName: "Hermes menu"
                    accessibleDescription: "Connection: "
                        + root.connectionSummary()
                    controlSize: 30
                    tint: root.actionsOpen ? HermesTheme.accent
                        : HermesTheme.textMuted
                    onTriggered: root.toggleActions()
                }
            }

            Rectangle {
                id: pickerPopup
                visible: root.pickerOpen
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.bottom
                anchors.topMargin: 3
                height: Math.min(330, Math.max(58, 10
                    + (root.showPickerSearch ? 39 : 0)
                    + (root.pickerRows.length > 0 ? 44
                        + Math.max(0, root.pickerRows.length - 1) * 49 : 0)
                    + (Hermes.conversationsLoading
                        || Hermes.conversationsError !== ""
                        || (root.pickerQuery !== ""
                            && root.pickerRows.length === 1) ? 39 : 0)))
                radius: HermesTheme.panelRadius
                color: HermesTheme.overlay
                border.width: 1
                border.color: HermesTheme.borderStrong
                clip: true

                Rectangle {
                    id: pickerSearchBox
                    visible: root.showPickerSearch
                    x: 5
                    y: 5
                    width: parent.width - 10
                    height: visible ? 34 : 0
                    radius: HermesTheme.controlRadius
                    color: HermesTheme.surfaceRaised
                    border.width: pickerSearchInput.activeFocus ? 1 : 0
                    border.color: HermesTheme.focus

                    Sym {
                        id: pickerSearchIcon
                        anchors.left: parent.left
                        anchors.leftMargin: 9
                        anchors.verticalCenter: parent.verticalCenter
                        name: "search"
                        size: Theme.iconSmall
                        symWeight: 450
                        color: HermesTheme.textFaint
                    }

                    TextInput {
                        id: pickerSearchInput
                        anchors.left: pickerSearchIcon.right
                        anchors.leftMargin: 6
                        anchors.right: clearPickerSearch.visible
                            ? clearPickerSearch.left : parent.right
                        anchors.rightMargin: clearPickerSearch.visible ? 3 : 9
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.pickerQuery
                        onTextEdited: {
                            root.pickerQuery = text;
                            pickerList.currentIndex = 0;
                        }
                        clip: true
                        selectByMouse: true
                        font.family: HermesTheme.fontUi
                        font.pixelSize: Theme.typography.control
                        color: HermesTheme.textPrimary
                        Accessible.name: "Search Hermes conversation history"
                        Accessible.role: Accessible.EditableText

                        Text {
                            visible: pickerSearchInput.text === ""
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Search conversations"
                            font.family: HermesTheme.fontUi
                            font.pixelSize: Theme.typography.control
                            color: HermesTheme.textFaint
                        }

                        Keys.onPressed: event => {
                            if (event.key === Qt.Key_Down) {
                                root.focusPickerRow(0);
                                event.accepted = true;
                            } else if (event.key === Qt.Key_Up) {
                                root.focusPickerRow(root.pickerRows.length - 1);
                                event.accepted = true;
                            } else if ((event.key === Qt.Key_Return
                                    || event.key === Qt.Key_Enter)
                                    && root.pickerQuery !== ""
                                    && root.pickerRows.length > 1) {
                                root.choose(root.pickerRows[1].id);
                                event.accepted = true;
                            } else if (event.key === Qt.Key_Escape) {
                                root.closePicker(true);
                                event.accepted = true;
                            }
                        }
                    }

                    IconButton {
                        id: clearPickerSearch
                        visible: pickerSearchInput.text !== ""
                        anchors.right: parent.right
                        anchors.rightMargin: 4
                        anchors.verticalCenter: parent.verticalCenter
                        controlSize: 26
                        symbol: "close"
                        accessibleName: "Clear conversation search"
                        tint: HermesTheme.textFaint
                        onTriggered: {
                            root.pickerQuery = "";
                            Qt.callLater(() => {
                                if (root.showPickerSearch)
                                    pickerSearchInput.forceActiveFocus();
                                else
                                    root.focusPickerRow(0);
                            });
                        }
                    }
                }

                ListView {
                    id: pickerList
                    cacheBuffer: 0
                    anchors.left: parent.left
                    anchors.leftMargin: 5
                    anchors.right: parent.right
                    anchors.rightMargin: 5
                    anchors.top: root.showPickerSearch
                        ? pickerSearchBox.bottom : parent.top
                    anchors.topMargin: root.showPickerSearch ? 4 : 5
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: 5
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    spacing: 1
                    keyNavigationEnabled: true
                    // A closed dropdown should own no row delegates. When it is
                    // open, ListView creates only the handful inside its 330px
                    // viewport instead of all historical conversations.
                    model: root.pickerOpen ? root.pickerRows : []

                    delegate: Rectangle {
                        id: conversationRow
                        required property var modelData
                        required property int index

                        readonly property bool selected:
                            modelData.id === Hermes.selectedConversationId
                        readonly property int requestCount:
                            root.safeCount(modelData.requestCount)
                        readonly property int unreadCount:
                            root.safeCount(modelData.unread)
                        readonly property string priority:
                            root.priorityFor(modelData)

                        width: pickerList.width
                        height: modelData.id === "" ? 44 : 48
                        radius: HermesTheme.controlRadius
                        color: selected ? HermesTheme.hoverStrong
                            : rowMouse.containsMouse || activeFocus
                                ? HermesTheme.hover : "transparent"
                        border.width: activeFocus ? 1 : 0
                        border.color: HermesTheme.focus
                        activeFocusOnTab: true
                        Accessible.role: Accessible.Button
                        Accessible.name: modelData.id === ""
                            ? "New chat" : "Conversation " + modelData.title
                                + ", " + root.statusWord(modelData)
                                + (requestCount > 0 ? ", " + requestCount
                                    + (requestCount === 1 ? " request" : " requests") : "")
                                + (unreadCount > 0 ? ", " + unreadCount
                                    + " unread" : "")
                        Accessible.onPressAction: root.choose(modelData.id)
                        onActiveFocusChanged: if (activeFocus)
                            pickerList.currentIndex = index

                        Keys.onPressed: event => {
                            if (event.key === Qt.Key_Return
                                    || event.key === Qt.Key_Enter
                                    || event.key === Qt.Key_Space) {
                                root.choose(conversationRow.modelData.id);
                                event.accepted = true;
                            } else if (event.key === Qt.Key_Down) {
                                root.focusPickerRow(conversationRow.index + 1);
                                event.accepted = true;
                            } else if (event.key === Qt.Key_Up) {
                                if (conversationRow.index === 0
                                        && root.showPickerSearch)
                                    pickerSearchInput.forceActiveFocus();
                                else
                                    root.focusPickerRow(conversationRow.index - 1);
                                event.accepted = true;
                            } else if (event.key === Qt.Key_Home) {
                                root.focusPickerRow(0);
                                event.accepted = true;
                            } else if (event.key === Qt.Key_End) {
                                root.focusPickerRow(root.pickerRows.length - 1);
                                event.accepted = true;
                            } else if (event.key === Qt.Key_Escape) {
                                root.closePicker(true);
                                event.accepted = true;
                            }
                        }

                        Rectangle {
                            id: statusDot
                            x: 8
                            anchors.verticalCenter: parent.verticalCenter
                            width: 6
                            height: 6
                            radius: 3
                            color: conversationRow.modelData.id === ""
                                ? HermesTheme.accent
                                : conversationRow.priority === "attention"
                                    ? HermesTheme.amber
                                    : conversationRow.priority === "error"
                                        ? HermesTheme.red
                                        : conversationRow.priority === "working"
                                            ? HermesTheme.success
                                            : conversationRow.priority === "unread"
                                                ? HermesTheme.accent
                                                : HermesTheme.textFaint
                        }

                        Column {
                            anchors.left: statusDot.right
                            anchors.leftMargin: 8
                            anchors.right: historyBadges.visible
                                ? historyBadges.left : rowMeta.left
                            anchors.rightMargin: 8
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 2

                            Text {
                                width: parent.width
                                text: conversationRow.modelData.title
                                elide: Text.ElideRight
                                font.family: HermesTheme.fontUi
                                font.pixelSize: Theme.typography.secondary
                                font.weight: conversationRow.selected
                                    ? Theme.weightSemibold : Theme.weightMedium
                                color: conversationRow.selected
                                    ? HermesTheme.textPrimary
                                    : HermesTheme.textSecondary
                            }

                            Text {
                                visible: conversationRow.modelData.id !== ""
                                width: parent.width
                                text: root.conversationDetail(
                                    conversationRow.modelData)
                                elide: Text.ElideRight
                                font.family: HermesTheme.fontUi
                                font.pixelSize: Theme.typography.metadata
                                color: conversationRow.priority === "attention"
                                    ? HermesTheme.amber
                                    : conversationRow.priority === "error"
                                        ? HermesTheme.red
                                        : HermesTheme.textFaint
                            }
                        }

                        Row {
                            id: historyBadges
                            visible: conversationRow.modelData.id !== ""
                                && (conversationRow.requestCount > 0
                                    || conversationRow.unreadCount > 0)
                            anchors.right: rowMeta.left
                            anchors.rightMargin: 6
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 3

                            CountBadge {
                                visible: conversationRow.requestCount > 0
                                width: visible ? implicitWidth : 0
                                label: conversationRow.requestCount + " req"
                                tint: HermesTheme.amber
                                fill: HermesTheme.amberSoft
                                outline: HermesTheme.amberBorder
                            }

                            CountBadge {
                                visible: conversationRow.unreadCount > 0
                                width: visible ? implicitWidth : 0
                                label: conversationRow.unreadCount + " new"
                                tint: HermesTheme.accent
                                fill: HermesTheme.accentSubtle
                                outline: HermesTheme.borderStrong
                            }
                        }

                        Text {
                            id: rowMeta
                            anchors.right: parent.right
                            anchors.rightMargin: 8
                            anchors.verticalCenter: parent.verticalCenter
                            width: 58
                            horizontalAlignment: Text.AlignRight
                            text: conversationRow.modelData.id === ""
                                ? "NEW" : Hermes.relativeTime(
                                    conversationRow.modelData.updatedAt)
                            font.family: HermesTheme.fontUi
                            font.pixelSize: Theme.typography.metadata
                            font.features: HermesTheme.tabularNumberFeatures
                            color: conversationRow.modelData.id === ""
                                ? HermesTheme.accent : HermesTheme.textFaint
                        }

                        MouseArea {
                            id: rowMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                conversationRow.forceActiveFocus();
                                root.choose(conversationRow.modelData.id);
                            }
                        }
                    }

                    footer: Text {
                        visible: Hermes.conversationsLoading
                            || Hermes.conversationsError !== ""
                            || (root.pickerQuery !== ""
                                && root.pickerRows.length === 1)
                        width: pickerList.width
                        height: visible ? 38 : 0
                        verticalAlignment: Text.AlignVCenter
                        horizontalAlignment: Text.AlignHCenter
                        text: Hermes.conversationsLoading
                            ? "Loading history…"
                            : Hermes.conversationsError !== ""
                                ? Hermes.conversationsError
                                : "No history matches “" + root.pickerQuery + "”"
                        elide: Text.ElideRight
                        font.family: HermesTheme.fontUi
                        font.pixelSize: Theme.typography.secondary
                        color: Hermes.conversationsError !== ""
                            ? HermesTheme.red : HermesTheme.textFaint
                    }
                }

                ScrollChrome { target: pickerList }
            }

            Rectangle {
                id: actionsPopup
                visible: root.actionsOpen
                anchors.right: parent.right
                anchors.rightMargin: 4
                anchors.top: parent.bottom
                anchors.topMargin: 3
                width: Math.min(280, conversationHeader.width - 8)
                height: actionsColumn.implicitHeight + 10
                radius: HermesTheme.panelRadius
                color: HermesTheme.overlay
                border.width: 1
                border.color: HermesTheme.borderStrong

                component Entry: Rectangle {
                    id: entry
                    property string label: ""
                    property string symbol: ""
                    property color tint: HermesTheme.textSecondary
                    property bool actionEnabled: true
                    signal triggered()
                    width: parent ? parent.width : 0
                    height: 34
                    radius: HermesTheme.controlRadius
                    color: (entryMouse.containsMouse || activeFocus) && actionEnabled
                        ? HermesTheme.hoverStrong : "transparent"
                    border.width: activeFocus ? 1 : 0
                    border.color: HermesTheme.focus
                    opacity: actionEnabled ? 1 : 0.38
                    activeFocusOnTab: actionEnabled && visible
                    Accessible.role: Accessible.Button
                    Accessible.name: label
                    Accessible.onPressAction: {
                        if (actionEnabled)
                            triggered();
                    }

                    Keys.onPressed: event => {
                        if ((event.key === Qt.Key_Return
                                || event.key === Qt.Key_Enter
                                || event.key === Qt.Key_Space)
                                && entry.actionEnabled) {
                            entry.triggered();
                            event.accepted = true;
                        } else if (event.key === Qt.Key_Escape) {
                            root.closeActions(true);
                            event.accepted = true;
                        } else if (event.key === Qt.Key_Down) {
                            root.focusAdjacentAction(entry, 1);
                            event.accepted = true;
                        } else if (event.key === Qt.Key_Up) {
                            root.focusAdjacentAction(entry, -1);
                            event.accepted = true;
                        }
                    }

                    Sym {
                        id: entryIcon
                        x: 8
                        anchors.verticalCenter: parent.verticalCenter
                        name: entry.symbol
                        size: Theme.iconSmall
                        symWeight: 450
                        color: entry.tint
                    }
                    Text {
                        anchors.left: entryIcon.right
                        anchors.leftMargin: 8
                        anchors.right: parent.right
                        anchors.rightMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        text: entry.label
                        elide: Text.ElideRight
                        font.family: HermesTheme.fontUi
                        font.pixelSize: Theme.typography.secondary
                        color: entry.tint
                    }
                    MouseArea {
                        id: entryMouse
                        anchors.fill: parent
                        enabled: entry.actionEnabled
                        hoverEnabled: true
                        cursorShape: enabled ? Qt.PointingHandCursor
                            : Qt.ForbiddenCursor
                        onClicked: {
                            entry.forceActiveFocus();
                            entry.triggered();
                        }
                    }
                }

                Column {
                    id: actionsColumn
                    x: 5
                    y: 5
                    width: parent.width - 10
                    spacing: 1

                    Rectangle {
                        id: connectionInfo
                        width: parent.width
                        height: Math.max(44,
                            connectionInfoCopy.implicitHeight + 14)
                        radius: HermesTheme.controlRadius
                        color: HermesTheme.surfaceRaised
                        border.width: 1
                        border.color: HermesTheme.border
                        Accessible.role: Accessible.StaticText
                        Accessible.name: "Hermes connection"
                        Accessible.description: root.connectionSummary()

                        Rectangle {
                            anchors.left: parent.left
                            anchors.leftMargin: 9
                            anchors.top: parent.top
                            anchors.topMargin: 14
                            width: 7
                            height: 7
                            radius: 4
                            color: root.connectionColor()
                            Accessible.ignored: true
                        }

                        Column {
                            id: connectionInfoCopy
                            anchors.left: parent.left
                            anchors.leftMargin: 25
                            anchors.right: parent.right
                            anchors.rightMargin: 9
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 2

                            Text {
                                width: parent.width
                                text: "CONNECTION"
                                font.family: HermesTheme.fontUi
                                font.pixelSize: Theme.typography.metadata
                                font.weight: Theme.weightSemibold
                                font.letterSpacing: 1
                                color: HermesTheme.textMuted
                            }

                            Text {
                                width: parent.width
                                text: root.connectionSummary()
                                wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                                maximumLineCount: 2
                                elide: Text.ElideRight
                                font.family: Hermes.remoteConnected
                                    ? HermesTheme.fontMono : HermesTheme.fontUi
                                font.pixelSize: Theme.typography.secondary
                                color: HermesTheme.textSecondary
                            }
                        }
                    }

                    Item {
                        width: 1
                        height: 4
                    }

                    Entry {
                        id: setupAction
                        label: "Connection setup"
                        symbol: "key"
                        onTriggered: {
                            root.closeActions(false);
                            root.setupRequested();
                        }
                    }

                    Entry {
                        id: refreshAction
                        label: Hermes.isNewChat ? "Refresh conversations"
                            : "Refresh conversation"
                        symbol: "refresh"
                        actionEnabled: Hermes.connected
                        onTriggered: {
                            root.closeActions(true);
                            HermesConversations.refreshAll();
                            if (!Hermes.isNewChat)
                                HermesConversations.refreshConversation(
                                    Hermes.selectedConversationId);
                        }
                    }

                    Rectangle {
                        visible: !Hermes.isNewChat
                        width: parent.width - 10
                        x: 5
                        height: visible ? 5 : 0
                        color: "transparent"

                        Rectangle {
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            height: 1
                            color: HermesTheme.border
                        }
                    }

                    Entry {
                        id: branchAction
                        visible: !Hermes.isNewChat
                            && Hermes.capabilities.branches === true
                        height: visible ? 34 : 0
                        label: Hermes.actionPending("branch",
                            Hermes.selectedConversationId, "all")
                            ? "Branching…" : "Branch conversation"
                        symbol: "call_split"
                        actionEnabled: root.conversation?.readOnly !== true
                            && root.conversation?.status !== "working"
                            && !Hermes.actionPending("branch",
                                Hermes.selectedConversationId, "all")
                        onTriggered: {
                            root.closeActions(true);
                            Hermes.branchConversation(
                                Hermes.selectedConversationId, undefined);
                        }
                    }

                    Entry {
                        id: compressAction
                        visible: !Hermes.isNewChat
                        height: visible ? 34 : 0
                        label: "Compress context"
                        symbol: "compress"
                        actionEnabled: root.conversation?.readOnly !== true
                        onTriggered: {
                            root.closeActions(true);
                            Hermes.compress(Hermes.selectedConversationId);
                        }
                    }
                    Entry {
                        id: deleteAction
                        visible: !Hermes.isNewChat
                        height: visible ? 34 : 0
                        label: root.confirmDelete
                            ? "Confirm delete" : "Delete conversation"
                        symbol: "delete"
                        tint: HermesTheme.red
                        actionEnabled: root.conversation?.readOnly !== true
                        onTriggered: {
                            if (!root.confirmDelete) {
                                root.confirmDelete = true;
                                return;
                            }
                            root.closeActions(true);
                            Hermes.deleteConversation(
                                Hermes.selectedConversationId);
                        }
                    }
                }
            }
        }

        Column {
            id: activityHome
            visible: root.showPriorityHome
            width: parent.width
            height: visible ? Math.max(140, implicitHeight) : 0
            spacing: 3

            Item {
                width: parent.width
                height: Theme.sectionHeaderHeight + 4

                Text {
                    id: activityHeading
                    anchors.left: parent.left
                    anchors.leftMargin: 2
                    anchors.verticalCenter: parent.verticalCenter
                    text: "ACTIVE CONVERSATIONS"
                    font.family: HermesTheme.fontUi
                    font.pixelSize: Theme.typography.metadata
                    font.weight: Theme.weightSemibold
                    font.letterSpacing: 1
                    color: HermesTheme.textMuted
                }

                Text {
                    id: activityCount
                    anchors.left: activityHeading.right
                    anchors.leftMargin: 7
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.allPriorityConversations.length
                    font.family: HermesTheme.fontUi
                    font.pixelSize: Theme.typography.metadata
                    font.weight: Theme.weightMedium
                    font.features: HermesTheme.tabularNumberFeatures
                    color: HermesTheme.textFaint
                }

                Rectangle {
                    anchors.left: activityCount.right
                    anchors.leftMargin: 10
                    anchors.right: activityLimit.visible
                        ? activityLimit.left : parent.right
                    anchors.rightMargin: activityLimit.visible ? 8 : 2
                    anchors.verticalCenter: parent.verticalCenter
                    height: 1
                    color: HermesTheme.border
                }

                Text {
                    id: activityLimit
                    visible: root.allPriorityConversations.length > 3
                    anchors.right: parent.right
                    anchors.rightMargin: 2
                    anchors.verticalCenter: parent.verticalCenter
                    text: "TOP 3"
                    font.family: HermesTheme.fontUi
                    font.pixelSize: Theme.typography.metadata
                    font.weight: Theme.weightMedium
                    font.letterSpacing: 0.7
                    color: HermesTheme.textFaint
                }
            }

            Repeater {
                id: activityRepeater
                model: root.priorityRows

                delegate: ActivityRow {
                    required property var modelData
                    conversation: modelData
                }
            }
        }

        HermesTranscript {
            id: transcript
            visible: !root.showPriorityHome
            width: parent.width
            conversationId: Hermes.selectedConversationId
            minHeight: root.transcriptFloor
            maxHeight: Math.max(root.transcriptFloor,
                root.maxHeight - conversationHeader.height
                - requestArea.height - composerDock.implicitHeight
                - content.spacing * 3)
            onErrorHandled: root.restoreConversationFocus()
        }

        Column {
            id: requestArea
            visible: root.requests.length > 0
            width: parent.width
            height: visible ? implicitHeight : 0
            spacing: 4

            Text {
                visible: root.requests.length > 1
                width: parent.width
                text: "1 shown · " + (root.requests.length - 1) + " more queued"
                horizontalAlignment: Text.AlignRight
                font.family: HermesTheme.fontUi
                font.pixelSize: Theme.typography.metadata
                color: HermesTheme.textFaint
            }

            Repeater {
                model: root.requests.length > 0 ? [root.requests[0]] : []
                delegate: HermesRequestCard {
                    required property var modelData
                    width: parent.width
                    conversationId: Hermes.selectedConversationId
                    request: modelData
                    maxHeight: root.requestMaxHeight
                    onResponseStarted: requestId =>
                        root.trackRequestResponse(requestId)
                }
            }
        }

        Item {
            id: composerDock
            width: parent.width
            implicitHeight: sessionStrip.height + composer.height

            HermesSessionStrip {
                id: sessionStrip
                anchors.top: parent.top
                width: parent.width
                conversationId: Hermes.selectedConversationId
                forceCompact: root.requests.length > 0 || root.maxHeight < 580
                onFocusFallbackRequested: root.restoreConversationFocus()
            }

            HermesComposer {
                id: composer
                anchors.top: sessionStrip.bottom
                width: parent.width
                z: 2
                conversationId: Hermes.selectedConversationId
            }
        }
    }
}
