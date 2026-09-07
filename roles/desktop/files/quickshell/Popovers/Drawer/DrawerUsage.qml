pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import "../../Common"
import ".."

// The drawer's Usage tab keeps providers as its first navigation level. A
// CLIProxyAPI provider adds a second, always-visible subscription accordion;
// direct mode and one-account pools retain the compact single-reading view.
Column {
    id: root

    readonly property string selected: Usage.selected
    readonly property bool hasProvider:
        Usage.providerKeys.indexOf(selected) !== -1
    readonly property var info: hasProvider ? Usage.meta[selected] : ({
        name: "Models", title: "Model usage", icon: "", cmd: ""
    })
    readonly property var record: hasProvider ? Usage.provider(selected) : null
    readonly property var accounts: record && Array.isArray(record.accounts)
        ? record.accounts : []
    readonly property bool multipleAccounts: accounts.length > 1
    readonly property var singleRecord: accounts.length === 1
        ? accounts[0] : record
    readonly property bool singleOk: singleRecord !== null
        && singleRecord.status === "ok"
    readonly property int accountCount: record
        && typeof record.accountCount === "number"
        ? record.accountCount : accounts.length
    readonly property int availableCount: record
        && typeof record.availableCount === "number"
        ? record.availableCount
        : accounts.filter(account => account.status === "ok").length

    // null means no explicit choice yet, so the best available account opens
    // initially. An empty string is an explicit "collapse all" choice.
    property var requestedAccountId: null
    readonly property string expandedAccountId: {
        if (!multipleAccounts)
            return "";
        if (requestedAccountId === "")
            return "";
        if (typeof requestedAccountId === "string"
                && accounts.some(account => account.id === requestedAccountId))
            return requestedAccountId;
        if (record && record.bestAccountId
                && accounts.some(account => account.id === record.bestAccountId))
            return record.bestAccountId;
        const available = accounts.find(account => account.status === "ok");
        return available ? available.id : accounts[0].id;
    }

    width: parent ? parent.width : 0
    spacing: Theme.scaled(14)

    onSelectedChanged: requestedAccountId = null

    function toggleAccount(accountId) {
        requestedAccountId = accountId === expandedAccountId ? "" : accountId;
    }

    Claim {
        active: root.visible
        onClaimed: Usage.acquireCountdown()
        onReleased: Usage.releaseCountdown()
    }

    function availabilityText() {
        if (accountCount <= 0)
            return "";
        const noun = accountCount === 1 ? "account" : "accounts";
        return `${availableCount}/${accountCount} ${noun} available`;
    }

    // ---- provider switch -------------------------------------------------
    Rectangle {
        width: parent.width
        height: 36
        radius: 9
        color: Theme.chip

        Row {
            anchors.fill: parent
            anchors.margins: 3
            spacing: 2

            Repeater {
                model: Usage.providerKeys

                delegate: Rectangle {
                    id: providerChoice

                    required property string modelData
                    readonly property bool on: root.selected === modelData

                    width: (parent.width - 2 * (Usage.providerKeys.length - 1))
                        / Usage.providerKeys.length
                    height: parent.height
                    radius: 7
                    color: on ? Theme.chipHover : "transparent"

                    Behavior on color {
                        ColorAnimation { duration: Theme.chipFadeDuration }
                    }

                    Row {
                        anchors.centerIn: parent
                        spacing: 7

                        BrandIcon {
                            anchors.verticalCenter: parent.verticalCenter
                            width: 12
                            height: 12
                            name: Usage.meta[providerChoice.modelData].icon
                            opacity: providerChoice.on ? 1 : 0.55
                        }

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: Usage.meta[providerChoice.modelData].name
                            font.family: Theme.fontMenu
                            font.pixelSize: Theme.fontCaption
                            font.weight: Theme.weightSemibold
                            color: providerChoice.on ? Theme.textHi : Theme.textFaint
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: Usage.selected = providerChoice.modelData
                    }

                    Accessible.role: Accessible.PageTab
                    Accessible.name: Usage.meta[providerChoice.modelData].name
                }
            }
        }
    }

    // ---- header ----------------------------------------------------------
    Item {
        width: parent.width
        height: 40

        Column {
            anchors.left: parent.left
            anchors.leftMargin: 4
            anchors.right: refreshButton.left
            anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2

            Text {
                width: parent.width
                text: {
                    const title = root.info.title;
                    if (!root.multipleAccounts && root.singleOk
                            && root.singleRecord.plan)
                        return title + " · " + root.singleRecord.plan;
                    return title;
                }
                font.family: Theme.fontMenu
                font.pixelSize: Theme.fontHeading - 1
                font.weight: Theme.weightSemibold
                color: Theme.textHi
                elide: Text.ElideRight
            }

            Text {
                width: parent.width
                text: {
                    const parts = [];
                    if (root.accountCount > 1)
                        parts.push(root.availabilityText());
                    if (Usage.updatedAt > 0)
                        parts.push("updated " + Qt.formatDateTime(
                            new Date(Usage.updatedAt), "HH:mm:ss"));
                    if (Usage.loading)
                        parts.push("refreshing…");
                    else
                        parts.push("next poll in "
                            + Usage.formatCountdown(Usage.nextPollSecs));
                    return parts.join(" · ");
                }
                font.family: Theme.fontMenu
                font.pixelSize: Theme.fontCaption
                color: root.accountCount > 1
                    && root.availableCount < root.accountCount
                    ? Theme.amber : Theme.textFaint
                elide: Text.ElideRight
            }
        }

        DrawerIconButton {
            id: refreshButton
            anchors.right: parent.right
            anchors.rightMargin: 2
            anchors.verticalCenter: parent.verticalCenter
            width: 28
            height: 28
            glyph: "refresh"
            glyphSize: 16
            enabled: !Usage.loading
            accessibleName: "Refresh usage"
            onClicked: Usage.refresh()
        }
    }

    // A provider without per-account information keeps the established
    // signed-out panel. An all-failed CLIProxy pool instead shows each failed
    // account below, so one bad credential is never hidden by a generic row.
    Rectangle {
        visible: !root.multipleAccounts && !root.singleOk
        width: parent.width
        height: signedOutColumn.implicitHeight + 24
        radius: 10
        color: Theme.chip

        Column {
            id: signedOutColumn
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.margins: 12
            anchors.verticalCenter: parent.verticalCenter
            spacing: 4

            Text {
                width: parent.width
                text: !root.hasProvider
                    ? (Usage.loading ? "Loading usage" : "No managed providers")
                    : Usage.fetchError !== "" ? "Usage unavailable"
                    : root.singleRecord && (root.singleRecord.kind === "auth"
                        || root.singleRecord.kind === "nocreds")
                    ? "Sign-in required" : "No usage data"
                font.family: Theme.fontMenu
                font.pixelSize: Theme.fontSecondary
                font.weight: Theme.weightSemibold
                color: Theme.textHi
            }

            Text {
                width: parent.width
                text: !root.hasProvider
                    ? (Usage.loading ? "Waiting for " + Usage.sourceName + "."
                        : Usage.sourceName + " did not return a supported enabled provider.")
                    : Usage.fetchError !== "" ? Usage.fetchError
                    : root.singleRecord && root.singleRecord.message
                    ? root.singleRecord.message
                    : Usage.loading ? "Fetching…" : "Nothing reported yet."
                font.family: Theme.fontMenu
                font.pixelSize: Theme.fontCaption
                color: Theme.textFaint
                wrapMode: Text.WordWrap
            }

            Text {
                visible: root.info.cmd !== ""
                    && root.singleRecord !== null
                    && (root.singleRecord.kind === "auth"
                        || root.singleRecord.kind === "nocreds")
                width: parent.width
                text: "Run " + root.info.cmd + " in a terminal."
                font.family: Theme.fontNumeric
                font.pixelSize: Theme.fontCaption
                color: Theme.textLow
                wrapMode: Text.WordWrap
            }
        }
    }

    Column {
        visible: root.multipleAccounts
        width: parent.width
        spacing: 4

        SectionLabel {
            width: parent.width
            text: "SUBSCRIPTIONS"
            detail: root.availabilityText()
        }

        Repeater {
            model: root.accounts

            delegate: DrawerUsageAccount {
                required property var modelData

                width: parent ? parent.width : 0
                record: modelData
                expanded: modelData.id === root.expandedAccountId
                best: root.record && modelData.id === root.record.bestAccountId
                providerStale: root.record && root.record.stale === true
                onToggled: root.toggleAccount(modelData.id)
            }
        }
    }

    DrawerUsageDetails {
        visible: !root.multipleAccounts && root.singleOk
        width: parent.width
        windows: root.singleRecord && root.singleRecord.windows
            ? root.singleRecord.windows : []
        credits: root.singleRecord ? (root.singleRecord.credits ?? null) : null
        stale: root.record && root.record.stale === true
    }

    DrawerFooter {
        info: root.record && root.record.source
            ? "via " + root.record.source
            : "source · " + Settings.modOpts.usage.source
        actionText: Settings.modOpts.usage.source !== "direct"
            && Usage.dashboardUrl !== ""
            ? "Open dashboard" : ""
        onActionClicked: {
            Popouts.close();
            Quickshell.execDetached(["xdg-open",
                Usage.dashboardUrl]);
        }
    }
}
