pragma Singleton
import QtQuick
import Quickshell

// Volume / brightness OSD state (design t3, shape 3a). One instance for
// both meters: a new key swaps the pill's content in place instead of
// stacking dialogs. The pill lingers 1.4s after the last change and every
// change retimes it.
Singleton {
    id: root

    property string kind: "volume" // "volume" | "brightness"
    readonly property bool active: linger.running

    // A local handle rather than reading Audio.sink at each site: the
    // onSinkChanged handler below is what re-arms the settle grace, and a
    // change handler needs a property on this object to hang off.
    readonly property var sink: Audio.sink

    // Pipewire replays volume and mute while the sink binds at session
    // start, and again whenever the default sink changes; neither is a
    // key press, so changes only count once the sink has settled.
    property bool settled: false

    Timer {
        id: grace
        interval: 1500
        running: true
        onTriggered: root.settled = true
    }

    onSinkChanged: {
        settled = false;
        grace.restart();
    }

    Connections {
        target: root.sink && root.sink.audio ? root.sink.audio : null

        function onVolumeChanged() {
            root.show("volume");
        }

        function onMutedChanged() {
            root.show("volume");
        }
    }

    // The audio and control popouts carry the same meter; the pill would
    // only double it underneath while one of them is on screen.
    readonly property bool suppressed: Popouts.open
        && (Popouts.currentName === "audio" || Popouts.currentName === "control")

    function show(k) {
        if (!settled || suppressed)
            return;
        kind = k;
        linger.restart();
    }

    // brightness-control pings this over IPC after brightnessctl runs:
    // sysfs backlight writes emit nothing watchable, and the % label
    // needs a fresh read anyway.
    function brightnessChanged() {
        SysInfo.refreshBrightness();
        show("brightness");
    }

    Timer {
        id: linger
        interval: 1400
    }
}
