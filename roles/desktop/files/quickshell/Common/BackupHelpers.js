// Pure helpers for personal-file backups (no Qt APIs, so Node tests load
// them). The user helper cybexos-backup owns the configuration, the
// keyring password and every restic run; Settings reads its `status --json`
// and starts long runs as transient user units, so closing Settings or
// restarting the shell never interrupts a backup or a restore.

var HELPER_NAME = "cybexos-backup";
// The same shapes the helper accepts (assets/scripts/cybexos-backup).
var HOST_PATTERN = /^[A-Za-z0-9_][A-Za-z0-9_.@%-]{0,253}$/;
var REMOTE_PATH_PATTERN = /^\/?[A-Za-z0-9_][A-Za-z0-9_. +\/-]{0,250}$/;
var SNAPSHOT_PATTERN = /^(latest|[0-9a-f]{8,64})$/;
var DEFAULT_REMOTE_PATH = "cybexos-backup";

function text(value) {
    return typeof value === "string" ? value : "";
}

function number(value) {
    return typeof value === "number" && isFinite(value) ? value : 0;
}

function emptyStatus() {
    return {
        valid: false, configured: false, running: false, progress: null,
        destination: { type: "", display: "", label: "", path: "", host: "" },
        automatic: false, reachable: null, unreachableReason: "",
        recoveryKeyConfirmed: true, lastSuccess: "", lastAttempt: "", lastResult: "",
        lastError: "", lastSkip: "", nextDue: "", stale: false, lastRestore: null,
        mediaRoot: "/"
    };
}

// A bounded, typed copy of `cybexos-backup status --json`.
function parseStatus(raw) {
    var data;
    try {
        data = JSON.parse(raw);
    } catch (e) {
        return emptyStatus();
    }
    if (!data || typeof data !== "object")
        return emptyStatus();
    var status = emptyStatus();
    status.valid = true;
    status.configured = data.configured === true;
    status.running = data.running === true;
    if (status.running && data.progress && typeof data.progress === "object") {
        status.progress = {
            operation: text(data.progress.operation) || "backup",
            percent: Math.max(0, Math.min(1, number(data.progress.percent)))
        };
    }
    if (/^\/[^\n\0]*$/.test(text(data.mediaRoot)))
        status.mediaRoot = data.mediaRoot;
    var restore = data.lastRestore;
    if (restore && typeof restore === "object") {
        status.lastRestore = { time: text(restore.time), ok: restore.ok === true,
            target: text(restore.target), error: text(restore.error).slice(0, 300) };
    }
    if (!status.configured)
        return status;
    var destination = data.destination && typeof data.destination === "object" ? data.destination : {};
    status.destination = {
        type: destination.type === "sftp" ? "sftp" : "local",
        display: text(destination.display).slice(0, 200),
        label: text(destination.label).slice(0, 80),
        path: text(destination.path),
        host: text(destination.host)
    };
    status.automatic = data.automatic === true;
    status.reachable = data.reachable === true ? true : data.reachable === false ? false : null;
    status.unreachableReason = text(data.unreachableReason).slice(0, 200);
    status.recoveryKeyConfirmed = data.recoveryKeyConfirmed === true;
    status.lastSuccess = text(data.lastSuccess);
    status.lastAttempt = text(data.lastAttempt);
    status.lastResult = text(data.lastResult);
    status.lastError = text(data.lastError).slice(0, 300);
    status.lastSkip = text(data.lastSkip);
    status.nextDue = text(data.nextDue);
    status.stale = data.stale === true;
    return status;
}

// Newest first, as the helper lists them.
function parseSnapshots(raw) {
    var data;
    try {
        data = JSON.parse(raw);
    } catch (e) {
        return [];
    }
    var list = data && Array.isArray(data.snapshots) ? data.snapshots : [];
    return list.filter(function(entry) {
        return entry && SNAPSHOT_PATTERN.test(text(entry.id)) && text(entry.id) !== "latest";
    }).slice(0, 200).map(function(entry) {
        return { id: entry.id, time: text(entry.time), host: text(entry.host),
            files: number(entry.files), bytes: number(entry.bytes) };
    });
}

// "ok", "running", "warning", "error" or "off": the status dot's colour.
function tone(status) {
    if (!status || !status.configured)
        return "off";
    if (status.running)
        return "running";
    if (status.lastResult === "failed")
        return "error";
    if (status.stale || !status.recoveryKeyConfirmed || status.lastSuccess === "")
        return "warning";
    return "ok";
}

function progressLabel(progress) {
    if (!progress)
        return "";
    var percent = Math.floor(number(progress.percent) * 100);
    if (progress.operation === "restore")
        return "Restoring… " + percent + "%";
    if (progress.operation === "cleanup")
        return "Tidying old backups…";
    return "Backing up… " + percent + "%";
}

// When the next automatic backup runs. `dueMs` is status.nextDue parsed by
// the page (LocalTime.parse) and `formatTime(ms)` phrases that instant the
// way the page does ("tomorrow after 10:05"). The timer checks hourly, so a
// due time is the earliest the backup starts.
function scheduleText(status, dueMs, nowMs, formatTime) {
    if (!status || !status.configured)
        return "";
    if (!status.automatic)
        return "Automatic backups are off";
    if (status.reachable === false)
        return "Next backup when the destination is available";
    if (typeof dueMs !== "number" || !isFinite(dueMs) || dueMs <= nowMs + 60000)
        return "Next backup within the hour";
    return "Next backup " + formatTime(dueMs);
}

