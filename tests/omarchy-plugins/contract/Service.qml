import QtQuick
QtObject {
    property var shell: null
    property var manifest: null
    property var pluginRegistry: null
    property string omarchyPath: ""
    property int count: 0
    function increment(arg) { return ++count; }
}
