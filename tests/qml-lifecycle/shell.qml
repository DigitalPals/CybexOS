pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import "Common" as Common
import "Common/SettingsHelpers.js" as SettingsHelpers
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

    function descendants(item, predicate) {
        const found = [];
        for (const child of item.children) {
            if (predicate(child))
                found.push(child);
            found.push(...descendants(child, predicate));
        }
        return found;
    }

    // The Network page's VPN and Hotspot groups against a service whose
    // snapshot is set by hand: no helper runs, nothing reaches NetworkManager.
    function runNetworkGroups() {
        const service = networkServiceComponent.createObject(harness);
        service.snapshot = {
            vpns: [
                { uuid: "u-office", name: "Office", type: "vpn", label: "OpenVPN", state: "activated", timestamp: 2 },
                { uuid: "u-home", name: "home", type: "wireguard", label: "WireGuard", state: "", timestamp: 1 }
            ],
            hotspot: { available: true, supported: true, state: "", ssid: "Studio", uuid: "",
                dropsWifi: true, wifiConnection: "Home" }
        };
        service.loaded = true;
        const vpn = vpnGroupComponent.createObject(harness, { service: service });
        const hotspot = hotspotGroupComponent.createObject(harness, { service: service });
        root.check(vpn !== null, "VPN group did not construct");
        root.check(hotspot !== null, "hotspot group did not construct");
        if (vpn) {
            root.check(descendants(vpn, child => child.confirming !== undefined).length === 2,
                "VPN group did not list one row per profile");
            root.check(descendants(vpn, child => child.accessibleName === "Connect Office"
                && child.checked === true).length === 1, "a connected VPN's switch is not on");
        }
        if (hotspot) {
            root.check(hotspot.visible, "hotspot group hid on a computer with Wi-Fi");
            root.check(hotspot.name === "Studio", "hotspot name did not follow the saved name");
            service.snapshot = { vpns: [], hotspot: { available: true, supported: true, ssid: "Lab" } };
            root.check(hotspot.name === "Lab", "an untouched hotspot name did not follow a rename");
            service.snapshot = { vpns: [], hotspot: { available: false } };
            root.check(!hotspot.visible, "hotspot group shows without Wi-Fi");
            hotspot.destroy();
        }
        if (vpn)
            vpn.destroy();
        service.destroy();
    }

    Component {
        id: networkServiceComponent
        Common.SystemSettingsBackend { domain: "network" }
    }
    Component {
        id: vpnGroupComponent
        SettingsUi.VpnGroup { width: 560 }
    }
    Component {
        id: hotspotGroupComponent
        SettingsUi.HotspotGroup { width: 560 }
    }

    function runLifecycle() {
        runNetworkGroups();
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
        runThemeLifecycle();
        runCommandLifecycle();
    }

    // A named theme through the real Theme, Settings and Themes singletons:
    // `theme use` applies its palette with Undo, every floor holds, and the
    // Appearance page builds around the Theme row.
    function runThemeLifecycle() {
        const theme = Common.Theme;
        check(!theme.themePaletteActive && Qt.colorEqual(theme.background, "#1a1917"),
            "the default look changed without a theme");
        const palette = { mode: "dark", background: "#2e3440", surface: "#3b4252",
            surfaceRaised: "#434c5e", text: "#eceff4", textMuted: "#d8dee9", textDim: "#4c566a",
            red: "#bf616a", amber: "#ebcb8b", green: "#a3be8c" };
        const answer = Common.Themes.use(JSON.stringify({ id: "nord", name: "Nord", patch: {
            theme: "nord", themeMode: "dark", paletteMode: "fixed", accent: "#88c0d0",
            barColorMode: "custom", barCustomHue: 220, barCustomSaturation: 16,
            barCustomLightness: 22, themePalette: palette } }));
        check(answer === "ok", "theme use refused a valid theme: " + answer);
        check(theme.themePaletteActive && Qt.colorEqual(theme.background, "#2e3440")
            && Qt.colorEqual(theme.menuBg, "#434c5e"), "the theme palette is not drawn");
        const reference = theme.copyReferenceBg.toString();
        check(SettingsHelpers.contrastRatio(theme.textHi.toString(), reference) >= 7,
            "themed primary text is below 7:1");
        for (const name of ["textMid", "textLow", "textDim", "textFaint", "redText", "amber", "ok",
                "accentText"])
            check(SettingsHelpers.contrastRatio(theme[name].toString(), reference) >= 4.5,
                "themed " + name + " is below 4.5:1");
        check(Common.Settings.undoAvailable && Common.Settings.resetLabel === "Theme",
            "applying a theme offered no Undo");
        check(Common.Themes.use("{\"id\": \"x\"}").indexOf("error:") === 0,
            "theme use accepted an invalid payload");
        const page = appearanceComponent.createObject(harness);
        check(page !== null, "Appearance did not construct");
        if (page)
            page.destroy();
        Common.Settings.undoReset();
        check(!theme.themePaletteActive && Qt.colorEqual(theme.background, "#1a1917"),
            "Undo did not restore the previous look");
    }

    property int commandStage: 0
    property int commandCompletions: 0
    property bool commandsFinished: false
    property Common.CommandRequest request: null

    function runCommandLifecycle() {
        request = requestComponent.createObject(harness);
        check(request !== null, "CommandRequest did not construct");
        if (!request) { finishLifecycle(); return; }
        request.available.connect(() => Qt.callLater(root.nextCommand));
        request.completed.connect((code, body, error) => {
            commandCompletions++;
            if (commandStage === 0) {
                check(code === 0 && body === "ready", "successful command lost stdout");
            } else if (commandStage === 1) {
                check(code === -1, "missing executable did not settle as launch failure");
            } else if (commandStage === 2) {
                check(code === 124 && body === "", "timeout published partial output or success");
            } else if (commandStage === 3) {
                check(code === 0 && body === "after-timeout", "request slot did not recover after timeout");
            } else if (commandStage === 4) {
                check(code === 0 && body === "payload", "stdin request was not delivered");
            }
            commandStage++;
            Qt.callLater(root.nextCommand);
        });
        nextCommand();
    }

    function nextCommand() {
        if (commandsFinished || request.running)
            return;
        if (commandStage >= 5) {
            commandsFinished = true;
            check(commandCompletions === 5, "a command completed more than once");
            request.destroy();
            runDesktopLifecycle();
            return;
        }
        request.timeoutMs = commandStage === 2 ? 80 : 1000;
        request.killGraceMs = 80;
        request.stdinEnabled = commandStage === 4;
        request.inputText = "payload\n";
        request.command = commandStage === 0 ? ["/usr/bin/printf", "ready"]
            : commandStage === 1 ? ["/cybexos-test-executable-does-not-exist"]
            : commandStage === 2 ? ["/bin/sh", "-c", "trap '' TERM; printf partial; exec sleep 10"]
            : commandStage === 3 ? ["/usr/bin/printf", "after-timeout"]
            : ["/bin/sh", "-c", "IFS= read -r value; printf '%s' \"$value\""];
        request.running = true;
    }

    Component { id: requestComponent; Common.CommandRequest {} }

    // The window overview's view under the real engine with no compositor:
    // its bindings must settle on an empty desktop (only the new-workspace
    // slot) without a TypeError, and it must tear down cleanly. Then the
    // Top processes sampler runs the shipped helper against this machine's
    // /proc for two samples, which is what yields CPU shares.
    property int processPolls: 0

    function runDesktopLifecycle() {
        const screen = Quickshell.screens.length > 0 ? Quickshell.screens[0] : null;
        if (screen !== null) {
            const view = overviewComponent.createObject(harness,
                { output: screen, width: 1280, height: 720 });
            check(view !== null, "OverviewView did not construct");
            if (view) {
                check(view.tiles.length === 1 && view.tiles[0].isNew === true,
                    "an empty desktop is not just the new-workspace slot");
                check(view.layout.cells.length === 1, "the overview grid did not lay out");
                check(view.selected === "", "an empty overview selected something");
                view.query = "anything";
                check(!view.anyMatch, "a filter matched windows that do not exist");
                view.destroy();
            }
        }
        const list = Common.ProcessList;
        list.acquire();
        check(list.watchers === 1, "ProcessList did not take the claim");
        processPoll.start();
    }

    function finishProcessLifecycle() {
        const list = Common.ProcessList;
        check(list.loaded && list.error === "", "the process list did not load: " + list.error);
        check(list.rows.length > 0 && list.rows.length <= list.limit, "the process list has no rows");
        check(list.rows.some(row => row.cpu !== null), "a second sample gave no CPU shares");
        list.setMode("memory");
        const memory = list.rows.map(row => row.memory);
        check(memory.every((value, index) => index === 0 || value <= memory[index - 1]),
            "memory ranking is not descending");
        list.setMode("cpu");
        const own = list.all.find(row => list.canEnd(row));
        if (own) {
            list.requestEnd(own);
            check(list.confirming !== null && list.confirming.pid === own.pid,
                "End process did not ask first");
            list.cancel();
            check(list.confirming === null, "Cancel left the question armed");
        }
        list.release();
        check(list.watchers === 0 && list.confirming === null && list.ending === null,
            "releasing the last claim left state behind");
        finishLifecycle();
    }

    Timer {
        id: processPoll
        interval: 100
        repeat: true
        onTriggered: {
            root.processPolls++;
            const list = Common.ProcessList;
            if (root.processPolls < 50 && !(list.loaded && list.rows.some(row => row.cpu !== null)))
                return;
            stop();
            root.finishProcessLifecycle();
        }
    }

    Component {
        id: overviewComponent
        OverviewView {}
    }

    function finishLifecycle() {
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
        // pam_fprintd and pam_u2f announce their step without an input
        // request; the dialog names it and hides it once the password is due.
        const status = descendant(view, "polkitStatus");
        root.check(status !== null, "Polkit status line is missing");
        if (status) {
            const cue = polkitFlow.createObject(harness);
            view.flow = cue;
            cue.isResponseRequired = false;
            cue.supplementaryMessage = "Place your finger on the fingerprint reader";
            root.check(status.text === "Touch the fingerprint reader, or wait to enter your password.",
                "the fingerprint step is not described: " + status.text);
            cue.supplementaryIsError = true;
            cue.supplementaryMessage = "Failed to match fingerprint";
            root.check(status.text === "Failed to match fingerprint", "a fingerprint mismatch is hidden");
            cue.supplementaryIsError = false;
            cue.supplementaryMessage = "Place your finger on the fingerprint reader";
            root.check(status.text.startsWith("Not recognised. "), "a retried scan reads as the first");
            cue.isResponseRequired = true;
            root.check(status.text === "", "a finished fingerprint step speaks over the password field");
            cue.isResponseRequired = false;
            cue.supplementaryMessage = "Touch your security key";
            root.check(status.text === "Touch your security key, or wait to enter your password.",
                "the security-key step is not described: " + status.text);
            view.flow = null;
            cue.destroy();
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
        id: appearanceComponent
        SettingsUi.AppearancePage { width: 640; height: 1200 }
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
