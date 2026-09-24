pragma ComponentBehavior: Bound
import QtQuick
import "../Common"
import "../Common/DisplayHelpers.js" as Displays

// Settings -> Displays. Edits are drafted against the live outputs, applied
// as a trial that restores itself unless kept, and only then saved to
// ~/.config/cybexos/displays.json, which Hyprland reads through displays.lua.
SettingsPage {
    id: page

    readonly property var service: DisplaySettings
    property var drafts: []
    property var baselineDrafts: []
    property string selectedKey: ""
    property int secondsLeft: 0
    // Load the next snapshot even with edits pending: after Keep or Revert
    // the drafts describe a state that is no longer the baselineDrafts.
    property bool resync: true
    readonly property var store: service.snapshot.store || ({})
    readonly property var loaderStatus: service.snapshot.status || null
    readonly property bool trialActive: service.preview !== null
    readonly property bool dirty: Displays.draftSignature(drafts) !== Displays.draftSignature(baselineDrafts)
    readonly property string problem: drafts.length ? Displays.validate(drafts) : ""
    readonly property var selected: drafts.find(draft => draft.key === selectedKey) || drafts[0] || null
    readonly property bool editable: !trialActive && !service.busy && service.loaded
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

    function load() {
        const next = Displays.draftsFromSnapshot(service.snapshot.monitors || [], store.document || null);
        baselineDrafts = next;
        drafts = next;
        if (!next.some(draft => draft.key === selectedKey)) {
            const first = next.find(draft => draft.enabled) || next[0];
            selectedKey = first ? first.key : "";
        }
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
        if (!dirty || problem !== "")
            return;
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
            if (action === "confirm" || action === "rollback")
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

    Column {
        width: parent.width
        spacing: Theme.settingsGroupSpacing

        Column {
            width: parent.width
            spacing: Theme.settingsRowSpacing

            SettingsHint {
                width: parent.width
                text: page.service.error || (page.service.busy ? "Applying…"
                    : page.service.message || (!page.service.loaded ? "Loading…" : ""))
                tone: page.service.error ? "error" : "info"
            }
            SettingsHint {
                width: parent.width
                text: page.loaderError
                tone: "warning"
            }
        }

        SettingsGroup {
            width: parent.width
            visible: page.trialActive
            title: "Keep these display settings?"

            SettingsHint {
                width: parent.width
                text: "The previous settings return in " + page.secondsLeft
                    + " seconds. Revert now, press Escape or close this page to restore them sooner."
            }
            Flow {
                width: parent.width
                spacing: Theme.controlSpacing
                enabled: !page.service.busy

                SettingsAction {
                    text: "Keep changes"
                    glyph: "check"
                    onTriggered: page.keep()
                }
                SettingsAction {
                    text: "Revert now"
                    glyph: "undo"
                    onTriggered: page.revert()
                }
            }
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
                text: "Drag displays to match where they stand. With the arrangement focused, arrow keys place the selected display beside the others."
            }
            PickerRow {
                width: parent.width
                label: "Display"
                model: page.drafts.map(draft => ({ value: draft.key,
                    label: draft.name + (draft.enabled ? "" : " · off") }))
                current: page.selected ? page.selected.key : ""
                onPicked: value => page.selectedKey = value
            }
        }

        SettingsGroup {
            width: parent.width
            visible: page.selected !== null
            title: page.selected ? page.selected.label : ""
            enabled: page.editable

            SettingsHint {
                width: parent.width
                text: page.selected ? page.selected.name + " · " + (page.selected.description || "no description") : ""
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

            Column {
                width: parent.width
                spacing: Theme.settingsRowSpacing
                visible: page.selected !== null && page.selected.enabled

                SystemChoice {
                    width: parent.width
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
                    visible: page.selectedGroup !== null
                    label: "Refresh rate"
                    choices: page.selectedGroup ? page.selectedGroup.refreshes.map(rate =>
                        ({ value: rate, label: Displays.refreshLabel(rate) })) : []
                    current: page.selectedGroup ? page.selected.mode.refresh : 0
                    onPicked: value => page.edit(page.selected.key, { mode: {
                        width: page.selected.mode.width, height: page.selected.mode.height, refresh: value } })
                }
                PickerRow {
                    width: parent.width
                    label: "Scale"
                    model: {
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
                PickerRow {
                    width: parent.width
                    label: "Rotation"
                    model: page.selected && page.selected.transform > 3
                        ? Displays.TRANSFORMS.concat([{ value: page.selected.transform, label: "Flipped" }])
                        : Displays.TRANSFORMS
                    current: page.selected ? page.selected.transform : 0
                    onPicked: value => page.edit(page.selected.key, { transform: value })
                }
                SystemChoice {
                    width: parent.width
                    label: "Mirror"
                    choices: page.selected ? [{ value: "", label: "Off: show its own picture" }].concat(
                        page.drafts.filter(draft => draft.key !== page.selected.key && draft.enabled
                            && draft.mirror === "").map(draft => ({ value: draft.key,
                                label: "Mirror " + draft.name + " (" + draft.label + ")" }))) : []
                    current: page.selected ? page.selected.mirror : ""
                    onPicked: value => page.edit(page.selected.key, { mirror: value })
                }
                PickerRow {
                    width: parent.width
                    label: "Adaptive sync"
                    model: Displays.VRR_CHOICES
                    current: page.selected ? page.selected.vrr : -1
                    onPicked: value => page.edit(page.selected.key, { vrr: value })
                }
                SettingsHint {
                    width: parent.width
                    text: "Default keeps CybexOS's policy for this display. Fullscreen enables variable refresh only for fullscreen windows."
                }
            }
        }

        Column {
            width: parent.width
            spacing: Theme.settingsRowSpacing

            SettingsHint {
                width: parent.width
                visible: page.dirty && page.problem !== ""
                text: page.problem
                tone: "warning"
            }
            Flow {
                width: parent.width
                spacing: Theme.controlSpacing

                SettingsAction {
                    text: "Apply"
                    glyph: "check"
                    enabled: page.editable && page.dirty && page.problem === ""
                    onTriggered: page.applyChanges()
                }
                SettingsAction {
                    text: "Discard changes"
                    glyph: "undo"
                    enabled: page.editable && page.dirty
                    onTriggered: page.load()
                }
                SettingsAction {
                    text: "Refresh"
                    glyph: "refresh"
                    enabled: !page.service.busy && !page.service.loading
                    onTriggered: {
                        page.service.error = "";
                        page.service.refresh();
                    }
                }
            }
            SettingsHint {
                width: parent.width
                text: "Saved per display in ~/.config/cybexos/displays.json. Monitor rules in ~/.config/cybexos/hypr/user.lua take precedence."
            }
        }
    }
}
