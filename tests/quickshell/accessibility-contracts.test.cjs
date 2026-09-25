const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { shellDir } = require("./shell.cjs");

// Quickshell's Fedora package embeds quickshell-coreplugin into the `qs`
// executable, so standalone qmltestrunner cannot instantiate these controls.
// Keep the pure-JS helper runtime tests in tests/qml and guard the shell-bound
// interaction contract here until the package exposes a loadable QML plugin.
function read(relative) {
    return fs.readFileSync(path.join(shellDir, relative), "utf8");
}

test("popover action primitives are keyboard and assistive-technology operable", () => {
    const link = read("Popovers/LinkText.qml");
    assert.match(link, /activeFocusOnTab:\s*enabled && visible/);
    assert.match(link, /Accessible\.role:\s*Accessible\.Button/);
    assert.match(link, /Accessible\.name:\s*accessibleName/);
    assert.match(link, /Qt\.Key_Return[\s\S]*Qt\.Key_Enter[\s\S]*Qt\.Key_Space/);
    assert.match(link, /font\.underline:\s*activeFocus/,
        "a keyboard-focused text action needs a visible focus state");

    const slider = read("Popovers/FillSlider.qml");
    assert.match(slider, /Accessible\.role:\s*Accessible\.Slider/);
    assert.match(slider, /Accessible\.onIncreaseAction:\s*applyValue/);
    assert.match(slider, /Accessible\.onDecreaseAction:\s*applyValue/);
    for (const key of ["Left", "Right", "PageDown", "PageUp", "Home", "End"])
        assert.match(slider, new RegExp(`Qt\\.Key_${key}`));
    assert.match(slider,
        /glyphIsButton[\s\S]*activeFocusOnTab:\s*visible && root\.ready[\s\S]*Accessible\.role:\s*Accessible\.Button/,
        "the mute glyph must be a separate named keyboard action");
});

test("every overflowed widget remains keyboard reachable with visible focus", () => {
    const overflow = read("Popovers/OverflowPopover.qml");
    assert.match(overflow, /activeFocusOnTab:\s*true/,
        "every repeated row must participate in sequential Tab focus");
    assert.match(overflow,
        /color:\s*rowMouse\.containsMouse \|\| activeFocus[\s\S]{0,100}?Theme\.hoverFill/,
        "keyboard focus needs the same visible highlight as pointer hover");
    assert.match(overflow,
        /Accessible\.role:\s*Accessible\.Button[\s\S]*Accessible\.name:\s*modelData\.label/);
    assert.match(overflow,
        /Qt\.Key_Return[\s\S]*Qt\.Key_Enter[\s\S]*Qt\.Key_Space/);
});

