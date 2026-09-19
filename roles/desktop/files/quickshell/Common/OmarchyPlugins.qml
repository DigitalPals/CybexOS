pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root
    property var records: ({})
    property var apis: ({})
    property var entryApis: ({})
    property var openIds: ({})
    property var errors: ({})
    property var catalog: ({})
    property int catalogRevision: 0
    property bool replacing: false
    property bool syncing: false
    readonly property bool ready: true
    readonly property bool replacementActive: replacing
    readonly property var barState: {
        const record = records[(UserPlugins.barConfig.id || "") + ":bar"];
        const bar = replacing && record ? record.host.instance : null;
        return {
            barHidden: bar && "barHidden" in bar ? bar.barHidden : Settings.autoHide,
            barSize: bar && "barSize" in bar ? bar.barSize : Theme.barHeight,
            fontFamily: bar && "fontFamily" in bar ? bar.fontFamily : Theme.fontMenu,
            position: bar && "position" in bar ? bar.position : Settings.position
        };
    }
    readonly property var barConfig: {
        const config = JSON.parse(JSON.stringify(UserPlugins.barConfig));
        const layout = { left: [], center: [], right: [] };
        for (const item of UserPlugins.enabledWidgets.filter(entry => entry.format === "omarchy" && !entry.error))
            layout[item.section || "right"].push(Object.assign({}, item.settings, { id: item.id, __cybexInstance: item.instanceName || "" }));
        return Object.assign({ position: Settings.position, transparent: false }, config, { layout: layout });
    }

    Component { id: apiFactory; OmarchyPluginApi {} }
    Component { id: hostFactory; OmarchyEntryHost {} }

    function descriptor(id) {
        return UserPlugins.plugins.find(item => item.id === id && item.enabled && !item.error
            && item.format === "omarchy") || null;
    }

    function apiFor(id) {
        if (!Object.prototype.hasOwnProperty.call(apis, id)) {
            const api = apiFactory.createObject(root, { pluginId: id });
            apis = Object.assign({}, apis, { [id]: api });
        }
        return apis[id];
    }

    function entryApi(id) {
        if (!descriptor(id))
            return null;
        if (!Object.prototype.hasOwnProperty.call(entryApis, id)) {
            const api = apiFactory.createObject(root, { pluginId: id, serviceAccess: false });
            entryApis = Object.assign({}, entryApis, { [id]: api });
        }
        return entryApis[id];
    }

    function setError(key, detail) {
        const next = Object.assign({}, errors);
        if (detail) next[key] = detail;
        else delete next[key];
        errors = next;
    }

    function serviceFor(id) {
        const record = records[id + ":service"];
        return record && record.host ? record.host.instance : null;
    }

    function unload(key) {
        const record = records[key];
        if (!record)
            return;
        const next = Object.assign({}, records);
        delete next[key];
        records = next;
        record.host.shutdown();
        record.host.destroy();
        setError(key, "");
    }

    function load(item, kind) {
        const key = item.id + ":" + kind;
        const source = item.sources[kind];
        if (records[key] && records[key].source !== source)
            unload(key);
        if (records[key]) {
            records[key].host.configure();
            return records[key].host;
        }
        const host = hostFactory.createObject(root, {
            pluginId: item.id, kind: kind, sourceUrl: source, api: apiFor(item.id)
        });
        if (!host) {
            setError(key, "Could not create plugin host");
            return null;
        }
        records = Object.assign({}, records, { [key]: { source: source, host: host } });
        const loaded = () => {
            // Notify bindings that initially observed an asynchronous service.
            records = Object.assign({}, records);
            setError(key, "");
            if (kind === "service") {
                for (const record of Object.values(records)) record.host.configure();
            }
            if (kind !== "service" && kind !== "bar" && openIds[item.id])
                deliver(item.id, host);
        };
        const failed = detail => {
            setError(key, detail);
            if (kind === "bar") replacing = false;
        };
        host.loaded.connect(loaded);
        host.failed.connect(failed);
        if (host.ready) loaded();
        else if (host.error) failed(host.error);
        return host;
    }

    function panelKind(item) {
        return ["panel", "overlay", "menu"].find(kind => item.kinds.includes(kind)) || "";
    }

    function sync() {
        if (syncing)
            return;
        syncing = true;
        try {
            const items = UserPlugins.plugins.filter(item => item.enabled && !item.error && item.format === "omarchy");
            const wanted = {};
            const selected = UserPlugins.barConfig.id || "";
            for (const item of items) {
                if (item.sources.service) wanted[item.id + ":service"] = true;
                const kind = panelKind(item);
                if (kind && (item.keepLoaded || openIds[item.id])) wanted[item.id + ":" + kind] = true;
                if (item.id === selected && item.sources.bar) wanted[item.id + ":bar"] = true;
            }
            // UI references must release their service before it is destroyed.
            const keys = Object.keys(records).sort((a, b) => Number(a.endsWith(":service")) - Number(b.endsWith(":service")));
            for (const key of keys) {
                if (!wanted[key]) unload(key);
            }
            const nextOpen = {};
            for (const id of Object.keys(openIds)) {
                if (descriptor(id)) nextOpen[id] = openIds[id];
            }
            openIds = nextOpen;
            for (const item of items) {
                if (item.sources.service) load(item, "service");
            }
            for (const item of items) {
                const kind = panelKind(item);
                if (kind && wanted[item.id + ":" + kind]) load(item, kind);
            }
            syncCatalog(items);
            const replacement = items.find(item => item.id === selected && item.sources.bar);
            if (replacement) {
                // Retire native bars before constructing the replacement.
                replacing = !errors[replacement.id + ":bar"];
                load(replacement, "bar");
            } else {
                replacing = false;
            }
            // Discard facades only after their entries have been destroyed.
            for (const mapName of ["apis", "entryApis"]) {
                const next = Object.assign({}, root[mapName]);
                for (const id of Object.keys(next)) {
                    if (!descriptor(id)) { next[id].destroy(); delete next[id]; }
                }
                root[mapName] = next;
            }
        } finally {
            syncing = false;
        }
    }

    function syncCatalog(items) {
        const next = {};
        for (const item of items.filter(entry => entry.sources.barWidget)) {
            let entry = Object.prototype.hasOwnProperty.call(catalog, item.id) ? catalog[item.id] : null;
            if (!entry || entry.source !== item.source) {
                const component = Qt.createComponent(item.source, Component.PreferSynchronous);
                entry = { source: item.source, component: component };
            }
            const metadata = Object.assign({}, item.manifest.barWidget || {}, {
                displayName: (item.manifest.barWidget || {}).displayName || item.name,
                pluginId: item.id, sourceDir: item.packagePath, source: "plugin", firstParty: false
            });
            next[item.id] = { source: entry.source, component: entry.component, metadata: metadata };
        }
        // Components can still be referenced by a retiring replacement bar's
        // Loader. Release our references and let the engine collect them.
        catalog = next;
        catalogRevision++;
    }

    function widgetFor(id) {
        const hosts = UserPlugins.widgetHosts.filter(host => host.descriptor.id === id && host.widget);
        const focused = Screens.focused ? Screens.focused.name : "";
        const host = hosts.find(item => item.screenName === focused) || hosts[0];
        return host ? host.widget : null;
    }

    function deliver(id, host) {
        const state = openIds[id];
        if (!state || !host.ready)
            return;
        const queue = state.queue || [];
        openIds = Object.assign({}, openIds, { [id]: { queue: [] } });
        try {
            if (typeof host.instance.open === "function") {
                for (const payload of queue) host.instance.open(payload);
            }
        } catch (exception) {
            setError(id + ":" + host.kind, String(exception));
            const next = Object.assign({}, openIds);
            delete next[id];
            openIds = next;
        }
    }

    function summon(id, payloadJson) {
        const item = descriptor(id);
        if (!item)
            return false;
        const kind = panelKind(item);
        if (!kind) {
            const widget = widgetFor(id);
            if (!widget || typeof widget.open !== "function") return false;
            widget.open();
            return true;
        }
        const queue = openIds[id] ? openIds[id].queue.slice() : [];
        queue.push(String(payloadJson || ""));
        openIds = Object.assign({}, openIds, { [id]: { queue: queue } });
        const host = load(item, kind);
        if (host && host.ready) deliver(id, host);
        return !!host && !host.error;
    }

    function hide(id) {
        const item = descriptor(id);
        if (!item) return false;
        const kind = panelKind(item);
        if (!kind) {
            const widget = widgetFor(id);
            if (!widget || typeof widget.close !== "function") return false;
            widget.close();
            return true;
        }
        const next = Object.assign({}, openIds);
        delete next[id];
        openIds = next;
        const record = records[id + ":" + kind];
        try {
            if (record && record.host.instance && typeof record.host.instance.close === "function")
                record.host.instance.close();
        } catch (exception) {
            setError(id + ":" + kind, String(exception));
        }
        if (!item.keepLoaded) unload(id + ":" + kind);
        return true;
    }

    function isPluginOpen(id) {
        const item = descriptor(id);
        if (!item) return false;
        const kind = panelKind(item);
        if (!kind) {
            const widget = widgetFor(id);
            return widget ? !!widget.opened : false;
        }
        const record = records[id + ":" + kind];
        if (record && record.host.instance && "opened" in record.host.instance)
            return !!record.host.instance.opened;
        return !!openIds[id];
    }

    function toggle(id, payloadJson) { return isPluginOpen(id) ? hide(id) : summon(id, payloadJson); }

    function call(id, method, arg) {
        const item = descriptor(id);
        if (!item || ["destroy", "deleteLater"].includes(method)) return "unknown";
        const record = records[id + ":" + (panelKind(item) || "service")];
        const target = record ? record.host.instance : widgetFor(id);
        if (!target || typeof target[method] !== "function") return "unknown";
        try {
            const result = target[method](arg);
            return result === undefined || result === null ? "ok" : String(result);
        } catch (exception) {
            setError(id + ":call", String(exception));
            return "error";
        }
    }

    function saveBarConfig(config) {
        if (!config || typeof config !== "object" || Array.isArray(config)) return false;
        UserPlugins.enqueue(["python3", UserPlugins.helper, "bar-config", JSON.stringify(config)]);
        return true;
    }

    Connections {
        target: UserPlugins
        function onPluginsChanged() { Qt.callLater(root.sync); }
        function onBarConfigChanged() { Qt.callLater(root.sync); }
    }

    IpcHandler {
        target: "shell"
        function ping(): string { return "pong"; }
        function summon(id: string, payloadJson: string): string { return root.summon(id, payloadJson) ? "ok" : "unknown"; }
        function hide(id: string): void { root.hide(id); }
        function toggle(id: string, payloadJson: string): void { root.toggle(id, payloadJson); }
        function call(id: string, method: string, arg: string): string { return root.call(id, method, arg); }
        function listPlugins(): string { return JSON.stringify({ plugins: UserPlugins.plugins, errors: root.errors }); }
        function rescanPlugins(): string { UserPlugins.refresh(); return "ok"; }
        function setPluginEnabled(id: string, enabled: bool): string {
            if (!UserPlugins.plugins.some(item => item.id === id)) return "unknown";
            UserPlugins.enqueue(["python3", UserPlugins.helper, enabled ? "enable" : "disable", id]);
            return "ok";
        }
    }

    Component.onCompleted: Qt.callLater(sync)
    Component.onDestruction: {
        for (const key of Object.keys(records)) records[key].host.shutdown();
    }
}
