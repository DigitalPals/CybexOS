pragma ComponentBehavior: Bound
import QtQuick
import "../Common"

// These are compositor preferences, like display configuration. There are no
// shell.json keys: changes are explicit API calls and state comes back through
// the compositor snapshot. Opening Settings never writes a default preference.
SettingsPage {
    id: page
    readonly property bool available: DesktopWorkspaces.ready && Settings.loaded
    readonly property string unavailableReason: available ? "" : I18n.tr("Workspace controls are waiting for the compositor")
    readonly property var layouts: {
        const rows = [{ value: "dwindle", label: I18n.tr("Tiled") }];
        if (DesktopWorkspaces.scrollingAvailable)
            rows.push({ value: "scrolling", label: I18n.tr("Scrolling") });
        rows.push({ value: "floating", label: I18n.tr("Floating") });
        return rows;
    }
    readonly property var monitorRows: DesktopWorkspaces.ready ? DesktopWorkspaces.snapshot.monitors : []
    property string selectedMonitor: Screens.focused ? Screens.focused.name : ""
    readonly property var selectedMonitorRow: DesktopWorkspaces.monitor(selectedMonitor) ?? monitorRows[0] ?? null
    readonly property var workspaceRows: selectedMonitorRow
        ? selectedMonitorRow.workspaces.map(id => DesktopWorkspaces.workspace(id))
            .filter(row => row !== null && DesktopWorkspaces.canSetLayout(row)) : []
    property int selectedId: 0
    readonly property var selectedWorkspace: workspaceRows.find(row => row.id === selectedId) ?? null
    readonly property var workspaceLayouts: [{ value: "default", label: I18n.tr("Default") }].concat(layouts)
    readonly property string selectedLayout: selectedWorkspace && selectedWorkspace.layoutOverride
        ? selectedWorkspace.layout : "default"

    function settleWorkspace() {
        if (!workspaceRows.some(row => row.id === selectedId)) {
            const activeId = selectedMonitorRow ? selectedMonitorRow.activeWorkspace : 0;
            selectedId = workspaceRows.some(row => row.id === activeId) ? activeId
                : workspaceRows.length > 0 ? workspaceRows[0].id : 0;
        }
    }
    onWorkspaceRowsChanged: settleWorkspace()
    Component.onCompleted: settleWorkspace()

    Column {
        width: parent.width
        spacing: Theme.settingsGroupSpacing

        SettingsGroup {
            width: parent.width
            title: I18n.tr("Workspaces")

            PickerRow {
                width: parent.width
                label: I18n.tr("Workspace mode")
                current: DesktopWorkspaces.mode
                disabledReason: page.unavailableReason
                hint: I18n.tr("Shared keeps global numbers. Per-monitor gives each display its own 1–10.")
                model: [{ value: "shared", label: I18n.tr("Shared") },
                    { value: "per-monitor", label: I18n.tr("Per-monitor") }]
                onPicked: value => DesktopWorkspaces.setMode(value)
                dirty: DesktopWorkspaces.mode !== "shared"
                onResetRequested: DesktopWorkspaces.setMode("shared")
            }
            PickerRow {
                width: parent.width
                label: I18n.tr("Default workspace layout")
                current: DesktopWorkspaces.defaultLayoutManaged ? DesktopWorkspaces.defaultLayout : "unmanaged"
                model: page.layouts
                caption: DesktopWorkspaces.defaultLayoutManaged
                    ? DesktopWorkspaces.layoutLabel(DesktopWorkspaces.defaultLayout, DesktopWorkspaces.nativeDefaultLayout)
                    : I18n.format("Unmanaged (%1)", [DesktopWorkspaces.nativeDefaultLayout])
                captionMono: false
                disabledReason: page.unavailableReason
                hint: I18n.tr("Used by workspaces without their own layout choice")
                onPicked: value => DesktopWorkspaces.setDefaultLayout(value)
                dirty: !DesktopWorkspaces.defaultLayoutManaged || DesktopWorkspaces.defaultLayout !== "dwindle"
                onResetRequested: DesktopWorkspaces.setDefaultLayout("dwindle")
            }
            SettingsHint {
                width: parent.width
                text: !DesktopWorkspaces.ready || DesktopWorkspaces.scrollingAvailable ? ""
                    : I18n.tr("Scrolling is unavailable in this compositor build")
                tone: "warning"
            }
            SettingsHint {
                width: parent.width
                text: DesktopWorkspaces.error
                tone: "error"
                maximumLines: 5
            }
        }

        SettingsGroup {
            width: parent.width
            title: I18n.tr("Workspace layout")

            SelectRow {
                width: parent.width
                label: I18n.tr("Display")
                current: page.selectedMonitorRow ? page.selectedMonitorRow.name : ""
                disabledReason: page.unavailableReason
                model: page.monitorRows.map(row => ({ value: row.name, label: row.label }))
                onPicked: value => { page.selectedMonitor = value; page.settleWorkspace(); }
            }
            SelectRow {
                width: parent.width
                label: I18n.tr("Workspace")
                current: page.selectedId
                disabledReason: page.unavailableReason
                model: page.workspaceRows.map(row => ({ value: row.id, label: row.label }))
                onPicked: value => page.selectedId = value
            }
            PickerRow {
                width: parent.width
                label: I18n.tr("Layout")
                current: page.selectedLayout
                model: page.workspaceLayouts
                caption: page.selectedWorkspace ? DesktopWorkspaces.layoutLabel(page.selectedWorkspace.layout,
                    page.selectedWorkspace.nativeLayout) : ""
                captionMono: false
                disabledReason: page.unavailableReason || (!page.selectedWorkspace ? I18n.tr("Select a workspace") : "")
                onPicked: value => DesktopWorkspaces.setLayout(page.selectedId, value)
                dirty: page.selectedWorkspace !== null && page.selectedLayout !== "default"
                onResetRequested: DesktopWorkspaces.setLayout(page.selectedId, "default")
                hint: I18n.tr("The bar layout button cycles the layout of its own display")
            }
        }

        SettingsGroup {
            width: parent.width
            title: I18n.tr("Floating windows")

            SwitchRow {
                width: parent.width
                label: I18n.tr("Floating titlebars")
                checked: DesktopWorkspaces.titlebarsEnabled
                disabledReason: page.unavailableReason
                description: DesktopWorkspaces.titlebarsAvailable
                    ? I18n.tr("Native titlebars for windows that need them")
                    : I18n.tr("Native titlebars are unavailable. Use Super-drag and the overview controls.")
                hintTone: DesktopWorkspaces.titlebarsAvailable ? "info" : "warning"
                onToggled: value => DesktopWorkspaces.setTitlebarsEnabled(value)
                dirty: !DesktopWorkspaces.titlebarsEnabled
                onResetRequested: DesktopWorkspaces.setTitlebarsEnabled(true)
            }
            SettingsHint {
                width: parent.width
                text: I18n.tr("The dock is optional in every layout. Minimized windows remain in the overview and launcher.")
                maximumLines: 4
            }
            SettingsAction {
                text: I18n.tr("Configure dock")
                glyph: "settings"
                onTriggered: Settings.showSetting("bar", "dock")
            }
            SettingsHint {
                width: parent.width
                text: I18n.tr("Open the overview with Super+Tab. Enter restores a window; Ctrl+M minimizes; Ctrl+L cycles layouts; Page Up/Down selects workspaces.")
                maximumLines: 5
            }
        }
    }
}
