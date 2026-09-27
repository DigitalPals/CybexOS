pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls as Controls
import Quickshell
import Quickshell.Io
import Quickshell.Services.Polkit
import Quickshell.Wayland
import "Common"

PanelWindow {
    id: root

    property string hostScreenName: ""
    readonly property bool active: agent.flow !== null
        && !agent.flow.isCompleted && !agent.flow.isCancelled
    onActiveChanged: NetworkOverlayState.authenticationActive = active

    visible: active
    screen: Screens.byName(hostScreenName) ?? Screens.focused
    anchors { top: true; left: true; right: true; bottom: true }
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "qs-polkit"
    WlrLayershell.keyboardFocus: active ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    function releaseOverlays() {
        if (!active)
            return;
        Launcher.close();
        Popouts.close();
        Session.closeKeys();
    }

    PolkitAgent {
        id: agent
        onFlowChanged: {
            if (!root.active)
                return;
            root.hostScreenName = Screens.focused ? Screens.focused.name : "";
            // Release other exclusive shell surfaces before taking the keyboard.
            root.releaseOverlays();
        }
    }

    // A global shortcut must not put another exclusive surface in front of
    // the prompt while the user is entering a response.
    Connections {
        target: Launcher
        function onOpenChanged() { if (Launcher.open) root.releaseOverlays(); }
    }
    Connections {
        target: Popouts
        function onOpenChanged() { if (Popouts.open) root.releaseOverlays(); }
    }
    Connections {
        target: Session
        function onKeysOpenChanged() { if (Session.keysOpen) root.releaseOverlays(); }
    }

    // Health checks can inspect registration without exposing identities,
    // actions, cookies or responses. There is deliberately no submit IPC.
    IpcHandler {
        target: "polkit"
        function status(): string {
            return JSON.stringify({registered: agent.isRegistered, active: root.active});
        }
    }

    Rectangle {
        anchors.fill: parent
        color: Theme.scrim
        // An accidental click outside the card must not cancel an app's request.
        MouseArea { anchors.fill: parent }
    }

    Rectangle {
        anchors.centerIn: parent
        width: Math.max(1, Math.min(Theme.scaled(440, Theme.typeScale), root.width - 32))
        height: Math.min(root.height - 32, promptLoader.implicitHeight + Theme.scaled(48))
        radius: Theme.popRadius
        color: Theme.background
        border.width: 1
        border.color: Theme.stroke

        Controls.ScrollView {
            anchors.fill: parent
            anchors.margins: Theme.scaled(24)
            contentWidth: availableWidth
            contentHeight: promptLoader.implicitHeight
            clip: true
            Controls.ScrollBar.horizontal.policy: Controls.ScrollBar.AlwaysOff

            Loader {
                id: promptLoader
                width: parent.width
                active: root.active
                focus: true
                sourceComponent: PolkitPrompt {
                    flow: agent.flow
                    width: promptLoader.width
                }
            }
        }
    }
}
