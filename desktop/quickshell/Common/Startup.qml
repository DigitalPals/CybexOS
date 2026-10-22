pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// A marker keyed to the current compositor session. It separates a new login
// (where configured startup policies apply) from a Quickshell service reload
// (where the live choices in Settings must resume untouched). The session key
// matters on machines with systemd user lingering: their XDG runtime directory
// can survive logout and must not itself be treated as session identity.
// Permission and IO failures fail closed: they are never mistaken for a new
// session that is allowed to turn a feature on automatically.
Singleton {
    id: root

    readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR")
    readonly property string sessionKey:
        Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE")
        || Quickshell.env("XDG_SESSION_ID") || "runtime"
    readonly property string markerPath: runtimeDir !== ""
        ? runtimeDir + "/cybexos-quickshell-started"
        : "/tmp/cybexos-quickshell-"
            + (Quickshell.env("USER") || "user") + "-started"
    property bool ready: false
    property bool firstStart: false
    property bool loadHandled: false

    function finish(first) {
        if (loadHandled)
            return;
        loadHandled = true;
        firstStart = first;
        ready = true;
        if (first)
            marker.setText(sessionKey + "\n");
    }

    FileView {
        id: marker
        path: root.markerPath
        printErrors: false
        atomicWrites: true
        blockWrites: true
        blockLoading: true
        onLoaded: root.finish(text().trim() !== root.sessionKey)
        onLoadFailed: error => {
            if (error === FileViewError.FileNotFound)
                root.finish(true);
            else {
                console.warn("startup marker could not be read:",
                    FileViewError.toString(error));
                root.finish(false);
            }
        }
        onSaveFailed: error => console.warn("startup marker could not be saved:",
            FileViewError.toString(error))
    }

    Component.onCompleted: {
        if (loadHandled)
            return;
        const existing = marker.text();
        if (!loadHandled && marker.loaded)
            finish(existing.trim() !== sessionKey);
    }
}
