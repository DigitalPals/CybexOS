import QtQuick
import "../Common"
import "InputDraft.js" as Draft

// Touchpad: how far a two-finger scroll moves. Pointer and keyboard settings
// would join it here.
SettingsPage {
    id: page
    pageReset: true
    readonly property SystemSettingsBackend service: SystemSettings.input
    property var draft: ({tap: true, naturalScroll: true, sensitivity: 0})
    property var original: ({tap: true, naturalScroll: true, sensitivity: 0})
    property string version: ""
    readonly property var changes: Draft.patch(draft, original, ["tap", "naturalScroll", "sensitivity"])
    readonly property bool dirty: Object.keys(changes).length > 0
    readonly property string disabledReason: service.busy ? "Applying…" : !service.loaded ? "Loading…" : ""
    bottomInset: applyBar.reservedHeight
    function load() {
        if (!service.loaded || !service.snapshot.touchpad) return;
        original = Draft.clone(service.snapshot.touchpad);
        draft = Draft.clone(original);
        version = service.snapshot.version;
    }
    function edit(key, value) {
        const updated = Draft.clone(draft);
        updated[key] = value;
        draft = updated;
    }
    Claim {
        active: page.visible && Settings.panelOpen
        onClaimed: { page.service.acquire(); page.load(); }
        onReleased: page.service.release()
    }
    Connections {
        target: page.service
        function onSnapshotChanged() { if (!page.dirty) page.load(); }
        function onLoadedChanged() { if (!page.dirty) page.load(); }
        function onCompleted(result) { if (result.success) page.original = Draft.clone(page.draft); }
    }
    overlay: ApplyBar {
        id: applyBar
        pending: page.dirty
        title: "Touchpad changes not applied yet"
        busy: page.service.busy
        onDiscard: page.load()
        onApply: page.service.run({action: "apply", section: "touchpad", version: page.version, values: page.changes})
    }

    Column {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Theme.settingsGroupSpacing
        SystemServiceStatus { width: parent.width; service: page.service; notice: page.service.message }

        SettingsGroup {
            width: parent.width
            title: "Touchpad"

            SwitchRow {
                width: parent.width
                label: "Tap to click"
                checked: page.draft.tap
                disabledReason: page.disabledReason
                onToggled: value => page.edit("tap", value)
            }
            SwitchRow {
                width: parent.width
                label: "Natural scrolling"
                description: "Move content in the direction your fingers move."
                checked: page.draft.naturalScroll
                disabledReason: page.disabledReason
                onToggled: value => page.edit("naturalScroll", value)
            }
            SliderRow {
                width: parent.width
                label: "Pointer sensitivity"
                hint: "Affects touchpads and mice. Per-device Hyprland rules take precedence."
                min: -1
                max: 1
                step: 0.05
                decimals: 2
                unit: ""
                value: page.draft.sensitivity
                disabledReason: page.disabledReason
                onMoved: value => page.edit("sensitivity", value)
            }

            SliderRow {
                width: parent.width
                label: "Scroll speed"
                settingKey: "scrollFactor"
                resetLabel: "Touchpad scroll speed"
                min: 0.2
                max: 2.0
                step: 0.1
                decimals: 1
                valueLabel: Settings.scrollFactor.toFixed(1) + "×"
                marks: [1.0]
                hint: "1.0× is Hyprland's default"
                dirty: Math.abs(Settings.scrollFactor - Settings.defaults.scrollFactor) > 0.001
            }
        }
    }
}
