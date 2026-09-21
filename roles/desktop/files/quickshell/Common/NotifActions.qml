pragma ComponentBehavior: Bound
import QtQuick

// The contextual action pills under a notification's body. The first action
// carries the accent, the rest are neutral. They are revealed on hover, and
// the shared Revealer keeps the pills alive through their exit so the card
// closes around them instead of snapping shorter on pointer exit.
Revealer {
    id: root

    required property var entry
    property string face: Theme.fontMenu
    property int pixelSize: Theme.fontCaption
    property bool keyboardEnabled: false

    property var items: []
    property int focusedActions: 0
    readonly property bool hasFocusedAction: focusedActions > 0

    orientation: Qt.Vertical

    function refreshItems() {
        items = Notifs.secondaryActions(entry);
    }

    onRevealChanged: {
        if (reveal)
            refreshItems();
    }
    onEntryChanged: {
        if (reveal)
            refreshItems();
    }
    Component.onCompleted: {
        if (reveal)
            refreshItems();
    }

    Flow {
        width: root.width
        spacing: Theme.iconTextSpacing

        Repeater {
            model: root.items

            delegate: Rectangle {
                id: pill

                required property var modelData
                required property int index

                readonly property bool primary: index === 0

                height: Math.max(Theme.chipInnerHeight, root.pixelSize + Theme.iconTextSpacing * 2)
                width: Math.min(root.width, pillText.implicitWidth + Theme.controlSpacing * 2, Theme.scaled(160))
                radius: Theme.chipRadius
                color: primary
                    ? (pillMouse.containsMouse || activeFocus ? Theme.accentBg : Theme.accentBgSoft)
                    : (pillMouse.containsMouse || activeFocus ? Theme.hoverFillStrong : Theme.hoverFill)
                activeFocusOnTab: root.keyboardEnabled && root.reveal
                border.width: activeFocus ? 1 : 0
                border.color: Theme.accentText
                Accessible.role: Accessible.Button
                Accessible.name: pill.modelData.text
                Accessible.onPressAction: Notifs.invoke(root.entry, pill.modelData)

                onActiveFocusChanged: root.focusedActions = Math.max(0,
                    root.focusedActions + (activeFocus ? 1 : -1))

                Keys.onPressed: event => {
                    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                            || event.key === Qt.Key_Space) {
                        Notifs.invoke(root.entry, pill.modelData);
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Right || event.key === Qt.Key_Down) {
                        const next = pill.nextItemInFocusChain(true);
                        if (next)
                            next.forceActiveFocus();
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Left || event.key === Qt.Key_Up) {
                        const previous = pill.nextItemInFocusChain(false);
                        if (previous)
                            previous.forceActiveFocus();
                        event.accepted = true;
                    }
                }

                Text {
                    id: pillText
                    anchors.centerIn: parent
                    width: parent.width - 16
                    text: pill.modelData.text
                    font.family: root.face
                    font.pixelSize: root.pixelSize
                    font.weight: Theme.weightMedium
                    color: pill.primary ? Theme.accentText : Theme.textMid
                    horizontalAlignment: Text.AlignHCenter
                    elide: Text.ElideRight
                }

                MouseArea {
                    id: pillMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        pill.forceActiveFocus();
                        Notifs.invoke(root.entry, pill.modelData);
                    }
                }
            }
        }
    }
}
