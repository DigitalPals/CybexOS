import QtQuick
import QtTest
import "../../roles/desktop/files/quickshell/Common/Persistence" as Common
import "../../roles/desktop/files/quickshell/Common/SettingsHelpers.js" as Helpers

Item {
    Component { id: factory; Common.SettingsDocument {} }
    Timer {
        id: asynchronousCommit
        property var callback: null
        interval: 5
        onTriggered: if (callback) callback()
    }

    TestCase {
        name: "SettingsDocumentLifecycle"
        property var document: null

        function init() {
            document = factory.createObject(parent, { values: Helpers.defaults() });
            verify(document !== null);
        }

        function cleanup() {
            asynchronousCommit.stop();
            asynchronousCommit.callback = null;
            document.destroy();
        }

        function test_default_choice_is_explicit_and_reset_releases_it() {
            compare(JSON.parse(document.text()), { v: Helpers.VERSION });
            document.explicitKeys = ["barHeight"];
            compare(JSON.parse(document.text()).barHeight, Helpers.defaults().barHeight);
            document.explicitKeys = [];
            verify(!("barHeight" in JSON.parse(document.text())));
        }

        function test_unknown_fields_survive_a_real_qml_save_cycle() {
            document.source = { v: 26, future: { opaque: [1, "keep"] },
                modOpts: { weather: { place: "Home", futureOption: true } } };
            document.explicitKeys = ["modOpts"];
            document.values = Helpers.merge(document.source);
            verify(document.begin());
            const saved = document.submitted;
            compare(JSON.parse(saved).future.opaque, [1, "keep"]);
            verify(JSON.parse(saved).modOpts.weather.futureOption);
            const complete = document.complete(saved);
            verify(!complete.pending);
            verify(!document.busy);
            compare(document.baseline, saved);
        }

        function test_edit_during_write_rebases_on_external_changes() {
            document.source = { v: Helpers.VERSION, barHeight: 40 };
            document.explicitKeys = ["barHeight"];
            document.values = Helpers.merge(document.source);
            document.baseline = JSON.stringify(document.source);
            verify(document.begin());
            verify(!document.begin(), "a second writer must not overlap");
            const next = Helpers.clone(document.values);
            next.unit = "f";
            document.values = next;
            document.explicitKeys = ["barHeight", "unit"];
            // The atomic writer merged an independent edit from another process.
            const saved = JSON.stringify({ v: Helpers.VERSION, barHeight: 40,
                themeMode: "light", future: "external" });
            const result = document.complete(saved);
            verify(result.pending);
            compare(result.values.unit, "f");
            compare(result.values.themeMode, "light");
            document.values = result.values;
            const second = JSON.parse(document.text());
            compare(second.unit, "f");
            compare(second.future, "external");
            verify(document.begin());
            verify(!document.complete(document.submitted).pending);
        }

        function test_failed_write_keeps_pending_values_for_retry() {
            document.explicitKeys = ["themeMode"];
            const next = Helpers.clone(document.values);
            next.themeMode = "light";
            document.values = next;
            verify(document.begin());
            const candidate = document.submitted;
            document.abandon();
            verify(!document.busy);
            verify(document.begin());
            compare(document.submitted, candidate);
        }

        function test_reset_retains_unknown_nested_fields() {
            document.source = { v: Helpers.VERSION,
                modOpts: { weather: { place: "Chosen", futureOption: "keep" } },
                futureRoot: [1, 2] };
            document.values = Helpers.merge(document.source);
            document.explicitKeys = [];
            const reset = JSON.parse(document.text());
            compare(reset.modOpts.weather, { futureOption: "keep" });
            compare(reset.futureRoot, [1, 2]);
            compare(Helpers.overrideKeys(reset), []);
        }

        function test_event_loop_edit_survives_delayed_completion_and_reload() {
            document.source = { v: Helpers.VERSION, unit: "c" };
            document.explicitKeys = ["unit"];
            document.values = Helpers.merge(document.source);
            verify(document.begin());
            const first = document.submitted;
            let completed = false;
            asynchronousCommit.callback = function() {
                const result = document.complete(first);
                verify(result.pending);
                compare(result.values.unit, "f");
                document.values = result.values;
                completed = true;
            };
            asynchronousCommit.start();
            Qt.callLater(function() {
                const edited = Helpers.clone(document.values);
                edited.unit = "f";
                document.values = edited;
            });
            tryVerify(() => completed);
            verify(document.begin());
            const second = document.complete(document.submitted);
            verify(!second.pending);
            compare(Helpers.merge(JSON.parse(document.baseline)).unit, "f");
        }

        function test_concurrent_same_key_is_rejected() {
            let failed = false;
            try {
                Helpers.rebaseDocuments({ unit: "c" }, { unit: "f" }, { unit: "other" });
            } catch (_) { failed = true; }
            verify(failed);
        }

        function test_legacy_default_equality_never_resets_a_choice() {
            const chosen = Helpers.merge({ v: 3, font: "oppo", barHeight: 30,
                barRadius: 9, gap: 8, accent: "#9ecbeb" });
            compare(chosen.font, "oppo");
            compare(chosen.barHeight, 30);
            compare(chosen.gap, 8);
            compare(chosen.accent, "#9ecbeb");
            compare(Helpers.merge({ v: 6, font: "urbanist" }).font, "urbanist");
        }
    }
}
