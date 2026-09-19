import QtQuick
import qs.Ui
BarWidget {
    readonly property var shared: bar ? bar.shell.serviceFor(moduleName) : null
    function saveLabel(value) { bar.shell.updateEntryInline(moduleName, { label: value }); }
    Text { text: parent.shared ? String(parent.shared.count) : "waiting" }
}
