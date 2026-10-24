import QtQuick
import ".."
import "../../Common"

// Shows and hides the Cybex OS Assistant on this bar's display. Lit while the
// character is out; a dot while it works or holds an unread reply, which is
// how a turn left running with the character hidden is still visible.
BarModule {
    id: root

    moduleId: "assistant"

    BarIcon {
        id: icon
        host: root.host
        isle: root.isle
        anchorItem: root.groupAnchor ?? icon
        glyph: "assistant"
        glyphWidth: Theme.barIconSize
        idleColor: Settings.assistantShown ? Theme.barAccent : Theme.barIcon
        label: Assistant.waiting ? "!" : Assistant.busy ? "…" : Assistant.unread ? "•" : ""
        labelColor: Assistant.waiting ? Theme.barAmber : Theme.barAccent
        compact: root.compact
        tooltip: Assistant.waiting ? I18n.tr("The assistant needs your answer")
            : Assistant.busy ? I18n.tr("The assistant is working")
            : Assistant.unread ? I18n.tr("The assistant has replied")
            : Settings.assistantShown ? I18n.tr("Hide the assistant")
            : I18n.tr("Show the assistant")
        tooltipAlign: 1
        Accessible.role: Accessible.Button
        Accessible.name: I18n.tr("Cybex OS Assistant")
        onClicked: Assistant.toggleShown(root.host ? root.host.outputName : "")
    }
}
