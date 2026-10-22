import QtQuick
import "../Common"
import "InputDraft.js" as Draft

// Touchpad: how far a two-finger scroll moves. Pointer and keyboard settings
// would join it here.
SettingsPage {
    id: page
    pageReset: true
    readonly property InputDraftState editState: InputDrafts.touchpad
    readonly property var service: editState.service
    readonly property var draft: editState.draft
    readonly property bool dirty: editState.dirty
    readonly property string disabledReason: service.busy ? "Applying…" : !service.loaded ? "Loading…" : ""
    bottomInset: applyBar.reservedHeight
    function edit(key, value) {
        const updated = Draft.clone(draft);
        updated[key] = value;
        editState.draft = updated;
    }
    Claim {
        active: page.visible && Settings.panelOpen
        onClaimed: { page.service.acquire(); page.editState.refresh(); }
        onReleased: page.service.release()
    }
    overlay: ApplyBar {
        id: applyBar
        pending: page.dirty
        title: I18n.tr("Touchpad changes not applied yet")
        busy: page.service.busy
        onDiscard: page.editState.load()
        onApply: page.editState.apply()
    }

    Column {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Theme.settingsGroupSpacing
        SystemServiceStatus { width: parent.width; service: page.service; notice: page.service.message }

        SettingsGroup {
            width: parent.width
            title: I18n.tr("Touchpad")

            SwitchRow {
                width: parent.width
                label: I18n.tr("Tap to click")
                checked: page.draft.tap
                disabledReason: page.disabledReason
                onToggled: value => page.edit("tap", value)
            }
            SwitchRow {
                width: parent.width
                label: I18n.tr("Natural scrolling")
                description: I18n.tr("Move content in the direction your fingers move.")
                checked: page.draft.naturalScroll
                disabledReason: page.disabledReason
                onToggled: value => page.edit("naturalScroll", value)
            }
            SwitchRow {
                width: parent.width
                label: I18n.tr("Swipe between workspaces")
                description: I18n.tr("Swipe three fingers left or right.")
                checked: page.draft.workspaceSwipe
                disabledReason: page.disabledReason
                onToggled: value => page.edit("workspaceSwipe", value)
            }
            SliderRow {
                width: parent.width
                label: I18n.tr("Pointer sensitivity")
                hint: I18n.tr("Affects touchpads and mice. Per-device Hyprland rules take precedence.")
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
                label: I18n.tr("Scroll speed")
                settingKey: "scrollFactor"
                resetLabel: "Touchpad scroll speed"
                min: 0.2
                max: 2.0
                step: 0.1
                decimals: 1
                valueLabel: Settings.scrollFactor.toFixed(1) + "×"
                marks: [1.0]
                hint: I18n.tr("1.0× is Hyprland's default")
                dirty: Math.abs(Settings.scrollFactor - Settings.defaults.scrollFactor) > 0.001
            }
        }
    }
}
