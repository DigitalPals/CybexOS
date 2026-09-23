pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Services.UPower
import Quickshell.Wayland

// Whether anyone is at the machine, and whether it should spend energy on
// polish. Background pollers gate their timers on `idle`, so an unattended or
// locked session stops spawning work nobody will see; `resumed` is their cue
// to refresh whatever went stale meanwhile, the way the online edge already
// is for network work.
//
// The monitor respects idle inhibitors: "stay awake" and fullscreen video keep
// the shell as live as the screen they keep on.
Singleton {
    id: root

    readonly property bool idle: monitor.isIdle
    readonly property bool onBattery: UPower.onBattery
    // The user's explicit request to trade polish for battery. Motion and
    // compositor effects follow it; pollers follow `idle` instead.
    readonly property bool powerSaver:
        PowerProfiles.profile === PowerProfile.PowerSaver

    signal resumed()

    IdleMonitor {
        id: monitor

        // Idle notification is a Wayland protocol. The offscreen test
        // harness has no compositor to ask, and a monitor that never
        // reports idle is the right answer there.
        enabled: Qt.platform.pluginName.startsWith("wayland")
        timeout: 300
        respectInhibitors: true
        onIsIdleChanged: {
            if (!isIdle)
                root.resumed();
        }
    }
}
