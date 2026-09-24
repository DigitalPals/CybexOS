import QtQuick
import QtTest
import "../../roles/desktop/files/quickshell/Settings/LocalTime.js" as LocalTime
import "../../roles/desktop/files/quickshell/Settings/IdleTimelineModel.js" as Timeline

// The About and Power pages' pure helpers under Qt's JavaScript engine, not
// only Node's: the two have disagreed about date strings before, which is
// why LocalTime parses ISO 8601 by hand.
Item {
    TestCase {
        name: "SettingsSystemPages"

        function test_python_timestamps_parse_in_the_qml_engine() {
            compare(LocalTime.parse("2026-09-24T17:16:48.655239+00:00"),
                Date.UTC(2026, 8, 24, 17, 16, 48, 655));
            compare(LocalTime.parse("20260924T171648Z"), Date.UTC(2026, 8, 24, 17, 16, 48));
            verify(isNaN(LocalTime.parse("not a time")));
        }

        function test_relative_labels() {
            const now = new Date(2026, 8, 24, 20, 30).getTime();
            compare(LocalTime.label(new Date(2026, 8, 24, 19, 16).getTime(), now, true), "Today at 19:16");
            compare(LocalTime.label(new Date(2026, 8, 23, 8, 2).getTime(), now, true), "Yesterday at 08:02");
        }

        function test_timeline_warning() {
            const axis = Timeline.axis([[0, 1, 2, 5, 10, 15, 30], [0, 15, 30, 60, 120]]);
            const verdict = Timeline.assessment(
                { idleLockMins: 30, idleScreenOffMins: 10, idleSuspendMins: 0 }, false, axis);
            compare(verdict.tone, "warning");
            compare(verdict.text,
                "The screen turns off 20 minutes before it locks. Waking it in that time skips the lock screen.");
        }
    }
}
