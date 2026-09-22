pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Notifications
import "SettingsHelpers.js" as SettingsHelpers
import "ProcHelpers.js" as ProcHelpers

// Shell settings store (design v2, "Shell settings"). Single source of truth
// for user-tunable shell configuration: merged over defaults on load,
// debounce-saved, and watched so external edits of the JSON apply live.
//
// The path is a fixed user-owned config file rather than
// Quickshell.statePath(): statePath resolves under by-shell/<config-hash>/, so
// a dev run from a different vendor directory would silently fork settings.
//
// Dependency rule: Theme binds to Settings, never the reverse. Keeping the
// direction one-way is what makes the live-apply bindings loop-free.
Singleton {
    id: root

    readonly property string filePath:
        Quickshell.env("HOME") + "/.config/fedora-config/shell.json"

    readonly property bool connectedWidgetsConfigured:
        Quickshell.env("FEDORA_CONFIG_CONNECTED_WIDGETS") === "1"
    readonly property var defaults: {
        const value = SettingsHelpers.defaults();
        if (connectedWidgetsConfigured) {
            for (const column of ["left", "center", "right"])
                value.mods[column] = value.mods[column].map(entry => ({
                    id: entry.id,
                    on: ["gh", "t3", "hermes", "usage"].indexOf(entry.id) !== -1
                        ? true : entry.on,
                    detail: entry.detail
                }));
        }
        return value;
    }
    readonly property var fontChoices: SettingsHelpers.FONT_CHOICES
    readonly property var barColorChoices: SettingsHelpers.BAR_COLOR_CHOICES

    // ---- Persisted settings ----------------------------------------------
    property string wall: defaults.wall
    property string wallDir: defaults.wallDir
    property string shuffle: defaults.shuffle
    property string themeMode: defaults.themeMode
    property bool glassEnabled: defaults.glassEnabled
    property bool highContrast: defaults.highContrast
    property bool reducedMotion: defaults.reducedMotion
    property int shellFontSize: defaults.shellFontSize
    property int shellScale: defaults.shellScale
    property string surfaceBorderMode: defaults.surfaceBorderMode
    property string surfaceBorderColor: defaults.surfaceBorderColor
    property int surfaceBorderWidth: defaults.surfaceBorderWidth
    property int surfaceBorderOpacity: defaults.surfaceBorderOpacity
    property int surfaceCornerRadius: defaults.surfaceCornerRadius
    property int pluginScale: defaults.pluginScale
    property string pluginBorderMode: defaults.pluginBorderMode
    property string pluginBorderColor: defaults.pluginBorderColor
    property int pluginBorderWidth: defaults.pluginBorderWidth
    property int pluginBorderOpacity: defaults.pluginBorderOpacity
    property int pluginRadius: defaults.pluginRadius
    property var pluginThemeOverrides: defaults.pluginThemeOverrides
    property string textScale: defaults.textScale
    property string interfaceDensity: defaults.interfaceDensity
    property string barColorMode: defaults.barColorMode
    property int barCustomHue: defaults.barCustomHue
    property int barCustomSaturation: defaults.barCustomSaturation
    property int barCustomLightness: defaults.barCustomLightness
    property int barHeight: defaults.barHeight
    property int barRadius: defaults.barRadius
    property string font: defaults.font
    property string accent: defaults.accent
    property string paletteMode: defaults.paletteMode
    property string position: defaults.position
    property string barStyle: defaults.barStyle
    property int gap: defaults.gap
    property bool autoHide: defaults.autoHide
    property bool exclusive: defaults.exclusive
    property bool clock24: defaults.clock24
    property string unit: defaults.unit
    property int warmth: defaults.warmth
    property string osd: defaults.osd
    property int pollMax: defaults.pollMax
    property real scrollFactor: defaults.scrollFactor
    property bool nightLight: defaults.nightLight
    property string idleInhibitMode: defaults.idleInhibitMode
    property double idleInhibitUntilMs: defaults.idleInhibitUntilMs
    property bool notifDnd: defaults.notifDnd
    property double notifDndUntilMs: defaults.notifDndUntilMs
    property string notifQuiet: defaults.notifQuiet
    property int notifQuietStart: defaults.notifQuietStart
    property int notifQuietEnd: defaults.notifQuietEnd
    property int notifDuration: defaults.notifDuration
    property string notifPosition: defaults.notifPosition
    property string notifDensity: defaults.notifDensity
    property bool notifIcons: defaults.notifIcons
    property bool notifProgress: defaults.notifProgress
    property int notifBodyLines: defaults.notifBodyLines
    property var drawerTabs: defaults.drawerTabs
    property var drawerOverview: defaults.drawerOverview
    property string drawerHover: defaults.drawerHover
    property int drawerWidth: defaults.drawerWidth
    property var mods: defaults.mods
    property var modOpts: defaults.modOpts

    // ---- Runtime state (not persisted) -----------------------------------
    property bool panelOpen: false
    property string page: "appearance"
    property bool loaded: false
    property bool firstRun: false
    property bool savePending: false
    property bool saveError: false
    property bool loadError: false
    property string loadErrorText: ""
    readonly property bool persistenceError: loadError || saveError
    property double lastSavedAt: 0
    property var resetSnapshot: null
    property string resetLabel: ""
    property string announcement: ""
    // The settings row the nav search jumped to. Rows watch it, flash, and
    // the view clears it after the highlight has had its moment.
    property string highlightKey: ""
    // Change counter for dirty-state bindings; see scheduleSave().
    property int revision: 0
    property bool migrationPending: false
    property bool writeInFlight: false
    property string writeSnapshot: ""
    property bool initialLoadHandled: false
    // Blocks every save while an unreadable settings file is being moved
    // aside, and stays set if that move fails — overwriting it then would
    // destroy the only copy of the user's settings.
    property bool corruptBackupPending: false
    readonly property bool undoAvailable: resetSnapshot !== null

    // Guards saves while loaded values are being applied.
    property bool ready: false

    // Fixed choices stay available while wallpaper mode is active. Theme
    // selects Palette's roles when they are ready and falls back to these
    // values without changing paletteMode when Matugen is unavailable.
    readonly property string effectiveAccent: accent
    readonly property string effectiveBarColor: SettingsHelpers.resolveBarColor(
        barColorMode, themeMode, barCustomHue, barCustomSaturation, barCustomLightness)
    readonly property bool modsModified:
        JSON.stringify(mods) !== JSON.stringify(defaults.mods)

    readonly property var validPages: ["appearance", "wallpaper", "bar", "modules", "plugins", "drawer", "notifications", "system"]

    // One dirty/reset key list per settings page (grouped-rail design 1c).
    readonly property var sectionKeys: ({
        wallpaper: ["wall", "wallDir", "shuffle"],
        appearance: ["themeMode", "glassEnabled", "highContrast", "reducedMotion",
            "textScale", "interfaceDensity", "shellFontSize", "shellScale", "surfaceBorderMode", "surfaceBorderColor", "surfaceBorderWidth", "surfaceBorderOpacity", "surfaceCornerRadius",
            "barColorMode", "barCustomHue",
            "barCustomSaturation", "barCustomLightness", "font", "accent", "paletteMode"],
        bar: ["position", "barStyle", "gap", "barHeight", "barRadius", "autoHide",
            "exclusive"],
        modules: ["mods", "modOpts"],
        plugins: ["pluginScale", "pluginBorderMode", "pluginBorderColor", "pluginBorderWidth", "pluginBorderOpacity", "pluginRadius", "pluginThemeOverrides"],
        drawer: ["drawerTabs", "drawerOverview", "drawerHover", "drawerWidth"],
        notifications: ["notifDnd", "notifDndUntilMs", "notifQuiet", "notifQuietStart", "notifQuietEnd",
            "notifDuration", "notifPosition", "notifDensity", "notifIcons",
            "notifProgress", "notifBodyLines"],
        system: ["clock24", "unit", "warmth", "osd", "pollMax", "scrollFactor",
            "nightLight", "idleInhibitMode", "idleInhibitUntilMs"]
    })

    // ---- Independent settings window -----------------------------------
    property string panelScreenName: ""
    signal presentPanel()

    function showPanel(targetPage, targetScreenName) {
        if (targetPage && validPages.indexOf(targetPage) !== -1)
            page = targetPage;
        Popouts.close();
        if (!panelOpen)
            panelScreenName = targetScreenName || (Screens.focused ? Screens.focused.name : "");
        panelOpen = true;
        presentPanel();
    }

    function togglePanel(targetPage, targetScreenName) {
        if (panelOpen)
            closePanel();
        else
            showPanel(targetPage, targetScreenName);
    }

    function closePanel() {
        panelOpen = false;
    }

    function sectionDirty(section) {
        return (sectionKeys[section] || []).some(key =>
            JSON.stringify(root[key]) !== JSON.stringify(defaults[key]));
    }

    // ---- Writers ---------------------------------------------------------
    function clearUndo() {
        resetTimer.stop();
        resetSnapshot = null;
        resetLabel = "";
    }

    function set(key, value) {
        clearUndo();
        migrationPending = false;
        root[key] = value;
    }

    function previewBarColor(mode) {
        return SettingsHelpers.resolveBarColor(mode, themeMode, barCustomHue,
            barCustomSaturation, barCustomLightness);
    }

    function setModuleEnabled(id, on) {
        clearUndo();
        migrationPending = false;
        const next = { left: [], center: [], right: [] };
        for (const col of ["left", "center", "right"])
            next[col] = mods[col].map(m => m.id === id
                ? ({ id: m.id, on: on, detail: m.detail }) : m);
        mods = next;
    }

    function setModuleDetail(id, detail) {
        clearUndo();
        migrationPending = false;
        const next = { left: [], center: [], right: [] };
        for (const col of ["left", "center", "right"])
            next[col] = mods[col].map(m => m.id === id
                ? ({ id: m.id, on: m.on, detail: SettingsHelpers.detailIn(detail) }) : m);
        mods = next;
    }

    function setModuleOption(id, key, value) {
        const changes = {};
        changes[key] = value;
        setModuleOptions(id, changes);
    }

    function setModuleOptions(id, changes) {
        clearUndo();
        migrationPending = false;
        const next = SettingsHelpers.clone(modOpts);
        for (const key of Object.keys(changes || ({})))
            next[id][key] = changes[key];
        modOpts = SettingsHelpers.normalizeModOpts(next);
    }

    function setModuleOrder(left, center, right) {
        clearUndo();
        migrationPending = false;
        mods = SettingsHelpers.normalizeMods({ left: left, center: center, right: right });
    }

    function setDrawerTabEnabled(id, on) {
        clearUndo();
        migrationPending = false;
        drawerTabs = SettingsHelpers.normalizeDrawerTabs(drawerTabs.map(tab =>
            tab.id === id ? ({ id: tab.id, on: on }) : tab));
    }

    function setDrawerTabOrder(ids) {
        clearUndo();
        migrationPending = false;
        const held = {};
        for (const tab of drawerTabs)
            held[tab.id] = tab.on;
        drawerTabs = SettingsHelpers.normalizeDrawerTabs(ids.map(id =>
            ({ id: id, on: held[id] !== false })));
    }

    function setDrawerOverviewKey(key, on) {
        clearUndo();
        migrationPending = false;
        const next = SettingsHelpers.clone(drawerOverview);
        next[key] = on;
        drawerOverview = SettingsHelpers.normalizeDrawerOverview(next);
    }

    function applyModulePreset(name) {
        const enabled = name === "everything"
            ? SettingsHelpers.MODULE_IDS
            : name === "connected"
            ? ["ws", "media", "indicators", "clock", "weather", "notes", "updates", "gh",
                "t3", "hermes", "usage", "tray", "notifications", "vol", "wifi", "bt", "batt"]
            : ["ws", "media", "indicators", "clock", "weather", "notes", "updates", "tray",
                "notifications", "vol", "wifi", "batt"];
        clearUndo();
        migrationPending = false;
        resetSnapshot = { mods: SettingsHelpers.clone(mods) };
        resetLabel = "Widget profile";
        const next = { left: [], center: [], right: [] };
        for (const col of ["left", "center", "right"])
            next[col] = mods[col].map(entry => ({
                id: entry.id,
                on: enabled.indexOf(entry.id) !== -1,
                detail: entry.detail
            }));
        mods = next;
        announcement = "Applied " + name
            + " widget profile. Undo available for eight seconds.";
        resetTimer.restart();
    }

    function resetKeys(keys, label) {
        migrationPending = false;
        const previous = {};
        for (const key of keys)
            previous[key] = SettingsHelpers.clone(root[key]);
        resetSnapshot = previous;
        resetLabel = label || (keys.length === 1 ? "Setting" : "Settings");
        for (const key of keys)
            root[key] = key === "mods" ? SettingsHelpers.clone(defaults.mods)
                : key === "modOpts" ? SettingsHelpers.defaultModOpts()
                : defaults[key];
        announcement = resetLabel + " reset. Undo available for eight seconds.";
        resetTimer.restart();
    }

    function resetSection(section) {
        const labels = {
            wallpaper: "Wallpaper", appearance: "Appearance", bar: "Bar",
            modules: "Widgets", drawer: "Drawer",
            notifications: "Notifications", system: "System"
        };
        resetKeys(sectionKeys[section] || [], labels[section] || "Settings");
    }

    function resetAll() {
        resetKeys(Object.keys(defaults), "All settings");
    }

    function undoReset() {
        if (!resetSnapshot)
            return;
        const previous = resetSnapshot;
        resetTimer.stop();
        for (const key of Object.keys(previous))
            root[key] = SettingsHelpers.clone(previous[key]);
        resetSnapshot = null;
        const label = resetLabel;
        resetLabel = "";
        announcement = label + " restored.";
    }

    function retrySave() {
        if (loadError) {
            announcement = "Retrying the settings file…";
            store.reload();
            return;
        }
        savePending = true;
        saveNow();
    }

    // ---- Persistence -----------------------------------------------------
    // The persisted set is exactly the schema's keys, read off this object by
    // name. Enumerating them here as well is how a new setting gets added and
    // then silently never saved; settings.test.cjs holds the schema and the
    // property declarations together instead.
    function snapshot() {
        const out = {};
        for (const key of Object.keys(root.defaults))
            out[key] = root[key];
        return out;
    }

    // One-time migration of the old QS_WEATHER_* env configuration: only a
    // file that predates modOpts (or no file at all) takes the env values;
    // after the first save modOpts exists on disk and the seed never re-fires.
    function seedWeatherFromEnv(parsed, modOptions) {
        if (parsed !== null && parsed.modOpts !== undefined)
            return modOptions;
        const lat = Quickshell.env("QS_WEATHER_LAT");
        const lon = Quickshell.env("QS_WEATHER_LON");
        const place = Quickshell.env("QS_WEATHER_PLACE");
        if (!lat && !lon && !place)
            return modOptions;
        const next = SettingsHelpers.clone(modOptions);
        if (lat)
            next.weather.lat = Number(lat);
        if (lon)
            next.weather.lon = Number(lon);
        if (place)
            next.weather.place = place;
        return SettingsHelpers.normalizeModOpts(next);
    }

    // A file we cannot read is not a first run — those bytes are the user's
    // only copy. Move them aside before anything is allowed to save over them.
    function backUpCorruptFile() {
        if (corruptBackupPending)
            return;
        corruptBackupPending = true;
        console.warn("settings: unreadable file at", filePath, "— backing it up");
        corruptBackupProc.backupPath = filePath + ".corrupt-" + Math.floor(Date.now() / 1000);
        corruptBackupProc.command = ["mv", filePath, corruptBackupProc.backupPath];
        corruptBackupProc.running = true;
    }

    // `announcement` only ever reaches an Accessible.AlertMessage inside the
    // settings window, so a user who never opens it would never learn their
    // settings file was unreadable. Corruption — and only corruption — also
    // raises a critical notification, which persists until dismissed.
    //
    // This is the one place Settings reaches for Notifs, which binds back to
    // Settings.notifDnd. It is a one-shot call from a Process exit handler,
    // never a binding, and it cannot run before both singletons exist: the
    // `mv` has to start and finish first. The dependency rule above stands.
    function notifyCorruption(message) {
        Notifs.send({
            appName: "Shell settings",
            appIcon: "preferences-system",
            urgency: NotificationUrgency.Critical,
            summary: "Settings file problem",
            body: message
        });
    }

    function applyLoaded(rawText) {
        initialLoadHandled = true;
        loadError = false;
        loadErrorText = "";
        const result = SettingsHelpers.parse(rawText);
        // Before the no-op check below: a corrupt file whose defaults happen to
        // match the running state would otherwise slip through unprotected.
        if (result.status === "corrupt")
            backUpCorruptFile();
        const parsed = result.value;
        const merged = SettingsHelpers.merge(parsed);
        // Skip echoes of our own atomic writes (watchChanges reports them)
        // and external edits that merge back to the current state.
        if (loaded && SettingsHelpers.serialize(merged) === SettingsHelpers.serialize(snapshot())) {
            ready = true;
            return;
        }
        ready = false;
        saveTimer.stop();
        savePending = false;
        clearUndo();
        for (const key of Object.keys(root.defaults))
            root[key] = merged[key];
        // The one key that is not a straight copy: a file predating modOpts
        // (or no file at all) still takes the retired QS_WEATHER_* env
        // configuration on its way in.
        modOpts = seedWeatherFromEnv(parsed, merged.modOpts);
        ready = true;
        migrationPending = parsed !== null && parsed.v !== SettingsHelpers.VERSION;
        firstRun = result.status === "empty";
        loaded = true;
        applyScrollFactor();
        applyGlassEffect();
    }

    function handleLoadFailure(error) {
        initialLoadHandled = true;
        if (error === FileViewError.FileNotFound) {
            loadError = false;
            loadErrorText = "";
            applyLoaded("");
            return;
        }

        // Keep the last known-good in-memory values, and close every write
        // path. Treating permission/IO failures as an empty first run would
        // make the next setting change replace a file we never read.
        ready = false;
        loadError = true;
        loadErrorText = "Could not read " + filePath + " ("
            + FileViewError.toString(error) + ").";
        saveTimer.stop();
        savePending = false;
        announcement = loadErrorText + " Settings will not be saved until it can be read.";
        console.warn("settings load failed:", FileViewError.toString(error));
    }

    function handleSaveSucceeded() {
        const completedSnapshot = writeSnapshot;
        const wasRetry = saveError;
        writeInFlight = false;
        writeSnapshot = "";
        saveError = false;
        lastSavedAt = Date.now();
        const changedWhileSaving = SettingsHelpers.serialize(snapshot())
            !== completedSnapshot;
        savePending = changedWhileSaving;
        if (wasRetry)
            announcement = "Settings saved.";
        if (changedWhileSaving)
            saveTimer.restart();
    }

    function handleSaveFailure(error) {
        writeInFlight = false;
        writeSnapshot = "";
        savePending = false;
        saveError = true;
        announcement = "Could not save settings. Retry is available.";
        console.warn("settings save failed:", FileViewError.toString(error));
    }

    function saveNow() {
        if (!ready || migrationPending || corruptBackupPending || loadError
                || writeInFlight)
            return;
        writeSnapshot = SettingsHelpers.serialize(snapshot());
        writeInFlight = true;
        try {
            // FileView reports completion through saved/saveFailed even when
            // blockWrites is enabled. Do not advertise success before that
            // signal; a failed atomic rename is still a failed save.
            store.setText(writeSnapshot);
        } catch (error) {
            handleSaveFailure(FileViewError.Unknown);
            console.warn("settings save threw:", error);
        }
    }

    function scheduleSave() {
        // Bumped on every value change, saved or not: bindings that call the
        // sectionDirty() *function* re-evaluate by referencing this counter.
        revision++;
        if (!ready || migrationPending || corruptBackupPending || loadError)
            return;
        savePending = true;
        saveTimer.restart();
    }

    onWallChanged: scheduleSave()
    onWallDirChanged: scheduleSave()
    onShuffleChanged: scheduleSave()
    onThemeModeChanged: scheduleSave()
    onGlassEnabledChanged: {
        scheduleSave();
        applyGlassEffect();
    }
    onHighContrastChanged: {
        scheduleSave();
        applyGlassEffect();
    }
    onReducedMotionChanged: scheduleSave()
    onShellFontSizeChanged: scheduleSave()
    onShellScaleChanged: scheduleSave()
    onSurfaceBorderModeChanged: scheduleSave()
    onSurfaceBorderColorChanged: scheduleSave()
    onSurfaceBorderWidthChanged: scheduleSave()
    onSurfaceBorderOpacityChanged: scheduleSave()
    onSurfaceCornerRadiusChanged: scheduleSave()
    onPluginScaleChanged: scheduleSave()
    onPluginBorderModeChanged: scheduleSave()
    onPluginBorderColorChanged: scheduleSave()
    onPluginBorderWidthChanged: scheduleSave()
    onPluginBorderOpacityChanged: scheduleSave()
    onPluginRadiusChanged: scheduleSave()
    onPluginThemeOverridesChanged: scheduleSave()
    onTextScaleChanged: scheduleSave()
    onInterfaceDensityChanged: scheduleSave()
    onBarColorModeChanged: scheduleSave()
    onBarCustomHueChanged: scheduleSave()
    onBarCustomSaturationChanged: scheduleSave()
    onBarCustomLightnessChanged: scheduleSave()
    onBarHeightChanged: scheduleSave()
    onBarRadiusChanged: scheduleSave()
    onFontChanged: scheduleSave()
    onAccentChanged: scheduleSave()
    onPaletteModeChanged: scheduleSave()
    onPositionChanged: scheduleSave()
    onBarStyleChanged: scheduleSave()
    onGapChanged: scheduleSave()
    onAutoHideChanged: scheduleSave()
    onExclusiveChanged: scheduleSave()
    onClock24Changed: scheduleSave()
    onUnitChanged: scheduleSave()
    onWarmthChanged: scheduleSave()
    onOsdChanged: scheduleSave()
    onPollMaxChanged: scheduleSave()
    onNightLightChanged: scheduleSave()
    onIdleInhibitModeChanged: scheduleSave()
    onIdleInhibitUntilMsChanged: scheduleSave()
    onScrollFactorChanged: {
        scheduleSave();
        applyScrollFactor();
    }
    onNotifDndChanged: scheduleSave()
    onNotifDndUntilMsChanged: scheduleSave()
    onNotifQuietChanged: scheduleSave()
    onNotifQuietStartChanged: scheduleSave()
    onNotifQuietEndChanged: scheduleSave()
    onNotifDurationChanged: scheduleSave()
    onNotifPositionChanged: scheduleSave()
    onNotifDensityChanged: scheduleSave()
    onNotifIconsChanged: scheduleSave()
    onNotifProgressChanged: scheduleSave()
    onNotifBodyLinesChanged: scheduleSave()
    onDrawerTabsChanged: scheduleSave()
    onDrawerOverviewChanged: scheduleSave()
    onDrawerHoverChanged: scheduleSave()
    onDrawerWidthChanged: scheduleSave()
    onModsChanged: scheduleSave()
    onModOptsChanged: scheduleSave()

    Timer {
        id: saveTimer
        interval: 400
        onTriggered: root.saveNow()
    }

    Timer {
        id: resetTimer
        interval: 8000
        onTriggered: root.clearUndo()
    }

    // Debounce pointer motion from the slider, then apply the final value to
    // Hyprland immediately. input.lua reads the same persisted setting so a
    // compositor reload or reboot retains it.
    property real dispatchedScrollFactor: -1

    function applyScrollFactor() {
        if (loaded)
            scrollApplyTimer.restart();
    }

    Timer {
        id: scrollApplyTimer
        interval: 75
        onTriggered: {
            if (scrollFactorProc.running)
                return;
            root.dispatchedScrollFactor = root.scrollFactor;
            scrollFactorProc.command = ["hyprctl", "keyword",
                "input:touchpad:scroll_factor", root.scrollFactor.toFixed(1)];
            scrollFactorProc.running = true;
        }
    }

    Process {
        id: scrollFactorProc

        onExited: exitCode => {
            if (exitCode !== 0)
                console.warn("could not apply touchpad scroll speed:", exitCode);
            if (Math.abs(root.dispatchedScrollFactor - root.scrollFactor) > 0.001)
                scrollApplyTimer.restart();
        }
    }

    // The layer namespace is fixed once Quickshell connects the Wayland
    // surface, so glass is toggled through the named rule handle exported by
    // looknfeel.lua. Surface fills still change synchronously through Theme;
    // this call removes the compositor pass as well.
    property bool dispatchedGlassEnabled: true
    property bool glassApplyError: false

    function applyGlassEffect() {
        if (!loaded || glassApplyProc.running)
            return;
        dispatchedGlassEnabled = glassEnabled && !highContrast;
        glassApplyProc.command = ["hyprctl", "eval",
            "quickshell_blur_rule:set_enabled("
                + (dispatchedGlassEnabled ? "true" : "false") + ")"];
        glassApplyProc.running = true;
    }

    Timer {
        id: glassReplayTimer
        interval: 0
        onTriggered: root.applyGlassEffect()
    }

    Process {
        id: glassApplyProc
        property bool exitSeen: false
        property int lastExit: 0

        onExited: exitCode => {
            exitSeen = true;
            lastExit = exitCode;
        }
        onRunningChanged: {
            if (running) {
                exitSeen = false;
                lastExit = 0;
                return;
            }
            const code = exitSeen ? lastExit : ProcHelpers.NOT_STARTED;
            root.glassApplyError = code !== 0;
            if (code !== 0)
                console.warn("could not apply compositor glass effect:", code);
            if (root.dispatchedGlassEnabled !== (root.glassEnabled && !root.highContrast))
                glassReplayTimer.restart();
        }
    }

    Process {
        id: corruptBackupProc

        property string backupPath: ""

        onExited: exitCode => {
            if (exitCode === 0) {
                root.corruptBackupPending = false;
                root.announcement = "The settings file could not be read. It was kept as "
                    + corruptBackupProc.backupPath + " and the defaults were restored.";
                root.notifyCorruption(root.announcement);
                return;
            }
            // Deliberately leaves corruptBackupPending set: saving now would
            // overwrite the file we just failed to copy.
            root.announcement = "The settings file could not be read or backed up. "
                + "Settings will not be saved until " + root.filePath + " is moved aside.";
            root.notifyCorruption(root.announcement);
            console.warn("settings: backing up", root.filePath, "failed with exit", exitCode);
        }
    }

    FileView {
        id: store
        path: root.filePath
        printErrors: false
        atomicWrites: true
        blockWrites: true
        blockLoading: true
        watchChanges: true
        onFileChanged: reload()
        onLoaded: root.applyLoaded(text())
        onLoadFailed: error => root.handleLoadFailure(error)
        onSaved: root.handleSaveSucceeded()
        onSaveFailed: error => root.handleSaveFailure(error)
    }

    // Force the load to complete during singleton construction so the first
    // Theme/Bar bindings never see one frame of defaults.
    Component.onCompleted: {
        if (!loaded && !initialLoadHandled) {
            const initialText = store.text();
            // A blocking read emits loaded/loadFailed before returning. The
            // fallback only covers an already-preloaded FileView that emitted
            // its signal before this singleton's completion handler ran.
            if (!initialLoadHandled && store.loaded)
                applyLoaded(initialText);
        }
    }
}
