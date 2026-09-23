pragma ComponentBehavior: Bound
import QtQuick
import "../Common"

// Full Hermes menubar mini-client: connection health, native WebUI conversation
// history, streaming chat, tool/request activity and durable context.
Surface {
    id: root

    spacing: 6
    padding: HermesTheme.pagePadding
    surfaceColor: Theme.barSurface
    surfaceBorderColor: Theme.surfaceBorderColor

    availableWidth: 560 - Theme.barSideMargin * 2
    availableHeight: 900 - Theme.barTopMargin - Theme.barHeight - 16
    property bool workspaceExpanded: false
    implicitWidth: Math.max(Theme.t3MinWidth,
        Math.min(workspaceExpanded ? 760 : 520, root.availableWidth))

    readonly property int bodyBudget: Math.max(420, root.availableHeight
        - root.padding * 2 - header.height - footer.height
        - root.spacing * 2)
    readonly property int threadMaxHeight: workspaceExpanded ? bodyBudget
        : Math.min(bodyBudget, Math.max(520, Math.round(root.availableHeight / 2)))

    detachedOverflowHeight: !root.showingSetup
        ? inbox.detachedOverflowHeight : 0
    detachedOverflowItem: !root.showingSetup
        ? inbox.detachedOverflowItem : null

    property bool setupOpen: false
    readonly property bool showingSetup: setupOpen
        || Hermes.bridgeReady && Hermes.setupRequired

    onShowingSetupChanged: Qt.callLater(() => {
        if (!root.visible)
            return;
        if (root.showingSetup)
            authPanel.focusFirstField();
        else
            inbox.focusToolbar();
    })

    function openSetup() {
        setupOpen = true;
        Qt.callLater(() => authPanel.focusFirstField());
    }

    function closeSetup() {
        setupOpen = false;
        authPanel.clearSecret();
        Qt.callLater(() => {
            if (root.showingSetup)
                authPanel.focusFirstField();
            else
                inbox.focusToolbar();
        });
    }

    function handleEscape(): bool {
        if (showingSetup && setupOpen && Hermes.agentReady) {
            closeSetup();
            return true;
        }
        if (!showingSetup && inbox.handleEscape())
            return true;
        if (workspaceExpanded) {
            workspaceExpanded = false;
            return true;
        }
        return false;
    }

    Claim {
        active: root.visible
        onClaimed: {
            Hermes.setPopoverVisible(true);
            // refresh() re-checks remote and provider status and reloads the
            // list, so each probe runs once per open rather than twice.
            if (Hermes.bridgeReady || !Hermes.conversationsReady
                    || Hermes.conversations.length === 0)
                Hermes.refresh();
        }
        onReleased: {
            Hermes.setPopoverVisible(false);
            authPanel.clearSecret();
        }
    }

    Item {
        id: header
        // Conversation views own one compact toolbar. The branded/status
        // header is reserved for connection setup, where that context is the
        // page rather than a second row above New chat.
        visible: root.showingSetup
        width: parent.width
        height: visible ? HermesTheme.headerHeight : 0

        Rectangle {
            x: -root.padding
            y: parent.height - 1
            width: root.width
            height: 1
            color: HermesTheme.border
        }

        Text {
            id: hermesMark
            anchors.left: parent.left
            anchors.leftMargin: 2
            anchors.verticalCenter: parent.verticalCenter
            text: "⚕"
            font.family: HermesTheme.fontUi
            font.pixelSize: Theme.iconLarge
            font.weight: Theme.weightSemibold
            color: Hermes.agentReady ? HermesTheme.accent
                : Hermes.bridgeReady ? HermesTheme.amber : HermesTheme.textFaint
            Accessible.ignored: true
        }

        Column {
            anchors.left: hermesMark.right
            anchors.leftMargin: 8
            anchors.right: headerActions.left
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2

            Text {
                width: parent.width
                text: "Hermes Agent"
                elide: Text.ElideRight
                font.family: HermesTheme.fontUi
                font.pixelSize: Theme.typography.primary
                font.weight: Theme.weightSemibold
                color: HermesTheme.textPrimary
            }

            Row {
                spacing: 6

                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: 5
                    height: 5
                    radius: 3
                    color: !Hermes.connected ? HermesTheme.red
                        : !Hermes.bridgeReady || Hermes.remoteLoading
                            ? HermesTheme.amber : Hermes.remoteSessionExpired
                                ? HermesTheme.amber : !Hermes.remoteConfigured
                                && (Hermes.backendStatus === "reconnecting"
                                || Hermes.backendStatus === "error"
                                || Hermes.backendStatus === "offline"
                                || Hermes.backendStatus === "unavailable")
                                    ? HermesTheme.red : Hermes.setupRequired
                                        ? HermesTheme.amber : HermesTheme.success
                }

                Text {
                    width: Math.max(0, header.width - headerActions.width - 78)
                    text: {
                        if (!Hermes.connected)
                            return Hermes.connectionError || "Bridge offline";
                        if (!Hermes.bridgeReady)
                            return Hermes.bridgeError || "Starting…";
                        if (Hermes.remoteLoading)
                            return "Checking remote Hermes session…";
                        if (Hermes.remoteSessionExpired)
                            return "Session sign-in required · remote WebUI session expired";
                        if (Hermes.remoteConnected)
                            return "Remote · " + Hermes.remoteOrigin;
                        if (Hermes.remoteConfigured && Hermes.remoteError !== "")
                            return Hermes.remoteError;
                        if (Hermes.remoteConfigured)
                            return "Remote sign-in required · " + Hermes.remoteOrigin;
                        if (Hermes.backendError !== "" && !Hermes.localProviderReady)
                            return Hermes.backendError;
                        if (!Hermes.remoteConfigured && Hermes.localProviderReady)
                            return "Local · " + Hermes.providerName + " · "
                                + Hermes.providerModel;
                        return Hermes.localBackendAvailable
                            ? "Connect a Hermes WebUI · local provider setup is advanced"
                            : "Connect a remote Hermes WebUI";
                    }
                    elide: Text.ElideRight
                    font.family: HermesTheme.fontUi
                    font.pixelSize: Theme.typography.secondary
                    color: HermesTheme.textFaint
                }
            }
        }

        Row {
            id: headerActions
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2

            IconButton {
                symbol: root.workspaceExpanded ? "close_fullscreen" : "open_in_full"
                accessibleName: root.workspaceExpanded
                    ? "Use compact Hermes popover" : "Expand Hermes workspace"
                accessibleDescription: root.workspaceExpanded
                    ? "Return to the glanceable view" : "Use more width and conversation height"
                tint: root.workspaceExpanded ? HermesTheme.accent : HermesTheme.textMuted
                onTriggered: root.workspaceExpanded = !root.workspaceExpanded
            }

            IconButton {
                symbol: "refresh"
                accessibleName: "Refresh Hermes status"
                tint: HermesTheme.textMuted
                onTriggered: Hermes.refresh()
            }

            IconButton {
                symbol: "key"
                accessibleName: root.showingSetup
                    ? "Return to Hermes conversations" : "Hermes connection setup"
                tint: root.showingSetup ? HermesTheme.accent : HermesTheme.textMuted
                enabled: Hermes.bridgeReady
                onTriggered: {
                    if (root.showingSetup && root.setupOpen && Hermes.agentReady)
                        root.closeSetup();
                    else
                        root.openSetup();
                }
            }
        }
    }

    HermesInboxPage {
        id: inbox
        visible: !root.showingSetup
        width: parent.width
        height: visible ? implicitHeight : 0
        maxHeight: root.threadMaxHeight
        workspaceExpanded: root.workspaceExpanded
        onWorkspaceToggleRequested: root.workspaceExpanded = !root.workspaceExpanded
        onSetupRequested: root.openSetup()
    }

    HermesAuthPanel {
        id: authPanel
        visible: root.showingSetup
        width: parent.width
        height: visible ? authPanel.implicitHeight : 0
        maxHeight: root.bodyBudget
        onConfigured: root.closeSetup()
        onCloseRequested: root.closeSetup()
    }

    Item {
        id: footer
        visible: root.showingSetup
        width: parent.width
        height: visible ? HermesTheme.footerHeight : 0

        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: 1
            color: HermesTheme.border
        }

        Text {
            anchors.left: parent.left
            anchors.leftMargin: 2
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width * 0.68
            text: Hermes.remoteConnected ? Hermes.remoteOrigin
                : Hermes.remoteConfigured ? Hermes.remoteOrigin + " · sign-in required"
                : Hermes.localProviderReady ? Hermes.providerName + " · " + Hermes.providerModel
                : Hermes.connected ? "local transport · "
                    + Hermes.endpoint.replace(/^wss?:\/\//, "")
                    : "Hermes reconnects automatically"
            elide: Text.ElideMiddle
            font.family: HermesTheme.fontMono
            font.pixelSize: Theme.typography.metadata
            color: HermesTheme.textFaint
        }

        Text {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: Hermes.remoteSessionExpired ? "session expired"
                : !Hermes.agentReady ? "sign-in required"
                : Hermes.workingCount > 0 ? Hermes.workingCount + " working"
                : Hermes.attentionCount > 0 ? Hermes.attentionCount + " waiting"
                    : Hermes.conversations.length + " conversations"
            font.family: HermesTheme.fontUi
            font.pixelSize: Theme.typography.metadata
            font.features: HermesTheme.tabularNumberFeatures
            color: Hermes.attentionCount > 0 ? HermesTheme.amber
                : HermesTheme.textFaint
        }
    }
}
