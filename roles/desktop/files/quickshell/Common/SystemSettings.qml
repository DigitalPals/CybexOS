pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root
    readonly property bool externalBusy: external.running
    property string externalDomain: "accounts"
    function openExternal(domain) {
        if (external.running) return;
        externalDomain = domain;
        external.running = true;
    }
    property Process external: Process {
        command: [root.externalDomain === "accounts" ? "gnome-online-accounts-gtk"
            : root.externalDomain === "sound" ? "pavucontrol" : "nm-connection-editor"]
        stdout: StdioCollector {}
        stderr: StdioCollector {}
        onExited: exitCode => {
            const service = root.externalDomain === "accounts" ? root.accounts
                : root.externalDomain === "sound" ? root.sound : root.network;
            if (exitCode !== 0)
                service.error = "The advanced settings window could not open. Check that its package is installed.";
            service.refresh();
        }
    }
    readonly property SystemSettingsBackend sound: SystemSettingsBackend { domain: "sound" }
    readonly property SystemSettingsBackend network: SystemSettingsBackend { domain: "network" }
    readonly property SystemSettingsBackend accounts: SystemSettingsBackend {
        domain: "accounts"
        onCompleted: result => { if (result.success) Calendar.refreshDefault(); }
    }
}
