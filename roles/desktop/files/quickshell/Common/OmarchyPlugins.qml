pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "../Commons" as OmarchyTheme

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

    function resolveId(id) {
        const clone = UserPlugins.plugins.find(item => item.enabled && !item.error && item.manifest
            && item.manifest.omarchy && item.manifest.omarchy.clonedFrom === id);
        return clone ? clone.id : id;
    }

    function descriptor(id) {
        id = resolveId(id);
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
        if (records[key] && records[key].source !== source && !(kind === "service" && item.keepLoaded)) {
            unload(key);
            if (openIds[item.id] && kind !== "service" && kind !== "bar") {
                const state = openIds[item.id];
                openIds = Object.assign({}, openIds, { [item.id]: { queue: [state.lastPayload || "{}"] } });
            }
        }
        if (records[key]) {
            const existing = records[key].host;
            existing.configure();
            // A host that failed to load keeps its load error.
            if (existing.ready)
                setError(key, existing.configureError);
            return existing;
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
            setError(key, host.configureError);
            if (kind === "bar") replacing = true;
            if (kind === "service") {
                for (const other of Object.keys(records)) {
                    const otherHost = records[other].host;
                    otherHost.configure();
                    if (otherHost.ready)
                        setError(other, otherHost.configureError);
                }
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

    // One plugin's exception must not abort sync() for every plugin after it.
    function loadSafely(item, kind) {
        try {
            return load(item, kind);
        } catch (exception) {
            setError(item.id + ":" + kind, String(exception));
            return null;
        }
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
                if (wanted[key]) continue;
                try {
                    unload(key);
                } catch (exception) {
                    console.warn("plugins: could not unload", key, exception);
                }
            }
            const nextOpen = {};
            for (const id of Object.keys(openIds)) {
                if (descriptor(id)) nextOpen[id] = openIds[id];
            }
            openIds = nextOpen;
            for (const item of items) {
                if (item.sources.service) loadSafely(item, "service");
            }
            for (const item of items) {
                const kind = panelKind(item);
                if (kind && wanted[item.id + ":" + kind]) loadSafely(item, kind);
            }
            syncCatalog(items);
            const replacement = items.find(item => item.id === selected && item.sources.bar);
            if (replacement) {
                // Retire native bars before constructing the replacement.
                replacing = !errors[replacement.id + ":bar"];
                if (!loadSafely(replacement, "bar"))
                    replacing = false;
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
            try {
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
            } catch (exception) {
                setError(item.id + ":barWidget", String(exception));
            }
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
        openIds = Object.assign({}, openIds, { [id]: { queue: [], lastPayload: queue.length ? queue[queue.length - 1] : state.lastPayload } });
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
        id = resolveId(id);
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
        const host = loadSafely(item, kind);
        if (host && host.ready) deliver(id, host);
        return !!host && !host.error;
    }

    function hide(id) {
        id = resolveId(id);
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
        id = resolveId(id);
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
        id = resolveId(id);
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

    function placeWidget(id, placementJson, operation) {
        try {
            const placement = JSON.parse(placementJson || "{}");
            if (!placement || typeof placement !== "object" || Array.isArray(placement)) return "invalid placement";
            id = resolveId(id);
            const item = UserPlugins.plugins.find(entry => entry.id === id && !entry.error);
            if (!item) return "unknown";
            if (!item.kinds.includes("bar-widget")) {
                if (operation !== "enable") return "not a widget";
                UserPlugins.enqueue(["python3", UserPlugins.helper, "enable", id]);
                return "ok";
            }
            if (item.format !== "omarchy") return "not an Omarchy widget";
            const layout = JSON.parse(JSON.stringify(barConfig.layout));
            const sections = ["left", "center", "right"];
            let existing = null;
            for (const section of sections) {
                const index = layout[section].findIndex(entry => entry.id === id);
                if (!existing && index >= 0 && (!placement.fromSection || section === placement.fromSection))
                    existing = { section: section, index: index, entry: layout[section][index] };
            }
            if (placement.fromIndex !== undefined) {
                const at = Number(placement.fromIndex);
                const entries = layout[placement.fromSection];
                if (!entries || !Number.isInteger(at) || at < 0 || !entries[at] || entries[at].id !== id)
                    return "invalid source index";
                existing = { section: placement.fromSection, index: at, entry: entries[at] };
            }
            if (operation === "put" && existing) return "ok";
            if (operation === "move" && !existing) return "unknown";
            let section = placement.section || (existing ? existing.section : item.section);
            if (!sections.includes(section)) return "invalid section";
            if (placement.before && placement.after) return "choose before or after";
            let entry = existing ? existing.entry : Object.assign({}, item.settings, { id: id });
            if (existing) layout[existing.section].splice(existing.index, 1);
            let index = layout[section].length;
            const relative = placement.before || placement.after;
            if (relative) {
                const relativeSection = sections.find(name => (!placement.section || placement.section === name)
                    && layout[name].some(candidate => candidate.id === resolveId(relative)));
                if (!relativeSection && operation !== "put") return "relative widget not found";
                if (relativeSection) {
                    section = relativeSection;
                    index = layout[section].findIndex(candidate => candidate.id === resolveId(relative)) + (placement.after ? 1 : 0);
                }
            } else if (placement.index !== undefined) {
                index = Number(placement.index);
                if (!Number.isInteger(index) || index < 0 || index > layout[section].length) return "invalid index";
            }
            layout[section].splice(index, 0, entry);
            for (const key of ["before", "after"])
                if (placement[key]) placement[key] = resolveId(placement[key]);
            UserPlugins.enqueue(["python3", UserPlugins.helper, "layout-edit", operation, id, JSON.stringify(placement)]);
            return "ok";
        } catch (exception) { return "invalid placement: " + exception; }
    }

    function setBarWidgetValue(id, key, valueJson, selectorJson) {
        try {
            const selector = JSON.parse(selectorJson || "{}");
            const value = JSON.parse(valueJson);
            if (!selector || typeof selector !== "object" || Array.isArray(selector) || ["id", "__cybexInstance"].includes(key)) return "invalid selector or key";
            const layout = JSON.parse(JSON.stringify(barConfig.layout));
            const section = selector.fromSection || selector.section;
            const index = selector.fromIndex !== undefined ? selector.fromIndex : selector.index;
            const sections = section ? [section] : ["left", "center", "right"];
            if (index !== undefined && !section) return "index requires section";
            for (const name of sections) {
                if (!layout[name]) return "invalid section";
                const at = index !== undefined ? Number(index) : layout[name].findIndex(entry => entry.id === resolveId(id));
                if (!Number.isInteger(at)) return "invalid index";
                const entry = layout[name][at];
                if (entry && entry.id === resolveId(id)) {
                    entry[key] = value;
                    UserPlugins.enqueue(["python3", UserPlugins.helper, "layout-edit", "set", resolveId(id),
                        JSON.stringify({ key: key, value: value, selector: selector })]);
                    return "ok";
                }
            }
            return "unknown";
        } catch (exception) { return "invalid widget setting: " + exception; }
    }

    Connections {
        target: UserPlugins
        function onPluginsChanged() { Qt.callLater(root.sync); }
        function onBarConfigChanged() { Qt.callLater(root.sync); }
    }

    IpcHandler {
        target: "shell"
        function debugPluginTheme(): string {
            return JSON.stringify({
                fontBaseSize: OmarchyTheme.Style.fontBaseSize,
                fontFamily: Theme.fontMenu,
                nativeTypography: Theme.typography,
                pluginTypography: OmarchyTheme.Style.typography,
                plugin: { family: OmarchyTheme.Style.font.family,
                    body: OmarchyTheme.Style.font.body, caption: OmarchyTheme.Style.font.caption,
                    title: OmarchyTheme.Style.font.title, heading: OmarchyTheme.Style.font.heading,
                    display: OmarchyTheme.Style.font.display, displayLarge: OmarchyTheme.Style.font.displayLarge },
                native: { fontBase: Theme.fontBaseSize, body: Theme.fontBody,
                    caption: Theme.fontCaption, bar: Theme.barTextSize,
                    title: Theme.fontProminent, heading: Theme.fontHeading,
                    display: Theme.fontDisplay, displayLarge: Theme.fontHero, spacingScale: Theme.contentScale,
                    panelWidth: Theme.popWidth, controlHeight: Theme.settingsControlHeight,
                    borderWidth: Theme.surfaceBorderWidth, borderColor: String(Theme.surfaceBorderColor),
                    radius: Theme.panelRadius },
                spacingScale: OmarchyTheme.Style.effectiveSpacingScale,
                modelUsageWidth: OmarchyTheme.Style.space(420),
                cornerRadius: OmarchyTheme.Style.cornerRadius,
                popupBorder: OmarchyTheme.Border.surfaceSpec("popups", "border",
                    OmarchyTheme.Color.popups.border, 2),
                values: OmarchyTheme.Color.shellValues
            });
        }
        function applyTheme(colorsB64: string, shellB64: string): string {
            try {
                const colors = Qt.atob(colorsB64);
                const shell = Qt.atob(shellB64);
                OmarchyTheme.Color.loadColors(colors);
                OmarchyTheme.Color.loadShell(shell);
                return "ok";
            } catch (exception) { return "invalid theme"; }
        }
        function reloadConfig(): string { UserPlugins.refresh(); return "ok"; }
        function listShellConfig(): string { return JSON.stringify({ bar: root.barConfig,
            plugins: UserPlugins.enabled.map(item => item.id),
            disabledPlugins: UserPlugins.plugins.filter(item => !item.enabled).map(item => item.id) }); }
        function enablePlugin(id: string, placementJson: string): string { return root.placeWidget(id, placementJson, "enable"); }
        function putBarWidget(id: string, placementJson: string): string { return root.placeWidget(id, placementJson, "put"); }
        function moveBarWidget(id: string, placementJson: string): string { return root.placeWidget(id, placementJson, "move"); }
        function setBarWidget(id: string, key: string, valueJson: string, selectorJson: string): string {
            return root.setBarWidgetValue(id, key, valueJson, selectorJson);
        }
        function togglePanelAt(section: string, index: string): string {
            const entries = root.barConfig.layout[section];
            const at = Number(index);
            const entry = entries && Number.isInteger(at) && at >= 0 ? entries[at] : null;
            return entry && root.toggle(entry.id, "{}") ? entry.id : "unknown";
        }
        function toggleBarTransparency(): string {
            if (!root.replacementActive) return "no-bar";
            root.saveBarConfig({ transparent: !root.barConfig.transparent });
            return "ok";
        }
        function debugBarGeometry(): string {
            const record = root.records[(UserPlugins.barConfig.id || "") + ":bar"];
            const bar = record ? record.host.instance : null;
            return JSON.stringify(bar && typeof bar.debugBarGeometry === "function" ? bar.debugBarGeometry() : []);
        }
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
