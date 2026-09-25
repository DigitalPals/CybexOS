import QtQuick
import "../../Common"
import "../../ModelUsage" as ModelUsage

// Model Usage: provider quota chips in the bar, and the Limits/Costs panel.
//
// The panel is the digitalpals.model-usage Omarchy plugin, vendored unchanged
// in ModelUsage/ (see its README). It is written against the Omarchy host API
// (qs.Ui, qs.Commons and a `bar` facade), which the shell already implements
// for installed plugins. This module supplies that facade as a built-in: the
// panel's settings live in Settings.modOpts.modelusage, not plugins.json.
BarModule {
    id: root

    moduleId: "modelusage"

    // What OmarchyBarApi reads from the widget host it serves.
    readonly property var descriptor: ({ id: "digitalpals.model-usage", instanceName: "" })
    readonly property var themeValues: ({
        foreground: String(Theme.barTextHi), background: String(Theme.barChip),
        accent: String(Theme.barAccent), fontFamily: Theme.fontMenu,
        fontSize: Theme.typography.bar, typography: Theme.typography,
        reducedMotion: Theme.reducedMotion
    })
    readonly property string screenName: host ? host.outputName : ""

    OmarchyBarApi {
        id: barApi
        host: root
        shell: QtObject {
            // The panel saves its whole settings object through this call.
            function updateEntryInline(id, settings) {
                if (!settings || typeof settings !== "object" || Array.isArray(settings))
                    return false;
                Settings.setModuleOptions("modelusage", settings);
                return true;
            }
        }
    }

    ModelUsage.Panel {
        id: panel

        bar: barApi
        settings: Settings.modOpts.modelusage
        height: Theme.chipHeight

        Component.onCompleted: ModelUsageHub.register(panel, root)
        Component.onDestruction: ModelUsageHub.unregister(panel)
    }

    // A save assigns the panel a plain settings value, which ends the binding
    // above; changes made in Settings still have to reach it.
    Connections {
        target: Settings
        function onModOptsChanged() {
            panel.settings = Settings.modOpts.modelusage;
        }
    }
}
