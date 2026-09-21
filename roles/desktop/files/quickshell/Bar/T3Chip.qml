import QtQuick
import QtQuick.Effects
import "../Common"

// T3 Code chip: the official T3 mark (pingdotgg/t3code, MIT), a live dot while
// agents are working, and a status word. Sessions needing approval or input
// win (amber), then running/background-monitoring work, then a quiet idle
// mark. The mark follows the shared menubar ink while connected and dims only
// while off or connecting.
BarChip {
    id: root

    property int displayMode: 2

    readonly property bool live: T3Code.state === "connected"
    readonly property bool stressed: live && T3Code.attentionCount > 0
    readonly property bool busy: live && !stressed
        && (T3Code.runningCount > 0 || T3Code.monitoringCount > 0)
    readonly property string label: {
        if (!live) {
            if (T3Code.cloudLoginRunning)
                return "signing in…";
            if (T3Code.state === "signed-out")
                return "sign in";
            if (T3Code.state === "cloud-empty")
                return "no links";
            return T3Code.state === "connecting" ? "connecting…" : "off";
        }
        if (T3Code.attentionCount > 0)
            return T3Code.attentionCount + " waiting";
        if (T3Code.runningCount > 0)
            return T3Code.runningCount + " running";
        if (T3Code.monitoringCount > 0)
            return T3Code.monitoringCount + " monitoring";
        if (T3Code.doneCount > 0)
            return T3Code.doneCount + " done";
        return "idle";
    }
    // Keep the expanded measurement available while the label is compacted;
    // otherwise the fit pass forgets this saving and oscillates between chips.
    readonly property real detailSaving: labelText.implicitWidth + spacing

    shape: "inner"
    hPadding: 9
    spacing: 6
    // Attention remains visible in the label without giving this module a
    // resting tile that its neighbours do not have.
    restFill: "transparent"
    tooltipAlign: 1
    tooltip: {
        if (T3Code.cloudLoginRunning)
            return "T3 Code · finish T3 Connect sign-in in your browser";
        if (T3Code.state === "signed-out")
            return "T3 Code · sign in to T3 Connect";
        if (T3Code.state === "cloud-empty")
            return "T3 Code · no environments linked through T3 Connect";
        // Off covers a refused port, a dead name, a bad certificate and a
        // rejected ticket; say which one when the transport gave a reason
        // worth repeating.
        if (!root.live)
            return "T3 Code · " + T3Code.state
                + (T3Code.connectionError !== ""
                    ? " · " + T3Code.connectionError : "");
        const environment = T3Code.environmentLabel !== ""
            ? T3Code.environmentLabel : "sessions";
        return "T3 Code · " + environment + " · " + T3Code.runningCount + " running, "
            + (T3Code.monitoringCount > 0
                ? T3Code.monitoringCount + " monitoring, " : "")
            + T3Code.attentionCount + " waiting";
    }

    BarBrandIcon {
        id: t3Mark
        anchors.verticalCenter: parent.verticalCenter
        // PreserveAspectFit, so the box is a bound rather than a shape: the
        // 5:3 mark draws 15x9 inside it.
        height: 9
        width: 15
        name: "t3"
        opacity: highlighted || root.live ? 1 : 0.52
        highlighted: root.held || root.hovered
    }

    // Live work: a lit dot with its own bloom, deliberately static. A pulse
    // here would animate a permanent fixture of the bar.
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

        Behavior on opacity {
            NumberAnimation { duration: Theme.chipFadeDuration }
        }

        RectangularShadow {
            anchors.fill: dot
            radius: dot.radius
            blur: 6
            spread: 0
            color: Theme.barAccentGlow
        }

        Rectangle {
            id: dot
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
        font.family: Theme.fontMenu
        font.pixelSize: Theme.typography.bar
        font.weight: root.stressed ? Theme.weightBold : Theme.weightSemibold
        font.features: Theme.tabularNumberFeatures
        color: {
            if (!root.live)
                return T3Code.state === "connecting" ? Theme.barTextLow : Theme.barTextFaint;
            if (root.stressed)
                return Theme.barAmber;
            if (T3Code.runningCount > 0 || T3Code.monitoringCount > 0
                    || T3Code.doneCount > 0)
                return Theme.barTextMid;
            return Theme.barTextLow;
        }

        Behavior on color {
            ColorAnimation { duration: Theme.chipFadeDuration }
        }
    }
}
