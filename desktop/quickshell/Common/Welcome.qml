pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "WelcomeHelpers.js" as Helpers

Singleton {
    id: root
    readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/cybexos"
    readonly property string filePath: stateDir + "/welcome.json"
    readonly property string version: {
        if (Quickshell.env("CYBEXOS_VERSION")) return Quickshell.env("CYBEXOS_VERSION");
        try { return JSON.parse(releaseVersion.text()).version || sourceVersion.text().trim(); }
        catch (_) { return sourceVersion.text().trim(); }
    }
    property var document: Helpers.initial(version)
    property bool loaded: false
    property bool protectedFile: false
    property string error: ""
    property bool open: false
    property string screenName: ""
    property bool wallpaperDrawn: false
    property bool autoAttempted: false
    property bool writeInFlight: false
    property string writeSnapshot: ""
    property string storeText: ""
    property string persistedText: ""
    property bool directoryReady: false
    property bool resetPending: false
    readonly property string step: document.step
    readonly property bool hasHyprland: Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") !== ""
    property string firstName: Quickshell.env("USER") || ""
    readonly property var checklist: Helpers.checklist({
        assistantAvailable: Assistant.available, assistant: Assistant.agentReady,
        reader: (SystemSettings.security.snapshot.reader || {}).state === "ready",
        fingerprint: (SystemSettings.security.snapshot.fingers || []).length > 0,
        backupKnown: Backup.statusError === "" && backupRead,
        backup: Backup.configured, accountsKnown: SystemSettings.accounts.loaded && SystemSettings.accounts.error === "",
        accounts: (SystemSettings.accounts.snapshot.accounts || []).length > 0
    }, document.checklist)
    property bool backupRead: false
    property var webapps: []
    property string webappsError: ""
    readonly property bool webappsBusy: webappList.running || webappRemove.running
    signal present()

    function changed(value) {
        document = value;
        saveTimer.restart();
    }
    function maybeOpen() {
        if (autoAttempted || !loaded || !Settings.loaded || !wallpaperDrawn) return;
        autoAttempted = true;
        if (!protectedFile && Quickshell.env("CYBEXOS_WELCOME") !== "0"
                && ["new", "open"].includes(document.status)) show("");
    }
    function wallpaperReady() { wallpaperDrawn = true; maybeOpen(); }
    function show(requested) {
        const next = Helpers.resume(document, requested);
        if (!next) return "unknown";
        next.version = version;
        const wasOpen = open;
        screenName = Screens.focused ? Screens.focused.name : "";
        changed(next);
        open = true;
        if (wasOpen) present();
        return "ok";
    }
    function go(id) {
        if (!Helpers.STEPS.includes(id)) return;
        changed(Helpers.visit(document, id));
    }
    function move(delta) {
        go(Helpers.STEPS[Math.max(0, Math.min(Helpers.STEPS.length - 1, Helpers.STEPS.indexOf(step) + delta))]);
    }
    function dismiss() {
        if (!open) return;
        open = false;
        const notify = !document.notified;
        changed(Object.assign({}, document, {status: "dismissed", notified: true}));
        saveNow();
        if (notify) Notifs.send({appName: "Cybex OS", summary: I18n.tr("Welcome guide"),
            body: I18n.tr("You can finish setting up any time: open the launcher and search for Welcome.")});
    }
    function finish() {
        changed(Object.assign({}, document, {status: "completed"}));
        open = false;
        saveNow();
    }
    function later(id, value) {
        const items = Object.assign({}, document.checklist);
        if (value) items[id] = "later"; else delete items[id];
        changed(Object.assign({}, document, {checklist: items}));
    }
    function status() {
        return JSON.stringify({open: open, status: document.status, step: step, checklist: checklist});
    }
    function reset() {
        open = false;
        autoAttempted = true;
        saveTimer.stop();
        resetPending = true;
        if (!writeInFlight) resetRequest.running = true;
    }
    function refreshWebapps() { if (!webappList.running) webappList.running = true; }
    function removeWebapp(id) {
        if (webappsBusy || !webapps.some(app => app.id === id)) return;
        webappRemove.command = ["cybexos-webapp", "remove", "--notify", id];
        webappRemove.running = true;
    }
    function applyLoaded(text) {
        const result = Helpers.parse(text);
        loaded = true;
        if (result.error) {
            protectedFile = true;
            error = I18n.tr("Your welcome progress could not be read. The file has been kept unchanged.");
            console.warn("welcome: invalid state at", filePath);
        } else {
            document = result.value;
            persistedText = storeText = text;
        }
        maybeOpen();
    }
    function loadFailed(code) {
        loaded = true;
        if (code !== FileViewError.FileNotFound) {
            protectedFile = true;
            error = I18n.tr("Your welcome progress could not be read. The file has been kept unchanged.");
            console.warn("welcome: load failed", FileViewError.toString(code));
        }
        maybeOpen();
    }
    function saveNow() {
        if (!loaded || protectedFile || writeInFlight || resetPending) return;
        if (!directoryReady) { if (!makeDirectory.running) makeDirectory.running = true; return; }
        const next = Helpers.serialize(document);
        if (next === persistedText || next + "\n" === persistedText) return;
        // FileView remembers failed attempted bytes too. A newline makes an
        // identical retry emit saved/saveFailed instead of silently skipping.
        writeSnapshot = next === storeText ? next + "\n" : next;
        writeInFlight = true;
        store.setText(writeSnapshot);
    }
    function settled(success) {
        storeText = writeSnapshot;
        if (success) { persistedText = writeSnapshot; if (!protectedFile) error = ""; }
        writeInFlight = false;
        writeSnapshot = "";
        if (!success) error = I18n.tr("Your progress could not be saved. Try again.");
        if (resetPending) resetRequest.running = true;
        else if (success) saveTimer.restart();
    }
    Connections { target: Backup; function onStatusChanged() { root.backupRead = true; } }
    Connections { target: Settings; function onLoadedChanged() { root.maybeOpen(); } }
    Timer { id: saveTimer; interval: 120; onTriggered: root.saveNow() }
    Timer {
        interval: 10000; repeat: true; running: root.open && root.step === "finish"
        onTriggered: { root.refreshWebapps(); Backup.refresh(); }
    }
    CommandRequest {
        id: makeDirectory
        command: ["mkdir", "-p", "--", root.stateDir]
        onCompleted: (code, body, detail) => {
            root.directoryReady = code === 0;
            if (code === 0) root.saveNow();
            else root.error = I18n.tr("Your progress could not be saved. Try again.");
        }
    }
    CommandRequest {
        id: resetRequest
        command: ["rm", "-f", "--", root.filePath]
        onCompleted: (code, body, detail) => {
            root.resetPending = false;
            if (code !== 0) { root.error = I18n.tr("Your progress could not be saved. Try again."); return; }
            root.document = Helpers.initial(root.version);
            root.protectedFile = false;
            root.error = root.persistedText = "";
            store.reload();
        }
    }
    CommandRequest {
        id: userRequest; command: ["getent", "passwd", Quickshell.env("USER") || ""]
        running: true
        onCompleted: (code, body, detail) => root.firstName = Helpers.firstName(code === 0 ? body : "", Quickshell.env("USER"))
    }
    CommandRequest {
        id: webappList; command: ["cybexos-webapp", "list", "--json"]
        onCompleted: (code, body, detail) => {
            try {
                const rows = JSON.parse(body);
                if (code !== 0 || !Array.isArray(rows)) throw new Error("list");
                root.webapps = rows.filter(row => row && typeof row.id === "string" && typeof row.name === "string");
                root.webappsError = "";
            } catch (_) { root.webappsError = I18n.tr("Web apps could not be read. Open Software to manage your apps."); }
        }
    }
    CommandRequest {
        id: webappRemove
        onCompleted: (code, body, detail) => {
            if (code !== 0) root.webappsError = I18n.tr("The web app could not be removed. Try again.");
            root.refreshWebapps();
        }
    }
    FileView { id: releaseVersion; path: "/etc/cybexos/release.json"; printErrors: false; blockLoading: true }
    FileView { id: sourceVersion; path: Quickshell.shellDir + "/../../VERSION"; printErrors: false; blockLoading: true }
    FileView {
        id: store; path: root.filePath; printErrors: false
        atomicWrites: true; blockWrites: false; blockLoading: true
        onLoaded: root.applyLoaded(text())
        onLoadFailed: code => root.loadFailed(code)
        onSaved: root.settled(true)
        onSaveFailed: code => root.settled(false)
    }
    Component.onCompleted: {
        const text = store.text();
        if (!loaded && store.loaded) applyLoaded(text);
    }
}
