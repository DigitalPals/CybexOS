// Pure helpers for recovery points (no Qt APIs, so Node tests load them).
// The root-owned `cybexos-system-snapshot refresh` publishes the index this
// reads; restoring goes through systemd, whose Polkit prompt authorizes it.

var ID_PATTERN = /^[0-9]{8}T[0-9]{6}Z-[0-9]+$/;
var INDEX_PATH = "/run/cybexos-snapshots/recovery-points.json";
// A recovery boot's own filesystem may predate `restore`; the initramfs
// carries the installed helper to this path.
var RECOVERY_HELPER = "/run/cybexos-recovery/cybexos-system-snapshot";
var INSTALLED_HELPER = "/usr/local/libexec/cybexos-system-snapshot";

function validId(value) {
    return typeof value === "string" && ID_PATTERN.test(value);
}

// The recovery point this boot runs from, or "".
function recoveryBootId(cmdline) {
    var tokens = String(cmdline || "").split(/\s+/);
    for (var i = 0; i < tokens.length; i++) {
        if (tokens[i].indexOf("cybexos.recovery=") === 0) {
            var value = tokens[i].slice("cybexos.recovery=".length);
            return validId(value) ? value : "";
        }
    }
    return "";
}

function text(value) {
    return typeof value === "string" ? value : "";
}

// A bounded, typed copy of the published index; anything malformed is
// dropped rather than shown.
function parseIndex(raw) {
    var empty = { supported: false, message: "", recoveryBoot: "", pendingReboot: false,
        bootMenu: false, points: [], replaced: [], valid: false };
    var data;
    try {
        data = JSON.parse(raw);
    } catch (e) {
        return empty;
    }
    if (!data || typeof data !== "object" || data.version !== 1)
        return empty;
    var points = (Array.isArray(data.points) ? data.points : [])
        .filter(function(point) { return point && validId(point.id); })
        .slice(0, 20)
        .map(function(point) {
            return {
                id: point.id,
                description: text(point.description).slice(0, 120),
                created: text(point.created),
                kernel: text(point.kernel),
                bootable: point.bootable === true,
                reason: text(point.reason)
            };
        });
    var replaced = (Array.isArray(data.replaced) ? data.replaced : [])
        .filter(function(root) { return root && /^root\.replaced-[0-9]{8}T[0-9]{6}Z$/.test(root.name); })
        .map(function(root) {
            return { name: root.name, created: text(root.created), restoredFrom: text(root.restoredFrom) };
        });
    return {
        supported: data.supported === true,
        message: text(data.message),
        recoveryBoot: validId(data.recoveryBoot) ? data.recoveryBoot : "",
        pendingReboot: data.pendingReboot === true,
        bootMenu: data.bootMenu === true,
        points: points,
        replaced: replaced,
        valid: true
    };
}

// "2026-09-23 17:31 UTC" from the identifier itself, independent of locale.
function pointTime(id) {
    if (!validId(id))
        return "";
    return id.slice(0, 4) + "-" + id.slice(4, 6) + "-" + id.slice(6, 8) + " "
        + id.slice(9, 11) + ":" + id.slice(11, 13) + " UTC";
}

// Updater points are described as "update <run id>"; say what they are.
function pointLabel(point) {
    var description = text(point && point.description);
    if (/^update [0-9-]+$/.test(description))
        return "Before an update";
    return description || "Recovery point";
}

function pointStatus(point) {
    if (!point)
        return "";
    if (point.bootable)
        return "In the boot menu" + (point.kernel ? " · kernel " + point.kernel : "");
    return point.reason ? "Restore only · " + point.reason : "Restore only";
}

function helperPath(recoveryBoot, recoveryHelperExists) {
    return recoveryBoot && recoveryHelperExists ? RECOVERY_HELPER : INSTALLED_HELPER;
}

// Runs the root helper as a transient system unit. systemd asks the session's
// Polkit agent to authorize it, as the updater does; --pipe returns its output.
function restoreCommand(helper, id, serial) {
    if (!validId(id) || (helper !== RECOVERY_HELPER && helper !== INSTALLED_HELPER))
        return [];
    return ["systemd-run", "--system", "--quiet", "--collect", "--wait", "--pipe",
        "--unit=cybexos-recovery-restore-" + String(serial).replace(/[^0-9]/g, ""),
        "--description=Restore CybexOS recovery point " + id,
        "--", helper, "restore", id];
}

function restoreError(exitCode, stderr) {
    var lines = String(stderr || "").split("\n").map(function(line) { return line.trim(); })
        .filter(function(line) { return line !== ""; });
    var all = lines.join("\n");
    if (/not authori[sz]ed|Interactive authentication required|Authentication (failed|required)|Access denied|polkit/i.test(all))
        return "Authorization was cancelled, so nothing was changed.";
    for (var i = lines.length - 1; i >= 0; i--) {
        var match = /^cybexos-system-snapshot: (.+)$/.exec(lines[i]);
        if (match)
            return match[1].charAt(0).toUpperCase() + match[1].slice(1);
    }
    if (lines.length > 0)
        return lines[lines.length - 1];
    return "Restore failed (exit " + exitCode + ").";
}

var exported = {
    ID_PATTERN: ID_PATTERN,
    INDEX_PATH: INDEX_PATH,
    RECOVERY_HELPER: RECOVERY_HELPER,
    INSTALLED_HELPER: INSTALLED_HELPER,
    validId: validId,
    recoveryBootId: recoveryBootId,
    parseIndex: parseIndex,
    pointTime: pointTime,
    pointLabel: pointLabel,
    pointStatus: pointStatus,
    helperPath: helperPath,
    restoreCommand: restoreCommand,
    restoreError: restoreError
};

if (typeof module !== "undefined" && module.exports)
    module.exports = exported;
