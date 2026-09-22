pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import "../Common"

// Each section has its own bounded plugin area; native API 1 defaults right.
Row {
    id: root
    anchors.verticalCenter: parent ? parent.verticalCenter : undefined

    property string section: "right"
    property var barHost: null
    readonly property var entries: UserPlugins.enabledWidgets.filter(plugin => (plugin.section || "right") === section)
    property string screenName: ""
    property real availableWidth: 320
    readonly property var themeValues: ({
        foreground: String(Theme.barTextHi), background: String(Theme.barChip),
        accent: String(Theme.barAccent), fontFamily: Theme.fontMenu,
        fontSize: Theme.typography.bar, typography: Theme.typography, reducedMotion: Settings.reducedMotion
    })
    spacing: Theme.barSpacing
    visible: root.entries.length > 0 || (section === "right" && (UserPlugins.error !== "" || Object.keys(OmarchyPlugins.errors).length > 0))
    readonly property var hiddenWidgets: root.entries.filter((plugin, index) => !fits(index))
    // Settings polling must not destroy timer state or close an open popup.
    readonly property string widgetIdsJson: JSON.stringify(root.entries.map(plugin => plugin.key))
    readonly property var widgetIds: JSON.parse(widgetIdsJson)

    function fits(index) {
        let used = 0;
        for (let i = 0; i <= index && i < root.entries.length; i++)
            used += root.entries[i].width + (i > 0 ? spacing : 0);
        // Reserve space for an overflow count so hidden widgets are discoverable.
        return used <= Math.max(0, availableWidth - 36);
    }

    function slotFor(key) {
        for (let i = 0; i < widgetRepeater.count; i++) {
            const slot = widgetRepeater.itemAt(i) as UserWidgetHost;
            if (slot && slot.descriptor.key === key && slot.visible && slot.width > 0)
                return slot;
        }
        return null;
    }

    Repeater {
        id: widgetRepeater
        model: root.widgetIds
        delegate: UserWidgetHost {
            id: widgetHost
            required property var modelData
            required property int index
            descriptor: root.entries.find(plugin => plugin.key === modelData)
                || ({ id: modelData, name: modelData, width: 120, error: "Plugin disabled" })
            themeValues: root.themeValues
            screenName: root.screenName
            width: descriptor.width
            height: Theme.chipHeight
            visible: root.fits(index)
            opacity: root.barHost && root.barHost.dragWidget
                && root.barHost.dragWidget.pluginKey === modelData ? 0.35 : 1
            onSettingRequested: (pluginId, key, value) => UserPlugins.setSetting(pluginId, key, value)

            HoverHandler { id: hover }
            ToolTip.visible: hover.hovered && widgetHost.error !== ""
            ToolTip.text: widgetHost.error
        }
    }

    Text {
        visible: root.hiddenWidgets.length > 0
        text: "+" + root.hiddenWidgets.length
        color: Theme.barTextHi
        font.family: Theme.fontMenu
        font.pixelSize: Theme.typography.bar
        height: Theme.chipHeight
        verticalAlignment: Text.AlignVCenter
        readonly property string description: "Widgets hidden for space: "
            + root.hiddenWidgets.map(plugin => plugin.name).join(", ")
        Accessible.name: description
        HoverHandler { id: overflowHover }
        ToolTip.visible: overflowHover.hovered
        ToolTip.text: description
    }

    Text {
        visible: (root.section === "right" && (UserPlugins.error !== "" || Object.keys(OmarchyPlugins.errors).length > 0))
        text: "Plugins !"
        color: Theme.barTextHi
        font.family: Theme.fontMenu
        font.pixelSize: Theme.typography.bar
        height: Theme.chipHeight
        verticalAlignment: Text.AlignVCenter
        Accessible.name: UserPlugins.error || JSON.stringify(OmarchyPlugins.errors)
        HoverHandler { id: registryHover }
        ToolTip.visible: registryHover.hovered
        ToolTip.text: UserPlugins.error || JSON.stringify(OmarchyPlugins.errors)
    }
}
