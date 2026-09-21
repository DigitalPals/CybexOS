import QtQuick
import "../Common"

// Hermes Agent chip: a compact agent mark followed by the highest-priority
// live activity across conversations. Blocking requests win over failures and work;
// the full conversation context remains in the popover and tooltip.
BarChip {
    id: root

    property int displayMode: 2

    readonly property bool live: Hermes.connected && Hermes.bridgeReady
    readonly property bool needsSetup: live && !Hermes.agentReady
        && (Hermes.setupRequired || Hermes.remoteError !== "")
    readonly property bool stressed: Hermes.agentReady && Hermes.attentionCount > 0
    readonly property bool failed: Hermes.agentReady && !stressed && Hermes.errorCount > 0
    readonly property bool busy: Hermes.agentReady && !stressed && !failed
        && Hermes.workingCount > 0
    readonly property string label: {
        if (Hermes.state === "disabled")
            return "disabled";
        if (Hermes.state === "connecting")
            return "connecting…";
        if (!Hermes.connected)
            return "offline";
        if (!Hermes.bridgeReady)
            return Hermes.bridgeError !== "" ? "bridge error" : "starting…";
        if (Hermes.remoteLoading)
            return "checking…";
        if (Hermes.remoteSessionExpired)
            return "session expired";
        if (Hermes.remoteConfigured && Hermes.remoteError !== "")
            return "sign-in error";
        if (Hermes.setupRequired)
            return "sign in";
        if (!Hermes.remoteConfigured && (Hermes.backendStatus === "error"
                || Hermes.backendStatus === "unavailable"))
            return "backend off";
        if (Hermes.attentionCount > 0)
            return Hermes.attentionCount === 1 && Hermes.activityConversation
                ? Hermes.activityConversation.title + " needs you"
                : Hermes.attentionCount + " waiting";
        if (Hermes.errorCount > 0)
            return Hermes.errorCount + " failed";
        if (Hermes.workingCount > 1)
            return Hermes.workingCount + " working";
        if (Hermes.workingCount === 1)
            return Hermes.activityLabel;
        if (Hermes.unreadCount > 0)
            return Hermes.unreadCount + " unread";
        if (Hermes.doneCount > 0)
            return Hermes.doneCount + " done";
        return "idle";
    }
    // The fit pass must be able to reconstruct the expanded width after it has
    // hidden this label. Basing the measurement on `visible` makes the saving
    // disappear while compact, so adjacent candidates alternate forever.
    readonly property real detailSaving: labelText.implicitWidth + spacing

    shape: "inner"
    hPadding: 9
    spacing: 6
    restFill: "transparent"
    tooltipAlign: 1
    tooltip: {
        if (!Hermes.connected)
            return "Hermes Agent · " + (Hermes.connectionError !== ""
                ? Hermes.connectionError : Hermes.state);
        if (!Hermes.bridgeReady)
            return "Hermes Agent · " + (Hermes.bridgeError !== ""
                ? Hermes.bridgeError : "waiting for the bridge");
        if (Hermes.remoteSessionExpired)
            return "Hermes Agent · Session sign-in required · remote WebUI session expired";
        if (Hermes.remoteConnected)
            return "Hermes Agent · remote · " + Hermes.remoteOrigin;
        if (Hermes.remoteConfigured && Hermes.remoteError !== "")
            return "Hermes Agent · " + Hermes.remoteError;
        if (Hermes.setupRequired)
            return "Hermes Agent · remote WebUI sign-in required";
        if (Hermes.backendError !== "")
            return "Hermes Agent · " + Hermes.backendError;
        const conversation = Hermes.activityConversation
            ? Hermes.activityConversation.title + " · " : "";
        return "Hermes Agent · " + conversation + root.label + " · "
            + Hermes.conversations.length + (Hermes.conversations.length === 1 ? " conversation" : " conversations");
    }

    // Hermes' compact upstream mark (also used by its CLI/banner/favicon)
    // remains distinct and legible where the detailed portrait logo does not.
    Text {
        anchors.verticalCenter: parent.verticalCenter
        text: "⚕"
        font.family: Theme.fontMenu
        font.pixelSize: Theme.barIconSize + 2
        font.weight: Theme.weightSemibold
        color: root.held || root.hovered ? Theme.barTextHi
            : root.needsSetup ? Theme.barAmber
                : Hermes.agentReady ? Theme.barIcon : Theme.barTextFaint
        Accessible.ignored: true
    }

    Item {
        anchors.verticalCenter: parent.verticalCenter
        width: root.busy ? 5 : 0
        height: 5
        opacity: root.busy ? 1 : 0

        Behavior on width {
            NumberAnimation {
                duration: Theme.expandDuration
                easing.type: Easing.BezierSpline
                easing.bezierCurve: Theme.springCurve
            }
        }
        Behavior on opacity { NumberAnimation { duration: Theme.chipFadeDuration } }

        Rectangle {
            id: activityDot
            width: 5
            height: 5
            radius: 2.5
            color: Theme.barAccent
        }
    }

    Text {
        id: labelText
        visible: root.displayMode > 0
        anchors.verticalCenter: parent.verticalCenter
        text: root.label
        elide: Text.ElideRight
        maximumLineCount: 1
        font.family: Theme.fontMenu
        font.pixelSize: Theme.typography.bar
        font.weight: root.stressed || root.failed
            ? Theme.weightBold : Theme.weightSemibold
        font.features: Theme.tabularNumberFeatures
        color: !root.live ? Theme.barTextFaint
            : root.needsSetup ? Theme.barAmber
                : root.stressed ? Theme.barAmber
                : root.failed ? Theme.barRed
                    : root.busy || Hermes.unreadCount > 0 || Hermes.doneCount > 0
                        ? Theme.barTextMid : Theme.barTextLow

        Behavior on color { ColorAnimation { duration: Theme.chipFadeDuration } }
    }
}
