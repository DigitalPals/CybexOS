pragma ComponentBehavior: Bound
import QtQuick
import "../Common"
import "../Common/DisplayHelpers.js" as Displays

// Settings -> Displays. Edits are drafted against the live outputs, applied
// as a trial that restores itself unless kept, and only then saved to
// ~/.config/cybexos/displays.json, which Hyprland reads through displays.lua.
//
// The arrangement is also the display picker: the group under it edits
// whichever display is selected there. Unlike the shell settings on the
// rest of the page, display edits wait — the Apply bar pinned to the page's
// foot names them, and during a trial counts down to the automatic revert
// (2026-09 redesign; the in-page Apply/Discard buttons and "Keep these
// display settings?" group are gone).
SettingsPage {
    id: page
    pageReset: true
    resetText: "Reset night light to defaults"
    bottomInset: applyBar.reservedHeight

    readonly property var service: DisplaySettings
    property var drafts: []
    property var baselineDrafts: []
    property string selectedKey: ""
    property int secondsLeft: 0
    // Load the next snapshot even with edits pending: after Keep or Revert
    // the drafts describe a state that is no longer the baselineDrafts.
    property bool resync: true
    // An outcome worth saying once the Apply bar has gone: the trial ran out.
    property string notice: ""
    readonly property var store: service.snapshot.store || ({})
    readonly property var loaderStatus: service.snapshot.status || null
    readonly property bool trialActive: service.preview !== null
    readonly property bool dirty: Displays.draftSignature(drafts) !== Displays.draftSignature(baselineDrafts)
    readonly property var changes: page.changeList(drafts, baselineDrafts)
    readonly property string problem: drafts.length ? Displays.validate(drafts) : ""
    readonly property var selected: drafts.find(draft => draft.key === selectedKey) || drafts[0] || null
    readonly property bool editable: !trialActive && !service.busy && service.loaded
    readonly property bool showRows: selected !== null && selected.enabled
    readonly property var groups: selected ? Displays.modeGroups(selected.availableModes) : []
    readonly property var selectedGroup: {
        if (!selected || selected.mode === "preferred")
            return null;
        const mode = selected.mode;
        return groups.find(group => group.width === mode.width && group.height === mode.height) || null;
    }
    readonly property string loaderError: {
        if (store.error)
            return store.error;
        if (loaderStatus && loaderStatus.error)
            return "Hyprland ignored the saved display settings: " + loaderStatus.error;
        return "";
    }
    // The selected display's group heading names the kind of display and its
    // maker; the connector and model follow as a note beneath it.
    readonly property var identity: {
        if (!selected)
            return { title: "", note: "" };
        const monitor = (service.snapshot.monitors || []).find(item => item.name === selected.name) || {};
        const clean = value => {
            const text = String(value || "").trim();
            return /^0x[0-9a-f]+$/i.test(text) ? "" : text;
        };
        const vendor = clean(monitor.make);
        const model = clean(monitor.model);
        const kind = /^(eDP|LVDS|DSI)/.test(selected.name) ? "Built-in display" : "External display";
        return {
            title: kind + (vendor !== "" ? " · " + vendor : ""),
            note: selected.name + (model !== "" ? " · " + model : "")
        };
    }

    function load() {
        const next = Displays.draftsFromSnapshot(service.snapshot.monitors || [], store.document || null);
        baselineDrafts = next;
        drafts = next;
        if (!next.some(draft => draft.key === selectedKey)) {
            const first = next.find(draft => draft.enabled) || next[0];
            selectedKey = first ? first.key : "";
        }
    }

    // What differs from the live outputs, in words for the Apply bar:
    // "scale", or "DP-1 scale" once there is more than one display. A move
    // anywhere counts once, as the arrangement.
    function changeList(next, before) {
        const list = [];
        let moved = false;
        const size = mode => mode === "preferred" ? "preferred" : mode.width + "x" + mode.height;
        for (const draft of next) {
            const old = before.find(item => item.key === draft.key);
            if (!old)
                continue;
            const add = what => list.push(next.length > 1 ? draft.name + " " + what : what);
            if (draft.enabled !== old.enabled)
                add(draft.enabled ? "turned on" : "turned off");
            if (size(draft.mode) !== size(old.mode))
                add("resolution");
            else if (draft.mode !== "preferred" && Math.abs(draft.mode.refresh - old.mode.refresh) >= 0.005)
                add("refresh rate");
            if (draft.scale !== old.scale)
                add("scale");
            if (draft.transform % 4 !== old.transform % 4)
                add("rotation");
            if ((draft.transform >= 4) !== (old.transform >= 4))
                add("flip");
            if (draft.mirror !== old.mirror)
                add("mirroring");
            if (draft.vrr !== old.vrr)
                add("adaptive sync");
            if (draft.x !== old.x || draft.y !== old.y)
                moved = true;
        }
        if (moved)
            list.push("arrangement");
        return list;
    }

    // Change one field of one draft. Geometry changes re-attach the other
    // displays around it; leaving or joining the layout re-packs it.
    function edit(key, change) {
        const before = drafts;
        const next = JSON.parse(JSON.stringify(drafts));
        const draft = next.find(item => item.key === key);
        if (!draft)
            return;
        const wasPlaced = draft.enabled && draft.mirror === "";
        Object.assign(draft, change);
        const isPlaced = draft.enabled && draft.mirror === "";
        // Anything mirroring a display that just left the layout stops.
        if (!isPlaced)
            for (const other of next)
                if (other.mirror === key)
                    other.mirror = "";
        if (isPlaced && !wasPlaced) {
            drafts = Displays.nudge(next, key, "right");
        } else if (!isPlaced && wasPlaced) {
            const anchor = next.find(item => item.enabled && item.mirror === "");
            drafts = anchor ? Displays.relayout(next, anchor.key, before) : next;
        } else if (isPlaced) {
            drafts = Displays.relayout(next, key, before);
        } else {
            drafts = next;
        }
    }

    function pickResolution(value) {
        if (!selected)
            return;
        if (value === "preferred") {
            edit(selected.key, { mode: "preferred" });
            return;
        }
        const group = groups.find(item => item.id === value);
        if (!group)
            return;
        const current = selected.mode === "preferred" ? null : selected.mode.refresh;
        const refresh = group.refreshes.find(rate => current !== null && Math.abs(rate - current) < 0.01)
            ?? group.refreshes[0];
        const change = { mode: { width: group.width, height: group.height, refresh: refresh } };
        if (selected.scale !== "auto" && !Displays.scaleValid(group.width, group.height, selected.scale))
            change.scale = "auto";
        edit(selected.key, change);
    }

    function applyChanges() {
        if (!dirty || problem !== "" || !editable)
            return;
        notice = "";
        // The bar's countdown starts full rather than from the last trial's end.
        secondsLeft = Displays.TRIAL_SECONDS;
        service.run({
            action: "apply",
            document: Displays.buildDocument(store.document || null, drafts),
            baseDigest: store.digest || "absent"
        });
    }

    function keep() {
        if (service.preview)
            service.run({ action: "confirm", checkpoint: service.preview.checkpoint });
    }

    function revert() {
        if (service.preview)
            service.run({ action: "rollback", checkpoint: service.preview.checkpoint });
    }

    // SettingsView asks the page first: Escape during a trial restores the
    // previous arrangement instead of closing Settings.
    function handleEscape(): bool {
        if (!trialActive)
            return false;
        if (!service.busy)
            revert();
        return true;
    }

    Claim {
        active: page.visible && Settings.panelOpen
        onClaimed: {
            page.resync = true;
            page.service.acquire();
        }
        onReleased: page.service.release()
    }

    Connections {
        target: page.service
        function onRefreshed() {
            if (page.resync || (!page.dirty && !page.trialActive)) {
                page.resync = false;
                page.load();
            }
        }
        function onCompleted(result) {
            const action = page.service.request.action;
            if (action !== "confirm" && action !== "rollback")
                return;
            // A kept trial is the new baseline; anything else leaves the
            // previous settings on screen. Settle the drafts now so the bar
            // does not flash the old edits back up until the next read.
            if (action === "confirm" && result.success)
                page.baselineDrafts = page.drafts;
            else
                page.drafts = page.baselineDrafts;
            // A revert at zero is the countdown's, not the user's: say so
            // once the bar has gone.
            if (action === "rollback" && result.success && page.secondsLeft === 0)
                page.notice = "The trial ran out, so the previous display settings are back.";
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
            page.secondsLeft = Displays.secondsLeft(page.service.preview.expires, Date.now());
            if (page.secondsLeft === 0 && !page.service.busy)
                page.revert();
        }
    }

    overlay: ApplyBar {
        id: applyBar
        pending: page.dirty && !page.trialActive
        trial: page.trialActive
        busy: page.service.busy
        title: page.trialActive ? "Keep these display settings?"
            : page.changes.length === 1 ? "1 change not applied yet"
            : page.changes.length + " changes not applied yet"
        // Apply stays pressable while a problem stands; applyChanges()
        // refuses, and the problem is the line under the title.
        detail: page.trialActive
            ? "The previous settings return in " + page.secondsLeft + " s. Escape restores them now."
            : page.problem !== "" ? page.problem
            : page.service.error !== "" ? page.service.error
            : page.changes.join(", ").replace(/^./, first => first.toUpperCase())
        remaining: page.secondsLeft / Displays.TRIAL_SECONDS
        onApply: page.applyChanges()
        onDiscard: page.load()
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
            notice: page.trialActive ? "" : page.notice
        }
        SettingsHint {
            width: parent.width
            text: page.loaderError
            tone: "warning"
        }

        SettingsGroup {
            width: parent.width
            title: "Arrangement"

            DisplayArrangement {
                width: parent.width
                enabled: page.editable
                drafts: page.drafts
                selectedKey: page.selected ? page.selected.key : ""
                onSelected: key => page.selectedKey = key
                onMoved: (key, x, y) => page.drafts = Displays.moveDisplay(page.drafts, key, x, y)
                onNudged: (key, direction) => page.drafts = Displays.nudge(page.drafts, key, direction)
            }
            SettingsHint {
                width: parent.width
                text: page.drafts.length > 1
                    ? "Drag displays to match where they stand, or select one to change it below. Arrow keys place the focused display beside the others."
                    : "Connect another display to arrange them side by side."
            }
        }

        SettingsGroup {
            width: parent.width
            visible: page.selected !== null
            title: page.identity.title
            enabled: page.editable

            SettingsHint {
                width: parent.width
                text: page.identity.note
            }
            SwitchRow {
                width: parent.width
                label: "Use this display"
                checked: page.selected ? page.selected.enabled : false
                description: "A display turned off here turns back on by itself when the displays it was turned off beside are disconnected."
                disabledReason: page.selected && page.selected.enabled
                    && !Displays.canDisable(page.drafts, page.selected.key)
                    ? "At least one display must stay on." : ""
                onToggled: value => page.edit(page.selected.key, { enabled: value })
            }
            SystemChoice {
                width: parent.width
                visible: page.showRows
                label: "Resolution"
                choices: page.selected ? [{ value: "preferred",
                    label: "Preferred (" + Displays.sizeLabel(page.selected.liveWidth, page.selected.liveHeight) + ")" }]
                    .concat(page.groups.map(group => ({ value: group.id, label: group.label }))) : []
                current: !page.selected ? "" : page.selected.mode === "preferred" ? "preferred"
                    : page.selected.mode.width + "x" + page.selected.mode.height
                onPicked: value => page.pickResolution(value)
            }
            SystemChoice {
                width: parent.width
                visible: page.showRows && page.selectedGroup !== null
                label: "Refresh rate"
                choices: page.selectedGroup ? page.selectedGroup.refreshes.map(rate =>
                    ({ value: rate, label: Displays.refreshLabel(rate) })) : []
                current: page.selectedGroup ? page.selected.mode.refresh : 0
                onPicked: value => page.edit(page.selected.key, { mode: {
                    width: page.selected.mode.width, height: page.selected.mode.height, refresh: value } })
            }
            SystemChoice {
                width: parent.width
                visible: page.showRows
                label: "Scale"
                choices: {
                    if (!page.selected)
                        return [];
                    const size = page.selected.mode === "preferred"
                        ? { width: page.selected.liveWidth, height: page.selected.liveHeight }
                        : page.selected.mode;
                    return Displays.scaleChoices(size.width, size.height,
                        typeof page.selected.scale === "number" ? page.selected.scale : undefined);
                }
                current: page.selected ? page.selected.scale : "auto"
                onPicked: value => page.edit(page.selected.key, { scale: value })
            }
            // Hyprland's transforms 4–7 are 0–3 flipped; the page splits
            // them into a rotation and a switch.
            PickerRow {
                width: parent.width
                visible: page.showRows
                label: "Rotation"
                model: Displays.TRANSFORMS
                current: page.selected ? page.selected.transform % 4 : 0
                onPicked: value => page.edit(page.selected.key,
                    { transform: value + (page.selected.transform >= 4 ? 4 : 0) })
            }
            SwitchRow {
                width: parent.width
                visible: page.showRows
                label: "Flipped"
                checked: page.selected ? page.selected.transform >= 4 : false
                description: "Mirrors the picture left to right"
                onToggled: value => page.edit(page.selected.key,
                    { transform: page.selected.transform % 4 + (value ? 4 : 0) })
            }
            SystemChoice {
                width: parent.width
                visible: page.showRows
                label: "Mirror"
                choices: page.selected ? [{ value: "", label: "Off" }].concat(
                    page.drafts.filter(draft => draft.key !== page.selected.key && draft.enabled
                        && draft.mirror === "").map(draft => ({ value: draft.key,
                            label: draft.label === draft.name ? draft.name : draft.name + " · " + draft.label }))) : []
                current: page.selected ? page.selected.mirror : ""
                hint: page.selected && page.selected.mirror !== ""
                    ? "Shows the same picture and leaves the arrangement" : ""
                onPicked: value => page.edit(page.selected.key, { mirror: value })
            }
            SystemChoice {
                width: parent.width
                visible: page.showRows
                label: "Adaptive sync"
                choices: Displays.VRR_CHOICES
                current: page.selected ? page.selected.vrr : -1
                hint: "Default keeps CybexOS's policy for this display. Fullscreen enables variable refresh only for fullscreen windows."
                onPicked: value => page.edit(page.selected.key, { vrr: value })
            }
            SettingsHint {
                width: parent.width
                text: "Saved per display in ~/.config/cybexos/displays.json. Monitor rules in ~/.config/cybexos/hypr/user.lua take precedence."
            }
        }

        NightLightGroup {
            width: parent.width
        }
    }
}
