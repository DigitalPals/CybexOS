pragma Singleton
import QtQuick
import Quickshell

// Each bar's Model Usage panel, so Settings can open the panel at its own
// source, credential and cost settings. Those forms store private keys
// through the panel's helpers, so Settings links to them rather than
// duplicating them.
Singleton {
    id: root

    property var entries: []
    readonly property bool available: entries.length > 0

    function register(panel, module) {
        entries = entries.filter(entry => entry.panel !== panel)
            .concat([{ panel: panel, module: module }]);
    }

    function unregister(panel) {
        entries = entries.filter(entry => entry.panel !== panel);
    }

    // The panel on the focused output, else any.
    function panelForFocus() {
        const focused = Screens.focused ? Screens.focused.name : "";
        const entry = entries.find(item => item.module.screenName === focused) || entries[0];
        return entry ? entry.panel : null;
    }

    function showSettings() {
        const panel = panelForFocus();
        if (panel)
            panel.showSettings();
        return panel !== null;
    }

    function showCostSettings() {
        const panel = panelForFocus();
        if (panel)
            panel.showCostSettings();
        return panel !== null;
    }
}
