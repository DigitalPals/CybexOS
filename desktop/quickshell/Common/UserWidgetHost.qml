import QtQuick

// The public v1 contract is the injected pluginApi object, not any shell type.
Item {
    id: root

    required property var descriptor
    required property var themeValues
    property string screenName: ""
    property var component: null
    property Item widget: null
    property string loadError: ""
    readonly property string error: descriptor.error || loadError
    readonly property bool ready: widget !== null
    readonly property bool omarchy: descriptor.format === "omarchy"
    property bool initialized: false
    readonly property string loadIdentity: JSON.stringify([
        descriptor.source || "", descriptor.format || "native", descriptor.error || ""
    ])
    onLoadIdentityChanged: if (initialized) reload()
    signal settingRequested(string pluginId, string key, string value)

    clip: true
    implicitWidth: descriptor.width

    OmarchyBarApi {
        id: omarchyApi
        host: root
    }

    QtObject {
        id: api
        readonly property int version: 1
        readonly property string id: root.descriptor.id
        readonly property var settings: root.descriptor.settings
        readonly property var theme: root.themeValues
        readonly property string packagePath: root.descriptor.packagePath || ""
        readonly property string dataPath: root.descriptor.dataPath || ""
        readonly property string screenName: root.screenName
        readonly property real width: root.width
        readonly property real height: root.height

        function setSetting(key, value) {
            root.settingRequested(id, String(key), JSON.stringify(value));
        }
    }

    function finishLoad() {
        if (!component)
            return;
        if (component.status === Component.Error) {
            loadError = component.errorString();
        } else if (component.status === Component.Ready && !widget) {
            const properties = omarchy
                ? { bar: omarchyApi, moduleName: descriptor.id, settings: descriptor.settings }
                : { pluginApi: api };
            const object = component.createObject(root, properties);
            const item = object as Item;
            if (!item) {
                if (object)
                    object.destroy();
                loadError = omarchy ? "Omarchy widget must be an Item with bar, moduleName and settings"
                    : "Widget must be a QtQuick Item with a pluginApi property";
                return;
            }
            widget = item;
            if (omarchy)
                widget.settings = Qt.binding(() => root.descriptor.settings);
            widget.width = Qt.binding(() => root.width);
            widget.height = Qt.binding(() => root.height);
        }
    }

    function unload() {
        omarchyApi.tooltipTarget = null;
        UserPlugins.unregisterHost(root);
        if (widget) {
            widget.destroy();
            widget = null;
        }
        if (component) {
            component.destroy();
            component = null;
        }
    }

    function reload() {
        unload();
        loadError = "";
        if (descriptor.error || !descriptor.source)
            return;
        component = Qt.createComponent(descriptor.source, Component.Asynchronous);
        UserPlugins.registerHost(root);
        if (component.status === Component.Loading)
            component.statusChanged.connect(finishLoad);
        finishLoad();
    }

    Component.onCompleted: {
        initialized = true;
        reload();
    }
    Component.onDestruction: unload()

    Rectangle {
        anchors.fill: parent
        visible: root.error !== ""
        color: root.themeValues.background
        radius: 5
        Text {
            anchors.fill: parent
            anchors.margins: 4
            verticalAlignment: Text.AlignVCenter
            text: root.descriptor.name + " !"
            elide: Text.ElideRight
            color: root.themeValues.foreground
            font.family: root.themeValues.fontFamily
            font.pixelSize: root.themeValues.fontSize
        }
        Accessible.role: Accessible.StaticText
        Accessible.name: root.descriptor.name + ": " + root.error
    }
}
