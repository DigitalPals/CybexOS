const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { shellDir, load } = require("./shell.cjs");

function read(relative) {
    return fs.readFileSync(path.join(shellDir, relative), "utf8");
}

const indicators = read("Bar/Modules/Indicators.qml");

test("open views preserve disclosure through hover loss and pending collapse", () => {
    const vm = require("node:vm");
    const changed = indicators.match(/function onChanged\(\) \{([\s\S]*?)\n        \}/)[1];
    const timeout = indicators.match(/id: collapseDelay[\s\S]*?onTriggered: \{([\s\S]*?)\n        \}/)[1];
    const context = {
        root: {
            host: { tooltipPointerInside: false, popoutActive: true },
            reminderOpen: false,
            disclosureLatched: true
        },
        Settings: { modOpts: { indicators: { mode: "hover" } } },
        collapseDelay: {
            running: true,
            stop() { this.running = false; },
            restart() { this.running = true; }
        }
    };
    vm.createContext(context);
    // Calendar and every other local view stop an already pending collapse.
    vm.runInContext(changed, context);
    assert.equal(context.collapseDelay.running, false);
    vm.runInContext(timeout, context);
    assert.equal(context.root.disclosureLatched, true);
    // Opening an unrelated view does not reveal shortcuts on its own.
    context.root.disclosureLatched = false;
    vm.runInContext(changed, context);
    assert.equal(context.root.disclosureLatched, false);
    context.root.reminderOpen = true;
    vm.runInContext(changed, context);
    assert.equal(context.root.disclosureLatched, true);
    // Closing or handing the view to another output permits normal collapse.
    context.root.reminderOpen = false;
    context.root.host.popoutActive = false;
    vm.runInContext(changed, context);
    assert.equal(context.collapseDelay.running, true);
    context.root.host.tooltipPointerInside = true;
    vm.runInContext(timeout, context);
    assert.equal(context.root.disclosureLatched, true);
    context.root.host.tooltipPointerInside = false;
    vm.runInContext(timeout, context);
    assert.equal(context.root.disclosureLatched, false);
});

test("indicators declares the seven canonical quick actions in order", () => {
    const helpers = load("SettingsHelpers.js");
    assert.deepEqual(helpers.INDICATOR_ACTION_IDS, [
        "dictation", "recording", "ocr", "reminder", "night-light", "dnd", "stay-awake"
    ]);
    assert.deepEqual(helpers.defaultModOpts().indicators.order,
        helpers.INDICATOR_ACTION_IDS);
    assert.match(indicators, /SettingsHelpers\.INDICATOR_ACTION_CHOICES/);
    assert.match(indicators, /Settings\.modOpts\.indicators\.order/);
});

test("OCR is an orderable stateless action that launches the installed helper", () => {
    const helpers = load("SettingsHelpers.js");
    assert.deepEqual(
        helpers.INDICATOR_ACTION_CHOICES.find(action => action.id === "ocr"),
        { id: "ocr", label: "OCR", glyph: "document_scanner" }
    );
    assert.match(indicators, /case "ocr": return false;/,
        "OCR must stay in the inactive disclosure instead of claiming persistent state");
    assert.match(indicators, /OCR a region · copies text · Super Shift O/);
    assert.match(indicators,
        /case "ocr":\s*Quickshell\.execDetached\(\[root\.ocrScript\]\);/);
    assert.match(indicators,
        /Quickshell\.env\("HOME"\) \+ "\/\.local\/bin\/screen-ocr"/);
});

