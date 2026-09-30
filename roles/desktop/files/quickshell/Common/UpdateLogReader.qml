import QtQuick
import "UpdatesHelpers.js" as UpdatesHelpers

// A byte-range read is bound to the run and offset that issued it. The
// transaction model owns offsets/parsing; this transport rejects stale reads
// and publishes only complete successful responses.
CommandRequest {
    id: root
    required property string kind
    property string currentRun: ""
    property int currentOffset: 0
    property string targetRunStamp: ""
    property int sourceOffset: 0
    property int targetOffset: 0
    signal accepted(string body, int offset)
    signal stale()
    timeoutMessage: kind + " update log read timed out"
    onCompleted: (code, body, error) => {
        if (UpdatesHelpers.acceptsLogRead(currentRun, currentOffset,
                targetRunStamp, sourceOffset, targetOffset, true, code)) {
            accepted(body, targetOffset);
        } else if (targetRunStamp !== currentRun || sourceOffset !== currentOffset) {
            stale();
        } else if (code !== 0) {
            console.warn(kind + " update log read failed:", code, error);
        }
    }
}
