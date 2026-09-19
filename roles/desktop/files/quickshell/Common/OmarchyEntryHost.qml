import QtQuick
import Quickshell

QtObject {
    id: root
    required property string pluginId
    required property string kind
    required property string sourceUrl
    required property var api
    property var component: null
    property var instance: null
    property string error: ""
    property bool disposed: false
    readonly property bool ready: instance !== null
    signal loaded()
    signal failed(string detail)

    function configure() {
        if (!instance)
            return;
        // Match upstream's optional, post-construction injection contract.
        const fields = { shell: api, manifest: api.manifest,
            pluginRegistry: api.pluginRegistry, barWidgetRegistry: api.barWidgetRegistry,
            omarchyPath: Quickshell.env("OMARCHY_PATH") || Quickshell.shellDir + "/compat/omarchy",
            barConfig: api.barConfig, settings: api.descriptor.settings || {},
            service: OmarchyPlugins.serviceFor(pluginId) };
        for (const key of Object.keys(fields)) {
            if (key in instance)
                instance[key] = fields[key];
        }
    }

    function finish() {
        if (disposed || !component || component.status === Component.Loading)
            return;
        if (component.status === Component.Ready) {
            instance = component.createObject(root);
            if (instance) {
                configure();
                loaded();
                return;
            }
        }
        error = component.errorString() || "Could not construct plugin entrypoint " + kind;
        failed(error);
    }

    function shutdown() {
        disposed = true;
        if (instance) {
            try { if (typeof instance.close === "function") instance.close(); } catch (exception) { /* still unload */ }
            instance.destroy();
            instance = null;
        }
        if (component) {
            component.destroy();
            component = null;
        }
    }

    Component.onCompleted: {
        component = Qt.createComponent(sourceUrl, Component.PreferSynchronous);
        if (component.status === Component.Loading)
            component.statusChanged.connect(finish);
        finish();
    }
    Component.onDestruction: shutdown()
}
