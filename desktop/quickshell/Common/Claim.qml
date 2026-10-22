import QtQuick

// Holds a claim on a polling singleton for exactly as long as `active` is
// true, and gives up the claim on teardown even if `active` never went false.
//
// This exists because lifecycle hooks are the wrong signal. `IslandPopout`
// latches the Control Panel (its `warmNames`), so that panel is constructed
// once and never destroyed — an acquire in `Component.onCompleted` with a
// release in `Component.onDestruction` would leave its pollers running for
// the rest of the session, which is worse than the `Popouts.open` gate it
// replaced. An item's `visible` does track presence, because window
// visibility propagates down to items, and it works the same for latched and
// non-latched panels.
//
//   Claim {
//       active: root.visible
//       onClaimed: SysInfo.acquire()
//       onReleased: SysInfo.release()
//   }
//
// The signals stay unpaired-proof: `held` guarantees the two edges alternate,
// so a consumer can never double-release.
QtObject {
    id: claim

    property bool active: false
    readonly property bool held: heldInternal

    signal claimed()
    signal released()

    property bool heldInternal: false

    function sync() {
        if (active === heldInternal)
            return;
        heldInternal = active;
        if (heldInternal)
            claim.claimed();
        else
            claim.released();
    }

    onActiveChanged: sync()
    Component.onCompleted: sync()

    // A destroyed claim is a released one. Nothing else runs after this, so
    // going through sync() would only obscure that.
    Component.onDestruction: {
        if (heldInternal) {
            heldInternal = false;
            claim.released();
        }
    }
}
