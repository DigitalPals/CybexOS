import QtQuick
import "../Common"
import "Modules"

// One configured module in the bar: loads the module's component when the
// module is enabled and its auto-rule allows it, and hands it the context it
// needs to draw itself — including which column it landed in.
//
// Lived inside Bar.qml as an inline component until the bar started grouping
// modules into pills; Cluster needs the type by name, and an inline component
// is not reachable from another file.
Loader {
    id: slot

    required property var modelData
    required property int index
    required property Bar host
    property string col: "left"
    // Optional composite context retained for modules whose content can be
    // embedded in another target. Current configurable widgets are interactive
    // themselves, so Cluster leaves these defaults alone.
    property Item groupAnchor: null
    property bool interactive: true
    // Trigger hover handed to progressive-disclosure content. The clock uses
    // this to reveal its adjacent Indicators module without sharing a target.
    property bool groupHovered: false

    // `as` gives qmllint a typed handle on what the Loader built, so the
    // module contract below is checked rather than duck-typed.
    readonly property BarModule mod: item as BarModule
    readonly property real detailSaving: mod ? mod.detailSaving : 0

    anchors.verticalCenter: parent ? parent.verticalCenter : undefined
    // Every output carries a bar, but only the mapped one is visible; the
    // others must not instantiate a full set of modules (and their timers)
    // behind an unmapped surface.
    active: host.visible && modelData.on && host.autoRule(modelData.id)
    visible: active && !host.moduleOverflowed(modelData.id)
    source: host.moduleSources[slot.modelData.id] ?? ""

    // Dimmed, not removed, while it is being dragged along the bar: the drag
    // reads the live slot positions to decide where a drop lands, and taking
    // this one out from under the pointer would resequence every measurement
    // it is being compared against.
    opacity: host.dragWidget && host.dragWidget.id === slot.modelData.id ? 0.35 : 1

    Behavior on opacity {
        NumberAnimation { duration: Theme.chipFadeDuration }
    }

    // `host` goes last on purpose. Assigning it is what makes a module's chip
    // own its panel, and the chip registers its anchor at that moment — so
    // everything the anchor is derived from has to be in place first, or the
    // panel registers under the glyph and its popout hangs off-centre until
    // something else re-registers it.
    onLoaded: {
        if (slot.mod) {
            slot.mod.isle = slot.col;
            slot.mod.groupAnchor = slot.groupAnchor;
            slot.mod.interactive = slot.interactive;
            slot.mod.groupHovered = slot.groupHovered;
            slot.mod.host = slot.host;
        }
        host.scheduleFit();
    }

    onWidthChanged: host.scheduleFit()
    onDetailSavingChanged: host.scheduleFit()
    onGroupHoveredChanged: {
        if (slot.mod)
            slot.mod.groupHovered = slot.groupHovered;
    }

    // The bar's fit pass needs every live slot, and the alternative — walking
    // the grouped Repeaters — hands it back an untyped QQuickItem it cannot
    // read `detailSaving` off. Registering by module id works because
    // normalizeMods() guarantees an id appears at most once across all three
    // columns.
    Component.onCompleted: host.registerSlot(modelData.id, slot)
    Component.onDestruction: host.unregisterSlot(modelData.id, slot)
}