test("inactive disclosure and persistent active actions use separate animated blocks", () => {
    const cluster = read("Bar/Cluster.qml");
    const revealer = read("Common/Revealer.qml");
    assert.match(indicators, /readonly property var inactiveActions:/);
    assert.match(indicators, /readonly property var activeActions:/);
    assert.match(indicators,
        /Revealer\s*\{[\s\S]{0,180}?orientation:\s*Qt\.Horizontal[\s\S]{0,180}?reveal:\s*root\.revealInactive/);
    assert.match(indicators, /opacity:\s*reveal \? 0\.58 : 0/);
    assert.match(indicators,
        /actionEnabled\(action\.id\) && !isActive\(action\.id\)/,
        "inactive shortcuts honor per-action visibility");
    assert.match(indicators,
        /actionEnabled\(action\.id\) \|\| mandatoryWhileActive\(action\.id\)/,
        "running recording and dictation controls can override being hidden");
    assert.match(indicators, /Settings\.modOpts\.indicators\.mode === "always"/);
    assert.match(indicators, /Settings\.modOpts\.indicators\.mode === "hover"/);
    assert.match(indicators, /interval:\s*180/,
        "leaving the bar should use a short anti-oscillation delay");
    assert.match(indicators, /root\.host\.tooltipPointerInside/,
        "disclosure stays latched while the pointer crosses the rest of the bar");
    assert.match(revealer, /readonly property bool widthAnimating:[\s\S]{0,100}?horizontalWidthAnimation\.running/);
    assert.match(revealer,
        /easing\.bezierCurve:\s*root\.reveal\s*\? Theme\.springCurve : Theme\.easeInCurve/,
        "closing disclosure must not spring past zero width and rebound");
    const bar = read("Bar/Bar.qml");
    assert.match(cluster,
        /groupHovered:\s*entry\.modelData\.entry\.id === "indicators"[\s\S]{0,100}?indicatorTriggerHovered/,
        "the separate clock pill must still disclose its neighbouring actions");
    assert.match(cluster,
        /group\.items\[0\]\.entry\.id === "indicators"[\s\S]{0,100}?indicatorDisclosureAnimating/,
        "the Indicators wrapper must yield while its revealer owns width motion");
    assert.match(bar,
        /indicatorTriggerHovered = barWindow\.itemContainsPoint\([\s\S]{0,100}?panelAnchors\.calendar/,
        "bar-wide pointer truth must recover a clock enter lost while mapping a popout");
    assert.doesNotMatch(cluster, /kind === "center"|center:\s*"notifications"/,
        "the indicators must not depend on a shared notification-center target");
    assert.match(bar,
        /readonly property real centerPinBias:[\s\S]{0,180}?currentCenterExtents\(\)/,
        "the clock pin must follow reveal geometry synchronously");
    assert.doesNotMatch(bar, /centerPinBias\s*=/,
        "the deferred fit pass must not assign the clock pin a frame late");
    assert.match(bar,
        /id:\s*centerCluster[\s\S]*?x:\s*parent\.width \/ 2 - barWindow\.currentClockPin\(\)/,
        "center placement must use the clock pin directly, without cancelling two changing widths");
    assert.match(bar, /function itemCenterXWithin\([\s\S]*?position \+= current\.x/,
        "clock placement must react to each intermediate Row layout position");
});

test("clock and weather own their targets without covering indicator actions", () => {
    const cluster = read("Bar/Cluster.qml");
    const clock = read("Bar/Modules/Clock.qml");
    const weather = read("Bar/Modules/Weather.qml");
    assert.match(clock, /BarChip\s*\{[\s\S]*?panelName:\s*"calendar"/);
    assert.match(weather, /BarChip\s*\{[\s\S]*?panelName:\s*"weather"/);
    assert.doesNotMatch(cluster, /ownsPointer|groupPanels|groupMouse/,
        "layout groups must not cover independently interactive widgets");
    assert.doesNotMatch(cluster, /center:\s*"notifications"/);
    assert.match(indicators, /acceptedButtons:\s*Qt\.LeftButton \| Qt\.MiddleButton/);
});

test("recording and dictation expose their complete live state", () => {
    assert.match(indicators, /Recorder\.elapsedLabel/);
    // The recording mark blinks on the elapsed timer's 1 Hz tick: one frame
    // a second, not a pulse that repaints every bar at display rate for the
    // whole recording.
    assert.match(indicators,
        /opacity:\s*button\.recording && !Theme\.reducedMotion\s*&& Recorder\.elapsed % 2 === 1 \? [\d.]+ : 1/,
        "recording must blink with its elapsed timer");
    assert.doesNotMatch(indicators, /SequentialAnimation on opacity/,
        "a continuous recording pulse renders the bar at display rate");
    assert.match(indicators, /Dictation\.recording/);
    assert.match(indicators, /Dictation\.transcribing/);
    assert.match(indicators, /"progress_activity"/);
    assert.match(indicators, /RotationAnimation on rotation/);
    assert.match(indicators,
        /dictationSecondaryLanguage[\s\S]*dictationPrimaryLanguage/);
    assert.match(read("Common/Dictation.qml"),
        /Settings\.modOpts\.indicators\.dictationModel/);
    assert.match(read("Common/Recorder.qml"),
        /Settings\.modOpts\.indicators\.recordingMode/);

    const clock = read("Bar/Modules/Clock.qml");
    const bar = read("Bar/Bar.qml");
    assert.doesNotMatch(clock, /StateMark|do_not_disturb_on|coffee/);
    assert.doesNotMatch(bar, /RecordingChip\s*\{/);
    assert.equal(fs.existsSync(path.join(shellDir, "Bar/RecordingChip.qml")), false);
});

test("active clock-side actions light only their glyph", () => {
    const action = indicators.slice(
        indicators.indexOf("component IndicatorAction:"),
        indicators.indexOf("Revealer {"));

    assert.match(action, /activeState \? Theme\.barAccent\b/);
    assert.doesNotMatch(action, /activeState \? Theme\.barAccentFg\b/);
    assert.match(action, /color:\s*recording \? Theme\.barRed : "transparent"/,
        "an active toggle must not paint an accent pill behind its glyph");
    assert.match(action,
        /BarHover\s*\{[\s\S]{0,120}?target:\s*button/,
        "clock-side actions must use the same hover surface as other modules");
    assert.doesNotMatch(action,
        /\n\s*color:\s*[\s\S]{0,100}?activeState/);
});

test("indicator settings cover ordering, display, actions, and feature defaults", () => {
    const detail = read("Settings/ModuleDetailView.qml");
    for (const key of [
        "order", "enabled", "dictationPrimaryLanguage", "dictationSecondaryLanguage",
        "dictationModel", "recordingMode", "recordingShowElapsed",
        "reminderDisplay", "reminderClick", "reminderMinutes",
        "nightLightStartup", "dndStartup", "dndDefaultMode",
        "idleStartup", "idleDefaultMode", "idleShowRemaining"
    ])
        assert.match(detail, new RegExp(`(?:view\\.opts\\.|view\\.(?:set|reset)Opt\\(\")${key}`),
            `${key} must be reachable from the Indicators settings page`);
    assert.match(detail, /value:\s*"active", label:\s*"Active only"/);
    assert.match(detail, /function beginIndicatorDrag/);
    assert.match(detail, /function commitIndicatorDrag/);
    assert.match(detail, /SettingsHelpers\.DICTATION_MODEL_CHOICES/);
    assert.match(detail, /Restarting only the menubar resumes its current state/);
    assert.match(indicators, /Settings\.modOpts\.indicators\.reminderDisplay/);
    assert.match(indicators, /Settings\.modOpts\.indicators\.idleShowRemaining/);
    assert.match(indicators, /Notifs\.toggleDefaultDnd\(\)/);
    assert.match(indicators, /Reminders\.add\(Settings\.modOpts\.indicators\.reminderMinutes/);
});

test("all shared toggles use one persisted write path", () => {
    const sys = read("Common/SysInfo.qml");
    const control = read("Popovers/ControlCenterPopover.qml");
    assert.match(sys, /readonly property bool nightLight:\s*Settings\.nightLight/);
    assert.match(sys,
        /readonly property bool idleInhibited:\s*idleInhibitMode !== "off"/);
    assert.match(sys, /readonly property string idleInhibitMode:\s*Settings\.idleInhibitMode/);
    assert.match(sys, /readonly property double idleInhibitUntilMs:\s*Settings\.idleInhibitUntilMs/);
    assert.match(sys, /function setIdleInhibitMode\(mode\)/);
    assert.match(sys, /\["off", "30m", "1h", "unplugged", "always"\]/);
    assert.match(sys, /idleInhibitUntilMs/);
    assert.match(sys, /onPluggedInChanged/);
    assert.match(sys, /function setNightLight\(value\)/);
    assert.match(sys, /function toggleNightLight\(\)/);
    assert.match(sys, /function setIdleInhibited\(value\)/);
    assert.match(sys, /function toggleIdleInhibited\(\)/);
    assert.match(sys, /Settings\.modOpts\.indicators\.idleDefaultMode/);
    assert.match(sys, /function applyStartupPolicies\(\)/);
    assert.match(sys, /Startup\.firstStart/);
    for (const state of ["nightLightPending", "nightLightEffective",
        "nightLightError", "idleInhibitPending", "idleInhibitEffective",
        "idleInhibitError"])
        assert.match(sys, new RegExp(`property \\w+ ${state}:`),
            `${state} must distinguish desired state from process reality`);
    assert.match(sys,
        /id: nightLightConfirm[\s\S]*nightLightEffective = true/);
    assert.match(sys,
        /id: idleInhibitConfirm[\s\S]*idleInhibitEffective = true/);
    assert.match(sys,
        /nightLightLifecycle = "error"[\s\S]*nightLightRetry\.restart\(\)/);
    assert.match(sys,
        /idleInhibitLifecycle = "error"[\s\S]*idleInhibitRetry\.restart\(\)/);
    assert.match(control, /onToggled:\s*SysInfo\.toggleNightLight\(\)/);
    assert.match(control, /onToggled:\s*SysInfo\.toggleIdleInhibited\(\)/);
    assert.match(control, /statusOverride:\s*SysInfo\.idleInhibitStatus/);
    const systemPage = read("Settings/SystemPage.qml");
    for (const mode of ["off", "30m", "1h", "unplugged", "always"])
        assert.match(systemPage, new RegExp(`value: "${mode}"`));
    assert.match(systemPage, /SysInfo\.setIdleInhibitMode\(value\)/);

    const notifs = read("Common/Notifs.qml");
    assert.match(notifs, /function setDndMode\(mode\)/);
    assert.match(notifs, /function toggleDefaultDnd\(\)/);
    assert.match(notifs, /Settings\.notifDndUntilMs/);
    assert.match(notifs, /Settings\.modOpts\.indicators\.dndDefaultMode/);
    assert.match(notifs, /Startup\.firstStart/);

    const startup = read("Common/Startup.qml");
    assert.match(startup, /XDG_RUNTIME_DIR/);
    assert.match(startup, /HYPRLAND_INSTANCE_SIGNATURE/,
        "a lingering user manager must still distinguish compositor sessions");
    assert.match(startup, /text\(\)\.trim\(\) !== root\.sessionKey/,
        "service reloads in one compositor session must not reapply login policy");
    assert.match(startup, /error === FileViewError\.FileNotFound/,
        "an absent marker must be treated as a fresh login");
    assert.match(startup, /else \{[\s\S]{0,180}?root\.finish\(false\)/,
        "permission and IO failures must not be mistaken for a fresh login");
});

test("Control Panel fills use their intended accent strength", () => {
    const control = read("Popovers/ControlCenterPopover.qml");
    const battery = read("Popovers/BatteryPopover.qml");
    const slider = read("Popovers/FillSlider.qml");
    const radioRow = control.slice(
        control.indexOf("component RadioRow:"),
        control.indexOf("component QuickTile:"));

    // The radios are rows: they carry a value and a chevron, and a row that is
    // merely connected is not a selection, so nothing about them is painted.
    // Only its mark takes the accent.
    assert.match(radioRow,
        /color: radioMouse\.containsMouse \|\| activeFocus \? Theme\.chip : "transparent"/,
        "keyboard focus must expose the same neutral state layer as hover");
    assert.doesNotMatch(radioRow, /Theme\.(?:accentContainer|accentSoft|accentBg|accentSubtle)/,
        "a radio row must not paint an accent field behind its label");
    assert.match(radioRow, /color: radio\.on \? Theme\.accentText : Theme\.icon/,
        "the accent survives on the glyph, where it is a mark");

    // Quick actions and value sliders use the same full-strength accent as
    // the machine meters, with the palette's foreground on top.
    const quickTile = control.slice(
        control.indexOf("component QuickTile:"),
        control.indexOf("component SessionAction:"));
    assert.match(quickTile, /tile\.effective \? Theme\.accent\b/,
        "process-backed actions light only after the requested state is effective");
    assert.match(quickTile, /tile\.effective\s*\n\s*\? Theme\.accentFg/);
    assert.doesNotMatch(quickTile, /Theme\.accentContainer/,
        "active quick actions must not use the darker container treatment");
    // A running capture is the one state that owns a field of its own, and it
    // is the error colour, not the accent. It moved out of the grid with the
    // other two capture actions, so the rule is asserted on the track.
    assert.match(control, /capture\.recording \? Theme\.redBg/);
    // The power profile is a segmented control: its held segment takes the
    // chip, never an accent field. (Accent survives on that segment's ripple
    // tint, which is a mark.) It lives only in BatteryPopover now — the
    // Control Panel stopped carrying a second copy of the battery's controls.
    assert.match(battery, /color: current \? Theme\.chipHover/);
    assert.doesNotMatch(battery, /color: current \? Theme\.accent\b/);
    assert.doesNotMatch(control, /PowerProfiles/,
        "the profile track lives in BatteryPopover, not in the dashboard");
    assert.match(control, /property color barTone: Theme\.accent/,
        "machine meters must establish the full-strength accent reference");
    assert.match(slider, /color: Theme\.accent/,
        "slider values must use the same full-strength accent as machine meters");
    assert.doesNotMatch(slider,
        /Theme\.(?:accentContainer|accentBgSoft|accentSoft)/,
        "slider values must not use one of the darker accent treatments");
});

test("reminder manager and shell-wide refresh IPC are wired to the action", () => {
    const registry = read("Common/PanelRegistryData.js");
    const shell = read("shell.qml");
    const manager = read("Popovers/ReminderPopover.qml");
    assert.match(indicators, /panelName:\s*"reminders"/);
    assert.match(registry,
        /name:\s*"reminders"[^\n]+moduleId:\s*"indicators"[^\n]+ReminderPopover\.qml/);
    assert.match(shell, /target:\s*"reminders"[\s\S]{0,120}?Reminders\.refresh\(\)/);
    for (const minutes of [5, 15, 30, 60])
        assert.match(manager, new RegExp(`\\b${minutes}\\b`));
    assert.match(manager, /validator:\s*IntValidator \{ bottom: 1 \}/);
    assert.match(manager, /Optional message/);
    assert.match(manager, /root\.clearArmed \? "Confirm clear all" : "Clear all"/);
    assert.match(manager, /Reminders\.cancel\(reminderRow\.modelData\.id\)/);
});
