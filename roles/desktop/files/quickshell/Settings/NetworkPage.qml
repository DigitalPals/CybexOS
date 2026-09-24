pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import "../Common"

// Settings -> Network: the saved Wi-Fi and wired connections NetworkManager
// knows, and the everyday settings of the one selected. Selecting a
// connection in the list opens it below as a draft; the Apply bar pinned to
// the page's foot names what changed, and applying an active connection runs
// a NetworkManager checkpoint that restores itself unless kept (2026-09
// redesign; the Saved connection dropdown and in-page Apply/Keep groups are
// gone).
SettingsPage {
    id: page
    bottomInset: applyBar.reservedHeight

    readonly property SystemSettingsBackend service: SystemSettings.network
    // The selected connection as NetworkManager last reported it, and the
    // page's edited copy of it.
    property var saved: null
    property var draft: null
    // Load the next snapshot even with edits pending: after Keep or Revert
    // the draft describes a state that is no longer the saved one.
    property bool resync: false
    property int secondsLeft: 0
    // The trial's length when this page first saw it, so the bar's line
    // starts full however long activation took.
    property real trialSpan: 60
    // An outcome worth saying once the Apply bar has gone.
    property string notice: ""
    readonly property var profiles: service.snapshot.profiles || []
    readonly property var devices: service.snapshot.devices || []
    readonly property bool trialActive: service.preview !== null
    readonly property var changes: page.changeList(draft, saved)
    readonly property bool dirty: changes.length > 0
    readonly property bool editable: draft !== null && draft.supported === true
        && !service.busy && !trialActive
    readonly property string problem: {
        if (!draft)
            return "";
        if (draft.ipv4.method === "disabled" && draft.ipv6.method === "disabled")
            return "Enable at least one IP version";
        return ipv4.problem || ipv6.problem;
    }
    readonly property var emptyIp: ({method: "auto", addresses: "", gateway: "", dns: "", autoDns: true})

    function copy(value) {
        return value ? JSON.parse(JSON.stringify(value)) : null;
    }

    function load(uuid) {
        const profile = profiles.find(p => p.uuid === uuid) || profiles[0] || null;
        saved = copy(profile);
        draft = copy(profile);
    }

    function discard() {
        draft = copy(saved);
    }

    function change(key, value) {
        const next = Object.assign({}, draft);
        next[key] = value;
        draft = next;
    }

    // What differs from the saved connection, in words for the Apply bar.
    // Address lists compare as lists, so a stray space is not a change.
    function changeList(next, before) {
        if (!next || !before)
            return [];
        const list = [];
        const same = (a, b) => String(a || "").split(/[,\s]+/).filter(part => part !== "").join(",")
            === String(b || "").split(/[,\s]+/).filter(part => part !== "").join(",");
        if (next.autoconnect !== before.autoconnect)
            list.push("autoconnect");
        if (next.metered !== before.metered)
            list.push("metered connection");
        for (const family of ["ipv4", "ipv6"]) {
            const a = next[family];
            const b = before[family];
            const name = family === "ipv4" ? "IPv4" : "IPv6";
            if (a.method !== b.method)
                list.push(name + " method");
            if (!same(a.addresses, b.addresses))
                list.push(name + " address");
            if (!same(a.gateway, b.gateway))
                list.push(name + " gateway");
            if (a.autoDns !== b.autoDns)
                list.push(name + " automatic DNS");
            if (!same(a.dns, b.dns))
                list.push(name + " DNS servers");
        }
        return list;
    }

    function applyChanges() {
        if (!dirty || problem !== "" || !editable)
            return;
        notice = "";
        // The bar's countdown starts full rather than from the last trial's end.
        secondsLeft = Math.ceil(trialSpan);
        service.run(Object.assign({}, draft, {action: "apply"}));
    }

    function keep() {
        if (service.preview)
            service.run(Object.assign({}, service.preview, {action: "confirm"}));
    }

    function revert() {
        if (service.preview)
            service.run({action: "rollback", checkpoint: service.preview.checkpoint});
    }

    onTrialActiveChanged: {
        if (trialActive && service.preview)
            trialSpan = Math.max(1, service.preview.expires - Date.now() / 1000);
    }

    Claim {
        active: page.visible && Settings.panelOpen
        onClaimed: {
            page.load(page.draft ? page.draft.uuid : "");
            page.service.acquire();
        }
        onReleased: {
            page.service.release();
            page.draft = null;
            page.saved = null;
        }
    }
    Connections {
        target: page.service
        function onSnapshotChanged() {
            if (page.resync || (!page.dirty && !page.trialActive)) {
                page.resync = false;
                page.load(page.draft ? page.draft.uuid : "");
            }
        }
        function onCompleted(result) {
            const request = page.service.request;
            if (!result.success) {
                // A failed confirm or revert leaves NetworkManager on the
                // previous settings; a failed apply keeps the edits to fix.
                if (request.action === "confirm" || request.action === "rollback") {
                    page.discard();
                    page.resync = true;
                }
                return;
            }
            if (result.checkpoint)
                return;
            if (request.action === "confirm") {
                // Kept: the edits are the connection now, at the version the
                // trial left it at.
                const kept = page.copy(page.draft);
                if (kept && request.version)
                    kept.version = request.version;
                page.draft = kept;
                page.saved = page.copy(kept);
            } else if (request.action === "apply") {
                // An inactive connection saves without a trial.
                page.saved = page.copy(page.draft);
                page.notice = result.message || "";
            } else {
                page.discard();
            }
            page.resync = true;
        }
    }
    Timer {
        interval: 500
        running: page.trialActive
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            if (!page.service.preview)
                return;
            page.secondsLeft = Math.max(0, Math.ceil(page.service.preview.expires - Date.now() / 1000));
            if (page.secondsLeft === 0 && !page.service.busy) {
                // NetworkManager owns this timeout and restores by itself.
                page.service.preview = null;
                page.notice = "The trial ran out, so NetworkManager restored the previous settings.";
                page.discard();
                page.resync = true;
                page.service.refresh();
            }
        }
    }

    overlay: ApplyBar {
        id: applyBar
        pending: page.dirty && !page.trialActive
        trial: page.trialActive
        busy: page.service.busy
        title: page.trialActive ? "Keep these network settings?"
            : page.changes.length === 1 ? "1 change not applied yet"
            : page.changes.length + " changes not applied yet"
        // A standing problem disables Apply and is the line under the title;
        // applyChanges() refuses as well.
        applyEnabled: page.problem === ""
        detail: page.trialActive
            ? "Check your connection. NetworkManager restores the previous settings in "
                + page.secondsLeft + " s."
            : page.problem !== "" ? page.problem
            : page.service.error !== "" ? page.service.error
            : page.changes.join(", ").replace(/^./, first => first.toUpperCase())
        remaining: page.secondsLeft / page.trialSpan
        onApply: page.applyChanges()
        onDiscard: page.discard()
        onKeep: page.keep()
        onRevert: page.revert()
    }

    Column {
        width: parent.width
        spacing: Theme.settingsGroupSpacing

        SystemServiceStatus {
            width: parent.width
            service: page.service
            // The Apply bar says "Applying…" itself.
            showBusy: false
            notice: page.trialActive || page.dirty ? "" : page.notice
        }

        SettingsGroup {
            width: parent.width
            title: "Connections"

            Repeater {
                model: ScriptModel {
                    values: page.profiles.map(profile => profile.uuid)
                }
                delegate: ChoiceRow {
                    id: connection
                    required property string modelData
                    readonly property var profile: page.profiles.find(p => p.uuid === connection.modelData)
                        || ({name: "", kind: "", active: false})
                    readonly property bool wireless: profile.kind === "802-11-wireless"
                    width: parent ? parent.width : 0
                    glyph: wireless ? "wifi" : "lan"
                    label: profile.name
                    detail: wireless ? "Wi-Fi" : "Ethernet"
                    meta: profile.active ? "Connected" : ""
                    opens: true
                    checked: page.draft !== null && page.draft.uuid === connection.modelData
                    // Another connection would drop the edits made here.
                    enabled: !page.trialActive && !page.service.busy && (!page.dirty || checked)
                    onActivated: page.load(connection.modelData)
                }
            }
            SettingsHint {
                width: parent.width
                text: page.service.loaded && page.profiles.length === 0
                    ? "No saved Wi-Fi or wired connections yet." : ""
            }
            SettingsHint {
                width: parent.width
                text: page.dirty && page.draft
                    ? "Apply or discard the changes to " + page.draft.name + " to edit another connection."
                    : ""
            }
            SettingsHint {
                width: parent.width
                text: !page.service.loaded ? ""
                    : page.devices.length === 0 ? "No physical network adapters"
                    : (page.devices.length === 1 ? "Adapter: " : "Adapters: ")
                        + page.devices.map(device => device.name).join(", ")
            }
            ActionRow {
                width: parent.width
                hint: "VPN, enterprise certificates, bridges and routing are in the advanced editor."

                SettingsAction {
                    text: "Connect to Wi-Fi…"
                    glyph: "wifi"
                    onTriggered: {
                        Settings.closePanel();
                        Popouts.openPanel("wifi", "right");
                    }
                }
                SettingsAction {
                    text: "Advanced connection editor"
                    glyph: "open_in_new"
                    enabled: !SystemSettings.externalBusy
                    onTriggered: SystemSettings.openExternal("network")
                }
            }
        }

        SettingsGroup {
            width: parent.width
            visible: page.draft !== null
            title: page.draft ? page.draft.name : ""
            enabled: page.editable

            SettingsHint {
                width: parent.width
                text: page.draft && !page.draft.supported
                    ? "This connection uses IP settings only the advanced connection editor can change." : ""
            }
            SwitchRow {
                width: parent.width
                label: "Autoconnect"
                checked: page.draft ? page.draft.autoconnect : false
                description: "Connect automatically when this network is available"
                onToggled: value => page.change("autoconnect", value)
            }
            PickerRow {
                width: parent.width
                label: "Metered connection"
                model: [{value: 0, label: "Automatic"}, {value: 1, label: "Yes"}, {value: 2, label: "No"}]
                current: page.draft ? page.draft.metered : 0
                hint: "Tells apps to limit background data"
                onPicked: value => page.change("metered", value)
            }
        }
        IpSettings {
            id: ipv4
            width: parent.width
            visible: page.draft !== null
            enabled: page.editable
            title: "IPv4"
            config: page.draft ? page.draft.ipv4 : page.emptyIp
            onEdited: value => page.change("ipv4", value)
        }
        IpSettings {
            id: ipv6
            width: parent.width
            visible: page.draft !== null
            enabled: page.editable
            title: "IPv6"
            config: page.draft ? page.draft.ipv6 : page.emptyIp
            onEdited: value => page.change("ipv6", value)
        }
    }
}
