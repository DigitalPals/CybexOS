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
        runPolkitLifecycle();
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

    function descendant(item, name) {
        if (item.objectName === name) return item;
        for (const child of item.children || []) {
            const result = descendant(child, name);
            if (result) return result;
        }
        return null;
    }

    // Drive the shipped view with a PAM-like conversation: these fixtures
    // never register an agent or authenticate against the host system.
    function runPolkitLifecycle() {
        const conversation = polkitFlow.createObject(harness);
        const next = polkitFlow.createObject(harness);
        const view = polkitView.createObject(harness, { flow: conversation });
        root.check(view !== null, "Polkit prompt did not construct");
        if (!view) return;
        const field = descendant(view, "polkitResponse");
        const reveal = descendant(view, "polkitReveal");
        root.check(field !== null && reveal !== null, "Polkit controls are missing");
        if (field && reveal) {
            view.focusResponse();
            root.check(field.focus, "Polkit did not focus the response field");
            root.check(field.echoMode === TextInput.Password, "secret prompt is not masked");
            field.text = "fixture response";
            reveal.triggered();
            root.check(field.echoMode === TextInput.Normal, "reveal does not show the response");
            view.submit();
            root.check(conversation.received === "fixture response", "response was not submitted intact");
            root.check(field.text === "" && !view.revealed, "submit retained a response or reveal state");
            view.submit();
            root.check(conversation.submissions === 1, "double submission was accepted while waiting");

            conversation.authenticationFailed();
            conversation.isResponseRequired = true;
            root.check(view.hasError, "retry lacks an error indication");
            root.check(field.echoMode === TextInput.Password, "retry reused reveal state");
            field.text = "discard on account switch";
            conversation.selectedIdentity = conversation.identities[1];
            root.check(field.text === "" && !view.attemptFailed, "account switch retained response or error");
            root.check(view.account === "Admin (admin)", "selected identity label is incorrect");

            conversation.inputPrompt = "Verification code:";
            conversation.responseVisible = true;
            root.check(field.echoMode === TextInput.Normal && !reveal.visible,
                "visible PAM response is incorrectly treated as a password");
            field.text = "discard on prompt change";
            conversation.inputPrompt = "Password:";
            conversation.responseVisible = false;
            root.check(field.text === "", "new prompt retained the previous response");

            field.text = "discard on next request";
            view.detailsOpen = true;
            view.flow = next;
            root.check(field.text === "" && !view.detailsOpen, "next request retained conversation state");
            field.text = "discard on cancellation";
            view.cancel();
            root.check(next.isCancelled && field.text === "", "cancel did not clear and abort the request");

            view.flow = conversation;
            field.text = "discard on remote cancellation";
            conversation.isCancelled = true;
            root.check(field.text === "" && !field.enabled, "remote cancellation retained an enabled input");
            conversation.isCancelled = false;
            field.text = "discard on success";
            conversation.isCompleted = true;
            root.check(field.text === "" && !field.enabled, "completed flow retained an enabled input");
            view.flow = null;
            root.check(view.finished, "removed flow is still actionable");
        }
        view.destroy();
        conversation.destroy();
        next.destroy();
    }

    Component {
        id: polkitView
        PolkitPrompt { width: 392 }
    }
    Component {
        id: polkitFlow
        QtObject {
            property string message: "Authenticate to unlock the fixture"
            property string actionId: "org.cybexos.fixture"
            property var identities: [
                { string: "john", displayName: "John Example" },
                { string: "admin", displayName: "Admin" }
            ]
            property var selectedIdentity: identities[0]
            property bool isResponseRequired: true
            property bool isCompleted: false
            property bool isCancelled: false
            property bool responseVisible: false
            property string inputPrompt: "Password:"
            property string supplementaryMessage: ""
            property bool supplementaryIsError: false
            property string received: ""
            property int submissions: 0
            signal authenticationFailed()
            function submit(value) {
                received = value;
                submissions++;
                isResponseRequired = false;
            }
            function cancelAuthenticationRequest() { isCancelled = true; }
        }
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