// The line under "Last backup": a running backup, the reason it failed, a
// week without one, or when the next one runs.
function statusHint(status, dueMs, nowMs, formatTime) {
    if (!status || !status.configured)
        return "";
    if (status.running)
        return status.progress && status.progress.operation === "restore"
            ? "Restoring into a new folder in Restored."
            : "You can keep working; it continues in the background.";
    if (status.lastResult === "failed" && status.lastError !== "")
        return status.lastError;
    var schedule = scheduleText(status, dueMs, nowMs, formatTime);
    if (status.stale)
        return "More than a week since the last backup. " + schedule + ".";
    return schedule + ".";
}

function hintTone(status) {
    var verdict = tone(status);
    if (verdict === "error")
        return "error";
    if (verdict === "running")
        return "active";
    return status && status.stale ? "warning" : "info";
}

function validHost(host) {
    return HOST_PATTERN.test(String(host || "").trim());
}

function remotePath(path) {
    var value = String(path || "").trim().replace(/\/+$/, "");
    return value === "" ? DEFAULT_REMOTE_PATH : value;
}

function validRemotePath(path) {
    var value = remotePath(path);
    return REMOTE_PATH_PATTERN.test(value) && value.split("/").indexOf("..") === -1;
}

// A path inside the backed-up home folder; "" restores everything.
function validRestorePath(path) {
    var value = String(path || "").trim();
    if (value === "")
        return true;
    if (/[\n\0*?[\\]/.test(value))
        return false;
    return value.replace(/^~\/?/, "").split("/").indexOf("..") === -1;
}

function helperPath(home) {
    return String(home || "") + "/.local/bin/" + HELPER_NAME;
}

// `kind` is "local" (target: a folder) or "sftp" (target: an SSH alias or
// user@host, path: the folder on the server). [] when invalid.
function setupCommand(helper, kind, target, path, existing) {
    var command;
    if (kind === "local") {
        var folder = String(target || "").trim();
        if (folder === "" || /[\n\0]/.test(folder))
            return [];
        command = [helper, "setup", "local", folder];
    } else if (kind === "sftp") {
        if (!validHost(target) || !validRemotePath(path))
            return [];
        command = [helper, "setup", "sftp", String(target).trim(), remotePath(path)];
    } else {
        return [];
    }
    if (existing)
        command.push("--existing");
    command.push("--json");
    return command;
}

// Long runs leave the shell's cgroup: a transient user unit keeps a backup
// or restore going when Settings closes or the shell restarts, and the
// helper's lock refuses a second one.
function transient(name, serial, description) {
    return ["systemd-run", "--user", "--quiet", "--collect",
        "--unit=cybexos-backup-" + name + "-" + String(serial).replace(/[^0-9]/g, ""),
        "--description=" + description, "--"];
}

function nowCommand(helper, serial) {
    return transient("now", serial, "Back up personal files").concat([helper, "now", "--notify"]);
}

function restoreCommand(helper, snapshotId, path, serial) {
    if (!SNAPSHOT_PATTERN.test(String(snapshotId || "")) || !validRestorePath(path))
        return [];
    var command = transient("restore", serial, "Restore personal files")
        .concat([helper, "restore", snapshotId]);
    var relative = String(path || "").trim();
    if (relative !== "")
        command.push("--path", relative);
    return command.concat(["--open", "--notify"]);
}

// The helper prints {"ok": false, "error": "..."} for --json requests and
// "cybexos-backup: ..." on stderr otherwise.
function errorText(code, body, stderr) {
    var data = null;
    try {
        data = JSON.parse(body);
    } catch (e) {
        data = null;
    }
    if (data && typeof data.error === "string" && data.error !== "")
        return data.error;
    var lines = String(stderr || "").split("\n").map(function(line) { return line.trim(); })
        .filter(function(line) { return line !== ""; });
    for (var i = lines.length - 1; i >= 0; i--) {
        var match = /^cybexos-backup: (.+)$/.exec(lines[i]);
        if (match)
            return match[1];
    }
    if (/already exists|already loaded/i.test(String(stderr || "")))
        return "A backup or restore is already running.";
    if (code === -1)
        return "The backup helper is not installed.";
    return lines.length > 0 ? lines[lines.length - 1] : "The backup helper failed (exit " + code + ").";
}

function formatBytes(count) {
    var value = number(count);
    var units = ["B", "KB", "MB", "GB", "TB"];
    var unit = 0;
    while (value >= 1000 && unit < units.length - 1) {
        value /= 1000;
        unit++;
    }
    return (unit === 0 ? String(Math.round(value)) : value.toFixed(1)) + " " + units[unit];
}

var exported = {
    HELPER_NAME: HELPER_NAME,
    DEFAULT_REMOTE_PATH: DEFAULT_REMOTE_PATH,
    emptyStatus: emptyStatus,
    parseStatus: parseStatus,
    parseSnapshots: parseSnapshots,
    tone: tone,
    progressLabel: progressLabel,
    scheduleText: scheduleText,
    statusHint: statusHint,
    hintTone: hintTone,
    validHost: validHost,
    remotePath: remotePath,
    validRemotePath: validRemotePath,
    validRestorePath: validRestorePath,
    helperPath: helperPath,
    setupCommand: setupCommand,
    nowCommand: nowCommand,
    restoreCommand: restoreCommand,
    errorText: errorText,
    formatBytes: formatBytes
};

if (typeof module !== "undefined" && module.exports)
    module.exports = exported;
