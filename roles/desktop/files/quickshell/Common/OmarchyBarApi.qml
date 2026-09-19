import QtQuick
import QtQuick.Controls
import Quickshell
import "../Ui" as Omarchy

Omarchy.PluginBarApi {
    id: root
    required property var host
    pluginId: host.descriptor.id
    moduleName: pluginId
    foreground: host.themeValues.foreground
    barForeground: foreground
    background: host.themeValues.background
    urgent: Theme.red
    fontFamily: host.themeValues.fontFamily
    barSize: host.height
    foregroundAnimationEnabled: !host.themeValues.reducedMotion
    activePopout: UserPlugins.activePopout
    clickTargets: UserPlugins.clickTargets
    layoutConfig: ({ position: position })

    property var tooltipTarget: null
    property ToolTip tooltip: ToolTip {
        parent: root.tooltipTarget || root.host
        visible: root.tooltipTarget !== null
        contentItem: Text { text: root.tooltip.text; textFormat: Text.PlainText }
    }

    _showTooltip: (target, text) => {
        tooltip.text = text;
        tooltipTarget = target;
    }
    _hideTooltip: target => {
        if (!target || tooltipTarget === target)
            tooltipTarget = null;
    }
    _registerClickTarget: target => {
        if (!UserPlugins.clickTargets.includes(target))
            UserPlugins.clickTargets = UserPlugins.clickTargets.concat([target]);
    }
    _unregisterClickTarget: target => {
        UserPlugins.clickTargets = UserPlugins.clickTargets.filter(item => item !== target);
    }
    _requestPopout: owner => UserPlugins.requestPopout(owner)
    _releasePopout: owner => UserPlugins.releasePopout(owner)
    _targetBelongsToWindow: (target, window) => target.QsWindow.window === window
    _moduleWidgets: id => UserPlugins.widgetHosts
        .filter(item => item.descriptor.id === id && item.widget).map(item => item.widget)
    _run: command => Quickshell.execDetached(["bash", "-c", command])
    _setCenterHoverRevealSuppressed: value => { _centerHoverRevealSuppressed = value; }
    _switchPanelFrom: (owner, direction) => {
        const panels = UserPlugins.widgetHosts.filter(item => item.screenName === host.screenName
            && item.widget && typeof item.widget.open === "function");
        if (panels.length < 2)
            return false;
        const index = panels.findIndex(item => item.widget === owner);
        if (index < 0)
            return false;
        panels[(index + (direction < 0 ? -1 : 1) + panels.length) % panels.length].widget.open();
        return true;
    }

    position: Settings.position
    shell: OmarchyPluginApi {
        pluginId: root.pluginId
        instanceName: root.host.descriptor.instanceName || ""
        bar: root
    }
}
