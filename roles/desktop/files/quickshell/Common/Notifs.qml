pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Services.Notifications
import Quickshell.Io
import Quickshell.Wayland
import "NotifPolicy.js" as Policy
import "NotifSmart.js" as Smart
import "NotifHelpers.js" as Helpers
import "NotifHolds.js" as Holds
import "SettingsHelpers.js" as SettingsHelpers
import "Format.js" as Format

Singleton {
    id: root

    // Do Not Disturb persists with the shell settings; quiet hours silence
    // toasts on a schedule the same way. Both only gate the popup — every
    // notification still lands in the center.
    readonly property bool dnd: Settings.notifDnd
    property double dndClockMs: Date.now()
    readonly property int dndRemainingSecs: Settings.notifDndUntilMs > 0
        ? Math.max(0, Math.ceil((Settings.notifDndUntilMs - dndClockMs) / 1000)) : 0
    readonly property string dndStatus: {
        if (!dnd)
            return "Off";
        if (Settings.notifDndUntilMs <= 0)
            return "Until turned off";
        const mins = Math.max(1, Math.ceil(dndRemainingSecs / 60));
        if (mins < 60)
            return mins + " min left";
        const remainder = mins % 60;
        return Math.floor(mins / 60) + "h"
            + (remainder === 0 ? "" : " " + remainder + "m") + " left";
    }
    property bool startupApplied: false
    readonly property bool quietActive: SettingsHelpers.quietActive(Settings.notifQuiet,
        Settings.notifQuietStart, Settings.notifQuietEnd,
        quietClock.date.getHours() * 60 + quietClock.date.getMinutes())
    readonly property bool toastsSuppressed: dnd || quietActive
    // Bounded session history, newest first. Fields are copied so history
    // remains readable after the remote notification object expires.
    property var entries: []
    property var toasts: []
    property var snoozes: []
    property var burstEvents: []
    property var heldGroups: ({})
    readonly property var groupHoldQueue: Holds.create(callback => Qt.callLater(callback),
        groups => { root.heldGroups = groups; })
    property bool historyLoaded: false
    property bool historyError: false
    property bool historyPending: false
    property bool historyDirty: false
    property int historyGeneration: 0
    property string clipboardSecret: ""
    property string imageIdentityError: ""
    property bool imageIdentityWarningLogged: false
    readonly property var toastGroups: Policy.groups(toasts)
    readonly property var fullscreenOutputs: {
        const names = [];
        for (const top of ToplevelManager.toplevels.values) {
            if (!top.fullscreen)
                continue;
            for (const screen of top.screens) {
                if (names.indexOf(screen.name) < 0)
                    names.push(screen.name);
            }
        }
        return names;
    }
    readonly property int count: entries.length
    readonly property bool hasUrgent: entries.some(e => e.urgency === NotificationUrgency.Critical)

    function nextQuietBoundaryMs() {
        const range = SettingsHelpers.quietRange(Settings.notifQuiet,
            Settings.notifQuietStart, Settings.notifQuietEnd) || ({
                start: Settings.notifQuietStart,
                end: Settings.notifQuietEnd
            });
        if (range.start === range.end)
            return Date.now() + 60 * 60000;
        const now = new Date();
        function occurrence(minutes) {
            const value = new Date(now.getFullYear(), now.getMonth(), now.getDate(),
                Math.floor(minutes / 60), minutes % 60, 0, 0);
            if (value.getTime() <= now.getTime())
                value.setDate(value.getDate() + 1);
            return value.getTime();
        }
        return Math.min(occurrence(range.start), occurrence(range.end));
    }

    function setDndMode(mode) {
        if (["off", "always", "1h", "quiet-boundary"].indexOf(mode) === -1)
            mode = "off";
        if (mode === "off") {
            Settings.set("notifDnd", false);
            Settings.set("notifDndUntilMs", 0);
        } else {
            const until = mode === "1h" ? Date.now() + 60 * 60000
                : mode === "quiet-boundary" ? nextQuietBoundaryMs() : 0;
            Settings.set("notifDndUntilMs", until);
            Settings.set("notifDnd", true);
            dndClockMs = Date.now();
        }
    }

    function setDnd(value) {
        setDndMode(value ? "always" : "off");
    }

    function toggleDefaultDnd() {
        setDndMode(dnd ? "off" : Settings.modOpts.indicators.dndDefaultMode);
    }

    function applyStartupPolicy() {
        if (startupApplied || !Startup.ready || !Settings.loaded)
            return;
        startupApplied = true;
        if (Startup.firstStart) {
            const policy = Settings.modOpts.indicators.dndStartup;
            if (policy === "off")
                setDnd(false);
            else if (policy === "on")
                setDnd(true);
        }
        scheduleDndTick();
    }

    SystemClock {
        id: quietClock
        precision: SystemClock.Minutes
    }

    // dndStatus only speaks in whole minutes, so wake when that label next
    // changes rather than every second. The last wait lands on the deadline
    // itself, which is what ends a timed DND. Before the startup policy has
    // run, an already-expired deadline is left to applyStartupPolicy so a
    // half-loaded settings file is never written back.
    function scheduleDndTick() {
        dndClockMs = Date.now();
        dndTimer.stop();
        if (!dnd || Settings.notifDndUntilMs <= 0)
            return;
        const wait = Helpers.countdownTickMs(Settings.notifDndUntilMs, dndClockMs);
        if (wait > 0) {
            dndTimer.interval = wait;
            dndTimer.start();
        } else if (startupApplied) {
            setDnd(false);
        }
    }

    Timer {
        id: dndTimer
        repeat: false
        onTriggered: root.scheduleDndTick()
    }

    onDndChanged: {
        if (startupApplied && !dnd && Settings.notifDndUntilMs !== 0)
            Settings.set("notifDndUntilMs", 0);
        scheduleDndTick();
    }

    Connections {
        target: Startup

        function onReadyChanged() {
            root.applyStartupPolicy();
        }
    }

    Connections {
        target: Settings

        function onLoadedChanged() {
            root.applyStartupPolicy();
            root.configureHistory();
        }

        function onNotifDndUntilMsChanged() {
            root.scheduleDndTick();
        }
        function onNotifHistoryPersistChanged() { root.configureHistory(); }
        function onNotifHistoryCountChanged() { root.pruneHistory(); }
        function onNotifHistoryHoursChanged() { root.pruneHistory(); }
        function onNotifHistoryBytesChanged() { root.queueHistory(); }
        function onNotifPopupGroupsChanged() { root.boundPopups(); }
        function onNotifPopupPerGroupChanged() { root.boundPopups(); }
        function onNotifFullscreenChanged() { root.reconcileScreens(); }
    }

    onToastsSuppressedChanged: {
        if (!toastsSuppressed)
            return;
        const visible = toasts.slice();
        toasts = [];
        for (const entry of visible) {
            if (entry.live && entry.notif)
                entry.notif.expire();
        }
    }

    function updateEntry(key, changes) {
        entries = entries.map(entry => entry.key === key ? Object.assign({}, entry, changes) : entry);
        toasts = toasts.map(entry => entry.key === key ? Object.assign({}, entry, changes) : entry);
    }

    function removeEntry(key) {
        entries = entries.filter(entry => entry.key !== key);
        toasts = toasts.filter(entry => entry.key !== key);
    }

    function hideToast(entry, expireRemote) {
        toasts = toasts.filter(item => item.key !== entry.key);
        if (expireRemote && entry.live && entry.notif)
            entry.notif.expire();
    }

    function dismiss(entry) {
        removeEntry(entry.key);
        if (entry.live && entry.notif)
            entry.notif.dismiss();
    }

    function invoke(entry, action) {
        if (!entry || !action)
            return;
        // Resolve against current state; a menu may outlive a replacement.
        const current = entries.find(item => item.key === entry.key);
        if (!current)
            return;
        if (action.kind === "copy-code") {
            if ((current.codes || []).indexOf(action.value) < 0 || current.restored)
                return;
            clipboardSecret = action.value;
            copyCode.command = ["wl-copy", "--sensitive", "--", action.value];
            copyCode.running = true;
            clipboardLife.restart();
            return;
        }
        if (action.kind === "link") {
            const url = Smart.safeHttpUrl(action.value);
            if (!current.restored && url && (current.links || []).indexOf(url) >= 0)
                Qt.openUrlExternally(url);
            return;
        }
        if (action.kind === "snooze") {
            snoozeSource(current.sourceKey, current.webSourceIdentity
                ? current.webSourceIdentity.replace(/^unqualified:/, "") : current.displayAppName, action.minutes);
            return;
        }
        if (action.kind === "unsnooze") {
            unsnooze(current.sourceKey);
            return;
        }
        if (!current.live || !current.notif
                || Helpers.actionList(current.actions).indexOf(action) < 0)
            return;
        action.invoke();
        hideToast(current, false);
    }

    function defaultAction(entry) {
        return entry && entry.live ? Helpers.defaultAction(entry.actions) : null;
    }

    function secondaryActions(entry) {
        if (!entry)
            return [];
        let result = entry.live ? Helpers.secondaryActions(entry.actions) : [];
        if (!entry.restored) {
            for (const code of (entry.codes || []).slice(0, 2))
                result.push({ kind: "copy-code", text: I18n.tr("Copy verification code"), value: code });
            for (const link of (entry.links || []).slice(0, 2))
                result.push({ kind: "link", text: I18n.tr("Open link") + " · " + link.split("/")[2], value: link });
        }
        if (snoozes.some(item => item.key === entry.sourceKey)) {
            result.push({ kind: "unsnooze", text: I18n.tr("Unsnooze") });
        } else {
            result = result.concat([
                { kind: "snooze", text: I18n.tr("Snooze 15 minutes"), minutes: 15 },
                { kind: "snooze", text: I18n.tr("Snooze 1 hour"), minutes: 60 },
                { kind: "snooze", text: I18n.tr("Snooze 8 hours"), minutes: 480 }
            ]);
        }
        return result;
    }

    function canActivate(entry) {
        return defaultAction(entry) !== null;
    }

    function invokeDefault(entry) {
        const action = defaultAction(entry);
        if (action)
            invoke(entry, action);
    }

    // Critical toasts never reach this: they persist until dismissed
    // (design t4), so only normal urgencies deplete.
    function timeoutFor(entry) {
        return Helpers.timeoutMs(Helpers.visibleCharacterCount(entry),
            entry.expireTimeout, Settings.notifDuration * 1000);
    }

    // Serial for keys of shell-originated notifications, which have no
    // D-Bus id to key on.
    property int localSerial: 0

    // The one place an entry is built and bounded, so a shell-originated
    // notification is presented exactly like a D-Bus one. `notif` is null for
    // shell senders: no remote object, no actions, which the rest of this file
    // already treats as an expired entry (see dismiss/hideToast/iconSource).
    function publish(source, notif) {
        const arrived = Date.now();
        const row = Object.assign({
            key: `n-${arrived}-${++localSerial}`,
            notif: notif ?? null, live: !!notif, arrived: arrived,
            lastArrived: arrived, occurrences: 1, revision: 0,
            actions: notif ? notif.actions : []
        }, describe(source));
        const old = Policy.duplicate(entries, row, arrived, Settings.notifDedupeSeconds);
        let entry = row;
        if (old) {
            entry = Object.assign({}, row, { key: old.key, arrived: old.arrived,
                occurrences: Math.min(9999, (old.occurrences || 1) + 1),
                revision: (old.revision || 0) + 1, screenName: old.screenName || "" });
            // Transfer the slot before expiring its previous object: a close
            // from the superseded sender must not close the new notification.
            updateEntry(old.key, entry);
            if (old.notif && old.notif !== notif)
                old.notif.expire();
        } else {
            const evicted = entries.slice(Settings.notifHistoryCount - 1);
            entries = [entry].concat(entries.slice(0, Settings.notifHistoryCount - 1));
            for (const item of evicted) {
                hideToast(item, true);
            }
        }
        const muted = Policy.quietReason(dnd, quietActive, snoozes, entry.sourceKey, arrived);
        const existing = toasts.some(item => item.key === entry.key);
        // Suppressed arrivals enter history only. Expiry never queues replay.
        if (muted || (notif && notif.lastGeneration)) {
            hideToast(entry, false);
            return entry;
        }
        if (!existing) {
            const gate = Policy.burst(burstEvents, entry.sourceKey, arrived, Settings.notifBurstLimit);
            burstEvents = gate.events;
            if (!gate.allowed || groupHoldQueue.isHeld(entry.sourceKey))
                return entry;
            const sourceDeck = toasts.find(item => item.sourceKey === entry.sourceKey);
            const display = Policy.targetScreen(sourceDeck ? sourceDeck.screenName
                : (Screens.focused ? Screens.focused.name : ""), Quickshell.screens, fullscreenOutputs, Settings.notifFullscreen);
            if (!display)
                return entry;
            entry = Object.assign({}, entry, { screenName: display });
            updateEntry(entry.key, entry);
        }
        const next = Policy.popupPlan(toasts, entry, Settings.notifPopupGroups, Settings.notifPopupPerGroup);
        const evicted = toasts.filter(item => !next.some(candidate => candidate.key === item.key));
        toasts = next;
        for (const item of evicted) {
            if (item.live && item.notif)
                item.notif.expire();
        }
        return entry;
    }

    // A sender cannot choose a component URL, provider, file or network fetch.
    // Loader.Error keeps source previews usable; production installs require
    // this module. An unresolved dynamic image is never eligible for dedupe.
    Loader {
        id: imageFingerprintLoader
        active: false
        asynchronous: false
        source: "NotifImageFingerprint.qml"
    }

    function fingerprintImage(source) {
        if (!Policy.isQsImage(source))
            return "";
        imageFingerprintLoader.active = true;
        const ready = imageFingerprintLoader.status === Loader.Ready && imageFingerprintLoader.item;
        const identity = ready ? imageFingerprintLoader.item.fingerprint(source) : "";
        imageIdentityError = identity ? "" : ready
            ? imageFingerprintLoader.item.error : "native-module-unavailable";
        if (!identity && !imageIdentityWarningLogged) {
            imageIdentityWarningLogged = true;
            console.warn("Notification image deduplication unavailable: " + imageIdentityError);
        }
        return identity;
    }

    function describe(source) {
        const rawSummary = Helpers.textValue(source.summary);
        const rawBody = Helpers.textValue(source.body);
        const appName = Helpers.singleLine(Helpers.textValue(source.appName).slice(0, 256));
        const desktopEntry = Helpers.textValue(source.desktopEntry).slice(0, 256);
        const hints = source.hints || {};
        const summary = rawSummary.slice(0, 2048);
        const body = rawBody.slice(0, 32768);
        const presentation = Helpers.derivePresentation({
            appName: appName, desktopEntry: desktopEntry,
            summary: summary, body: body,
            hints: { "x-kde-origin-name": Helpers.textValue(hints["x-kde-origin-name"]).slice(0, 1024) }
        });
        const requestedBrand = BrandIcons.has(source.brandIcon)
            ? BrandIcons.key(source.brandIcon) : "";
        const derivedBrand = BrandIcons.has(presentation.brandIcon)
            ? BrandIcons.key(presentation.brandIcon) : "";
        const detected = Smart.scan(presentation.displaySummary, presentation.displayBody);
        // Anchor hrefs become explicit actions; the source-origin anchor is
        // omitted so opening a site's own origin is never an implicit action.
        const anchorPattern = /<a\s+[^>]*href=["']([^"']+)["'][^>]*>/gi;
        let anchor;
        while ((anchor = anchorPattern.exec(body)) !== null && detected.links.length < 4) {
            const url = Smart.safeHttpUrl(Helpers.decodeEntities(anchor[1]));
            if (url && Helpers.webSource(url).identity !== presentation.webSourceIdentity
                    && detected.links.indexOf(url) < 0)
                detected.links.push(url);
        }
        const image = Helpers.textValue(source.image).slice(0, 2048);
        const appIcon = Helpers.textValue(source.appIcon).slice(0, 1024);
        const row = {
            appName: appName, appIcon: appIcon,
            desktopEntry: desktopEntry, image: image,
            imageFingerprint: fingerprintImage(image), appIconFingerprint: fingerprintImage(appIcon),
            summary: summary, body: body,
            displayAppName: presentation.displayAppName,
            displaySummary: presentation.displaySummary,
            displayBody: presentation.displayBody,
            webOrigin: presentation.webOrigin,
            webSourceIdentity: presentation.webSourceIdentity,
            brandIcon: requestedBrand || derivedBrand,
            urgency: source.urgency ?? NotificationUrgency.Normal,
            expireTimeout: source.expireTimeout ?? -1,
            codes: detected.codes, links: detected.links,
            actionSignature: Helpers.actionSignature(source.actions),
            progress: typeof hints.value === "number" || typeof hints["x-kde-progress"] === "number",
            oversized: rawSummary.length > 2048 || rawBody.length > 32768
                || Helpers.textValue(source.appName).length > 256
                || Helpers.textValue(source.desktopEntry).length > 256
        };
        row.sourceKey = row.oversized ? "oversized:" + (++localSerial) : Policy.sourceKey(row);
        return row;
    }

    function remoteSource(notif) {
        return {
            appName: notif.appName,
            appIcon: notif.appIcon,
            desktopEntry: notif.desktopEntry,
            hints: notif.hints,
            image: notif.image,
            summary: notif.summary,
            body: notif.body,
            urgency: notif.urgency,
            expireTimeout: notif.expireTimeout,
            actions: notif.actions
        };
    }

    // Properties a sender can replace in place (`notify-send -r`, progress
    // updates). A replacement reuses the Notification object and does not
    // raise onNotification again, so without these the toast and the history
    // would keep the first text.
    readonly property var replaceableSignals: ["appNameChanged", "appIconChanged",
        "desktopEntryChanged", "hintsChanged", "imageChanged", "summaryChanged",
        "bodyChanged", "urgencyChanged", "expireTimeoutChanged", "actionsChanged"]

    // Single in-shell path for notifications the shell raises itself. Going
    // out to `notify-send` and back in over D-Bus costs a process per toast
    // and only honours DND/quiet hours by accident of this shell owning
    // org.freedesktop.Notifications. Suppressed sends still reach the
    // notification center, exactly as a remote notification would.
    function send(request) {
        const options = request ?? {};
        return publish({
            appName: options.appName || "Shell",
            appIcon: options.appIcon ?? "",
            desktopEntry: options.desktopEntry ?? "",
            brandIcon: options.brandIcon ?? "",
            image: options.image ?? "",
            summary: options.summary ?? "",
            body: options.body ?? "",
            urgency: options.urgency,
            expireTimeout: options.expireTimeout
        }, null).key;
    }

    readonly property NotificationServer server: NotificationServer {
        keepOnReload: true
        persistenceSupported: true
        bodySupported: true
        actionsSupported: true
        imageSupported: true
        extraHints: ["x-kde-origin-name"]

        onNotification: notif => {
            notif.tracked = true;
            const entry = root.publish(root.remoteSource(notif), notif);
            let open = true;
            // One replacement changes several properties back to back;
            // Qt.callLater collapses them into a single rebuild.
            const refresh = () => {
                const current = root.entries.find(item => item.key === entry.key);
                if (!open || !current || current.notif !== notif)
                    return;
                const changes = Object.assign({ actions: notif.actions,
                    revision: (current.revision || 0) + 1, lastArrived: Date.now() },
                    root.describe(root.remoteSource(notif)));
                root.updateEntry(entry.key, changes);
                const updated = root.entries.find(item => item.key === entry.key);
                if (Policy.quietReason(root.dnd, root.quietActive, root.snoozes,
                        updated.sourceKey, Date.now()))
                    root.hideToast(updated, false);
            };
            const changed = () => Qt.callLater(refresh);
            for (const name of root.replaceableSignals)
                notif[name].connect(changed);
            notif.closed.connect(() => {
                open = false;
                for (const name of root.replaceableSignals)
                    notif[name].disconnect(changed);
                const current = root.entries.find(item => item.key === entry.key);
                if (current && current.notif === notif) {
                    root.updateEntry(entry.key, { live: false, notif: null, actions: [] });
                    root.toasts = root.toasts.filter(item => item.key !== entry.key);
                }
            });
        }
    }

    function clearAll() {
        historyGeneration++;
        historyLoaded = false;
        historyPending = true;
        historyDirty = false;
        historyWrite.stop();
        if (historyProcess.running)
            historyProcess.write(JSON.stringify(historyRequest("clear")) + "\n");
        const list = entries.slice();
        entries = [];
        toasts = [];
        for (const entry of list) {
            if (entry.live && entry.notif)
                entry.notif.dismiss();
        }
    }

    function snoozeSource(key, label, minutes) {
        if (!key || [15, 60, 480].indexOf(minutes) < 0)
            return;
        const now = Date.now();
        snoozes = [{ key: key, label: label || "Notification", until: now + minutes * 60000 }]
            .concat(Policy.activeSnoozes(snoozes, now).filter(item => item.key !== key)).slice(0, 64);
        for (const entry of toasts.filter(item => item.sourceKey === key))
            hideToast(entry, false);
        scheduleSnoozes();
    }

    function unsnooze(key) {
        snoozes = snoozes.filter(item => item.key !== key);
        scheduleSnoozes();
    }

    function unsnoozeAll() {
        snoozes = [];
        snoozeTimer.stop();
    }

    function scheduleSnoozes() {
        snoozeTimer.stop();
        const now = Date.now();
        snoozes = Policy.activeSnoozes(snoozes, now);
        if (snoozes.length) {
            snoozeTimer.interval = Math.max(50, Math.min(...snoozes.map(item => item.until)) - now);
            snoozeTimer.start();
        }
    }

    Timer { id: snoozeTimer; onTriggered: root.scheduleSnoozes() }

    function holdGroup(key, held, owner) {
        // Creation/destruction and hover signals can run while screenGroups
        // is evaluating. Mutate only plain JS here; publish after that stack.
        groupHoldQueue.set(owner ?? key, key, held);
    }

    function dismissGroup(key) {
        const group = entries.filter(item => item.sourceKey === key);
        for (const entry of group)
            dismiss(entry);
    }

    function dismissPopupGroup(key) {
        for (const entry of toasts.filter(item => item.sourceKey === key))
            dismiss(entry);
    }

    function boundPopups() {
        let next = [];
        // Preserve current order while reapplying changed bounds.
        for (const entry of toasts.slice().reverse())
            next = Policy.popupPlan(next, entry, Settings.notifPopupGroups, Settings.notifPopupPerGroup);
        const removed = toasts.filter(item => !next.some(row => row.key === item.key));
        toasts = next;
        for (const entry of removed) {
            if (entry.live && entry.notif)
                entry.notif.expire();
        }
    }

    // A disconnected output falls back predictably; fullscreen is a one-way
    // admission gate. Suppressed popups are never replayed after it ends.
    function reconcileScreens() {
        const names = Quickshell.screens.map(screen => screen.name);
        const remaining = [];
        for (const entry of toasts) {
            const present = names.indexOf(entry.screenName) >= 0;
            const name = Policy.targetScreen(present ? entry.screenName
                : (Screens.focused ? Screens.focused.name : ""),
                Quickshell.screens, fullscreenOutputs, Settings.notifFullscreen);
            if (name)
                remaining.push(entry.screenName === name ? entry : Object.assign({}, entry, { screenName: name }));
        }
        toasts = remaining;
    }

    onFullscreenOutputsChanged: reconcileScreens()
    Connections {
        target: Quickshell
        function onScreensChanged() { root.reconcileScreens(); }
    }

    Process {
        id: copyCode
        // Explicit user action only. No shell parser and no automatic process
        // per arrival. --sensitive asks clipboard managers not to retain codes.
        onExited: code => { if (code !== 0) root.clipboardSecret = ""; }
    }
    Timer {
        id: clipboardLife
        interval: 60000
        onTriggered: {
            if (root.clipboardSecret && Quickshell.clipboardText === root.clipboardSecret)
                Quickshell.clipboardText = "";
            root.clipboardSecret = "";
        }
    }

    function historyRequest(op) {
        return { op: op, id: historyGeneration, count: Settings.notifHistoryCount,
            hours: Settings.notifHistoryHours, bytes: Settings.notifHistoryBytes };
    }

    function configureHistory() {
        if (!historyProcess.running || !Settings.loaded)
            return;
        historyGeneration++;
        historyLoaded = false;
        historyError = false;
        historyPending = true;
        historyDirty = false;
        historyWrite.stop();
        historyProcess.write(JSON.stringify(historyRequest(Settings.notifHistoryPersist ? "read" : "clear")) + "\n");
    }

    function historyReply(line) {
        let reply;
        try { reply = JSON.parse(line); } catch (e) { historyError = true; return; }
        if (reply.id !== historyGeneration)
            return;
        historyPending = false;
        if (!reply.ok) {
            historyError = true;
            historyDirty = true;
            return;
        }
        historyError = false;
        if (reply.op === "read" && Settings.notifHistoryPersist) {
            const rows = Array.isArray(reply.entries) ? reply.entries.slice(0, Settings.notifHistoryCount) : [];
            const restored = rows.map((row, index) => {
                const clean = Object.assign({}, Smart.persistable(row), {
                    key: `history-${historyGeneration}-${index}`, live: false, notif: null,
                    actions: [], codes: [], links: [], image: "", appIcon: "", brandIcon: "",
                    summary: "", body: "",
                    restored: true, revision: 0, expireTimeout: -1
                });
                clean.summary = clean.displaySummary;
                clean.body = clean.displayBody;
                clean.webOrigin = Helpers.canonicalOriginHost(clean.webOrigin);
                clean.webSourceIdentity = Helpers.canonicalWebSourceIdentity(clean.webSourceIdentity, clean.webOrigin)
                    || (clean.webOrigin ? "unqualified:" + clean.webOrigin : "");
                clean.sourceKey = Policy.sourceKey(clean);
                return clean;
            });
            // Startup I/O cannot overwrite messages received in the meantime.
            entries = entries.filter(item => !item.restored).concat(restored)
                .slice(0, Settings.notifHistoryCount);
        }
        if (reply.op === "read" || reply.op === "clear") {
            historyLoaded = true;
            if (reply.op === "read")
                pruneHistory();
            else if (entries.length)
                queueHistory();
            else
                historyDirty = false;
        } else if (historyDirty) {
            queueHistory();
        }
    }

    function queueHistory() {
        historyDirty = true;
        // At most one snapshot is in flight. Bursts only mark it dirty;
        // a slow disk cannot grow an unbounded queue in the process pipe.
        if (Settings.loaded && Settings.notifHistoryPersist && historyLoaded
                && historyProcess.running && !historyPending && !historyWrite.running)
            historyWrite.start();
        scheduleRetention();
    }

    function pruneHistory() {
        const cutoff = Date.now() - Settings.notifHistoryHours * Format.MS_HOUR;
        const keep = entries.filter(item => (item.lastArrived || item.arrived) > cutoff)
            .slice(0, Settings.notifHistoryCount);
        const removed = entries.filter(item => !keep.some(row => row.key === item.key));
        if (removed.length)
            entries = keep;
        for (const entry of removed)
            hideToast(entry, true);
        queueHistory();
    }

    function scheduleRetention() {
        historyRetention.stop();
        if (!Settings.loaded || !entries.length)
            return;
        const oldest = Math.min(...entries.map(item => item.lastArrived || item.arrived));
        historyRetention.interval = Math.max(50,
            oldest + Settings.notifHistoryHours * Format.MS_HOUR - Date.now());
        historyRetention.start();
    }

    onEntriesChanged: queueHistory()
    Timer { id: historyRetention; onTriggered: root.pruneHistory() }
    Timer {
        id: historyWrite
        interval: 250
        onTriggered: {
            if (!Settings.notifHistoryPersist || !root.historyLoaded || !historyProcess.running)
                return;
            if (root.historyPending)
                return;
            root.historyPending = true;
            root.historyDirty = false;
            const request = root.historyRequest("write");
            request.entries = root.entries.map(entry => Smart.persistable(entry));
            historyProcess.write(JSON.stringify(request) + "\n");
        }
    }
    Process {
        id: historyProcess
        command: ["python3", "-u", Quickshell.shellDir + "/scripts/notification-history.py"]
        stdinEnabled: true
        running: Settings.loaded
        onStarted: root.configureHistory()
        onExited: { root.historyError = true; root.historyLoaded = false; }
        stdout: SplitParser { onRead: line => root.historyReply(line) }
    }

    // Resolve an app's desktop-entry icon from the appName a notification
    // carries. Senders write anything from exact ids ("google-chrome") to
    // display names ("Google Chrome", "Firefox"), so try the id heuristic,
    // a dashed lowercase form, and finally the entries' display names.
    function entryIcon(identity) {
        if (!identity)
            return "";
        const entry = DesktopEntries.heuristicLookup(identity)
            || DesktopEntries.heuristicLookup(identity.toLowerCase().replace(/\s+/g, "-"));
        if (entry && entry.icon)
            return entry.icon;
        const lower = identity.toLowerCase();
        const byName = DesktopEntries.applications.values.find(e => e.name && e.name.toLowerCase() === lower);
        return byName && byName.icon ? byName.icon : "";
    }

    function resolvedIcon(value) {
        if (!value || typeof value !== "string")
            return "";
        if (/^image:\/\/qsimage\/[0-9]+\/[0-9]+$/.test(value))
            return value;
        if (value.startsWith("image://icon/"))
            value = value.slice("image://icon/".length);
        const local = Smart.localImageUrl(value);
        if (local)
            return local;
        if (!/^[a-zA-Z0-9_.-]{1,256}$/.test(value))
            return "";
        return Quickshell.iconPath(value, true);
    }

    // Image source for the non-brand half of an entry's icon slot; NotifIcon
    // renders an approved brand name through BrandIcon before calling here.
    // Every step falls through when it cannot produce something loadable.
    // Browser notifications exclude the browser logo once an origin is known
    // and use only the site's safe attached notification image here.
    // Missing images fall back to the in-process web glyph.
    // Native applications use app icon, desktop entry, attached image, then
    // their glyph fallback.
    function iconSource(entry) {
        let source = "";
        if (entry.webOrigin) {
            source = resolvedIcon(entry.image || "");
            return source;
        }
        source = resolvedIcon(entry.appIcon || "");
        if (source !== "")
            return source;
        const named = entryIcon(entry.desktopEntry || entry.appName);
        if (named !== "") {
            source = resolvedIcon(named);
            if (source !== "")
                return source;
        }
        return resolvedIcon(entry.image || "");
    }

    function timeAgo(arrived, now) {
        const s = Math.max(0, ((now || Date.now()) - arrived) / 1000);
        if (s < Format.MINUTE)
            return "now";
        if (s < Format.HOUR)
            return Math.floor(s / Format.MINUTE) + "m";
        if (s < Format.DAY)
            return Math.floor(s / Format.HOUR) + "h";
        return Math.floor(s / Format.DAY) + "d";
    }

    Component.onCompleted: applyStartupPolicy()
    Component.onDestruction: groupHoldQueue.dispose()
}
