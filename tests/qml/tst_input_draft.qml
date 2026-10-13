import QtQuick
import QtTest
import "../../roles/desktop/files/quickshell/Settings/InputDraft.js" as Draft

TestCase {
    name: "NativeInputDraft"
    function test_edit_is_isolated_and_only_changed_fields_are_sent() {
        const original = {layouts: [{layout: "us", variant: "intl"}], shortcut: "custom:future"};
        const current = Draft.clone(original);
        current.layouts = Draft.changeLayout(current.layouts, 0, "nl", "");
        compare(original.layouts[0].layout, "us");
        const patch = Draft.patch(current, original, ["layouts", "shortcut"]);
        verify(!("shortcut" in patch));
        compare(patch.layouts[0].layout, "nl");
        compare(patch.layouts[0].variant, "");
        patch.layouts[0].layout = "de";
        compare(current.layouts[0].layout, "nl");
    }
    function test_reordering_and_boundaries() {
        const layouts = [{layout: "us"}, {layout: "nl"}];
        compare(Draft.move(layouts, 1, -1)[0].layout, "nl");
        compare(layouts[0].layout, "us");
        compare(Draft.move(layouts, 0, -1)[0].layout, "us");
        compare(Draft.move(layouts, 1, 1)[1].layout, "nl");
    }
    function test_filter_preserves_selected_option_and_matches_codes() {
        const choices = [{value: "us", label: "English"}, {value: "nl", label: "Dutch"}, {value: "de", label: "German"}];
        const result = Draft.filtered(choices, " NL ", "us");
        compare(result.length, 2);
        compare(result[0].value, "us");
        compare(result[1].value, "nl");
        compare(Draft.filtered(choices, "german", "")[0].value, "de");
        compare(Draft.filtered(choices, "german", "custom")[0].value, "custom");
        compare(choices.length, 3);
    }
    function test_touchpad_changes_preserve_false_and_zero() {
        const original = {tap: true, naturalScroll: true, sensitivity: 0.5};
        const result = Draft.patch({tap: false, naturalScroll: true, sensitivity: 0}, original, Object.keys(original));
        compare(result.tap, false);
        compare(result.sensitivity, 0);
        verify(!("naturalScroll" in result));
    }
}
