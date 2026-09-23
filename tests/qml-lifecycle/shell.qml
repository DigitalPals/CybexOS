pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import "Common" as Common
import "Settings" as SettingsUi
import "Popovers/Drawer" as DrawerUi

// tests/run overlays this file on an isolated copy of the production config
// before launching the real `qs` engine (never beside an existing live qs).
// Keeping dependencies inside the selected config root matches production and
// avoids Quickshell's intentional qrc:/qs-blackhole for out-of-root modules.
ShellRoot {
    id: root

    property bool failed: false
    property int toggles: 0
    property int actions: 0
    property Common.Revealer revealer: null
    property Common.Toggle toggle: null
    property SettingsUi.SettingsAction action: null
    property Common.StatusPlaceholder status: null

    function check(condition, message) {
        if (condition)
            return;
        failed = true;
        console.error("LIFECYCLE_FAIL " + message);
    }

    function runLifecycle() {
        root.revealer = revealerComponent.createObject(harness, { reveal: false });
        root.toggle = toggleComponent.createObject(harness);
        root.action = actionComponent.createObject(harness);
        root.status = statusComponent.createObject(harness,
            { kind: "loading", shown: true });
        root.check(root.revealer !== null, "Revealer did not construct");
        root.check(root.toggle !== null, "Toggle did not construct");
        root.check(root.action !== null, "SettingsAction did not construct");
        root.check(root.status !== null, "StatusPlaceholder did not construct");
        if (!root.failed) {
            root.check(root.revealer.implicitHeight === 0,
                "closed Revealer has non-zero height");
            root.toggle.toggled.connect(value => root.toggles += value ? 1 : 10);
            root.action.triggered.connect(() => root.actions++);
            root.revealer.reveal = true;
            root.toggle.toggled(true);
            root.action.triggered();
            root.status.kind = "error";
            root.check(root.revealer.implicitHeight === 28,
                "open Revealer did not adopt child height");
            root.check(root.toggles === 1, "Toggle signal was not delivered once");
            root.check(root.actions === 1, "Action signal was not delivered once");
            root.check(root.status.kind === "error", "Status state did not update");
            root.revealer.destroy();
            root.toggle.destroy();
            root.action.destroy();
            root.status.destroy();
        }
        // Warnings are mirrored to stderr by qs even without detailed-log
        // decoding, which makes the result observable to the shell driver.
        console.warn(root.failed ? "LIFECYCLE_RESULT fail" : "LIFECYCLE_RESULT pass");
        // A minimal ShellRoot has no production IPC object through which the
        // test driver can request shutdown. Terminate this exact test PID
        // after logging; timeout remains the outer leak guard.
        Quickshell.execDetached(["/usr/bin/bash", "-c",
            "sleep 0.2; kill -TERM -- \"$1\"", "bash", String(Quickshell.processId)]);
    }

    Component {
        id: revealerComponent
        Common.Revealer {
            Rectangle { width: 96; height: 28 }
        }
    }
    Component {
        id: toggleComponent
        Common.Toggle { accessibleName: "Lifecycle switch" }
    }
    Component {
        id: actionComponent
        SettingsUi.SettingsAction { text: "Refresh"; glyph: "refresh" }
    }
    Component {
        id: statusComponent
        Common.StatusPlaceholder {
            width: 360
            title: "Nothing here"
            detail: "A stable empty state"
        }
    }

    Item {
        id: harness
        width: 640
        height: 480
    }

    // Exercise production positioners after polish, not a duplicate formula.
    function checkLayouts() {
        const rows = [];
        for (const size of [320, 540, 700]) {
            rows.push(pickerComponent.createObject(harness, { width: size }));
        }
        const tabs = [160, 320, 400].map(size =>
            tabsComponent.createObject(harness, { width: size }));
        const fieldRow = fieldComponent.createObject(harness);
        const collapsibleGroup = groupComponent.createObject(harness);
        const subsection = subsectionComponent.createObject(harness);
        const heading = headingComponent.createObject(harness);
        Qt.callLater(() => {
            for (const row of rows) {
                root.check(row !== null, "picker did not construct");
                if (!row)
                    continue;
                const pills = row.children.find(child => child.model !== undefined);
                root.check(pills && pills.x >= Common.Theme.settingsMarkInset,
                    "picker lost the label gutter");
                if (pills) {
                    root.check(pills.y + pills.height <= row.height + 1,
                        "wrapped picker paints over the next row at " + row.width);
                    root.check(pills.x + pills.width <= row.contentRight + 1,
                        "picker paints under the reset lane at " + row.width);
                }
                row.destroy();
            }
            root.check(subsection !== null && subsection.height > 40,
                "subsection failed to include header and content");
            root.check(heading !== null && heading.height > Common.Theme.sectionHeaderHeight,
                "long section heading did not grow");
            for (const strip of tabs) {
                root.check(strip !== null, "drawer tabs did not construct");
                if (!strip) continue;
                const lane = strip.children.find(child => child.children
                    && child.children.some(item => item.modelData !== undefined));
                root.check(lane !== undefined, "drawer tab lane missing");
                if (lane) {
                    const segments = lane.children.filter(item => item.modelData !== undefined);
                    root.check(segments.every(item => item.width >= 0
                        && item.x + item.width <= lane.width + 1),
                        "drawer tabs exceed their host at " + strip.width);
                }
                strip.destroy();
            }
            root.check(fieldRow !== null, "settings field row did not construct");
            const field = fieldRow ? fieldRow.children.find(child =>
                child.placeholderText !== undefined) : null;
            root.check(field !== null && field !== undefined, "shared settings field missing");
            if (field) {
                field.text = "  renamed  ";
                field.editingFinished();
                root.check(fieldRow.value === "renamed", "field commit/normalization regressed");
            }
            if (subsection) subsection.destroy();
            if (heading) heading.destroy();
            const groupColumn = collapsibleGroup.children.find(child =>
                typeof child.forceLayout === "function");
            groupColumn.forceLayout();
            const expandedHeight = collapsibleGroup.height;
            collapsibleGroup.extraVisible = false;
            groupColumn.forceLayout();
            Qt.callLater(() => {
                root.check(collapsibleGroup.height < expandedHeight - 30,
                    "hidden trailing group content leaves stale whitespace: " + expandedHeight + " -> " + collapsibleGroup.height);
                collapsibleGroup.destroy();
                if (field) root.check(field.text === "renamed", "field did not reflect normalized value");
                if (fieldRow) fieldRow.destroy();
                root.runLifecycle();
            });
        });
    }

    Component {
        id: pickerComponent
        SettingsUi.PickerRow {
            label: "Wrapping options"
            caption: "A caption"
            model: [
                { value: "a", label: "First long option" },
                { value: "b", label: "Second long option" },
                { value: "c", label: "Third long option" }
            ]
        }
    }
    Component {
        id: subsectionComponent
        SettingsUi.SettingsSubsection {
            width: 320
            title: "Palette preview"
            insetContent: true
            Rectangle { width: parent.width; height: 40 }
        }
    }
    Component {
        id: headingComponent
        SettingsUi.SectionHeader {
            width: 260
            label: "A LONG SECTION HEADING THAT MUST WRAP"
        }
    }
    Component {
        id: tabsComponent
        DrawerUi.DrawerTabs { current: "notifications" }
    }
    Component {
        id: fieldComponent
        SettingsUi.SettingsTextRow {
            width: 400
            label: "Test field"
            value: "original"
            onCommitted: text => value = text.trim()
        }
    }
    Component {
        id: groupComponent
        SettingsUi.SettingsGroup {
            id: group
            property bool extraVisible: true
            width: 400
            title: "Conditional content"
            Rectangle { width: parent.width; height: 28 }
            Rectangle { width: parent.width; height: 40; visible: group.extraVisible }
        }
    }
    Component.onCompleted: checkLayouts()
}
