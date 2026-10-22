import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import "../Common"

// Panels use their own layer surface. Their content and native height may
// change while switching modules, but the menubar's surface remains stable.
PanelWindow {
    id: root

    required property Bar bar

    // Every output has a popout window, but only the bar that originated the
    // shell-wide popout may show it or take the focus grab.
    readonly property bool live: bar.visible && bar.popoutHost

    // Map immediately on open intent so the first Loader can incubate. Once
    // Popouts.open drops, `presented` keeps the surface alive through the
    // closing animation.
    visible: live && (Popouts.open || popout.presented)
    anchors {
        top: Settings.position === "top"
        bottom: Settings.position === "bottom"
        left: true
        right: true
    }
    implicitHeight: Math.max(1, popout.requiredHeight)
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"

    mask: Region {
        Region { item: popout.cardMaskItem }
        Region { item: popout.overflowMaskItem }
    }
    // Do not set HyprlandWindow.visibleMask here. In Quickshell 0.2.1 the
    // region is applied in the wrong coordinate space on scaled outputs,
    // clipping the detached card along its sides and bottom at 2x scale.
    // The input mask above is unaffected and must remain tight.

    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.keyboardFocus: root.visible ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
    WlrLayershell.namespace: "qs-bar-popout"

    HyprlandFocusGrab {
        active: root.live && Popouts.open
        windows: [root.bar, root]
        onCleared: {
            // Deactivating the old output during an intentional handoff is
            // not an outside click. The newly live host takes over the grab.
            if (root.live)
                Popouts.close();
        }
    }

    PopoutHost {
        id: popout
        width: root.bar.width
        height: root.implicitHeight
        live: root.live
        outputAvailableHeight: root.screen ? root.screen.height : 560
        leftIslandRect: root.bar.leftIslandRect
        centerIslandRect: root.bar.centerIslandRect
        rightIslandRect: root.bar.rightIslandRect
    }
}
