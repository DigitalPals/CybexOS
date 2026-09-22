import QtQuick
import "../Common"

// The contract the popout host has with whatever it loads.
//
// These three things used to be duck-typed at the host: it asked
// `item.availableWidth !== undefined` before sizing, `item.drawBackground
// !== undefined` before suppressing a doubled background, and
// `item.handleEscape && item.handleEscape()` before dismissing. None of that
// could be checked, and a panel that misspelled one simply never got the
// behaviour. Declaring them here lets IslandPopout hold its loaded item as a
// PopoutPanel and read them as properties.
//
// A FocusScope rather than an Item because Settings/SettingsView.qml is one
// and needs to stay one; every popover surface inherits this through
// Popovers/Surface.qml. Panels that want the keyboard say `focus: true`
// themselves — setting it here would have both of the host's two content
// slots claiming focus at once, including the one that is off screen.
FocusScope {
    id: root

    // Most panels use the shell surface. A product-integrated panel can
    // supply its own canvas without teaching the host about panel names.
    property color surfaceColor: Theme.barSurface
    property color surfaceBorderColor: Theme.surfaceBorderColor

    // The host paints the surface itself while it morphs the panel out of the
    // bar. A panel that draws its own background turns this off then, so the
    // two do not stack.
    property bool drawBackground: true

    // The usable envelope of the output the host is drawn on. The host has
    // already taken off the side margins, the bar and a shadow budget, so a
    // panel must not subtract them again.
    property real availableWidth: 0
    property real availableHeight: 0

    // Some controls need native surface room beyond the panel's own card. The
    // host keeps this trailing extent transparent and adds the supplied item
    // to its input region, so a floating menu can sit outside the card without
    // turning that room into a second full-width slab.
    property real detachedOverflowHeight: 0
    property Item detachedOverflowItem: null

    // Escape inside a panel. Return true if the panel consumed it — going back
    // a page, closing a sub-view, clearing a search — and false to let the
    // host dismiss the popout, which is what this default does.
    function handleEscape(): bool {
        return false;
    }
}
