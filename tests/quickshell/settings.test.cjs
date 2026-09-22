const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { shellDir, load } = require("./shell.cjs");

function read(relative) {
    return fs.readFileSync(path.join(shellDir, relative), "utf8");
}

test("the settings IPC target is declared exactly once shell-wide", () => {
    const qmlFiles = [];
    const walk = dir => {
        for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
            if (entry.isDirectory() && !entry.name.startsWith(".") && entry.name !== "tests")
                walk(path.join(dir, entry.name));
            else if (entry.name.endsWith(".qml"))
                qmlFiles.push(path.join(dir, entry.name));
        }
    };
    walk(shellDir);
    const declaring = qmlFiles.filter(file =>
        /target:\s*"settings"/.test(fs.readFileSync(file, "utf8")));
    assert.deepEqual(declaring.map(file => path.relative(shellDir, file)),
        ["shell.qml"]);
});

test("every connected output keeps a bar while popouts stay single-hosted", () => {
    const shell = read("shell.qml");
    const screens = read("Common/Screens.qml");
    const bar = read("Bar/Bar.qml");
    const window = read("Bar/BarPopoutWindow.qml");
    const popouts = read("Common/Popouts.qml");
    const barPage = read("Settings/BarLayoutPage.qml");

    assert.match(shell, /Variants\s*\{[\s\S]*?model:\s*Screens\.layerSurfaceModel[\s\S]*?Bar\s*\{/,
        "bars must still be created from the live screen model");
    assert.match(shell, /visible:\s*barScope\.output !== null/,
        "each connected output's bar must remain mapped independently of focus");
    assert.match(screens,
        /layerSurfaceModel:\s*Quickshell\.screens\.map\([\s\S]*?screen\.x[\s\S]*?screen\.y[\s\S]*?screen\.width[\s\S]*?screen\.height/,
        "persistent layer surfaces must be recreated when a surviving output moves");
    assert.equal((shell.match(/model:\s*(?:OmarchyPlugins\.replacementActive \? \[\] : )?Screens\.layerSurfaceModel/g) ?? []).length, 2,
        "both wallpaper and bar surfaces must use geometry-sensitive identities");
    assert.doesNotMatch(shell, /onFocusedScreen|barEnabled|Settings\.monitor/,
        "focus and the retired monitor picker must not gate a bar window");

    assert.match(popouts, /property string hostScreenName/);
    assert.match(popouts,
        /target:\s*Screens[\s\S]{0,180}?onLayerSurfaceModelChanged[\s\S]{0,180}?!Screens\.byName\(root\.hostScreenName\)[\s\S]{0,100}?root\.close\(\)/,
        "a popout must close before its removed output becomes a fallback surface");
    assert.match(bar, /Popouts\.toggle\(name, isle, anchorOf\(item\), outputName\)/,
        "pointer opens must identify the clicked bar's output");
    assert.match(window, /readonly property bool live:\s*bar\.visible && bar\.popoutHost/,
        "only the originating output may map the shared popout");
    const anchorSync = bar.slice(
        bar.indexOf("// IPC opens and transitions initiated inside a popout"),
        bar.indexOf("// Input region for the bar strip itself."));
    assert.equal((anchorSync.match(/if \(!barWindow\.popoutActive\)/g) ?? []).length, 2,
        "only the owning bar may reconcile the shared popout anchor, including after callLater");
    assert.doesNotMatch(anchorSync, /!barWindow\.visible/,
        "all connected bars are visible, so visibility cannot select the popout owner");
    const popoutHost = read("Bar/PopoutHost.qml");
    assert.match(popoutHost,
        /id:\s*closeTimer[\s\S]{0,500}?if \(host\.live && Popouts\.open\)\s*return;/,
        "an inactive host must release its stale surface during a handoff");
    assert.doesNotMatch(barPage, /settingKey:\s*"monitor"|Follow focus/,
        "settings must not advertise the removed single-monitor behavior");
});

test("settings uses an independent floating window with compatibility routes", () => {
    const shell = read("shell.qml");
    const settings = read("Common/Settings.qml");
    const window = read("SettingsWindow.qml");
    const popouts = read("Common/Popouts.qml");

    assert.match(shell, /SettingsWindow\s*\{/);
    assert.match(window, /FloatingWindow\s*\{/);
    assert.match(window, /window\.visible = Settings\.panelOpen/);
    assert.match(window, /onClosed: Settings\.closePanel\(\)/);
    assert.match(window, /view\.handleEscape\(\)/);
    assert.match(window, /startSystemMove\(\)/);
    assert.doesNotMatch(settings, /Popouts\.openPanel/);
    assert.doesNotMatch(settings, /target: Popouts/);
    assert.match(popouts, /Settings\.showPanel\(undefined, targetScreenName\)/);
    assert.match(popouts, /Settings\.togglePanel\(undefined, targetScreenName\)/);
});

test("the control dashboard uses a compact Settings action without a chevron", () => {
    const control = read("Popovers/ControlCenterPopover.qml");
    const footer = control.slice(control.indexOf("// ---- Footer"));

    assert.match(footer, /id:\s*settingsLabel[\s\S]{0,200}?text:\s*"Settings"/);
    assert.match(footer,
        /width:\s*settingsLabel\.x \+ settingsLabel\.implicitWidth \+ 9/,
        "the Settings hit target should hug its visible content");
    assert.match(footer, /height:\s*Theme\.chipHeight/,
        "footer actions are chips, at the bar's own control height");
    assert.doesNotMatch(footer, /Shell settings|chevron_right/);
});

test("the panel card grows out of its trigger and never out of thin air", () => {
    const host = read("Bar/PopoutHost.qml");

    // The scale origin is the trigger's own centre, clamped inside the card:
    // an origin outside the shape reads as the card sliding rather than
    // growing, which is the whole difference between the two.
    assert.match(host, /originX:\s*clamp\(anchor\.x \+ anchor\.width \/ 2 - bodyX/);
    assert.match(host, /Scale \{[\s\S]*?origin\.x: host\.originX/);
    assert.match(host, /origin\.y: host\.bottomBar \? card\.height : 0/,
        "a bottom bar grows the card upward, from its own lower edge");
    // Entry/exit are directional, morphing has only a small overshoot, and
    // opacity eases independently so it can never inherit the motion spring.
    assert.match(host,
        /Behavior on openProgress[\s\S]*?Theme\.popoutCloseDuration : Theme\.popoutOpenDuration[\s\S]*?Theme\.popoutExitCurve : Theme\.popoutEnterCurve/);
    assert.match(host,
        /Behavior on surfaceOpacity[\s\S]*?Theme\.popoutFadeOutDuration : Theme\.popoutFadeInDuration[\s\S]*?Theme\.easeInCurve : Theme\.easeOutCurve/);
    assert.match(host, /opacity:\s*Format\.clamp01\(host\.surfaceOpacity\)/);
    assert.match(host, /duration:\s*Theme\.popoutMorphDuration/);
    assert.match(host, /bezierCurve:\s*Theme\.popoutMorphCurve/);
    assert.match(host,
        /bodyTop:\s*barBottom \+ Theme\.popGap/,
        "all cards share the same small gap from the bar");
    // The mask has to come from real geometry, not from the animating card.
    const mask = host.match(/Item \{\s*id: cardHitRegion[\s\S]*?\n    \}/)?.[0] ?? "";
    assert.ok(mask !== "", "the popout host must still publish an input region");
    assert.doesNotMatch(mask, /transform|scale:/);
});

test("bar popouts use the quick detached motion profile", () => {
    const theme = read("Common/Theme.qml");
    const host = read("Bar/PopoutHost.qml");

    assert.match(theme, /popoutOpenDuration:\s*reducedMotion \? 0 : 250/);
    assert.match(theme, /popoutCloseDuration:\s*reducedMotion \? 0 : 165/);
    assert.match(theme, /popoutMorphDuration:\s*reducedMotion \? 0 : 320/);
    assert.match(theme, /popoutFadeInDuration:\s*reducedMotion \? 0 : 170/);
    assert.match(theme, /popoutFadeOutDuration:\s*reducedMotion \? 0 : 120/);
    assert.match(theme, /popoutContentFadeDuration:\s*reducedMotion \? 0 : 150/);
    assert.match(theme, /popoutInitialScale:\s*reducedMotion \? 1 : 0\.975/);
    assert.match(theme, /popoutTravel:\s*reducedMotion \? 0 : 10/);
    assert.match(host,
        /bodyTop:\s*barBottom \+ Theme\.popGap/,
        "the faster motion must retain the shared panel gap");
    assert.match(host, /xScale:\s*Theme\.popoutInitialScale/);
    assert.match(host, /host\.bottomBar \? Theme\.popoutTravel : -Theme\.popoutTravel/);
});

test("settings exposes responsive output and keyboard contracts", () => {
    const view = read("Settings/SettingsView.qml");
    const host = read("Bar/PopoutHost.qml");
    const modules = read("Settings/ModulesPage.qml");
    const picker = read("Settings/PickerRow.qml");

    // The envelope is declared once, on the contract both the settings view
    // and every popover surface inherit; the view only overrides defaults.
    const contract = read("Popovers/PopoutPanel.qml");
    assert.match(contract, /property real availableWidth/);
    assert.match(contract, /property real availableHeight/);
    assert.match(contract, /function handleEscape\(\): bool/);
    assert.match(view, /^PopoutPanel \{/m,
        "the settings view must inherit the popout contract");
    assert.match(read("Popovers/Surface.qml"), /^PopoutPanel \{/m,
        "every popover surface must inherit it too");
    assert.match(view, /availableWidth\s*<\s*Theme\.scaled\(860, Theme\.typeScale\)/);
    assert.match(view, /function handleEscape\(\): bool/);
    // The host holds its loaded item as the contract type now, so these are
    // plain property writes rather than existence checks.
    assert.match(host, /item as PopoutPanel/,
        "the host must hold its panel as the contract type");
    assert.match(host, /panel\.availableWidth = /);
    assert.match(host, /panel\.availableHeight = /);
    assert.doesNotMatch(host, /!== undefined/,
        "the panel contract must not be probed for at runtime any more");
    // Every panel lays out once at its own implicit size and is revealed by
    // the animating card; binding one to the card would relayout the whole
    // tree on every morph frame.
    assert.match(host, /width:\s*Math\.max\(1, implicitWidth\)/);
    assert.match(host, /height:\s*Math\.max\(1, implicitHeight\)/);
    assert.doesNotMatch(host, /width:\s*fillBody \? parent\.width/,
        "the settings surface must not track the animating clip size");
    assert.match(host, /nameFor\(frontSlot\) !== Popouts\.currentName/,
        "an outgoing popover must not overwrite Settings geometry during a morph");
    assert.match(read("Settings/WidgetPill.qml"), /Qt\.Key_Space/);
    assert.match(read("Settings/WidgetPill.qml"), /Qt\.Key_Escape/);
    assert.match(picker, /readonly property real captionWidth/);
    assert.doesNotMatch(picker, /width:\s*root\.narrow \? parent\.width : implicitWidth/,
        "picker flows need a concrete lane width or every pill wraps");
});

test("popout height cannot feed back into its own required envelope", () => {
    const host = read("Bar/PopoutHost.qml");
    const window = read("Bar/BarPopoutWindow.qml");

    assert.match(window, /implicitHeight:\s*Math\.max\(1, popout\.requiredHeight\)/);
    assert.doesNotMatch(host, /onHeightChanged:\s*retargetFront\(\)/,
        "requiredHeight drives native height, so native height cannot retarget requiredHeight");
    assert.match(host, /onOutputAvailableHeightChanged:\s*retargetFront\(\)/,
        "screen-height changes still need to recompute the panel envelope");
    // The envelope reads a stable surfaceH, never the animating renderedH:
    // tracking the morph per frame resizes the blurred Wayland surface on
    // every animation frame, while shrinking after the morph produces one
    // conspicuous compositor reconfigure after the card has already settled.
    assert.match(host, /requiredHeight:\s*presented\s*\?\s*bodyTop \+ Math\.max\(1, surfaceH\)/,
        "the surface envelope must come from the settled height");
    assert.match(host, /surfaceH = Math\.max\(surfaceH, geometry\.bodyH\)/,
        "the surface must grow to the morph's target before the springs start");
    assert.doesNotMatch(host, /surfaceH\s*=\s*(?:host\.)?targetH/,
        "the mapped surface must not shrink after a shorter panel settles");
    assert.doesNotMatch(host, /id:\s*settleTimer/,
        "a post-animation timer must not trigger a second layer-shell configure");
    assert.match(host, /host\.presented = false;\s*host\.surfaceH = 0;/,
        "the surface envelope resets only after the close animation unmaps it");
    // Quickshell 0.2.1 sends this region in the wrong coordinate space on a
    // scaled output. It is only a rendering optimisation, but at 2x it becomes
    // a hard visual clip through the panel sides and bottom.
    assert.doesNotMatch(window, /^\s*HyprlandWindow\.visibleMask\s*:/m,
        "a HiDPI popout must not be clipped by Hyprland's visible-mask hint");
    assert.doesNotMatch(host, /visualItem/,
        "the host must not retain a dead visual-mask contract");
    // The input mask holds still too — it binds to the morph's target, so the
    // compositor hears about it once per switch instead of once per frame.
    assert.match(host, /id: cardHitRegion[\s\S]{0,80}?x: host\.targetX/,
        "the input region must not follow the animating rendered geometry");
});

test("a newly fronted popout remeasures after nested content settles", () => {
    const host = read("Bar/PopoutHost.qml");

    assert.match(host,
        /frontSlot = slot;[\s\S]*?Qt\.callLater\(\(\) => \{[\s\S]*?retargetFront\(\);\s*animateToTargets\(\);/,
        "the final implicit-size change must not fall between presentation and resize listeners");
});

test("declared overflow paints and receives input outside the panel card", () => {
    const contract = read("Popovers/PopoutPanel.qml");
    const host = read("Bar/PopoutHost.qml");
    const window = read("Bar/BarPopoutWindow.qml");

    assert.match(contract, /property real detachedOverflowHeight:\s*0/);
    assert.match(contract, /property Item detachedOverflowItem:\s*null/);
    assert.match(host,
        /cardH:\s*contentH - overflowH[\s\S]*?targetCardH = geometry\.cardH/,
        "native extent and painted-card height must be separate geometry");
    assert.match(host,
        /id:\s*surface[\s\S]*?height:\s*Math\.max\(1, host\.renderedCardH\)/,
        "the shared background must stop before the transparent overflow tail");
    assert.match(host,
        /id:\s*cardHitRegion[\s\S]*?height:\s*Math\.max\(0, host\.targetCardH\)/);
    assert.match(window,
        /mask:\s*Region\s*\{[\s\S]*?item:\s*popout\.cardMaskItem[\s\S]*?item:\s*popout\.overflowMaskItem/,
        "the input mask is the union of the card and detached control");
});

test("the tray and the updates chip use the reorderable widget pipeline", () => {
    const helpers = read("Common/SettingsHelpers.js");
    const modules = read("Settings/ModulesPage.qml");
    const catalog = read("Common/WidgetCatalog.js");
    const bar = read("Bar/Bar.qml");

    assert.match(helpers, /"updates", "gh"/);
    assert.match(helpers, /"usage", "tray"/);
    assert.match(catalog, /updates:\s*\{ name: "Updates"/);
    assert.match(catalog, /tray:\s*\{ name: "System tray"/);
    assert.doesNotMatch(modules, /pinnedTail|text:\s*"pinned"/);
    // The widgets are files; the bar maps ids to their sources.
    assert.match(bar, /updates:\s*"Modules\/Updates\.qml"/);
    assert.match(bar, /tray:\s*"Modules\/Tray\.qml"/);
    assert.match(read("Bar/Modules/Updates.qml"), /panelName:\s*"updates"/);
    // A routine check is not itself a reason to show the module. Errors and
    // install outcomes remain reachable even after the pending count clears.
    assert.match(bar, /case "updates": return Updates\.total > 0 \|\| Updates\.error !== ""/);
    assert.doesNotMatch(bar, /Updates\.ran && Updates\.busy/);
    const updates = read("Bar/Modules/Updates.qml");
    assert.match(updates, /Updates\.runState === "done"\s*\? "check"/);
    assert.doesNotMatch(updates, /Theme\.barGreen|"check_circle"/);
    assert.match(bar, /case "tray": return SystemTray\.items\.values\.length > 0;/);
});

test("the three modules the redesign absorbed leave nothing behind", () => {
    const helpers = read("Common/SettingsHelpers.js");
    const modules = read("Settings/ModulesPage.qml");
    const bar = read("Bar/Bar.qml");

    for (const [id, file] of [["bell", "Bell"], ["idle", "Idle"], ["control", "Control"]]) {
        assert.ok(!fs.existsSync(path.join(shellDir, `Bar/Modules/${file}.qml`)),
            `Bar/Modules/${file}.qml is still on disk`);
        assert.doesNotMatch(bar, new RegExp(`${id}:\\s*"Modules/`),
            `the bar still maps a source for ${id}`);
        assert.doesNotMatch(modules, new RegExp(`^\\s*${id}:\\s*\\{ name:`, "m"),
            `the settings module list still names ${id}`);
    }
    assert.match(helpers, /RETIRED_MODULE_IDS = \["bell", "idle", "control"\]/);
});

test("T3 Code, Hermes Agent, and grouped model usage are separate reorderable widgets", () => {
    const helpers = read("Common/SettingsHelpers.js");
    const catalog = read("Common/WidgetCatalog.js");
    const bar = read("Bar/Bar.qml");

    assert.match(helpers, /"gh", "t3", "hermes",\s*"usage"/,
        "fresh layouts should keep the three agent widgets adjacent");
    assert.match(catalog, /t3:\s*\{ name: "T3 Code"/);
    assert.match(catalog, /hermes:\s*\{ name: "Hermes Agent"/);
    assert.match(catalog, /usage:\s*\{ name: "Model usage"/);
    assert.match(bar, /t3:\s*"Modules\/T3\.qml"/);
    assert.match(bar, /hermes:\s*"Modules\/Hermes\.qml"/);
    assert.match(bar, /usage:\s*"Modules\/Usage\.qml"/);
    assert.match(read("Bar/Modules/T3.qml"), /panelName:\s*"t3code"/);
    assert.match(read("Bar/Modules/Usage.qml"), /panelName:\s*"usage"/);
    // Separate files make this structural rather than a span check.
    assert.doesNotMatch(read("Bar/Modules/T3.qml"), /panelName:\s*"usage"/,
        "the T3 module must not own the grouped usage popout");
});

test("the T3 running indicator is a static dot", () => {
    const chip = read("Bar/T3Chip.qml");
    const dot = chip.match(/\/\/ Live work:[\s\S]*?\n    Text \{/)?.[0] ?? "";

    assert.ok(dot !== "", "the T3 chip must still mark live work");
    assert.match(dot, /width:\s*root\.busy \? 5 : 0/);
    assert.match(dot, /width:\s*5[\s\S]*height:\s*5/);
    assert.doesNotMatch(dot, /\b(?:Timer|SequentialAnimation|PropertyAnimation)\s*\{/,
        "the five-pixel running indicator must not pulse");
    assert.doesNotMatch(chip, /modOpts\.t3\.pulse|heartbeat|pulseOpacity|pulseStartedAt|barVisible/);
});

test("usage chip hover joins the latched menu session", () => {
    const bar = read("Bar/Bar.qml");
    const usage = read("Bar/Modules/Usage.qml");
    const chips = read("Bar/UsageChips.qml");

    // A closed bar remains inert. Once any popout was clicked open, hovering a
    // provider selects it and morphs the current view to Usage in place.
    assert.match(usage,
        /onChipEntered:\s*key => \{\s*if \(!Popouts\.open\)\s*return;[\s\S]{0,100}?if \(key !== ""\)[\s\S]{0,80}?Usage\.selected = key;\s*root\.host\.hoverPopout\("usage", root\.isle, usageChips\.anchorItem\);/,
        "provider hover must be gated by, and participate in, the open menu session");
    // Mapping the popout surface can cost Qt an enter event; motion over a
    // chip still re-delivers the provider.
    assert.match(chips, /onPositionChanged:[\s\S]{0,60}?chipEntered/);
    assert.match(chips, /function providerAtScenePoint\(scenePoint\)/,
        "the bar-wide fallback needs provider-level hit testing");
    const fallback = bar.match(/function hoverPanelAt\(position\)[\s\S]*?\n    \}/)?.[0] ?? "";
    assert.match(fallback, /providerAtScenePoint\(position\)/);
    assert.ok(fallback.indexOf("providerAtScenePoint(position)")
            < fallback.indexOf("Object.keys(panelAnchors)"),
        "provider selection must happen before generic Usage hit testing");
    assert.match(usage,
        /root\.host\.openPopout\("usage", root\.isle, usageChips\.anchorItem\)/,
        "all providers should retain the grouped UsageChips anchor");
});

test("model usage follows the source inventory and only shows real menubar values", () => {
    const chips = read("Bar/UsageChips.qml");
    const popover = read("Popovers/UsagePopover.qml");
    const usage = read("Common/Usage.qml");
    const drawer = read("Popovers/Drawer/DrawerUsage.qml");

    assert.match(usage,
        /providerKeys:\s*Helpers\.providerKeys\([\s\S]{0,100}?Settings\.modOpts\.usage\.source, data\)/,
        "one reactive inventory must drive every model-usage surface");
    assert.match(chips,
        /availableKeys:\s*Usage\.providerKeys\.filter[\s\S]*?return Usage\.minRemaining\(k\) >= 0;\s*\}\)/,
        "signed-out, failed, and valueless providers must not render as --% chips");
    assert.doesNotMatch(chips, /p\.status === "ok" \|\| p\.kind !== "nocreds"/,
        "provider errors are details for the popover, not menubar chips");
    assert.match(popover, /model:\s*Usage\.providerKeys/,
        "source-provided entries without a bar value remain reachable in the popover");
    assert.match(drawer, /model:\s*Usage\.providerKeys/,
        "the Usage tab must use the same source-provided inventory");
    assert.match(chips,
        /providerKey:\s*Usage\.providerKeys\.length > 0[\s\S]{0,100}?\? Usage\.providerKeys\[0\] : ""/,
        "an empty proxy inventory must not retain the last provider brand");
    assert.match(popover,
        /hasProvider:[\s\S]{0,100}?Usage\.providerKeys\.indexOf\(sel\) !== -1/);
    assert.match(drawer,
        /hasProvider:[\s\S]{0,120}?Usage\.providerKeys\.indexOf\(selected\) !== -1/);
});

test("regression fixes keep asynchronous state identity-safe", () => {
    const palette = read("Common/Palette.qml");
    const sysInfo = read("Common/SysInfo.qml");
    const bar = read("Bar/Bar.qml");
    const tooltip = read("Bar/BarTooltip.qml");
    const packages = fs.readFileSync(path.resolve(shellDir, "../../tasks/main.yml"), "utf8");

    assert.match(palette, /property string activeIdentity/);
    assert.match(palette, /PaletteHelpers\.resultIsCurrent\(completedIdentity,/);
    assert.match(palette, /wallpaper-palette\.json/);
    assert.match(palette, /property bool busy/);
    assert.match(palette, /property string error/);
    assert.match(palette, /atomicWrites:\s*true/);
    assert.match(palette,
        /\["matugen", "image", activeIdentity,[\s\S]{0,160}?"scheme-tonal-spot"/);
    assert.match(palette, /exitSeen \? lastExit : ProcHelpers\.NOT_STARTED/);
    assert.match(palette, /"Matugen is not installed"/);
    assert.match(packages, /- matugen/);
    assert.match(sysInfo, /property string nightLightLifecycle/);
    assert.doesNotMatch(sysInfo, /running:\s*root\.nightLight/);
    assert.match(bar, /Component\.onCompleted:[\s\S]*Settings\.autoHide[\s\S]*hideTimer\.restart/);
    assert.match(tooltip,
        /target:\s*Popouts[\s\S]*function onOpenChanged\(\)[\s\S]*delay\.stop\(\)[\s\S]*root\.ready = false/,
        "tooltips must be disarmed when a popout surface maps or unmaps");
    assert.match(bar, /readonly property bool tooltipPointerInside:\s*barHover\.hovered/);
    assert.match(bar,
        /const scenePoint = hoverLayer\.mapToItem[\s\S]{0,120}?barWindow\.tooltipPointerPosition = scenePoint/,
        "the full-bar handler must publish pointer motion for tooltip validation");
    // The hover check lives in one shared object now, so a chip's fill and the
    // tooltip hanging under it cannot disagree about whether the pointer is
    // there. The tooltip takes it as a typed, required property, which is what
    // stops a raw `containsMouse` being handed over by mistake.
    const check = read("Bar/PointerCheck.qml");
    assert.match(tooltip, /required property PointerCheck check/,
        "the tooltip must take the shared check, not a bare bool");
    assert.match(tooltip, /readonly property bool activeHover:\s*check\.over/);
    // The bar reaches the check as a typed `host`, not through Window.window —
    // an attached window is a plain QQuickWindow to the type system, so that
    // read could never be checked.
    assert.match(check, /required property Bar host/);
    assert.match(check, /required property Item target/);
    assert.match(check,
        /if \(!root\.host \|\| !root\.host\.tooltipPointerInside \|\| !root\.target\)\s*return false/,
        "a stale local MouseArea must not keep a hover state alive after leaving the bar");
    // Match code, not prose: the files explain in comments why they stopped
    // using Window.window.
    const code = (tooltip + check).split("\n")
        .filter(l => !l.trim().startsWith("//")).join("\n");
    assert.doesNotMatch(code, /Window\.window/,
        "reading the bar off the attached window is what made this unverifiable");
});

test("schema twenty-three keeps safe defaults and exposes accessibility preferences", () => {
    const helpers = read("Common/SettingsHelpers.js");
    assert.match(helpers, /var VERSION = 23/);
    // Schema 17: the drawer becomes configurable (turn-3 settings design).
    assert.match(helpers, /drawerHover: "open"/);
    assert.match(helpers, /drawerWidth: 400/);
    assert.match(helpers, /function normalizeDrawerTabs\(raw\)/);
    assert.match(helpers, /function normalizeDrawerOverview\(raw\)/);
    assert.match(helpers, /id === "overview" \? true/,
        "the Overview tab can be reordered but never disabled");
    assert.match(helpers, /highContrast: false/);
    assert.match(helpers, /reducedMotion: false/);
    assert.match(helpers, /textScale: "default"/);
    assert.match(helpers, /interfaceDensity: "default"/);
    assert.match(helpers, /"media", "indicators", "clock"/);
    assert.match(helpers, /nightLight:\s*false/);
    assert.match(helpers, /idleInhibitMode:\s*"off"/);
    assert.match(helpers, /idleInhibitUntilMs:\s*0/);
    assert.match(helpers, /"updates", "gh", "t3", "hermes",\s*"usage", "tray"/);
    assert.match(helpers, /hermes:\s*\{ showLabel: true, activityDetail: "verb" \}/);
    assert.match(helpers, /claudeAutoRefresh:\s*true/);
    assert.match(helpers,
        /notes:\s*\{[\s\S]*?titleProvider:\s*"off"[\s\S]*?codexModel:\s*"gpt-5\.6-luna"[\s\S]*?codexEffort:\s*"none"[\s\S]*?claudeModel:\s*"fable"[\s\S]*?claudeEffort:\s*"low"/);
    assert.match(helpers, /mod\("tray", false\), mod\("notifications", true\), mod\("vol", true\)/);
    assert.match(helpers, /notifications:\s*\{ group: "status" \}/);
    assert.match(helpers, /warmth:\s*3400/);
    assert.match(helpers, /osd:\s*"bottom"/);
    assert.match(helpers, /themeMode:\s*"dark"/);
    assert.match(helpers, /barHeight:\s*36/);
    assert.match(helpers, /barRadius:\s*11/);
    assert.match(helpers, /glassEnabled:\s*false/);
    assert.match(helpers, /barColorMode:\s*"default"/);
    assert.match(helpers, /paletteMode:\s*"wallpaper"/);
    assert.match(helpers, /barStyle:\s*"hug"/);
    assert.match(helpers, /function migrateBarStyle\(parsed, defaultsValue\)/);
    assert.match(helpers, /function migratePaletteMode\(parsed, defaultsValue\)/);
    assert.match(helpers, /function adoptSofterTypography\(parsed\)/);
    assert.match(helpers, /mod\("media", true\)/);
    assert.match(helpers, /mod\("bt", false\)/);
    assert.match(helpers, /wallDir:\s*"~\/Pictures\/Wallpapers"/);
    assert.match(helpers, /DETAIL_POLICIES/);
    // A settings file written by the previous schema must adopt the redesign
    // wherever the user never chose otherwise, or the redesign never appears.
    assert.match(helpers, /function adoptRedesign\(parsed\)/);
    assert.match(helpers, /V3_DEFAULTS = \{[\s\S]*?barHeight: 30/);
    assert.match(helpers, /function adoptClassicMenubar\(parsed\)/);
    assert.match(helpers, /V9_CLASSIC_DEFAULTS = \{[\s\S]*?barHeight: 46/);
});

test("Connected enables integration widgets including auto-hiding Bluetooth", () => {
    const settings = read("Common/Settings.qml");
    const preset = settings.slice(settings.indexOf("function modulePresetIds(name)"),
        settings.indexOf("function resetKeys("));
    assert.match(preset,
        /name === "connected"[\s\S]*?\["ws"[\s\S]*?"gh"[\s\S]*?"t3"[\s\S]*?"hermes"[\s\S]*?"usage"[\s\S]*?"bt"[\s\S]*?"batt"\]/,
        "Connected should enable every connection-driven widget; Bluetooth hides itself when idle");
});

test("settings improvements expose fitting, embedded folders, undo, and shortcut", () => {
    const bar = read("Bar/Bar.qml");
    const modules = read("Settings/ModulesPage.qml");
    const wallpaper = read("Settings/WallpaperPage.qml");
    const folder = read("Settings/FolderDialog.qml");
    const settings = read("Common/Settings.qml");
    const bindings = fs.readFileSync(path.resolve(shellDir, "../bindings.lua"), "utf8");

    assert.match(bar, /LayoutHelpers\.fitBar/);
    assert.doesNotMatch(bar, /width\s*>=\s*Theme\.breakpoint/);
    assert.match(modules, /Editor\.dropPlan/,
        "the editor maps visible gaps to configured indices");
    assert.match(modules, /LayoutHelpers\.moveWidget/,
        "both surfaces preserve the same move semantics");
    assert.match(wallpaper, /GridView\s*\{/);
    assert.match(folder, /popupType:\s*Controls\.Popup\.Item/);
    assert.match(settings, /interval:\s*8000/);
    assert.match(settings, /function retrySave/);
    assert.match(settings,
        /migrationPending = parsed !== null && parsed\.v !== SettingsHelpers\.VERSION/);
    assert.match(settings,
        /if \(!ready \|\| migrationPending \|\| corruptBackupPending \|\| loadError\)/,
        "older files must wait for the next user mutation before a current-schema write");
    assert.match(bindings, /mainMod \..*" \+ comma".*settings toggle/);
});

test("settings geometry accommodates wide menu fonts and focused rows", () => {
    const view = read("Settings/SettingsView.qml");
    const page = read("Settings/SettingsPage.qml");
    const theme = read("Common/Theme.qml");
    const base = read("Settings/SettingsRow.qml");
    const picker = read("Settings/PickerRow.qml");
    const switchRow = read("Settings/SwitchRow.qml");
    const system = read("Settings/SystemPage.qml");

    assert.match(view, /preferredWidth:\s*Theme\.scaled\(900, Theme\.contentScale\)/);
    assert.match(view, /preferredHeight:\s*Theme\.scaled\(664\)/,
        "the sheet is 44 header + 620 body, hanging from the bar");
    // The gutter is unconditional: making it depend on scrollbarVisible
    // loops (narrower content re-wraps taller and flips the scrollbar).
    assert.match(page, /scrollGutter:\s*8/);
    assert.doesNotMatch(page, /scrollGutter:\s*scrollbarVisible/);
    assert.match(page, /width:\s*root\.width - root\.scrollGutter/);
    // One fixed lane keeps every row aligned across all menu fonts.
    assert.match(theme,
        /readonly property int settingsLabelWidth:\s*scaled\(132, typeScale\)/);
    assert.match(theme, /readonly property int settingsNarrowWidth:\s*scaled\(520, typeScale\)/);
    assert.match(base, /readonly property int labelWidth:\s*markInset/,
        "the modified-mark gutter is part of every row's label column");
    assert.match(base, /Theme\.settingsLabelWidth >= root\.minimumLabelWidth/);
    assert.match(picker, /narrowHeight:[\s\S]{0,100}?pills\.implicitHeight/,
        "wrapped narrow picker pills must grow their row");
    assert.match(switchRow, /narrowHeight:[\s\S]{0,100}?descriptionText\.implicitHeight/,
        "wrapped switch descriptions must grow their row");
    for (const row of ["SliderRow", "PickerRow", "SwitchRow", "SettingsTextRow"])
        assert.match(read(`Settings/${row}.qml`), /^SettingsRow \{$/m,
            `${row} must build on SettingsRow`);
    assert.doesNotMatch(system, /resetArmed|Confirm reset/);
    assert.match(system, /onTriggered:\s*Settings\.resetAll\(\)/);
});

test("touchpad scroll speed defaults to Hyprland's factor and applies live", () => {
    const settings = read("Common/Settings.qml");
    const helpers = read("Common/SettingsHelpers.js");
    const system = read("Settings/SystemPage.qml");
    const input = fs.readFileSync(
        path.resolve(shellDir, "../../templates/input.lua.j2"), "utf8");

    assert.match(helpers, /scrollFactor:\s*1\.0/);
    assert.match(helpers, /realIn\(parsed\.scrollFactor, 0\.2, 2\.0, 0\.1/);
    assert.match(settings, /"input:touchpad:scroll_factor"/);
    assert.match(system, /min:\s*0\.2[\s\S]*max:\s*2\.0[\s\S]*step:\s*0\.1/);
    assert.match(input, /persisted_scroll_factor\(\)/);
    assert.match(input, /"scrollFactor"%s\*:%s\*\(\[%d%\.\]\+\)/);
    assert.doesNotMatch(input, /scroll_factor\s*=\s*0\.4/);
});

test("the grouped rail keeps labeled sections, the save state, and the nav search", () => {
    const view = read("Settings/SettingsView.qml");
    const settings = read("Common/Settings.qml");
    const searchData = read("Common/SettingsSearchData.js");

    assert.match(view, /group:\s*"SHELL"/);
    assert.match(view, /group:\s*"SYSTEM"/);
    assert.match(view, /id:\s*railFooter/);
    assert.match(view, /Saved · applies live/);
    assert.doesNotMatch(view, /shell-settings\.json/,
        "the config path chip lives on the System page, not a bottom footer");
    assert.match(view, /case "notifications": return notificationsPage;/);
    assert.match(view, /case "drawer": return drawerPage;/);
    assert.match(settings, /"notifications", "system"\]/);

    // Turn-3 search: "/" focuses the nav field, results jump to and
    // highlight the row through Settings.highlightKey.
    assert.match(view, /Qt\.Key_Slash/);
    assert.match(view, /function jumpToResult\(row\)/);
    assert.match(view, /SearchData\.search\(searchQuery\)/);
    assert.match(view, /function handleEscape[\s\S]{0,220}?clearSearch\(\)/,
        "Escape backs out of a search before anything else");
    assert.match(settings, /property string highlightKey/);

    // The index is hand-maintained; hold it against the schema so a renamed
    // key or page cannot leave a search row jumping nowhere.
    const schemaKeys = Object.keys(load("SettingsHelpers.js").defaults());
    const validPages = ["appearance", "wallpaper", "bar", "modules", "plugins", "drawer",
        "notifications", "system"];
    const rows = load("SettingsSearchData.js").ROWS;
    assert.ok(rows.length >= 30, "the search index must cover the workspace");
    for (const row of rows) {
        assert.ok(validPages.includes(row.page),
            `search row "${row.label}" names unknown page "${row.page}"`);
        if (row.key !== "")
            assert.ok(schemaKeys.includes(row.key),
                `search row "${row.label}" names unknown key "${row.key}"`);
    }
    void searchData;
});

test("settings workspace uses shared responsive groups and bounded header lanes", () => {
    const view = read("Settings/SettingsView.qml");
    const group = read("Settings/SettingsGroup.qml");
    const action = read("Settings/ResponsiveActionRow.qml");
    const qmldir = read("Settings/qmldir");

    assert.match(view, /preferredWidth:\s*Theme\.scaled\(900, Theme\.contentScale\)/);
    assert.match(view, /preferredHeight:\s*Theme\.scaled\(664\)/);
    assert.match(view, /compactNav:\s*availableWidth < Theme\.scaled\(860, Theme\.typeScale\)/);
    assert.match(view, /height:\s*Theme\.panelRowHeight \+ 2/,
        "navigation rows follow the shared panel rhythm, not a local literal");
    assert.match(view, /headerHeight:\s*Theme\.scaled\(44\)/,
        "the header is one line; the two-line form made it the tallest thing here");
    assert.match(view, /anchors\.right:\s*headerActions\.left/);
    assert.match(view, /id:\s*headerCopy[\s\S]{0,2000}?elide:\s*Text\.ElideRight/,
        "header copy must be bounded before the action lane");

    assert.match(group, /default property alias content:/);
    assert.match(group, /property bool dirty:/);
    assert.match(group, /signal resetRequested\(\)/);
    assert.match(action, /readonly property bool stacked:\s*width < breakpoint/);
    assert.match(action, /maximumLineCount:\s*root\.maximumLines/);
    assert.match(qmldir, /^SettingsGroup SettingsGroup\.qml$/m);
    assert.match(qmldir, /^ResponsiveActionRow ResponsiveActionRow\.qml$/m);

    for (const page of ["AppearancePage", "BarLayoutPage", "NotificationsPage", "SystemPage"])
        assert.match(read(`Settings/${page}.qml`), /SettingsGroup \{/,
            `${page} must use grouped settings sections`);
    for (const page of ["WallpaperPage", "SystemPage"])
        assert.match(read(`Settings/${page}.qml`), /ResponsiveActionRow \{/,
            `${page} must use bounded responsive action copy`);
});

// The menubar separates one run of modules from the next with a hairline and a
// gap. A settings page says the same thing the same way: nothing in it is a
// filled, bordered container, and the one accent stays a mark rather than
// becoming a field behind a 176px navigation row.
test("dialog chrome carries the menubar's grammar rather than a card stack", () => {
    const group = read("Settings/SettingsGroup.qml");
    const header = read("Settings/SectionHeader.qml");
    const pills = read("Settings/PillRow.qml");
    const view = read("Settings/SettingsView.qml");

    assert.match(group, /^Item \{$/m,
        "a settings group is a layout, not a Rectangle to paint");
    for (const banned of [/\bcolor:\s*Theme\.cardFill/, /\bborder\.color:/, /\bradius:/])
        assert.doesNotMatch(group, banned,
            "the group card is gone; the section header and its rule replace it");

    assert.match(header, /height:\s*Math\.max\(Theme\.sectionHeaderHeight/);
    assert.match(header, /color:\s*Theme\.hairlineSoft/,
        "a section label runs a hairline to the page edge, as T3's inbox groups do");

    assert.match(pills, /color:\s*pill\.selected \? Theme\.chipHover : "transparent"/,
        "the taken option lights the bar's held chip, not an accent tint");
    assert.match(pills, /radius:\s*Theme\.chipRadius/,
        "segments take the bar's chip corner rather than a pill");
    assert.doesNotMatch(pills, /Theme\.accentAlpha/,
        "broad selected controls must not paint the accent");

    assert.doesNotMatch(view, /Theme\.accentBg/,
        "the navigation rail's accent survives on the icon, never as a field");
    assert.match(view, /color:\s*current \? Theme\.chip : "transparent"/);
    assert.match(view, /surfaceColor:\s*Theme\.panelSurface/,
        "a dialog sits on the shell's deepest surface, not on a lighter card");
});

test("progressive disclosure hides inactive controls without discarding latent values", () => {
    const appearance = read("Settings/AppearancePage.qml");
    const bar = read("Settings/BarLayoutPage.qml");
    const reveal = read("Common/Revealer.qml");
    const picker = read("Settings/PickerRow.qml");

    const fixedAt = appearance.indexOf("id: fixedColorReveal");
    const paletteAt = appearance.indexOf("id: paletteContent");
    const barAt = appearance.indexOf('title: "Bar background"');
    const sizingAt = appearance.indexOf('title: "Shell sizing and surfaces"');
    assert.ok(fixedAt > 0 && paletteAt > fixedAt && barAt > paletteAt && sizingAt > barAt,
        "Fixed must reveal its accent controls immediately below the mode picker");
    const fixed = appearance.slice(fixedAt, paletteAt);
    const barColors = appearance.slice(barAt, sizingAt);
    assert.match(fixed, /reveal:\s*page\.fixedPalette/);
    assert.match(fixed, /\baccent\b/, "the manual accent choice belongs to fixed mode");
    assert.match(appearance,
        /onPicked:\s*value => \{[\s\S]{0,120}?page\.revealFixedColors\(\)/,
        "selecting Fixed must bring the newly revealed accent controls into view");
    assert.match(appearance,
        /id:\s*fixedColorScrollTimer[\s\S]{0,120}?page\.revealFixedColorsNow\(\)/,
        "the scroll must wait for the fixed-color reveal before measuring it");
    assert.match(appearance,
        /firstBarSwatch\s*=\s*barColorRepeater\.itemAt\(0\)[\s\S]{0,160}?page\.revealFocus\(firstBarSwatch/,
        "Fixed must reveal both the accent controls and the independent bar background");
    assert.doesNotMatch(appearance, /Component\.onCompleted:/,
        "opening Appearance must not scroll past typography or override a search jump");
    assert.match(appearance, /label: "Interface font"\s+settingKey: "font"/,
        "the interface font must support the shared settings search and persistence");
    assert.ok(appearance.indexOf('title: "Typography"') < fixedAt,
        "typography must be reachable before the long color controls");
    for (const key of ["barColorMode", "barCustomHue", "barCustomSaturation",
        "barCustomLightness"])
        assert.match(barColors, new RegExp(key),
            `${key} must remain available independently of the accent source`);
    assert.match(barColors,
        /id:\s*customColorReveal[\s\S]*?reveal:\s*Settings\.barColorMode === "custom"/);

    // Turn-3: floating-only geometry rows stay visible but dimmed and
    // disabled under other styles, so the page never reflows on a style
    // change and the latent values stay on screen.
    const gapAt = bar.indexOf('settingKey: "gap"');
    const behaviorAt = bar.indexOf('title: "Behavior"');
    assert.ok(gapAt > 0 && behaviorAt > gapAt);
    const floating = bar.slice(bar.indexOf('title: "Shape"'), behaviorAt);
    assert.match(floating, /settingKey:\s*"gap"/);
    assert.match(floating, /settingKey:\s*"barRadius"/);
    const dimmedRows = floating.match(/dimmed:\s*Settings\.barStyle !== "floating"/g) ?? [];
    assert.equal(dimmedRows.length, 2, "both floating-only rows dim when inactive");
    const disabledRows = floating.match(/enabled:\s*Settings\.barStyle === "floating"/g) ?? [];
    assert.equal(disabledRows.length, 2, "dimmed rows must not accept input");
    assert.equal((bar.match(/settingKey:\s*"(?:gap|barRadius)"/g) ?? []).length, 2,
        "floating-only controls must not have a second focusable copy");

    assert.match(reveal, /enabled:\s*root\.reveal/);
    assert.match(reveal, /Accessible\.ignored:\s*!root\.reveal/);
    assert.match(picker, /root\.commit\(value\)/,
        "mode pickers mutate only their own key, preserving hidden companion values");
});

test("bar geometry reset ownership moves from Appearance to Bar", () => {
    const settings = read("Common/Settings.qml");
    const appearance = read("Settings/AppearancePage.qml");
    const bar = read("Settings/BarLayoutPage.qml");
    const appearanceKeys = settings.match(/appearance:\s*\[([^\]]+)\]/s)?.[1] ?? "";
    const barKeys = settings.match(/bar:\s*\[([^\]]+)\]/s)?.[1] ?? "";

    for (const key of ["barHeight", "barRadius"]) {
        assert.doesNotMatch(appearanceKeys, new RegExp(`"${key}"`));
        assert.match(barKeys, new RegExp(`"${key}"`));
        assert.doesNotMatch(appearance, new RegExp(`settingKey:\\s*"${key}"`));
        assert.match(bar, new RegExp(`settingKey:\\s*"${key}"`));
    }
    assert.match(settings, /bar:\s*"Bar"/,
        "the reset announcement must use the new visible page name");
});

test("wallpaper and module layouts switch before content can collide", () => {
    const wallpaper = read("Settings/WallpaperPage.qml");
    const modules = read("Settings/ModulesPage.qml");

    assert.match(wallpaper, /columnCount:\s*width < Theme\.settingsNarrowWidth \? 1 : 2/);
    assert.match(wallpaper, /cellWidth:\s*Math\.floor\(width \/ columnCount\)/);
    assert.match(modules, /columns: Math.max\(1, Math.min\(3/);
    assert.match(read("Settings/WidgetPill.qml"), /elide:\s*Text\.ElideRight/);

});

test("notification settings drive the toasts and the notification center", () => {
    const toasts = read("NotificationToasts.qml");
    const notifs = read("Common/Notifs.qml");
    const page = read("Settings/NotificationsPage.qml");

    assert.match(toasts, /Settings\.notifPosition/);
    assert.match(toasts, /Settings\.notifDensity/);
    assert.match(toasts, /Settings\.notifIcons/);
    assert.match(toasts, /Settings\.notifBodyLines/);
    assert.match(toasts, /showProgress:\s*Settings\.notifProgress && !critical/);
    // A plain array model recreates every delegate when one toast expires,
    // resetting the survivors' countdowns; ScriptModel diffs by identity.
    assert.match(toasts, /model:\s*ScriptModel\s*\{\s*values:\s*Notifs\.toasts\s*\}/);
    assert.doesNotMatch(toasts, /model:\s*Notifs\.toasts/);
    assert.match(notifs, /readonly property bool dnd:\s*Settings\.notifDnd/);
    assert.match(notifs, /toastsSuppressed:\s*dnd \|\| quietActive/);
    assert.match(notifs, /Settings\.notifDuration \* 1000/);
    assert.match(page, /Send test notification/);
    assert.match(page, /Critical alerts ignore the timer/);
    // DND writers must go through the persisted setting, never the singleton.
    for (const name of ["Popovers/NotifsPopover.qml", "Popovers/ControlCenterPopover.qml"])
        assert.doesNotMatch(read(name), /Notifs\.dnd\s*=/,
            `${name} must use Notifs.setDnd`);
});

test("per-module options live under one validated modOpts key", () => {
    const helpers = read("Common/SettingsHelpers.js");
    const settings = read("Common/Settings.qml");

    assert.match(helpers, /function defaultModOpts/);
    assert.match(helpers, /function normalizeModOpts/);
    assert.match(helpers,
        /modOpts:\s*migrateModOpts\(parsed\.modOpts, parsed\.v, parsed\)/);
    assert.match(settings, /"mods", "modOpts"/);
    assert.match(settings, /function setModuleOption/);
    assert.match(settings, /onModOptsChanged:\s*scheduleSave/);
    // The QS_WEATHER_* env vars survive exactly one upgrade as a seed; a file
    // that already carries modOpts must never take them again.
    assert.match(settings, /function seedWeatherFromEnv/);
    assert.match(settings, /parsed\.modOpts !== undefined/);
    assert.doesNotMatch(read("Common/Weather.qml"), /Quickshell\.env\("QS_WEATHER/,
        "Weather must read its location from Settings, not the environment");
});

test("the gear opens built-in options in the widget dialog", () => {
    const modules = read("Settings/ModulesPage.qml");
    const view = read("Settings/SettingsView.qml");
    const detail = read("Settings/ModuleDetailView.qml");

    assert.doesNotMatch(modules, /cyclePolicy/,
        "the A/D/C policy cycler is replaced by the cog + sub-page");
    assert.match(modules, /function openSubPage/);
    assert.match(modules, /if \(dragActive\)\s*\n\s*return;/,
        "a drag in progress must not be interrupted by opening a sub-page");
    assert.match(modules, /ModuleDetailView \{/);
    assert.match(modules, /inlineMode:\s*true/,
        "the detail panel owns the heading and scrolling");
    assert.match(modules, /onActivated: page.openSubPage\(modelData.key\)/);
    assert.match(view, /moduleSubPageActive[\s\S]{0,120}?closeModuleSubPage\(\)/,
        "Escape must close an open module sub-page before clearing search");
    assert.match(detail, /Settings\.setModuleDetail\(view\.moduleId/,
        "the detail policy control lives on the sub-page, stored in mods");
    assert.match(detail, /Settings\.setModuleOption/);
    assert.match(detail, /case "hermes": return hermesOptions/);
    assert.match(detail, /case "notifications": return notificationsOptions/);
    assert.match(detail,
        /id:\s*notificationsOptions[\s\S]*?label:\s*"Grouping"[\s\S]*?value:\s*"solo", label:\s*"Separate"[\s\S]*?value:\s*"status", label:\s*"Status group"/);
    assert.match(detail,
        /id:\s*hermesOptions[\s\S]*?label:\s*"Status label"[\s\S]*?view\.opts\.showLabel/);
    assert.match(detail,
        /id:\s*hermesOptions[\s\S]*?label:\s*"Activity detail"[\s\S]*?value:\s*"full"[\s\S]*?value:\s*"verb"[\s\S]*?value:\s*"generic"/);
});

test("the settings store keeps its fixed user-owned config path", () => {
    const settings = read("Common/Settings.qml");
    assert.match(settings,
        /Quickshell\.env\("HOME"\) \+ "\/\.config\/fedora-config\/shell\.json"/);
    assert.match(settings, /path:\s*root\.filePath/);
    assert.doesNotMatch(settings, /:\s*Quickshell\.statePath\(/,
        "Settings must not use statePath — it forks per config directory");
});

test("an unreadable settings file is preserved before anything saves over it", () => {
    // Regression guard for silent data loss: parse() used to answer null for
    // both "no file yet" and "file we could not read", so applyLoaded treated
    // damage as a first run and the next debounced save replaced the user's
    // only copy with defaults.
    const settings = read("Common/Settings.qml");

    assert.match(settings, /firstRun = result\.status === "empty"/,
        "only an absent file counts as a first run");

    // The backup has to be triggered ahead of applyLoaded's no-op early
    // return, or a corrupt file that merges to the running state slips past.
    const applyLoaded = settings.slice(settings.indexOf("function applyLoaded"));
    const backupAt = applyLoaded.indexOf("backUpCorruptFile()");
    const earlyReturnAt = applyLoaded.indexOf("serialize(snapshot())");
    assert.ok(backupAt > 0, "applyLoaded must back up a corrupt file");
    assert.ok(backupAt < earlyReturnAt,
        "the backup must happen before the unchanged-settings early return");

    assert.match(settings, /"mv", filePath, corruptBackupProc\.backupPath/,
        "the original bytes are moved aside, not rewritten");
    assert.match(settings, /\.corrupt-" \+ Math\.floor\(Date\.now\(\) \/ 1000\)/);

    // Both save paths stay shut until the move has succeeded, and the failure
    // branch must not clear the guard.
    assert.match(settings,
        /function saveNow\(\) \{\s*\n\s*if \(!ready \|\| migrationPending \|\| corruptBackupPending \|\| loadError/);
    assert.match(settings,
        /function scheduleSave\(\) \{[\s\S]{0,300}?if \(!ready \|\| migrationPending \|\| corruptBackupPending \|\| loadError\)/);
    const onExited = settings.slice(settings.indexOf("id: corruptBackupProc"));
    const clears = onExited.slice(0, onExited.indexOf("console.warn"))
        .match(/corruptBackupPending = false/g) ?? [];
    assert.equal(clears.length, 1,
        "corruptBackupPending clears only on a successful move");

    assert.match(settings, /root\.announcement = "The settings file could not be read\./,
        "the user is told the file was kept rather than lost");
});

test("FileView failures cannot become empty settings or false save success", () => {
    const settings = read("Common/Settings.qml");

    assert.match(settings,
        /if \(error === FileViewError\.FileNotFound\) \{[\s\S]*?applyLoaded\(""\);[\s\S]*?return;/,
        "only a confirmed missing file may initialize first-run defaults");
    assert.match(settings,
        /function handleLoadFailure\(error\)[\s\S]*?ready = false;[\s\S]*?loadError = true;/,
        "other read errors must retain memory state and disable writes");
    assert.doesNotMatch(settings, /onLoadFailed:\s*root\.applyLoaded\(""\)/);
    assert.match(settings, /onSaved: root\.handleSaveSucceeded\(\)/);
    assert.match(settings,
        /onSaveFailed: error => root\.handleSaveFailure\(error\)/);
    const saveNow = settings.slice(settings.indexOf("function saveNow()"),
        settings.indexOf("function scheduleSave()"));
    assert.doesNotMatch(saveNow, /lastSavedAt\s*=/,
        "starting a write is not evidence that it succeeded");
    assert.match(settings,
        /function handleSaveSucceeded\(\)[\s\S]*lastSavedAt = Date\.now\(\)/);
});

test("an unchanged save cannot block subsequent widget changes", () => {
    const vm = require("node:vm");
    const source = read("Common/Settings.qml");
    let value = { mods: { left: [{ id: "ws", on: true }] } };
    let disk = JSON.stringify(value);
    let writes = 0;
    const context = vm.createContext({
        ready: true, migrationPending: false, corruptBackupPending: false, loadError: false,
        writeInFlight: false, writeSnapshot: "", lastPersistedText: disk,
        saveError: false, savePending: true, lastSavedAt: 0,
        SettingsHelpers: { serialize: JSON.stringify }, snapshot: () => value,
        saveTimer: { restart() {} }, FileViewError: { Unknown: 1 },
        store: { setText(text) {
            if (text === disk) return; // FileView emits no saved signal for a no-op.
            writes++; disk = text; context.handleSaveSucceeded();
        } }
    });
    for (const name of ["saveNow", "handleSaveSucceeded", "handleSaveFailure"]) {
        const body = source.match(new RegExp("    function " + name + "\\([^]*?^    }", "m"))[0];
        vm.runInContext(body, context);
    }
    context.saveNow();
    assert.equal(context.writeInFlight, false);
    assert.equal(context.savePending, false);
    assert.equal(writes, 0);
    for (const on of [false, true]) {
        value = { mods: { left: [{ id: "ws", on }] } };
        context.savePending = true;
        context.saveNow();
        assert.equal(context.writeInFlight, false);
        assert.equal(context.savePending, false);
        assert.equal(JSON.parse(disk).mods.left[0].on, on);
        context.saveNow(); // Opening a form can schedule the same value again.
        assert.equal(context.writeInFlight, false);
    }
    assert.equal(writes, 2);
});
