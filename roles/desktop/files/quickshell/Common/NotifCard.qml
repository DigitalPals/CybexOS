pragma ComponentBehavior: Bound
import QtQuick
import Quickshell.Services.Notifications

// The notification card anatomy, drawn by both the toast overlay and the
// notification centre: source icon, app/summary header, a timestamp that
// becomes a close button on hover, wrapped body, and contextual action pills.
// Toasts stack app and summary for a calmer hierarchy; compact centre rows
// keep them together.
//
// Surface chrome stays with the caller. This is a Rectangle, so `color`,
// `border` and `radius` are set at the call site the ordinary way, and extra
// children — the toast's countdown bar, the centre's nested separator —
// parent into it like any other child.
//
// Callers share Theme.typography.notification for message copy. The style
// object carries presentation differences (stacking, timestamps, line limits).
Rectangle {
    id: card

    required property var entry
    required property var style
    property real nowMs: 0
    property int padH: 12
    property int padV: 12
    // The centre hides the icon exactly when it hides the app name (a nested
    // row under a source header already says which app it came from); the
    // toast hides it on the Notifications settings page's own switch.
    property bool showIcon: true
    property bool showApp: true
    property int groupCount: 1
    property bool groupUrgent: false
    property int iconExtent: 28
    property int iconSize: 28
    property bool framedIcon: false
    // Toasts can trade their compact resting height for the complete text
    // while the pointer is holding their expiry timer. History rows instead
    // opt into an explicit disclosure so merely moving through them never
    // reflows the panel.
    property bool expandTextOnHover: false
    property bool allowTextExpansion: false
    property bool textExpandedByUser: false
    // Notification history participates in keyboard traversal; toast windows
    // deliberately do not request keyboard focus.
    property bool keyboardEnabled: false

    signal activated
    signal closeRequested

    readonly property bool urgent: groupUrgent
        || entry.urgency === NotificationUrgency.Critical
    readonly property bool hovered: cardHover.hovered
    readonly property bool textExpanded: textExpandedByUser
        || (expandTextOnHover && hovered)
    readonly property bool textTruncated: header.truncated
        || (summary.visible && summary.truncated)
        || (bodyText.visible && bodyText.truncated)
    readonly property bool showTextDisclosure: allowTextExpansion
        && (textExpandedByUser || textTruncated)
    readonly property bool actionable: groupCount > 1 || Notifs.canActivate(entry)
    // Real, not int: a card's height is text metrics plus padding and lands
    // on fractions, and truncating it costs a pixel that then shifts every
    // card below this one.
    readonly property real contentHeight: cardContent.implicitHeight + card.padV * 2

    height: contentHeight
    activeFocusOnTab: keyboardEnabled && actionable
    Accessible.role: actionable ? Accessible.Button : Accessible.StaticText
    Accessible.name: (entry.displayAppName || "Notification")
        + (entry.displaySummary ? ": " + entry.displaySummary : "")
    Accessible.description: entry.displayBody || ""
    Accessible.onPressAction: {
        if (card.actionable)
            card.activated();
    }

    Keys.onPressed: event => {
        if (card.actionable && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                || event.key === Qt.Key_Space)) {
            card.activated();
            event.accepted = true;
        } else if (card.keyboardEnabled && event.key === Qt.Key_Delete) {
            card.closeRequested();
            event.accepted = true;
        } else if (card.keyboardEnabled
                && (event.key === Qt.Key_Right || event.key === Qt.Key_Down)) {
            card.moveFocus(card, true);
            event.accepted = true;
        } else if (card.keyboardEnabled
                && (event.key === Qt.Key_Left || event.key === Qt.Key_Up)) {
            card.moveFocus(card, false);
            event.accepted = true;
        }
    }

    function toggleTextExpansion() {
        textExpandedByUser = !textExpandedByUser;
    }

    function moveFocus(item, forward) {
        const next = item.nextItemInFocusChain(forward);
        if (next)
            next.forceActiveFocus();
    }

    onEntryChanged: textExpandedByUser = false

    HoverHandler {
        id: cardHover
    }

    MouseArea {
        anchors.fill: parent
        enabled: card.actionable
        cursorShape: Qt.PointingHandCursor
        onClicked: {
            if (card.keyboardEnabled)
                card.forceActiveFocus();
            card.activated();
        }
    }

    Rectangle {
        anchors.fill: parent
        radius: card.radius
        color: "transparent"
        border.width: card.activeFocus ? 2 : 0
        border.color: Theme.accentText
    }

    Row {
        id: cardContent
        x: card.padH
        y: card.padV
        width: parent.width - card.padH * 2
        spacing: card.showIcon ? 10 : 0

        NotifIcon {
            visible: card.showIcon
            width: card.iconExtent
            height: card.iconExtent
            iconSize: card.iconSize
            framed: card.framedIcon
            entry: card.entry
            urgent: card.urgent
        }

        Column {
            width: cardContent.width
                - (card.showIcon ? card.iconExtent + cardContent.spacing : 0)
            spacing: 4

            Item {
                width: parent.width
                height: Math.max(header.implicitHeight, trailing.height)

                Text {
                    id: header
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - trailing.width - 8
                    text: card.style.stackedHeader && card.showApp
                        ? card.entry.displayAppName
                        : card.showApp
                            ? card.entry.displayAppName
                                + (card.entry.displaySummary
                                    ? " · " + card.entry.displaySummary : "")
                        : (card.entry.displaySummary || card.entry.displayAppName)
                    font.family: card.style.face
                    font.pixelSize: card.style.stackedHeader && card.showApp
                        ? card.style.pill : card.style.header
                    font.weight: card.style.stackedHeader && card.showApp
                        ? Theme.weightMedium : Theme.weightSemibold
                    color: card.style.stackedHeader && card.showApp
                        ? Theme.textMid : Theme.textHi
                    wrapMode: card.textExpanded ? Text.Wrap : Text.NoWrap
                    elide: card.textExpanded ? Text.ElideNone : Text.ElideRight
                }

                Item {
                    id: trailing
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    width: (card.groupCount > 1 ? 60 : 32)
                        // Keep the title's collapsed width stable while the
                        // disclosure appears. Letting `textTruncated` add its
                        // own width creates a binding loop at runtime.
                        + (card.allowTextExpansion ? textDisclosure.width : 0)
                    height: card.style.trailingHeight

                    // Collapsed-group count. The toast never groups, so this
                    // never renders there.
                    Rectangle {
                        visible: card.groupCount > 1
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        width: countText.implicitWidth + 12
                        height: Theme.chipInnerHeight
                        radius: Theme.chipRadius
                        color: "transparent"

                        Text {
                            id: countText
                            anchors.centerIn: parent
                            text: card.groupCount
                            font.family: card.style.face
                            font.pixelSize: card.style.pill
                            font.weight: Theme.weightMedium
                            font.features: Theme.tabularNumberFeatures
                            color: Theme.textMid
                        }
                    }

                    // The timestamp and the close button occupy the same
                    // spot, so a card never reflows when the pointer enters.
                    // The toast centres them in the trailing box and the
                    // centre right-aligns them; `stampCentred` keeps both
                    // surfaces where they were rather than picking one.
                    Text {
                        anchors.right: card.style.stampCentred ? undefined : parent.right
                        anchors.rightMargin: card.showTextDisclosure
                            && !card.style.stampCentred ? textDisclosure.width : 0
                        anchors.horizontalCenter: card.style.stampCentred
                            ? parent.horizontalCenter : undefined
                        anchors.verticalCenter: parent.verticalCenter
                        opacity: card.hovered || closeButton.activeFocus ? 0 : 1
                        text: Notifs.timeAgo(card.entry.arrived, card.nowMs)
                        font.family: card.style.stampFace
                        font.pixelSize: card.style.stampSize
                        font.weight: Theme.weightMedium
                        font.features: Theme.tabularNumberFeatures
                        color: Theme.textDim

                        Behavior on opacity {
                            NumberAnimation {
                                duration: Theme.chipFadeDuration / 2
                                easing.type: Easing.OutCubic
                            }
                        }
                    }

                    Rectangle {
                        id: closeButton
                        anchors.right: card.style.stampCentred ? undefined : parent.right
                        anchors.rightMargin: card.showTextDisclosure
                            && !card.style.stampCentred ? textDisclosure.width : 0
                        anchors.horizontalCenter: card.style.stampCentred
                            ? parent.horizontalCenter : undefined
                        anchors.verticalCenter: parent.verticalCenter
                        width: card.style.trailingHeight + 4
                        height: width
                        radius: width / 2
                        opacity: card.hovered || activeFocus ? 1 : 0
                        color: closeMouse.containsMouse || activeFocus
                            ? Theme.hoverFillStrong : "transparent"
                        activeFocusOnTab: card.keyboardEnabled
                        border.width: activeFocus ? 1 : 0
                        border.color: Theme.accentText
                        Accessible.role: Accessible.Button
                        Accessible.name: "Dismiss notification from "
                            + (card.entry.displayAppName || "this app")
                        Accessible.onPressAction: card.closeRequested()

                        Keys.onPressed: event => {
                            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                                    || event.key === Qt.Key_Space
                                    || event.key === Qt.Key_Delete) {
                                card.closeRequested();
                                event.accepted = true;
                            } else if (event.key === Qt.Key_Right || event.key === Qt.Key_Down) {
                                card.moveFocus(closeButton, true);
                                event.accepted = true;
                            } else if (event.key === Qt.Key_Left || event.key === Qt.Key_Up) {
                                card.moveFocus(closeButton, false);
                                event.accepted = true;
                            }
                        }

                        Sym {
                            anchors.centerIn: parent
                            name: "close"
                            size: card.style.close
                            color: closeMouse.containsMouse
                                ? Theme.textHi : card.style.closeColor
                        }

                        MouseArea {
                            id: closeMouse
                            anchors.fill: parent
                            enabled: card.hovered || closeButton.activeFocus
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                closeButton.forceActiveFocus();
                                card.closeRequested();
                            }
                        }

                        Behavior on opacity {
                            NumberAnimation {
                                duration: Theme.chipFadeDuration / 2
                                easing.type: Easing.OutCubic
                            }
                        }
                    }

                    Rectangle {
                        id: textDisclosure

                        visible: card.showTextDisclosure
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        width: card.style.trailingHeight + 4
                        height: width
                        radius: width / 2
                        color: disclosureMouse.containsMouse || activeFocus
                            ? Theme.hoverFillStrong : "transparent"
                        activeFocusOnTab: visible && card.keyboardEnabled
                        border.width: activeFocus ? 1 : 0
                        border.color: Theme.accentText

                        Accessible.role: Accessible.Button
                        Accessible.name: card.textExpandedByUser
                            ? "Collapse notification text"
                            : "Show full notification"
                        Accessible.onPressAction: card.toggleTextExpansion()

                        Keys.onPressed: event => {
                            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                                    || event.key === Qt.Key_Space) {
                                card.toggleTextExpansion();
                                event.accepted = true;
                            } else if (event.key === Qt.Key_Right || event.key === Qt.Key_Down) {
                                card.moveFocus(textDisclosure, true);
                                event.accepted = true;
                            } else if (event.key === Qt.Key_Left || event.key === Qt.Key_Up) {
                                card.moveFocus(textDisclosure, false);
                                event.accepted = true;
                            }
                        }

                        Sym {
                            anchors.centerIn: parent
                            name: card.textExpandedByUser
                                ? "expand_less" : "expand_more"
                            size: card.style.close
                            color: disclosureMouse.containsMouse
                                || textDisclosure.activeFocus
                                ? Theme.textHi : Theme.textDim
                        }

                        MouseArea {
                            id: disclosureMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                textDisclosure.forceActiveFocus();
                                card.toggleTextExpansion();
                            }
                        }
                    }
                }
            }

            Text {
                id: summary
                visible: card.style.stackedHeader && card.showApp
                    && card.entry.displaySummary !== ""
                width: parent.width
                text: card.entry.displaySummary || ""
                font.family: card.style.face
                font.pixelSize: card.style.header
                font.weight: Theme.weightSemibold
                color: Theme.textHi
                wrapMode: card.textExpanded ? Text.Wrap : Text.NoWrap
                elide: card.textExpanded ? Text.ElideNone : Text.ElideRight
            }

            Text {
                id: bodyText
                visible: text !== "" && card.style.bodyLines > 0
                width: parent.width
                text: card.entry.displayBody || ""
                font.family: card.style.face
                font.pixelSize: card.style.body
                color: card.urgent ? Theme.textHi : card.style.bodyColor
                wrapMode: Text.Wrap
                maximumLineCount: card.textExpanded
                    ? 2147483647 : Math.max(1, card.style.bodyLines)
                elide: card.textExpanded ? Text.ElideNone : Text.ElideRight
                lineHeight: card.style.bodyLeading
            }

            NotifActions {
                id: notificationActions
                entry: card.entry
                reveal: card.groupCount === 1 && (card.hovered || card.activeFocus
                    || closeButton.activeFocus || textDisclosure.activeFocus
                    || notificationActions.hasFocusedAction)
                keyboardEnabled: card.keyboardEnabled
                face: card.style.face
                pixelSize: card.style.pill
            }
        }
    }

    Behavior on color {
        ColorAnimation { duration: Theme.chipFadeDuration }
    }
}