test("notification history exposes primary, action, disclosure, dismiss, and clear paths", () => {
    const card = read("Common/NotifCard.qml");
    const actions = read("Common/NotifActions.qml");
    const centre = read("Popovers/NotifsPopover.qml");

    assert.match(card, /activeFocusOnTab:\s*keyboardEnabled && actionable/);
    assert.match(card, /Accessible\.role:\s*actionable \? Accessible\.Button : Accessible\.StaticText/);
    assert.match(card, /Qt\.Key_Delete[\s\S]*card\.closeRequested\(\)/);
    assert.match(card,
        /id:\s*closeButton[\s\S]*activeFocusOnTab:\s*card\.keyboardEnabled[\s\S]*Accessible\.name:\s*"Dismiss notification/);
    assert.match(card,
        /id:\s*textDisclosure[\s\S]*activeFocusOnTab:\s*visible && card\.keyboardEnabled[\s\S]*Accessible\.name:/);
    assert.match(actions,
        /activeFocusOnTab:\s*root\.keyboardEnabled && root\.reveal[\s\S]*Accessible\.name:\s*pill\.modelData\.text/);
    assert.match(actions, /hasFocusedAction:\s*focusedActions > 0/,
        "focus must keep contextual actions revealed after the pointer leaves");

    assert.match(centre, /focus:\s*visible/);
    assert.match(centre, /Keys\.onEscapePressed:\s*Popouts\.close\(\)/);
    assert.match(centre, /function focusInitial\(\)/);
    assert.match(centre, /keyboardEnabled:\s*true/);
    assert.match(centre, /id:\s*clearAll[\s\S]*enabled:\s*Notifs\.count > 0/);
    assert.match(centre, /Accessible\.role:\s*Accessible\.AlertMessage/,
        "notification-count changes need a nonvisual announcement channel");
});

test("Control Center focus reaches rows, toggles, audio, capture, session, and footer actions", () => {
    const control = read("Popovers/ControlCenterPopover.qml");
    assert.match(control, /focus:\s*visible/);
    assert.match(control,
        /Keys\.onEscapePressed:[\s\S]{0,260}?pendingSessionKey[\s\S]{0,260}?Popouts\.close\(\)/,
        "Escape cancels a pending destructive action before closing the panel");
    assert.match(control,
        /function focusInitial\(\)[\s\S]*brightnessSlider\.ready \? brightnessSlider : outputButton/);

    for (const component of ["RadioRow", "QuickTile", "SessionAction"])
        assert.match(control, new RegExp(
            `component ${component}:[\\s\\S]*?activeFocusOnTab: true[\\s\\S]*?Accessible\\.role:[\\s\\S]*?Keys\\.onPressed:`));
    assert.match(control,
        /component QuickTile:[\s\S]*Accessible\.checked:\s*tile\.effective/,
        "quick toggles must expose observed state, not just persisted intent");
    assert.match(control,
        /component QuickTile:[\s\S]*Accessible\.description:\s*tile\.statusDescription/,
        "pending and failure state must be announced with the toggle");
    assert.match(control,
        /id:\s*outputButton[\s\S]*Accessible\.name:\s*"Choose audio output"/);
    assert.match(control,
        /required property var modelData[\s\S]*Accessible\.name:\s*capture\.label[\s\S]*root\.runCapture/);
    for (const label of ["Open CybexOS Settings", "Keyboard shortcuts"])
        assert.match(control, new RegExp(`Accessible\\.name: "${label}"`));
});

test("Bluetooth and media panels announce state and expose one focusable action per control", () => {
    const bluetooth = read("Popovers/BluetoothPopover.qml");
    assert.match(bluetooth, /function focusInitial\(\)[\s\S]*bluetoothToggle\.forceActiveFocus/);
    assert.match(bluetooth,
        /readonly property string actionName:[\s\S]*activeFocusOnTab:\s*enabled[\s\S]*Accessible\.name:\s*actionName/);
    assert.match(bluetooth, /Qt\.Key_(?:Down|Right)[\s\S]*nextItemInFocusChain\(true\)/);
    assert.match(bluetooth, /Accessible\.role:\s*Accessible\.AlertMessage/);

    const media = read("Popovers/MediaPopover.qml");
    assert.match(media, /function focusInitial\(\)/);
    assert.match(media,
        /component TransportButton:[\s\S]*activeFocusOnTab:\s*available[\s\S]*Accessible\.checked:\s*toggle && active/);
    assert.match(media, /Qt\.Key_(?:Right|Down)[\s\S]*nextItemInFocusChain\(true\)/);
    assert.match(media,
        /Accessible\.name:\s*"Choose media player"[\s\S]*root\.selectSource\(-1\)/);
    assert.match(media, /Accessible\.role:\s*Accessible\.AlertMessage/);
});

test("reduced-motion mode stops infinite activity loops instead of busy-looping at zero duration", () => {
    const theme = read("Common/Theme.qml");
    assert.match(theme, /Quickshell\.env\("QS_REDUCED_MOTION"\)/);
    assert.match(theme,
        /\(Quickshell\.env\("QS_REDUCED_MOTION"\) \|\| ""\)\.trim\(\)\.toLowerCase\(\)/,
        "an unset optional environment override must retain the default motion mode");
    assert.match(theme, /readonly property bool reducedMotion:/);

    for (const relative of [
        "Bar/Modules/Indicators.qml",
        "Popovers/BatteryPopover.qml",
        "Popovers/T3Composer.qml",
        "Popovers/T3ThreadPage.qml",
        "Popovers/UpdatesPopover.qml",
        "Popovers/WifiPopover.qml"
    ]) {
        const source = read(relative);
        const loops = [...source.matchAll(/(?:RotationAnimation|SequentialAnimation)[\s\S]*?loops:\s*Animation\.Infinite/g)];
        assert.ok(loops.length > 0, `${relative} no longer contains the loop this contract covers`);
        for (const match of loops)
            assert.match(match[0], /running:[^\n]*(?:\n\s*)?[^\n]*!Theme\.reducedMotion/,
                `${relative} has an infinite loop that ignores reduced motion`);
    }
});
