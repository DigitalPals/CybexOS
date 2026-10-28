pragma Singleton
import QtQuick
import Quickshell
import "DoctorHelpers.js" as DoctorHelpers

// The read-only system check, `cybex doctor` (docs/system-check.md). The
// welcome guide runs it while the person makes their choices, so Ready can
// say what it found without an AI account; the assistant reads the same
// report to explain it and offer fixes.
Singleton {
    id: root

    property var report: null
    property string error: ""
    readonly property bool running: request.running
    // When the last run finished, in ms; 0 before the first.
    property double finishedAt: 0
    // Problems first, then suggestions.
    readonly property var attention: DoctorHelpers.attention(report)

    function refresh() {
        if (!request.running)
            request.running = true;
    }

    // The guide asks again only for a report older than two minutes.
    function refreshIfStale() {
        if (finishedAt === 0 || Date.now() - finishedAt > 120000)
            refresh();
    }

    // One line for a check that needs the person, in the shell's language.
    function sentence(check) {
        const problem = check.state === "problem";
        switch (check.id) {
        case "graphics":
            return problem ? I18n.tr("A graphics card has no driver")
                : I18n.tr("A graphics card is not using its recommended driver");
        case "drivers":
            return I18n.tr("A device has no driver");
        case "services":
            return I18n.tr("A system service has failed");
        case "audio":
            return I18n.tr("No speakers or headphones were found");
        case "secure-boot":
            return I18n.tr("Secure Boot is off");
        case "firmware-updates":
            return I18n.tr("Firmware updates are available");
        case "storage":
            return problem ? I18n.tr("Very little disk space is left") : I18n.tr("The disk is getting full");
        case "battery":
            return I18n.tr("The battery has lost much of its capacity");
        case "time":
            return I18n.tr("The clock is not synchronized");
        case "desktop":
            return I18n.tr("The desktop reported a problem");
        default:
            return check.summary;
        }
    }

    function status() {
        return {running: running, error: error, overall: report ? report.overall : "",
            attention: attention.map(check => check.id + ":" + check.state)};
    }

    CommandRequest {
        id: request
        command: ["cybex", "doctor", "--json"]
        timeoutMs: 45000
        timeoutMessage: I18n.tr("The system check took too long.")
        onCompleted: (code, body, detail) => {
            const report = code === 0 ? DoctorHelpers.parse(body) : null;
            if (report) {
                root.report = report;
                root.error = "";
            } else {
                root.error = code === 124 ? detail : I18n.tr("The system check could not run.");
                if (code > 0 && code !== 124)
                    console.warn("doctor: cybex doctor failed", code, String(detail).slice(0, 400));
            }
            root.finishedAt = Date.now();
        }
    }
}
