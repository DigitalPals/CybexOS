import QtQuick
import ".."
import "../../Common"

// Notes is intentionally icon-only: its content belongs in the Markdown
// popover, while the tooltip carries the one useful at-a-glance value.
BarModule {
    id: root

    moduleId: "notes"

    BarIcon {
        id: icon
        host: root.host
        panelName: "notes"
        isle: root.isle
        anchorItem: root.groupAnchor ?? icon
        glyph: "sticky_note_2"
        label: ""
        tooltip: Notes.count === 0 ? "Notes"
            : Notes.count + (Notes.count === 1 ? " note" : " notes")
    }
}
