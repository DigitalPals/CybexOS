import QtQuick

// Capability-scoped facade. Installed code remains trusted, unsandboxed QML.
QtObject {
    id: root
    required property string pluginId
    property var bar: barState
    property string instanceName: ""
    property bool serviceAccess: true
    readonly property var descriptor: UserPlugins.plugins.find(item => item.id === pluginId) || ({})
    readonly property bool fullBar: (descriptor.kinds || []).includes("bar")
    readonly property var manifest: JSON.parse(JSON.stringify(descriptor.manifest || {}))
    readonly property var barConfig: JSON.parse(JSON.stringify(OmarchyPlugins.barConfig))
    readonly property var idleConfig: ({})
    readonly property var appLibrary: (descriptor.kinds || []).includes("menu") ? OmarchyApplications : null

    property QtObject barState: QtObject {
        readonly property bool barHidden: OmarchyPlugins.barState.barHidden
        readonly property int barSize: OmarchyPlugins.barState.barSize
        readonly property string fontFamily: OmarchyPlugins.barState.fontFamily
        readonly property string position: OmarchyPlugins.barState.position
    }

    function owns(id) {
        return id === pluginId || (manifest.omarchy && id === manifest.omarchy.clonedFrom);
    }

    function mayControl(id) {
        return owns(id) || (fullBar && OmarchyPlugins.descriptor(id) !== null);
    }

    function serviceFor(id) {
        return serviceAccess && owns(id) ? OmarchyPlugins.serviceFor(pluginId) : null;
    }

    function firstPartyServiceFor(id) {
        // Supports upstream built-in packages installed under their original ID
        // or a clone ID, without publishing unrelated Cybex services.
        return serviceFor(id);
    }

    function pluginShellForBarEntry(ownerId, moduleName) {
        if (!fullBar || !String(ownerId || ""))
            return null;
        return OmarchyPlugins.entryApi(moduleName);
    }

    function summon(id, payloadJson) {
        return mayControl(id) && OmarchyPlugins.summon(owns(id) ? pluginId : id, payloadJson);
    }

    function hide(id) {
        return mayControl(id) && OmarchyPlugins.hide(owns(id) ? pluginId : id);
    }

    function toggle(id, payloadJson) {
        return mayControl(id) && OmarchyPlugins.toggle(owns(id) ? pluginId : id, payloadJson);
    }

    function isPluginOpen(id) {
        return mayControl(id) && OmarchyPlugins.isPluginOpen(owns(id) ? pluginId : id);
    }

    function updateEntryInline(id, settings) {
        if (!mayControl(id) || !settings || typeof settings !== "object" || Array.isArray(settings))
            return false;
        UserPlugins.mergeSettings(owns(id) ? pluginId : id, settings, owns(id) ? instanceName : "");
        return true;
    }

    function mutateShellConfig(mutator) {
        // Only replacement-bar configuration is writable through this facade.
        if (!fullBar || typeof mutator !== "function")
            return false;
        const draft = { bar: JSON.parse(JSON.stringify(barConfig)) };
        mutator(draft);
        return OmarchyPlugins.saveBarConfig(draft.bar);
    }

    readonly property QtObject pluginRegistry: QtObject {
        readonly property var installedPlugins: {
            const result = {};
            result[root.pluginId] = root.manifest;
            return result;
        }
        function isEnabled(id) { return root.owns(id) && !!root.descriptor.enabled && !root.descriptor.error; }
        function resolveEnabledId(id) { return isEnabled(id) ? root.pluginId : ""; }
        function entryPointUrl(candidate, kind) {
            return candidate && root.owns(candidate.id) ? (root.descriptor.sources || {})[kind] || "" : "";
        }
    }

    readonly property QtObject barWidgetRegistry: QtObject {
        readonly property var widgets: {
            const result = {};
            if (root.fullBar) {
                for (const id of Object.keys(OmarchyPlugins.catalog)) {
                    const item = OmarchyPlugins.catalog[id];
                    result[id] = { component: item.component, metadata: JSON.parse(JSON.stringify(item.metadata)) };
                }
            }
            return result;
        }
        readonly property int revision: OmarchyPlugins.catalogRevision
        function availableIds() { return Object.keys(widgets); }
        function has(id) { return widgets[id] !== undefined; }
        function metadataFor(id) { return widgets[id] ? widgets[id].metadata : null; }
    }
}
