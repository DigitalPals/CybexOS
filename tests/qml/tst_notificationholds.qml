import QtQuick
import QtTest
import "../../desktop/quickshell/Common/NotifHolds.js" as Holds
import "../../desktop/quickshell/Common/NotifPolicy.js" as Policy

// Exercise real Qt binding evaluation and delegate destruction with the
// production queues. The parent's matrix covers the actual PanelWindow,
// Quickshell ScriptModel, pointer, output and fullscreen integration.
Item {
    id: fixture
    width: 400
    height: 400
    property var rows: []
    property string outputName: "A"
    property var heldGroups: ({})
    readonly property var toastGroups: Policy.groups(rows)
    readonly property var holdQueue: Holds.create(callback => Qt.callLater(callback),
        groups => { fixture.heldGroups = groups; })

    Item {
        id: surface
        readonly property var screenGroups: fixture.toastGroups.map(group => ({
            key: group.key, items: group.items.filter(entry => entry.screenName === fixture.outputName)
        })).filter(group => group.items.length > 0)
        readonly property var groupKeys: screenGroups.map(group => group.key)

        Repeater {
            id: decks
            model: surface.groupKeys
            delegate: Item {
                id: deck
                required property var modelData
                readonly property var group: surface.screenGroups.find(group => group.key === modelData)
                    || ({items: []})
                property bool focusedWithin: false
                readonly property var focusHolds: Holds.create(callback => Qt.callLater(callback),
                    groups => { deck.focusedWithin = !!groups.focus; })
                onFocusedWithinChanged: fixture.holdQueue.set(deck, modelData, focusedWithin)
                Component.onDestruction: {
                    focusHolds.dispose();
                    fixture.holdQueue.set(deck, modelData, false);
                }
                Repeater {
                    model: deck.group.items
                    delegate: Item {
                        id: card
                        required property var modelData
                        Component.onCompleted: deck.focusHolds.set(card, "focus", true)
                        Component.onDestruction: deck.focusHolds.set(card, "focus", false)
                    }
                }
            }
        }
    }

    TestCase {
        name: "NotificationHoldLifecycle"
        function init() {
            failOnWarning(/.*/);
        }
        function test_model_rebuild_output_removal_and_queued_focus_cleanup() {
            for (let i = 0; i < 24; ++i) {
                fixture.rows = [
                    {sourceKey: "one", key: "first-" + i, screenName: "A"},
                    {sourceKey: "one", key: "second-" + i, screenName: "A"},
                    {sourceKey: "two", key: "third-" + i, screenName: "B"}
                ];
                compare(surface.screenGroups.length, 1);
                tryVerify(() => fixture.holdQueue.isHeld("one"));
                fixture.outputName = "B";
                compare(surface.screenGroups[0].key, "two");
                tryVerify(() => fixture.holdQueue.isHeld("two") && !fixture.holdQueue.isHeld("one"));
                fixture.rows = [];
                compare(surface.screenGroups.length, 0);
                tryVerify(() => Object.keys(fixture.heldGroups).length === 0);
                fixture.outputName = "A";
                // Tear down before either queued focus publisher runs.
                fixture.rows = [{sourceKey: "transient", key: "transient-" + i, screenName: "A"}];
                compare(surface.screenGroups.length, 1);
                fixture.rows = [];
                compare(surface.screenGroups.length, 0);
                wait(0);
                verify(!fixture.holdQueue.isHeld("transient"));
            }
        }
    }
}
