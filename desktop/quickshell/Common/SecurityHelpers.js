// Settings > Security copy and enrolment parsing (docs/hardware-security.md). Kept free
// of Qt APIs so tests/quickshell/security-settings.test.cjs can run it under
// Node. The helper scripts report fprintd's own result names; every word a
// person reads is chosen here.

var FINGER_ORDER = [
    "right-index-finger", "left-index-finger", "right-thumb", "left-thumb",
    "right-middle-finger", "left-middle-finger", "right-ring-finger",
    "left-ring-finger", "right-little-finger", "left-little-finger"
];

// "right-index-finger" -> "Right index finger"
function fingerLabel(name) {
    var words = String(name || "").split("-").filter(function(word) { return word !== ""; });
    if (words.length === 0)
        return "Fingerprint";
    var text = words.join(" ");
    return text.charAt(0).toUpperCase() + text.slice(1);
}

function fingerOptions(free) {
    return FINGER_ORDER.filter(function(name) { return (free || []).indexOf(name) !== -1; })
        .map(function(name) { return { value: name, label: fingerLabel(name) }; });
}

// One short line in place of controls that cannot work here.
function readerLine(state) {
    if (state === "none")
        return "No fingerprint reader was found.";
    if (state === "unavailable")
        return "Fingerprint support is not available right now.";
    return "";
}

function keyLine(state) {
    if (state === "missing")
        return "Security keys need the pam-u2f package.";
    if (state === "inactive")
        return "Security keys are not enabled in the NixOS authentication policy. Check your personal modules, then preview and apply the change.";
    return "";
}

function enrolInstruction(scanType) {
    return scanType === "swipe"
        ? "Swipe your finger across the reader."
        : "Place your finger on the reader, then lift it.";
}

// fprintd's EnrollStatus results that ask for another scan.
function enrolStatus(result, scanType) {
    switch (result) {
    case "enroll-stage-passed":
        return scanType === "swipe" ? "Good. Swipe again." : "Good. Lift your finger, then place it again.";
    case "enroll-retry-scan":
        return "Not read. Scan again.";
    case "enroll-swipe-too-short":
        return "The swipe was too short. Swipe again.";
    case "enroll-finger-not-centered":
        return "Center your finger on the reader and try again.";
    case "enroll-remove-and-retry":
        return "Lift your finger and try again.";
    case "enroll-too-fast":
        return "Too quick. Hold your finger on the reader a moment longer.";
    default:
        return enrolInstruction(scanType);
    }
}

// Results that end an enrolment without a new fingerprint.
function enrolFailure(result, message) {
    switch (result) {
    case "enroll-duplicate":
        return "This finger is already enrolled.";
    case "enroll-data-full":
        return "The reader has no room for more fingerprints.";
    case "enroll-disconnected":
        return "The reader was disconnected.";
    case "enroll-timeout":
        return "Nothing was scanned for a while, so adding stopped.";
    case "enroll-failed":
    case "enroll-unknown-error":
        return "The fingerprint was not added. Try again.";
    default:
        return message ? String(message) : "The fingerprint was not added. Try again.";
    }
}

// The scan counter beside the progress bar: "3 of 8", or "" when the
// reader does not say how many scans it needs.
function stageLabel(stage, stages) {
    return stages > 0 ? Math.min(stage, stages) + " of " + stages : "";
}

// One line of the enrolment helper's output, or null when it is not one of
// its events. Only known fields are kept.
function parseEnrolEvent(line) {
    var value;
    try {
        value = JSON.parse(String(line));
    } catch (error) {
        return null;
    }
    if (!value || typeof value !== "object" || Array.isArray(value))
        return null;
    var kinds = ["started", "progress", "completed", "failed", "cancelled"];
    if (kinds.indexOf(value.event) === -1)
        return null;
    return {
        event: value.event,
        result: typeof value.result === "string" ? value.result : "",
        message: typeof value.message === "string" ? value.message : "",
        stage: Number.isInteger(value.stage) && value.stage >= 0 ? value.stage : 0,
        stages: Number.isInteger(value.stages) && value.stages >= 0 ? value.stages : 0,
        scanType: value.scanType === "swipe" ? "swipe" : "press"
    };
}

if (typeof module !== "undefined" && module.exports)
    module.exports = {
        FINGER_ORDER, fingerLabel, fingerOptions, readerLine, keyLine, enrolInstruction,
        enrolStatus, enrolFailure, stageLabel, parseEnrolEvent
    };
