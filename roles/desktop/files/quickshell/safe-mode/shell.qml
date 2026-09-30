pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland

// Quickshell private PostReloadHook is absent from installed type metadata.
// qmllint disable import

// Deliberately standalone: no settings, theme, plugins or connected services
// are constructed. A broken personal configuration stays untouched on disk.
ShellRoot {
    id: root
    // Recovery tokens cannot depend on a possibly broken Theme/Settings tree.
    readonly property var typography: ({ control: 13, body: 14, caption: 12 })

    function terminal() { Quickshell.execDetached(["kitty"]); }
    function recover() { Quickshell.execDetached(["cybexos-runtime", "shell", "recover"]); }

    GlobalShortcut {
        appid: "quickshell"
        name: "launcherToggle"
        description: "Open a recovery terminal"
        onPressed: root.terminal()
    }
    IpcHandler {
        target: "recovery"
        function status(): string { return "safe"; }
        function terminal(): void { root.terminal(); }
        function retry(): void { root.recover(); }
    }
    // Existing keybindings remain usable in the recovery session.
    IpcHandler {
        target: "launcher"
        function toggle(): void { root.terminal(); }
    }
    SystemClock { id: clock; precision: SystemClock.Minutes }

    component Action: Rectangle {
        id: action
        required property string label
        signal triggered()
        implicitWidth: caption.implicitWidth + 24
        implicitHeight: 30
        radius: 5
        color: activeFocus || pointer.containsMouse ? "#4c4b40" : "#35342f"
        activeFocusOnTab: true
        Accessible.role: Accessible.Button
        Accessible.name: label
        Accessible.onPressAction: triggered()
        Keys.onReturnPressed: triggered()
        Keys.onSpacePressed: triggered()
        Text { id: caption; anchors.centerIn: parent; text: action.label; color: "#ffffff"; font.pixelSize: root.typography.control }
        MouseArea { id: pointer; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: action.triggered() }
    }

    Variants {
        model: Quickshell.screens
        PanelWindow {
            id: panel
            required property var modelData
            screen: modelData
            anchors { top: true; left: true; right: true }
            implicitHeight: 46
            color: "#23221e"
            WlrLayershell.namespace: "qs-recovery"
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
            Row {
                anchors.left: parent.left
                anchors.leftMargin: 12
                anchors.verticalCenter: parent.verticalCenter
                spacing: 12
                Text { text: "CybexOS recovery"; color: "#e1df9a"; font.pixelSize: root.typography.body; height: 30; verticalAlignment: Text.AlignVCenter }
                Action { label: "Terminal"; onTriggered: root.terminal() }
                Action { label: "Retry desktop"; onTriggered: root.recover() }
                Text {
                    visible: panel.width > 900
                    text: "Widgets paused · Your settings are preserved · cybex shell status"
                    color: "#c9c7bd"; font.pixelSize: root.typography.caption; height: 30; verticalAlignment: Text.AlignVCenter
                }
            }
            Text {
                anchors.right: parent.right; anchors.rightMargin: 14
                anchors.verticalCenter: parent.verticalCenter
                text: Qt.formatDateTime(clock.date, "HH:mm")
                color: "#ffffff"; font.pixelSize: root.typography.body
            }
        }
    }
}
