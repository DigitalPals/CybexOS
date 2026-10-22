import QtQuick
import "../Common"

// One hover surface for every interactive target in the menubar.
//
// MouseAreas remain responsible for their target-specific actions, but they
// are deliberately not the source of visual hover truth. A grouped target can
// own one MouseArea above several content modules, and a layer surface can
// cost a child MouseArea an enter or exit event. The bar-wide HoverHandler
// sees both cases, so validate its scene point against the actual click target
// and let the background and tooltip share that one answer.
StateLayer {
    id: root

    required property Bar host
    required property Item target
    property bool visualEnabled: true

    readonly property bool over: pointer.over
    readonly property PointerCheck check: pointer

    hovered: visualEnabled && over

    PointerCheck {
        id: pointer
        host: root.host
        target: root.target
        // The bar-wide point is the primary opinion for a visual target. It
        // does not depend on a child MouseArea receiving the same event.
        hovered: true
    }
}
