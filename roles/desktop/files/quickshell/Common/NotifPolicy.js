// Bounded, deterministic notification admission shared by QML and Node tests.
function sourceKey(row) {
    // webSourceIdentity is canonicalized by the admission/restore boundary.
    // Legacy hostname-only history never acquires an invented HTTP(S) origin.
    if (row.webOrigin) {
        var identity = typeof row.webSourceIdentity === "string" && row.webSourceIdentity.length <= 320
            ? row.webSourceIdentity : "";
        return "web:" + (identity || "unqualified:" + String(row.webOrigin).slice(0, 253).toLowerCase());
    }
    // Keep punctuation and case: lossy slugs alias unrelated native senders.
    return "app:" + JSON.stringify([row.desktopEntry || "", row.appName || "Notification"]);
}

function isQsImage(source) {
    return typeof source === "string" && source.length <= 64
        && /^image:\/\/qsimage\/[0-9]{1,20}\/[0-9]{1,20}$/.test(source)
        && !/[\r\n]/.test(source);
}

function imageIdentity(source, fingerprint) {
    // Quickshell allocates a different provider handle for each notification,
    // even when the attached pixels match. Never equate unresolved handles.
    if (String(source || "").indexOf("image://qsimage") === 0) {
        return isQsImage(source) && typeof fingerprint === "string" && fingerprint.length === 71
            && /^sha256:[0-9a-f]{64}$/.test(fingerprint) ? "pixels:" + fingerprint : null;
    }
    return "uri:" + (source || "");
}

function signature(row) {
    var image = imageIdentity(row.image, row.imageFingerprint);
    var icon = imageIdentity(row.appIcon, row.appIconFingerprint);
    if (image === null || icon === null) return null;
    // Compare full bounded content, not a hash or title alone. Action changes
    // are semantically different; progress is never an occurrence.
    return JSON.stringify([sourceKey(row), row.summary, row.body, row.urgency,
        icon, image, row.actionSignature || ""]);
}

function duplicate(entries, row, now, seconds) {
    if (!(seconds > 0) || row.progress || row.oversized)
        return null;
    var sig = signature(row);
    if (sig === null) return null;
    for (var i = 0; i < entries.length; i++) {
        var old = entries[i];
        // Window anchored to the first occurrence: a flood cannot extend it.
        if (!old.restored && !old.progress && !old.oversized && now >= old.arrived
                && now - old.arrived <= seconds * 1000 && signature(old) === sig)
            return old;
    }
    return null;
}

function activeSnoozes(snoozes, now) {
    return snoozes.filter(function(item) { return item.until > now; }).slice(0, 64);
}

function quietReason(dnd, quiet, snoozes, key, now) {
    if (dnd) return "dnd";
    if (quiet) return "quiet";
    return activeSnoozes(snoozes, now).some(function(item) { return item.key === key; })
        ? "snoozed" : "";
}

function burst(events, key, now, limit) {
    var recent = events.filter(function(item) { return now >= item.at && now - item.at < 10000; });
    var allowed = recent.filter(function(item) { return item.key === key; }).length < limit;
    if (allowed) recent.push({ key: key, at: now });
    // Limits total bookkeeping even with many hostile source identities.
    return { allowed: allowed && recent.length <= 256, events: recent.slice(-256) };
}

function groups(entries) {
    var map = Object.create(null), result = [];
    for (var i = 0; i < entries.length; i++) {
        var row = entries[i], key = row.sourceKey || sourceKey(row);
        if (!map[key]) {
            map[key] = { key: key, app: row.displayAppName, items: [] };
            result.push(map[key]);
        }
        map[key].items.push(row);
    }
    return result;
}

function popupPlan(toasts, row, groupLimit, perGroup) {
    var current = toasts.filter(function(item) { return item.key !== row.key; });
    var list = [row].concat(current), bySource = Object.create(null), accepted = [];
    var order = [];
    for (var i = 0; i < list.length; i++) {
        var item = list[i], key = item.sourceKey;
        if (!bySource[key]) {
            if (order.length >= groupLimit) continue;
            order.push(key);
            bySource[key] = 0;
        }
        if (bySource[key] >= perGroup) continue;
        bySource[key]++;
        accepted.push(item);
    }
    return accepted;
}

function targetScreen(focused, screens, fullscreen, policy) {
    var names = screens.map(function(screen) { return screen.name; });
    var name = names.indexOf(focused) >= 0 ? focused : (names[0] || "");
    if (policy === "show" || fullscreen.indexOf(name) < 0) return name;
    return names.find(function(candidate) { return fullscreen.indexOf(candidate) < 0; }) || "";
}

if (typeof module !== "undefined" && module.exports)
    module.exports = { sourceKey: sourceKey, isQsImage: isQsImage, imageIdentity: imageIdentity,
        signature: signature, duplicate: duplicate,
        activeSnoozes: activeSnoozes, quietReason: quietReason, burst: burst,
        groups: groups, popupPlan: popupPlan, targetScreen: targetScreen };
