import QtQuick
import qs.Ui
import "ReloadProbe.js" as Probe
BarWidget {
    readonly property int reloadRevision: Probe.revision
    readonly property var shared: bar ? bar.shell.serviceFor(moduleName) : null
    function saveLabel(value) { bar.shell.updateEntryInline(moduleName, { label: value }); }
    Text { text: parent.shared ? String(parent.shared.count) : "waiting" }
}
