pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "ProcHelpers.js" as ProcHelpers
import "SettingsHelpers.js" as SettingsHelpers
import "SysInfoHelpers.js" as SysInfoHelpers

Singleton {
    id: root

    property int cpuTemp: 0
    property bool cpuTempKnown: false
    property real cpuUsage: 0 // percent
    property bool cpuUsageKnown: false
    property real memUsage: 0 // percent
    property bool memKnown: false
    property double memTotalBytes: 0
    property double memUsedBytes: 0
    property bool swapKnown: false
    property double swapTotalBytes: 0
    property double swapUsedBytes: 0
    property real swapUsage: 0 // percent

    property string osId: ""
    property string osName: ""
    property string osVersion: ""
    property string osVariant: ""
    property string deviceVendor: ""
    property string deviceModel: ""
    property string kernelRelease: ""
    property string cpuModel: ""
    property int uptimeSecs: -1
    readonly property bool uptimeKnown: uptimeSecs >= 0

    property bool rootFsKnown: false
    property string rootFsType: ""
    property double rootFsTotalBytes: 0
    property double rootFsUsedBytes: 0
    property double rootFsAvailableBytes: 0
    property real rootFsUsage: 0 // percent
    property string rootFsError: ""

    property int brightness: -1 // percent, -1 while unknown
    readonly property string user: Quickshell.env("USER") || "user"
    property string host: ""

    // Shared idle-inhibit state (bar module + control center toggle). The mode
    // and absolute deadline are persisted so a service reload resumes the
    // request without granting it a fresh duration. Startup.qml distinguishes
    // that reload from a new login, where the configured policy is applied.
    property double idleInhibitClockMs: Date.now()
    readonly property string idleInhibitMode: Settings.idleInhibitMode
    readonly property double idleInhibitUntilMs: Settings.idleInhibitUntilMs
    readonly property bool idleInhibited: idleInhibitMode !== "off"
    readonly property int idleInhibitRemainingSecs: idleInhibitUntilMs > 0
        ? Math.max(0, Math.ceil((idleInhibitUntilMs - idleInhibitClockMs) / 1000)) : 0
    readonly property string idleInhibitStatus: {
        if (!idleInhibited)
            return "Off";
        if (idleInhibitMode === "always")
            return "Until turned off";
        if (idleInhibitMode === "unplugged")
            return "Until unplugged";
        const mins = Math.max(1, Math.ceil(idleInhibitRemainingSecs / 60));
        return mins + " min left";
    }
    property bool idleInhibitPending: false
    property bool idleInhibitEffective: false
    property string idleInhibitError: ""
    property string idleInhibitLifecycle: "stopped"
    property int idleInhibitRetrySecs: 5
    property bool startupApplied: false

    // Night light: hyprsunset warms the screen while enabled and restores
    // neutral gamma when the process is killed.
    readonly property bool nightLight: Settings.nightLight
    property string nightLightLifecycle: "stopped"
    property bool nightLightPending: false
    property bool nightLightEffective: false
    property string nightLightError: ""
    property int nightLightRetrySecs: 5
    property string tempPath: ""
    property var cpuPrev: null

    // Hypridle honors systemd's idle inhibitors directly. Keep this process
    // alive while the toggle is enabled because the Wayland inhibitor tied to
    // the bar layer surface is not consistently observed by Hypridle.
    Process {
        id: idleInhibitProc

        property bool exitSeen: false
        property int lastExit: -1
        property bool expectedStop: false

        command: ["systemd-inhibit", "--what=idle", "--who=Quickshell",
            "--why=Idle inhibit enabled from the menubar", "--mode=block",
            "sleep", "infinity"]

        onExited: exitCode => {
            exitSeen = true;
            lastExit = exitCode;
        }
        onRunningChanged: {
            if (running) {
                exitSeen = false;
                lastExit = -1;
                idleInhibitConfirm.restart();
                return;
            }
            idleInhibitConfirm.stop();
            root.idleInhibitEffective = false;
            if (expectedStop || !root.idleInhibited) {
                expectedStop = false;
                root.idleInhibitPending = false;
                root.idleInhibitLifecycle = "stopped";
                return;
            }
            root.idleInhibitPending = false;
            root.idleInhibitLifecycle = "error";
            root.idleInhibitError = exitSeen && lastExit >= 0
                ? "Idle inhibitor exited with status " + lastExit
                : "Idle inhibitor could not be started";
            idleInhibitRetry.interval = root.idleInhibitRetrySecs * 1000;
            root.idleInhibitRetrySecs = Math.min(root.idleInhibitRetrySecs * 2, 60);
            idleInhibitRetry.restart();
        }
    }

    Process {
        id: sunsetProc
        property bool exitSeen: false
        property int lastExit: -1
        command: ["hyprsunset", "--temperature", String(Settings.warmth)]
        running: false

        onExited: exitCode => {
            exitSeen = true;
            lastExit = exitCode;
        }
        onRunningChanged: {
            if (running) {
                exitSeen = false;
                lastExit = -1;
                nightLightConfirm.restart();
                return;
            }
            nightLightConfirm.stop();
            root.nightLightEffective = false;
            if (root.nightLightLifecycle === "restarting" && root.nightLight) {
                root.nightLightLifecycle = "starting";
                sunsetProc.command = ["hyprsunset", "--temperature", String(Settings.warmth)];
                sunsetProc.running = true;
            } else if (root.nightLightLifecycle === "stopping" || !root.nightLight) {
                root.nightLightLifecycle = "stopped";
                root.nightLightPending = false;
            } else {
                root.nightLightLifecycle = "error";
                root.nightLightPending = false;
                root.nightLightError = exitSeen && lastExit >= 0
                    ? "Night light exited with status " + lastExit
                    : "Night light could not be started";
                nightLightRetry.interval = root.nightLightRetrySecs * 1000;
                root.nightLightRetrySecs = Math.min(root.nightLightRetrySecs * 2, 60);
                nightLightRetry.restart();
            }
        }
    }

    function syncIdleInhibit() {
        idleInhibitRetry.stop();
        if (idleInhibited) {
            if (idleInhibitProc.running)
                return;
            idleInhibitProc.expectedStop = false;
            idleInhibitPending = true;
            idleInhibitLifecycle = "starting";
            idleInhibitError = "";
            idleInhibitProc.running = true;
        } else {
            idleInhibitError = "";
            idleInhibitRetrySecs = 5;
            idleInhibitPending = idleInhibitProc.running;
            idleInhibitLifecycle = idleInhibitProc.running ? "stopping" : "stopped";
            if (idleInhibitProc.running) {
                idleInhibitProc.expectedStop = true;
                idleInhibitProc.running = false;
            } else {
                idleInhibitEffective = false;
                idleInhibitPending = false;
            }
        }
    }

    function syncNightLight() {
        nightLightRetry.stop();
        if (nightLight) {
            if (sunsetProc.running)
                return;
            nightLightPending = true;
            nightLightError = "";
            nightLightLifecycle = "starting";
            sunsetProc.command = ["hyprsunset", "--temperature", String(Settings.warmth)];
            sunsetProc.running = true;
        } else if (sunsetProc.running) {
            nightLightPending = true;
            nightLightError = "";
            nightLightRetrySecs = 5;
            nightLightLifecycle = "stopping";
            sunsetProc.running = false;
        } else {
            nightLightPending = false;
            nightLightEffective = false;
            nightLightError = "";
            nightLightRetrySecs = 5;
            nightLightLifecycle = "stopped";
        }
    }

    function setNightLight(value) {
        Settings.set("nightLight", !!value);
    }

    function toggleNightLight() {
        setNightLight(!nightLight);
    }

    function setIdleInhibitMode(mode) {
        const accepted = ["off", "30m", "1h", "unplugged", "always"];
        if (accepted.indexOf(mode) === -1)
            mode = "off";

        const until = mode === "30m" ? Date.now() + 30 * 60000
            : mode === "1h" ? Date.now() + 60 * 60000 : 0;
        // Publish a deadline before enabling its timed mode. Readers can see
        // either endpoint during the two synchronous notifications, but never
        // an enabled timed request with a stale or zero deadline.
        if (until > 0)
            Settings.set("idleInhibitUntilMs", until);
        Settings.set("idleInhibitMode", mode);
        if (until === 0)
            Settings.set("idleInhibitUntilMs", 0);
        idleInhibitClockMs = Date.now();
        if (Settings.idleInhibitMode === mode)
            syncIdleInhibit();

        if (mode === "unplugged" && Battery.isLaptop && !Battery.pluggedIn)
            setIdleInhibitMode("off");
    }

    function setIdleInhibited(value) {
        setIdleInhibitMode(value ? "always" : "off");
    }

    function toggleIdleInhibited() {
        setIdleInhibitMode(idleInhibited ? "off"
            : Settings.modOpts.indicators.idleDefaultMode);
    }

    function applyStartupPolicies() {
        if (startupApplied || !Startup.ready || !Settings.loaded)
            return;
        startupApplied = true;

        if (Startup.firstStart) {
            const nightPolicy = Settings.modOpts.indicators.nightLightStartup;
            if (nightPolicy === "off" && Settings.nightLight)
                Settings.set("nightLight", false);
            else if (nightPolicy === "on" && !Settings.nightLight)
                Settings.set("nightLight", true);

            const idlePolicy = Settings.modOpts.indicators.idleStartup;
            if (idlePolicy === "off")
                setIdleInhibitMode("off");
            else if (idlePolicy === "on")
                setIdleInhibitMode("always");
        }

        // A remembered deadline may have elapsed while the shell or the whole
        // session was down. Never turn that into a fresh request.
        idleInhibitClockMs = Date.now();
        if ((idleInhibitMode === "30m" || idleInhibitMode === "1h")
                && idleInhibitUntilMs <= idleInhibitClockMs)
            setIdleInhibitMode("off");
        else if (idleInhibitMode === "unplugged" && Battery.isLaptop
                && !Battery.pluggedIn)
            setIdleInhibitMode("off");

        syncIdleInhibit();
        syncNightLight();
    }

    onNightLightChanged: {
        if (startupApplied)
            syncNightLight();
    }
    onIdleInhibitModeChanged: {
        if (startupApplied)
            syncIdleInhibit();
    }

    // Every reader shows whole minutes, so tick where the minute count
    // changes and at the deadline itself rather than once a second. Each tick
    // moves the clock, which re-arms the interval from the new reading; a
    // timer that fires early just lands one extra short tick.
    Timer {
        interval: SysInfoHelpers.countdownTickMs(root.idleInhibitUntilMs,
            root.idleInhibitClockMs)
        running: root.idleInhibitUntilMs > 0
        repeat: true
        onTriggered: {
            root.idleInhibitClockMs = Date.now();
            if (root.idleInhibitClockMs >= root.idleInhibitUntilMs)
                root.setIdleInhibitMode("off");
        }
    }

    Connections {
        target: Battery

        function onPluggedInChanged() {
            if (root.idleInhibitMode === "unplugged"
                    && Battery.isLaptop && !Battery.pluggedIn)
                root.setIdleInhibitMode("off");
        }

        function onIsLaptopChanged() {
            if (root.idleInhibitMode === "unplugged"
                    && Battery.isLaptop && !Battery.pluggedIn)
                root.setIdleInhibitMode("off");
        }
    }

    Timer {
        id: idleInhibitConfirm
        interval: 300
        onTriggered: {
            if (!idleInhibitProc.running || !root.idleInhibited)
                return;
            root.idleInhibitEffective = true;
            root.idleInhibitPending = false;
            root.idleInhibitError = "";
            root.idleInhibitLifecycle = "running";
            root.idleInhibitRetrySecs = 5;
        }
    }

    Timer {
        id: idleInhibitRetry
        onTriggered: {
            if (root.idleInhibited)
                root.syncIdleInhibit();
        }
    }

    Timer {
        id: nightLightConfirm
        interval: 300
        onTriggered: {
            if (!sunsetProc.running || !root.nightLight)
                return;
            root.nightLightEffective = true;
            root.nightLightPending = false;
            root.nightLightError = "";
            root.nightLightLifecycle = "running";
            root.nightLightRetrySecs = 5;
        }
    }

    Timer {
        id: nightLightRetry
        onTriggered: {
            if (root.nightLight)
                root.syncNightLight();
        }
    }

    // Command changes are inert on a running process, so a warmth change
    // restarts it — debounced so a slider drag doesn't churn processes.
    Timer {
        id: warmthRestart
        interval: 300
        onTriggered: {
            if (root.nightLight && sunsetProc.running) {
                nightLightRetry.stop();
                root.nightLightPending = true;
                root.nightLightLifecycle = "restarting";
                sunsetProc.running = false;
            } else if (root.nightLight)
                root.syncNightLight();
        }
    }

    Connections {
        target: Settings

        function onWarmthChanged() {
            warmthRestart.restart();
        }
    }

    Connections {
        target: Startup

        function onReadyChanged() {
            root.applyStartupPolicies();
        }
    }

    Connections {
        target: Settings

        function onLoadedChanged() {
            root.applyStartupPolicies();
        }
    }

    Component.onCompleted: {
        applyStartupPolicies();
        // hypridle started from the file as it was when the shell loaded it.
        idleTimeoutsApplied = persistedIdleTimeouts();
        refreshIdleUserConfig();
    }

    // ---- idle timeouts -------------------------------------------------
    // cybexos-runtime renders hypridle's configuration from shell.json
    // when hypridle starts, so a change applies by restarting the service
    // once the file holds it. The comparison uses the saved text, not the
    // live values: those can be ahead of the file while a save is in flight.
    // A user-owned hypridle.conf replaces the rendered file entirely.
    readonly property string idleUserConfigPath: Quickshell.env("HOME")
        + "/.config/cybexos/hypr/hypridle.conf"
    property string idleTimeoutsApplied: ""
    property string idleTimeoutsError: ""
    property bool idleUserConfig: false

    function idleTimeoutsKey(settings) {
        return [settings.idleLockMins, settings.idleScreenOffMins,
            settings.idleSuspendMins, settings.idleSuspendBatteryOnly].join(",");
    }

    function persistedIdleTimeouts() {
        const parsed = SettingsHelpers.parse(Settings.lastPersistedText);
        return idleTimeoutsKey(SettingsHelpers.merge(parsed.value));
    }

    function applyIdleTimeouts() {
        const key = persistedIdleTimeouts();
        if (key === idleTimeoutsApplied)
            return;
        if (idleRestartProc.running) {
            idleApplyTimer.restart();
            return;
        }
        idleRestartProc.key = key;
        idleRestartProc.running = true;
    }

    function refreshIdleUserConfig() {
        if (!idleUserConfigProc.running)
            idleUserConfigProc.running = true;
    }

    Connections {
        target: Settings

        function onLastPersistedTextChanged() {
            idleApplyTimer.restart();
        }
    }

    Timer {
        id: idleApplyTimer
        interval: 250
        onTriggered: root.applyIdleTimeouts()
    }

    Process {
        id: idleRestartProc

        property string key: ""
        property bool exitSeen: false
        property int lastExit: ProcHelpers.NOT_STARTED

        // try-restart leaves a stopped hypridle stopped (the live session
        // never starts it); the next start renders the new file anyway.
        command: ["systemctl", "--user", "try-restart", "hypridle.service"]
        onExited: exitCode => {
            exitSeen = true;
            lastExit = exitCode;
        }
        onRunningChanged: {
            if (running) {
                exitSeen = false;
                lastExit = ProcHelpers.NOT_STARTED;
                return;
            }
            const code = exitSeen ? lastExit : ProcHelpers.NOT_STARTED;
            if (code === 0) {
                root.idleTimeoutsApplied = key;
                root.idleTimeoutsError = "";
            } else {
                root.idleTimeoutsError = "The idle service could not be restarted";
                console.warn("could not restart hypridle.service:", code);
            }
            if (root.persistedIdleTimeouts() !== root.idleTimeoutsApplied && code === 0)
                idleApplyTimer.restart();
        }
    }

    Process {
        id: idleUserConfigProc

        // The same test cybexos-runtime applies before preferring it.
        command: ["sh", "-c", '[ -f "$1" ] && [ ! -L "$1" ]', "sh",
            root.idleUserConfigPath]
        onExited: exitCode => root.idleUserConfig = exitCode === 0
    }

    // ---- system identity and live metrics ----------------------------
    // Identity files are tiny and immutable for the lifetime of the shell,
    // so FileView loads each once. Live /proc and sysfs views are reloaded by
    // the watcher-scoped timers below.
    FileView {
        id: osReleaseView
        path: "/etc/os-release"
        printErrors: false
        blockLoading: true
        onLoaded: {
            const info = SysInfoHelpers.parseOsRelease(text());
            root.osId = info.id;
            root.osName = info.name;
            root.osVersion = info.version;
            root.osVariant = info.variant;
        }
        onLoadFailed: {
            root.osId = "";
            root.osName = "";
            root.osVersion = "";
            root.osVariant = "";
        }
    }

    FileView {
        path: "/etc/hostname"
        printErrors: false
        blockLoading: true
        onLoaded: root.host = text().trim()
        onLoadFailed: root.host = ""
    }

    FileView {
        path: "/sys/devices/virtual/dmi/id/sys_vendor"
        printErrors: false
        blockLoading: true
        onLoaded: root.deviceVendor = text().trim()
        onLoadFailed: root.deviceVendor = ""
    }

    FileView {
        path: "/sys/devices/virtual/dmi/id/product_name"
        printErrors: false
        blockLoading: true
        onLoaded: root.deviceModel = text().trim()
        onLoadFailed: root.deviceModel = ""
    }

    FileView {
        path: "/proc/sys/kernel/osrelease"
        printErrors: false
        blockLoading: true
        onLoaded: root.kernelRelease = text().trim()
        onLoadFailed: root.kernelRelease = ""
    }

    // Tens of kilobytes on a many-core machine and only shown in the system
    // panel: load it off the startup path.
    FileView {
        path: "/proc/cpuinfo"
        printErrors: false
        onLoaded: root.cpuModel = SysInfoHelpers.parseCpuModel(text())
        onLoadFailed: root.cpuModel = ""
    }

    // Discover the CPU sensor once, then use cheap FileView reloads.
    Process {
        id: sensorDiscovery
        command: ["sh", "-c", "for h in /sys/class/hwmon/hwmon*; do [ \"$(cat \"$h/name\" 2>/dev/null)\" = coretemp ] && { printf '%s' \"$h/temp1_input\"; exit; }; done"]
        running: true
        stdout: StdioCollector {
            onStreamFinished: root.tempPath = text.trim()
        }
    }

    FileView {
        id: tempView
        path: root.tempPath
        printErrors: false
        onLoaded: root.readTemperature()
        onLoadFailed: root.cpuTempKnown = false
    }

    FileView {
        id: statView
        path: "/proc/stat"
        printErrors: false
        onLoaded: root.readCpu()
        onLoadFailed: {
            root.cpuPrev = null;
            root.cpuUsageKnown = false;
        }
    }

    FileView {
        id: memView
        path: "/proc/meminfo"
        printErrors: false
        onLoaded: root.readMem()
        onLoadFailed: root.clearMemory()
    }

    FileView {
        id: uptimeView
        path: "/proc/uptime"
        printErrors: false
        onLoaded: root.readUptime()
        onLoadFailed: root.uptimeSecs = -1
    }

    function readTemperature() {
        if (tempPath === "") {
            cpuTempKnown = false;
            return;
        }
        const value = parseInt(tempView.text().trim());
        if (!isNaN(value) && value >= 0) {
            cpuTemp = Math.round(value / 1000);
            cpuTempKnown = true;
        } else {
            cpuTempKnown = false;
        }
    }

    function readCpu() {
        const current = SysInfoHelpers.parseCpuStat(statView.text());
        if (current === null) {
            cpuPrev = null;
            cpuUsageKnown = false;
            return;
        }
        const usage = SysInfoHelpers.cpuUsage(cpuPrev, current);
        cpuPrev = current;
        if (usage === null) {
            cpuUsageKnown = false;
            return;
        }
        cpuUsage = usage;
        cpuUsageKnown = true;
    }

    function clearMemory() {
        memKnown = false;
        memTotalBytes = 0;
        memUsedBytes = 0;
        memUsage = 0;
        swapKnown = false;
        swapTotalBytes = 0;
        swapUsedBytes = 0;
        swapUsage = 0;
    }

    function readMem() {
        const memory = SysInfoHelpers.parseMemInfo(memView.text());
        memKnown = memory.memKnown;
        memTotalBytes = memory.memTotalBytes;
        memUsedBytes = memory.memUsedBytes;
        memUsage = memory.memUsage;
        swapKnown = memory.swapKnown;
        swapTotalBytes = memory.swapTotalBytes;
        swapUsedBytes = memory.swapUsedBytes;
        swapUsage = memory.swapUsage;
    }

    function readUptime() {
        const value = SysInfoHelpers.parseUptime(uptimeView.text());
        uptimeSecs = value === null ? -1 : value;
    }

    function setRootFsUnavailable(reason) {
        const changed = rootFsKnown || rootFsError !== reason;
        rootFsKnown = false;
        rootFsType = "";
        rootFsTotalBytes = 0;
        rootFsUsedBytes = 0;
        rootFsAvailableBytes = 0;
        rootFsUsage = 0;
        rootFsError = reason;
        if (changed)
            console.warn("root filesystem probe:", reason);
    }

    function finishRootFsProbe(exitCode, stdoutText, stderrText) {
        if (exitCode !== 0) {
            setRootFsUnavailable(ProcHelpers.commandError(
                "df", exitCode, stderrText));
            return;
        }
        const disk = SysInfoHelpers.parseDf(stdoutText);
        if (disk === null) {
            setRootFsUnavailable("df returned unreadable root filesystem data");
            return;
        }
        rootFsType = disk.type;
        rootFsTotalBytes = disk.totalBytes;
        rootFsUsedBytes = disk.usedBytes;
        rootFsAvailableBytes = disk.availableBytes;
        rootFsUsage = disk.usage;
        rootFsError = "";
        rootFsKnown = true;
    }

    function refreshRootFs() {
        if (!rootFsProc.running)
            rootFsProc.running = true;
    }

    Process {
        id: rootFsProc

        property bool exitSeen: false
        property int lastExit: ProcHelpers.NOT_STARTED
        property string body: ""
        property string errText: ""

        command: ["df", "--block-size=1",
            "--output=fstype,size,used,avail,pcent,target", "/"]
        // QML object literals convert to QVariantHash at runtime; the shipped
        // Quickshell type description reports them as QVariantMap to qmllint.
        // qmllint disable incompatible-type
        environment: ({ LC_ALL: "C" })
        // qmllint enable incompatible-type
        stdout: StdioCollector {
            onStreamFinished: rootFsProc.body = text
        }
        stderr: StdioCollector {
            onStreamFinished: rootFsProc.errText = text
        }
        onExited: (exitCode, exitStatus) => {
            rootFsProc.exitSeen = true;
            rootFsProc.lastExit = exitCode;
        }
        onRunningChanged: {
            if (rootFsProc.running) {
                rootFsProc.exitSeen = false;
                rootFsProc.lastExit = ProcHelpers.NOT_STARTED;
                rootFsProc.body = "";
                rootFsProc.errText = "";
                return;
            }
            root.finishRootFsProbe(rootFsProc.exitSeen
                ? rootFsProc.lastExit : ProcHelpers.NOT_STARTED,
                rootFsProc.body, rootFsProc.errText);
        }
    }

    // ---- brightness --------------------------------------------------
    // Both directions go through brightness-control, because which screen is
    // in front of you decides whether brightness is a sysfs backlight or an
    // Apple display speaking USB HID, and that is not this singleton's
    // business to know. Reading used to be a direct sysfs read — free, and
    // the right number only while the laptop panel was the display. Docked to
    // the Studio Display it reported the closed lid's backlight, and writing
    // brightnessctl moved that panel instead of the one being looked at.
    readonly property string brightnessTool:
        Quickshell.env("HOME") + "/.local/bin/brightness-control"

    // The reading follows the pointer immediately so the slider stays live
    // under a drag; the process that writes it is coalesced onto the last
    // value, since a drag emits one on every mouse move.
    property int pendingBrightness: -1

    function setBrightness(pct) {
        pct = Math.max(0, Math.min(100, Math.round(pct)));
        brightness = pct;
        pendingBrightness = pct;
        brightnessWrite.restart();
    }

    Timer {
        id: brightnessWrite
        interval: 60
        onTriggered: {
            if (root.pendingBrightness < 0)
                return;
            // A write still in flight owns the device; re-arm rather than
            // start a second one over the top of it.
            if (brightnessSet.running) {
                brightnessWrite.restart();
                return;
            }
            brightnessSet.command = [root.brightnessTool, "set",
                String(root.pendingBrightness)];
            root.pendingBrightness = -1;
            brightnessSet.running = true;
            brightnessSettle.restart();
        }
    }

    // A failed write leaves the slider showing a value the display never
    // took; drop the settle window and read back what it really has.
    Process {
        id: brightnessSet
        property bool exitSeen: false
        property int lastExit: 0
        onExited: (exitCode, exitStatus) => {
            brightnessSet.exitSeen = true;
            brightnessSet.lastExit = exitCode;
        }
        onRunningChanged: {
            if (running) {
                exitSeen = false;
                lastExit = 0;
                return;
            }
            if (!exitSeen || lastExit !== 0)
                brightnessSettle.stop();
            Qt.callLater(root.refreshBrightness);
        }
    }

    // A write that has not landed yet is still the truth: a read overtaking
    // it would drag the slider back to a value the pointer has already left.
    // Once it has settled, read back what the display actually took.
    Timer {
        id: brightnessSettle
        interval: 400
        onTriggered: root.refreshBrightness()
    }

    // brightness-control talks to hardware (DDC/HID) that can stop
    // answering. A hung helper would otherwise hold its process forever:
    // a stuck read makes refreshBrightness a permanent no-op, a stuck write
    // re-arms brightnessWrite forever.
    Timer {
        interval: 5000
        running: brightnessRead.running
        onTriggered: brightnessRead.running = false
    }

    Timer {
        interval: 5000
        running: brightnessSet.running
        onTriggered: brightnessSet.running = false
    }

    // Nothing about either backend is watchable — sysfs backlight attributes
    // deliver no inotify events and a HID write emits none — so every
    // consumer that can observe an external change calls this. The OSD does,
    // over IPC from brightness-control itself.
    function refreshBrightness() {
        if (brightnessRead.running || brightnessWrite.running
                || brightnessSettle.running || brightnessSet.running)
            return;
        brightnessRead.running = true;
    }

    // Not read at login: nothing shows brightness until the Overview claims
    // SysInfo or brightness-control pings the OSD, and both read it then.
    // Until then it stays -1, which every view draws as unknown.
    Process {
        id: brightnessRead
        command: [root.brightnessTool, "get"]
        stdout: StdioCollector {
            onStreamFinished: {
                const value = parseInt(text.trim());
                if (!isNaN(value))
                    root.brightness = Math.max(0, Math.min(100, value));
            }
        }
    }

    onTempPathChanged: {
        if (tempPath !== "") {
            tempView.reload();
        } else
            cpuTempKnown = false;
    }

    // ---- watchers ---------------------------------------------------
    // Which views are on screen is their business, not this singleton's:
    // it used to sample whenever *any* popout was open, so opening the
    // media panel read /proc/stat for nobody. A view that wants these
    // figures says so for as long as it is alive.
    property int watchers: 0

    function acquire() {
        const firstWatcher = watchers === 0;
        watchers++;
        if (!firstWatcher)
            return;

        // Utilization needs two counter snapshots. Discard a stale baseline
        // when the first visible consumer arrives, prime it immediately, and
        // let the two-second poll produce the first live delta. Everything
        // else can return a reading from this first refresh.
        cpuPrev = null;
        cpuUsageKnown = false;
        statView.reload();
        cpuPrimeTimer.restart();
        memView.reload();
        uptimeView.reload();
        if (tempPath !== "")
            tempView.reload();
        refreshRootFs();
        refreshBrightness();
    }

    function release() {
        watchers = Math.max(0, watchers - 1);
        if (watchers === 0)
            cpuPrimeTimer.stop();
    }

    // The aggregate percentage needs a second snapshot. Take it promptly on
    // open so the hero does not wait for the first regular two-second tick.
    Timer {
        id: cpuPrimeTimer
        interval: 250
        onTriggered: {
            if (root.watchers > 0)
                statView.reload();
        }
    }

    // CPU and memory move quickly enough to be useful at a two-second cadence
    // while the Overview is visible. acquire() performs the initial refresh.
    Timer {
        interval: 2000
        running: root.watchers > 0
        repeat: true
        onTriggered: {
            statView.reload();
            memView.reload();
        }
    }

    // Temperature changes more slowly and its sensor is optional.
    Timer {
        interval: 10000
        running: root.watchers > 0
        repeat: true
        onTriggered: {
            if (root.tempPath !== "")
                tempView.reload();
        }
    }

    // Uptime and filesystem capacity are slow-moving. One minute avoids
    // process churn while still keeping a long-open Overview honest.
    Timer {
        interval: 60000
        running: root.watchers > 0
        repeat: true
        onTriggered: {
            uptimeView.reload();
            root.refreshRootFs();
        }
    }

    // Brightness is read by the control centre; the OSD asks for a fresh
    // read itself after every key press. The slow poll is only here to catch
    // a change this machine made no request for — a docked display swapped
    // under it, say. Tailscale moved to its own singleton, which polls on the
    // same watcher basis.
    Timer {
        interval: 30000
        running: root.watchers > 0
        repeat: true
        onTriggered: root.refreshBrightness()
    }

}
