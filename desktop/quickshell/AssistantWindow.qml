pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Window
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import "Common"
import "Assistant"
import "Common/AssistantHelpers.js" as AssistantHelpers

// The Cybex OS Assistant on screen (docs/assistant.md): the character, and the
// box under it — the composer, the working pill or the reply.
//
// One overlay surface covering the output the character is on, taking input
// only on the character and the box. A layer surface belongs to one output,
// so a drag that ends on another display moves the character there and the
// surface follows. The layer is neither blurred nor animated by Hyprland
// (looknfeel.lua), which is what makes a full-output surface affordable.
//
// Hovering opens the composer without taking the keyboard, so typing in the
// window underneath carries on; a click or Super+I gives it the keyboard.
PanelWindow {
    id: root

    readonly property real size: Theme.scaled(64)
    // The bar's band at the top, kept clear by the default place and the box.
    readonly property real topReserve: Settings.position === "top"
        ? Theme.barHeight + Theme.barTopMargin : 0
    readonly property var resting: AssistantHelpers.placement(
        { x: Settings.assistantX, y: Settings.assistantY },
        { width: root.width, height: root.height }, root.size, root.topReserve)

    property bool dragging: false
    // A button went down on the character and has not come up yet.
    property bool pressing: false
    property real dragX: 0
    property real dragY: 0
    property point pressWindow: Qt.point(0, 0)
    property point pressBubble: Qt.point(0, 0)
    readonly property real bubbleX: dragging ? dragX : resting.x
    readonly property real bubbleY: dragging ? dragY : resting.y
    readonly property var dockPlace: AssistantHelpers.dockPlacement(
        { x: root.bubbleX, y: root.bubbleY }, root.size,
        { width: root.width, height: root.height }, Theme.scaled(360), root.topReserve)

    // One surface at a time; the working pill wins, then the reply.
    readonly property bool showWorking: Assistant.busy && !Assistant.tucked
    readonly property bool showReply: Assistant.replyOpen && !Assistant.composing && !Assistant.busy
    readonly property bool showComposer: Assistant.composing && !Assistant.busy
    readonly property bool boxOpen: (showComposer || showWorking || showReply) && !Assistant.capturing
    // The box steps out of the way while the character is dragged.
    readonly property bool dockShown: boxOpen && !dragging

    // The keyboard goes to the box only when it was asked for. Exclusive
    // first, so the compositor hands it over without a click; then OnDemand
    // under a focus grab, so a click anywhere else takes it back (the
    // launcher's arrangement, LauncherWindow.qml).
    readonly property bool keyboardWanted: Assistant.focusRequested
        && (showComposer || (showWorking && Assistant.waiting))
    readonly property bool keyboardActive: root.contentItem.Window.active
    property bool grabReady: false
    onKeyboardActiveChanged: {
        if (keyboardActive && keyboardWanted)
            grabReady = true;
    }
    onKeyboardWantedChanged: {
        if (!keyboardWanted)
            grabReady = false;
        else if (keyboardActive)
            grabReady = true;
    }

    screen: Assistant.screen
    // Not root.screen: the window writes that back as it maps, which would
    // loop through this binding.
    visible: Assistant.shown && Assistant.screen !== null
    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"

    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "qs-assistant"
    // Follows the open box, not its drawing: a drag that hides the box
    // must not change the surface's keyboard mode under the held button.
    WlrLayershell.keyboardFocus: !root.boxOpen ? WlrKeyboardFocus.None
        : root.keyboardWanted && !grab.active ? WlrKeyboardFocus.Exclusive
        : WlrKeyboardFocus.OnDemand

    mask: Region {
        item: character

        Region {
            item: dockMask
        }

        Region {
            item: pressMask
        }
    }

    HyprlandFocusGrab {
        id: grab
        active: root.keyboardWanted && root.grabReady && root.visible
        windows: [root]
        onCleared: {
            root.grabReady = false;
            Assistant.focusRequested = false;
            Assistant.hoverEnded();
        }
    }

    // ---- hover ---------------------------------------------------------------
    readonly property bool pointerInside: characterHover.hovered || dockHover.hovered

    // A pass on the way somewhere else does not open the box.
    Timer {
        id: hoverDwell
        interval: 260
        onTriggered: {
            if (characterHover.hovered && !Assistant.busy && !Assistant.replyOpen
                    && !Assistant.composing && !root.dragging)
                Assistant.openComposer(false);
        }
    }

    Timer {
        id: leaveGrace
        interval: 700
        onTriggered: {
            if (!root.pointerInside)
                Assistant.hoverEnded();
        }
    }

    onPointerInsideChanged: {
        if (pointerInside)
            leaveGrace.stop();
        else
            leaveGrace.restart();
    }

    Item {
        id: stage
        anchors.fill: parent
        // Hidden for the screenshot it is about to take.
        opacity: Assistant.capturing ? 0 : 1

        // ---- the character ------------------------------------------------------
        AssistantCharacter {
            id: character
            x: root.bubbleX
            y: root.bubbleY
            width: root.size
            height: root.size
            mood: Assistant.mood
            mascot: Settings.assistantCharacter !== "mark"
            level: composer.level
            hovered: characterHover.hovered
            unread: Assistant.unread
            boxAbove: root.dockPlace.above
            scale: dragArea.pressed && !root.dragging ? 0.94 : root.dragging ? 1.06 : 1
            rotation: root.dragging && !Theme.reducedMotion
                ? AssistantHelpers.clamp((root.dragX - root.pressBubble.x) / 40, -8, 8) : 0
            Accessible.role: Accessible.Button
            Accessible.name: I18n.tr("Cybex OS Assistant")
            Accessible.description: Assistant.busy ? I18n.tr("Working. Click to tuck the box away.")
                : I18n.tr("Click to ask a question. Drag to move.")

            Behavior on x {
                enabled: !root.dragging && !Theme.reducedMotion
                NumberAnimation { duration: Theme.expandDuration; easing.type: Easing.OutCubic }
            }
            Behavior on y {
                enabled: !root.dragging && !Theme.reducedMotion
                NumberAnimation { duration: Theme.expandDuration; easing.type: Easing.OutCubic }
            }
            Behavior on scale {
                enabled: !Theme.reducedMotion
                NumberAnimation {
                    duration: Theme.pressDuration
                    easing.type: Easing.BezierSpline
                    easing.bezierCurve: Theme.springCurve
                }
            }

            HoverHandler {
                id: characterHover
                onHoveredChanged: {
                    if (hovered)
                        hoverDwell.restart();
                    else
                        hoverDwell.stop();
                }
                onPointChanged: {
                    character.lookX = AssistantHelpers.clamp(
                        (point.position.x - character.width / 2) / (character.width / 2), -1, 1);
                    character.lookY = AssistantHelpers.clamp(
                        (point.position.y - character.height / 2) / (character.height / 2), -1, 1);
                }
            }

        }

        // Keep pointer coordinates on the stationary output, independent of
        // the character's movement, press scale and playful drag rotation.
        // Moving the MouseArea with the character feeds those transforms back
        // into its local mouse coordinates and can reduce a drag to a wobble.
        MouseArea {
            id: dragArea
            anchors.fill: parent
            preventStealing: true
            cursorShape: root.dragging ? Qt.ClosedHandCursor : Qt.PointingHandCursor

            onPressed: mouse => {
                const local = character.mapFromItem(dragArea, mouse.x, mouse.y);
                if (!character.contains(local)) {
                    // A press that never came up (released on another
                    // output) leaves no full-output region behind.
                    root.pressing = false;
                    mouse.accepted = false;
                    return;
                }
                root.pressing = true;
                root.pressWindow = Qt.point(mouse.x, mouse.y);
                root.pressBubble = Qt.point(character.x, character.y);
                root.lastPointer = root.pressWindow;
            }
            onPositionChanged: mouse => {
                if (!pressed)
                    return;
                // In window coordinates; the press keeps the pointer, so
                // positions beyond this output still arrive here.
                const dx = mouse.x - root.pressWindow.x;
                const dy = mouse.y - root.pressWindow.y;
                if (!root.dragging && !AssistantHelpers.dragged(dx, dy))
                    return;
                if (!root.dragging) {
                    root.dragX = root.pressBubble.x;
                    root.dragY = root.pressBubble.y;
                    root.dragging = true;
                    Assistant.dragging = true;
                    hoverDwell.stop();
                }
                root.dragX = AssistantHelpers.clamp(root.pressBubble.x + dx, 0, root.width - root.size);
                root.dragY = AssistantHelpers.clamp(root.pressBubble.y + dy, 0, root.height - root.size);
                root.lastPointer = Qt.point(mouse.x, mouse.y);
            }
            onReleased: {
                root.pressing = false;
                if (root.dragging)
                    root.finishDrag();
                else
                    Assistant.characterClicked();
            }
            onCanceled: {
                root.pressing = false;
                if (root.dragging)
                    root.finishDrag();
            }
        }

        // ---- the box ----------------------------------------------------------
        Item {
            id: dock

            readonly property Item current: root.showWorking ? working
                : root.showReply ? replyCard : root.showComposer ? composer : null

            x: root.dockPlace.x
            width: root.dockPlace.width
            height: current ? current.height : 0
            y: root.dockPlace.above ? root.dockPlace.anchorY - height : root.dockPlace.anchorY
            opacity: root.dockShown ? 1 : 0
            visible: opacity > 0.01

            Behavior on opacity {
                NumberAnimation { duration: Theme.popoutFadeInDuration }
            }

            HoverHandler {
                id: dockHover
            }

            AssistantComposer {
                id: composer
                width: parent.width
                visible: root.showComposer
            }

            AssistantWorking {
                id: working
                width: parent.width
                visible: root.showWorking
            }

            AssistantReply {
                id: replyCard
                width: parent.width
                visible: root.showReply
                room: root.dockPlace.room
            }
        }

        // What the input mask admits of the box: nothing while it is hidden.
        Item {
            id: dockMask
            x: dock.x
            y: dock.y
            width: root.dockShown ? dock.width : 0
            height: root.dockShown ? dock.height : 0
        }

        // While the button is held the whole output takes the pointer, so
        // every motion of a drag arrives here even before the character's
        // own region has caught up with the pointer.
        Item {
            id: pressMask
            width: root.pressing ? stage.width : 0
            height: root.pressing ? stage.height : 0
        }
    }

    property point lastPointer: Qt.point(0, 0)

    // A drop on this output stays here; one past its edge lands on the
    // display under the pointer, at the same spot under the pointer.
    function finishDrag() {
        const outputs = Quickshell.screens.map(s => ({ x: s.x, y: s.y, width: s.width, height: s.height }));
        const globalX = root.screen.x + root.lastPointer.x;
        const globalY = root.screen.y + root.lastPointer.y;
        const index = AssistantHelpers.outputAt(outputs, globalX, globalY);
        const target = index >= 0 ? Quickshell.screens[index] : root.screen;
        if (target !== root.screen) {
            const grabX = root.pressWindow.x - root.pressBubble.x;
            const grabY = root.pressWindow.y - root.pressBubble.y;
            Assistant.moveTo(target.name,
                AssistantHelpers.clamp(globalX - target.x - grabX, 0, target.width - root.size),
                AssistantHelpers.clamp(globalY - target.y - grabY, 0, target.height - root.size));
        } else {
            Assistant.moveTo(root.screen.name, root.dragX, root.dragY);
        }
        root.dragging = false;
        Assistant.dragging = false;
    }
}
