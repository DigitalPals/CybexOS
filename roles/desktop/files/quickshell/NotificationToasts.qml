pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Services.Notifications
import Quickshell.Wayland
import "Common"
import "Common/Format.js" as Format

// Compact notification cards. Newest of at most three is on top; normal cards
// use an adaptive timer based on the configured duration, paused while hovered,
// and critical cards persist until explicitly dismissed. Corner, density,
// icons, body lines, and the timeout progress bar follow the Notifications
// settings page.
PanelWindow {
    id: root

    readonly property bool onTop: Settings.notifPosition.indexOf("top") === 0
    readonly property bool onLeft: Settings.notifPosition.indexOf("left") !== -1
    readonly property bool barSameEdge: Screens.hasBar(root.screen)
        && (Settings.position === "top") === onTop
    // Density scales the card's inner padding and content gap.
    readonly property int padV: Theme.scaled(Settings.notifDensity === "compact" ? 8
        : Settings.notifDensity === "roomy" ? 15 : 11)
    readonly property int padH: Theme.scaled(Settings.notifDensity === "compact" ? 10
        : Settings.notifDensity === "roomy" ? 16 : 12)

    // Toast and history messages use the shared notification role.
    readonly property var cardStyle: ({
        face: Theme.fontMenu,
        header: Theme.typography.notification,
        body: Theme.typography.notification,
        bodyColor: Theme.icon,
        bodyLines: Settings.notifBodyLines,
        bodyLeading: 1.15,
        stampFace: Theme.fontMono,
        stampSize: Theme.fontMicro,
        stampCentred: true,
        trailingHeight: Theme.scaled(18),
        close: Theme.scaled(17, Theme.typeScale),
        closeColor: Theme.textLow,
        pill: Theme.fontTiny,
        stackedHeader: true
    })

    // Keep the layer mapped through the final card's remove transition.
    visible: Notifs.toasts.length > 0 || reservedListHeight > 0
    screen: Screens.focused
    anchors {
        top: root.onTop
        bottom: !root.onTop
        left: root.onLeft
        right: !root.onLeft
    }
    // PanelWindow.margins is a Quickshell group qmllint cannot resolve. The
    // card carries its own stable 10px edge gutter; these margins only clear
    // a bar on the same edge.
    // qmllint disable unqualified
    margins.top: root.onTop
        ? (root.barSameEdge ? Theme.barTopMargin + Theme.barHeight : 0) : 0
    margins.bottom: !root.onTop
        ? (root.barSameEdge ? Theme.barTopMargin + Theme.barHeight : 0) : 0
    // qmllint enable unqualified

    // end-4's two current notification styles land around 344–390 logical px.
    // This shell used 420, which made short messages read like empty banners.
    // Keep a little more room than the compact reference while still adapting
    // to unusually narrow outputs.
    readonly property int edgeMargin: Math.max(10, Theme.barSideMargin)
    readonly property int windowPad: 12
    readonly property int cardWidth: Math.max(1, Math.min(Theme.scaled(380, Theme.contentScale),
        root.screen ? root.screen.width - edgeMargin - windowPad : 380))
    implicitWidth: cardWidth + edgeMargin + windowPad
    // Keep the old height just long enough for ListView's exit transition.
    // Without this reserve the layer surface shrinks before the departing
    // delegate can paint its slide/fade.
    property real reservedListHeight: 0
    implicitHeight: reservedListHeight + 24
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"

    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "qs-notifications"
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    mask: Region {
        item: toastList.contentItem
    }

    property real now: Date.now()

    Timer {
        interval: 30000
        repeat: true
        running: root.visible
        onTriggered: root.now = Date.now()
    }

    function syncListHeight() {
        const next = toastList.contentHeight;
        if (next >= reservedListHeight) {
            shrinkTimer.stop();
            reservedListHeight = next;
        } else {
            shrinkTimer.restart();
        }
    }

    Timer {
        id: shrinkTimer
        interval: 180
        onTriggered: root.reservedListHeight = toastList.contentHeight
    }

    ListView {
        id: toastList
        anchors.top: root.onTop ? parent.top : undefined
        anchors.topMargin: 12
        anchors.bottom: root.onTop ? undefined : parent.bottom
        anchors.bottomMargin: 12
        anchors.left: root.onLeft ? parent.left : undefined
        anchors.leftMargin: root.edgeMargin
        anchors.right: root.onLeft ? undefined : parent.right
        anchors.rightMargin: root.edgeMargin
        width: root.cardWidth
        height: root.reservedListHeight
        spacing: 8
        interactive: false
        clip: false

        onContentHeightChanged: root.syncListHeight()
        Component.onCompleted: root.syncListHeight()

        add: Transition {
            ParallelAnimation {
                NumberAnimation {
                    property: "opacity"
                    from: 0
                    to: 1
                    duration: Theme.reducedMotion ? 0 : 160
                    easing.type: Easing.OutCubic
                }
                NumberAnimation {
                    property: "x"
                    from: root.onLeft ? -18 : 18
                    to: 0
                    duration: Theme.reducedMotion ? 0 : 220
                    easing.type: Easing.BezierSpline
                    easing.bezierCurve: Theme.easeOutCurve
                }
            }
        }

        addDisplaced: Transition {
            NumberAnimation {
                property: "y"
                duration: Theme.reducedMotion ? 0 : 240
                easing.type: Easing.BezierSpline
                easing.bezierCurve: Theme.springCurve
            }
        }

        remove: Transition {
            ParallelAnimation {
                NumberAnimation {
                    property: "opacity"
                    to: 0
                    duration: Theme.reducedMotion ? 0 : 120
                    easing.type: Easing.InCubic
                }
                NumberAnimation {
                    property: "x"
                    to: root.onLeft ? -18 : 18
                    duration: Theme.reducedMotion ? 0 : 165
                    easing.type: Easing.BezierSpline
                    easing.bezierCurve: Theme.easeInCurve
                }
            }
        }

        removeDisplaced: Transition {
            NumberAnimation {
                property: "y"
                duration: Theme.reducedMotion ? 0 : 240
                easing.type: Easing.BezierSpline
                easing.bezierCurve: Theme.springCurve
            }
        }

        // ScriptModel diffs by entry identity, so removing one toast reuses
        // the surviving delegates instead of recreating them — a plain array
        // model would reset every card's countdown (and hover state) whenever
        // a sibling expired.
        model: ScriptModel {
            values: Notifs.toasts
        }

        delegate: Item {
            id: slot
            required property var modelData

            readonly property bool critical: modelData.urgency
                === NotificationUrgency.Critical
            readonly property int total: Notifs.timeoutFor(modelData)
            readonly property bool showProgress: Settings.notifProgress && !critical
            property int remaining: Notifs.timeoutFor(modelData)

            width: ListView.view.width
            implicitHeight: card.height

            // One continuous countdown instead of a 100ms tick: the progress
            // bar moves at display rate and the card needs no repeating timer.
            // Hovering stops the sequence with `remaining` frozen; unhovering
            // restarts it from the frozen value with a freshly captured
            // duration.
            SequentialAnimation {
                running: !card.hovered && !slot.critical
                ScriptAction {
                    script: countdown.duration = Math.max(1, slot.remaining)
                }
                NumberAnimation {
                    id: countdown
                    target: slot
                    property: "remaining"
                    to: 0
                }
                ScriptAction {
                    script: Notifs.hideToast(slot.modelData, true)
                }
            }

            NotifCard {
                id: card

                entry: slot.modelData
                style: root.cardStyle
                nowMs: root.now
                padH: root.padH
                padV: root.padV
                showIcon: Settings.notifIcons
                iconExtent: Theme.scaled(34)
                iconSize: Theme.scaled(24, Theme.typeScale)
                framedIcon: true
                expandTextOnHover: true

                width: parent.width
                height: contentHeight
                radius: Theme.panelRadius
                clip: true
                // The red fill is a translucent tint for an existing surface,
                // not a standalone background over application windows.
                readonly property color baseSurface: hovered
                    ? Theme.surfaceMenu : Theme.panelSurface
                color: slot.critical ? Qt.tint(baseSurface, Theme.redBgSoft)
                    : baseSurface
                border.width: Theme.surfaceBorderWidth
                border.color: slot.critical ? Theme.redBorder
                    : Theme.surfaceBorderColor

                onActivated: Notifs.invokeDefault(slot.modelData)
                onCloseRequested: Notifs.dismiss(slot.modelData)

                // A thin inset bar counts down the toast's remaining time and
                // freezes with the timer while hovered.
                Rectangle {
                    visible: slot.showProgress
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    anchors.leftMargin: card.padH
                    anchors.rightMargin: card.padH
                    anchors.bottomMargin: card.padV / 2
                    height: 2
                    radius: 1
                    color: Theme.activeFill

                    Rectangle {
                        height: parent.height
                        width: slot.total > 0
                            ? parent.width * Format.clamp01(slot.remaining / slot.total)
                            : 0
                        radius: 1
                        color: Theme.accent
                    }
                }
            }
        }
    }
}
