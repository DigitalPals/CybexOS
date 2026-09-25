const test = require("node:test");
const assert = require("node:assert/strict");
const { load } = require("./shell.cjs");

const H = load("SettingsHelpers.js");

test("defaults carry the design values", () => {
    const d = H.defaults();
    assert.equal(H.VERSION, 24);
    assert.deepEqual(d.drawerTabs.map(t => t.id),
        ["overview", "sound", "network", "bluetooth", "power", "notifications", "usage"]);
    assert.ok(d.drawerTabs.every(t => t.on === true));
    assert.deepEqual(d.drawerOverview,
        { media: true, sliders: true, tiles: true, updates: true });
    assert.equal(d.drawerHover, "open");
    assert.equal(d.drawerWidth, 400);
    assert.equal(d.themeMode, "dark");
    assert.equal(d.glassEnabled, false);
    assert.equal(d.highContrast, false);
    assert.equal(d.reducedMotion, false);
    assert.equal(d.textScale, "default");
    assert.equal(d.interfaceDensity, "default");
    assert.equal(d.barColorMode, "default");
    assert.deepEqual(
        [d.barCustomHue, d.barCustomSaturation, d.barCustomLightness],
        [230, 14, 9]);
    assert.equal(d.barHeight, 36);
    assert.equal(d.barRadius, 11);
    assert.equal(d.font, "mono");
    assert.equal(d.accent, "#d3d283");
    assert.equal(d.paletteMode, "wallpaper");
    assert.equal(d.position, "top");
    assert.equal(d.barStyle, "hug");
    assert.equal(d.gap, 8);
    assert.equal(d.autoHide, false);
    assert.equal(d.exclusive, true);
    assert.equal(d.clock24, true);
    assert.equal(d.unit, "c");
    assert.equal(d.warmth, 3400);
    assert.equal(d.osd, "bottom");
    assert.equal(d.pollMax, 300);
    assert.equal(d.scrollFactor, 1.0);
    assert.equal(d.nightLight, false);
    assert.equal(d.idleInhibitMode, "off");
    assert.equal(d.idleInhibitUntilMs, 0);
    assert.equal(d.shuffle, "Off");
    assert.equal(d.wallDir, "~/Pictures/Wallpapers");
    assert.equal(d.notifDnd, false);
    assert.equal(d.notifDndUntilMs, 0);
    assert.equal(d.notifQuiet, "off");
    assert.equal(d.notifQuietStart, 1320);
    assert.equal(d.notifQuietEnd, 420);
    assert.equal(d.notifDuration, 8);
    assert.equal(d.notifPosition, "top-right");
    assert.equal(d.notifDensity, "default");
    assert.equal(d.notifIcons, true);
    assert.equal(d.notifProgress, true);
    assert.equal(d.notifBodyLines, 2);
    assert.deepEqual(d.mods.left.map(m => m.id), ["ws", "media"]);
    assert.deepEqual(d.mods.center.map(m => m.id),
        ["indicators", "clock", "weather", "notes"]);
    assert.equal(d.mods.center.find(m => m.id === "notes").on, true);
    assert.deepEqual(d.mods.right.map(m => m.id),
        ["updates", "gh", "t3", "hermes", "usage", "tray", "notifications",
         "vol", "wifi", "bt", "batt", "control"]);
    assert.equal(d.mods.left[1].on, true, "the media chip hides itself when nothing plays");
    assert.equal(d.mods.right.find(m => m.id === "bt").on, true,
        "Bluetooth matches the portable desktop; its auto-rule hides idle hardware");
    assert.equal(d.mods.right.find(m => m.id === "tray").on, false);
    assert.equal(d.mods.right.find(m => m.id === "updates").on, true);
    assert.equal(d.mods.right.find(m => m.id === "notifications").on, true);
    for (const id of ["gh", "t3", "hermes", "usage"])
        assert.equal(d.mods.right.find(m => m.id === id).on, false,
            `${id} is available through Connected without crowding a fresh bar`);
    const moduleIds = [...d.mods.left, ...d.mods.center, ...d.mods.right]
        .map(module => module.id);
    assert.equal(new Set(moduleIds).size, moduleIds.length,
        "fresh layouts contain each widget exactly once");
    assert.deepEqual([...moduleIds].sort(), [...H.MODULE_IDS].sort());
    assert.ok(H.DETAIL_IDS.includes("notifications"));
    assert.ok([...d.mods.left, ...d.mods.center, ...d.mods.right]
        .every(module => module.detail === "auto"));
    assert.deepEqual(Object.keys(d.modOpts),
        ["ws", "media", "indicators", "clock", "weather", "notes", "t3", "hermes", "usage", "gh", "updates",
         "tray", "notifications", "vol", "batt"]);
    assert.equal(d.modOpts.ws.minSlots, 5);
    assert.equal(d.modOpts.ws.style, "numbers");
    assert.equal(d.modOpts.media.maxWidth, 180);
    assert.equal(d.modOpts.indicators.mode, "hover");
    assert.deepEqual(d.modOpts.indicators.order, H.INDICATOR_ACTION_IDS);
    assert.deepEqual(d.modOpts.indicators.enabled, H.INDICATOR_ACTION_IDS);
    assert.deepEqual({
        primary: d.modOpts.indicators.dictationPrimaryLanguage,
        secondary: d.modOpts.indicators.dictationSecondaryLanguage,
        model: d.modOpts.indicators.dictationModel,
        recording: d.modOpts.indicators.recordingMode,
        elapsed: d.modOpts.indicators.recordingShowElapsed,
        reminderDisplay: d.modOpts.indicators.reminderDisplay,
        reminderClick: d.modOpts.indicators.reminderClick,
        reminderMinutes: d.modOpts.indicators.reminderMinutes,
        nightStartup: d.modOpts.indicators.nightLightStartup,
        dndStartup: d.modOpts.indicators.dndStartup,
        dndMode: d.modOpts.indicators.dndDefaultMode,
        idleStartup: d.modOpts.indicators.idleStartup,
        idleMode: d.modOpts.indicators.idleDefaultMode,
        idleRemaining: d.modOpts.indicators.idleShowRemaining
    }, {
        primary: "en", secondary: "nl", model: "base",
        recording: "region", elapsed: true,
        reminderDisplay: "icon", reminderClick: "list", reminderMinutes: 15,
        nightStartup: "remember", dndStartup: "remember", dndMode: "always",
        idleStartup: "off", idleMode: "1h", idleRemaining: false
    });
    assert.equal(d.modOpts.clock.seconds, false);
    assert.equal(d.modOpts.clock.dateFormat, "ddd dd");
    assert.equal(d.modOpts.clock.showEvents, true);
    assert.equal(d.modOpts.clock.daysAhead, 14);
    assert.equal(d.modOpts.clock.pollMins, 15);
    assert.deepEqual(d.modOpts.updates, { pollMins: 30, flatpak: true, notify: true });
    assert.deepEqual(d.modOpts.tray, { expanded: false });
    assert.deepEqual(d.modOpts.notifications, { group: "status" });
    assert.deepEqual(d.modOpts.weather,
        { place: "", lat: 0, lon: 0, pollMins: 20 });
    assert.deepEqual(d.modOpts.notes, {
        titleProvider: "off",
        codexModel: "gpt-5.6-luna",
        codexEffort: "none",
        claudeModel: "fable",
        claudeEffort: "low"
    });
    assert.deepEqual(d.modOpts.t3, { showLabel: true });
    assert.deepEqual(d.modOpts.hermes, { showLabel: true, activityDetail: "verb" });
    assert.equal(d.modOpts.usage.warnAt, 25);
    assert.equal(d.modOpts.usage.critAt, 10);
    assert.equal(d.modOpts.usage.claudeAutoRefresh, true);
    assert.equal(d.modOpts.usage.source, "direct");
    assert.equal(d.modOpts.usage.cliproxyUrl, "");
    assert.equal(d.modOpts.usage.cliproxyTlsVerify, true);
    assert.equal(d.modOpts.usage.xai, true);
    assert.equal(d.modOpts.vol.step, 5);
    assert.equal(d.modOpts.vol.middleClick, "mute");
    assert.deepEqual(d.modOpts.batt, { showPct: true, warnAt: 20, critAt: 10 });
    assert.deepEqual(d.modOpts.gh,
        { badge: "dot", repos: 8, pollMins: 5, ciActivity: true, toasts: true, watch: [] });
    // A fresh list per call: a shared array would let one edit reach the
    // defaults every later comparison is made against.
    assert.notEqual(H.defaultModOpts().gh.watch, H.defaultModOpts().gh.watch);
    assert.notEqual(H.defaultModOpts().indicators.order,
        H.defaultModOpts().indicators.order);
    assert.notEqual(H.defaultModOpts().indicators.enabled,
        H.defaultModOpts().indicators.enabled);
});

test("menubar presets are a small intentional neutral palette", () => {
    assert.deepEqual(H.BAR_COLOR_CHOICES.map(choice => [choice.id, choice.label]), [
        ["default", "Shell Default"],
        ["macos", "macOS"],
        ["black", "Black"],
        ["graphite", "Graphite"],
        ["slate", "Slate"],
        ["white", "White"],
        ["custom", "Custom"]
    ]);

    const resolve = (mode, theme = "dark") =>
        H.resolveBarColor(mode, theme, 230, 14, 9);
    assert.equal(resolve("default"), "#1a1917");
    assert.equal(resolve("default", "light"), "#eae9ef");
    assert.equal(resolve("macos"), "#1d1d1f");
    assert.equal(resolve("macos", "light"), "#f5f5f7");
    assert.equal(resolve("black", "light"), "#000000");
    assert.equal(resolve("graphite"), "#2c2c2e");
    assert.equal(resolve("slate"), "#344054");
    assert.equal(resolve("white"), "#ffffff");
    assert.equal(resolve("custom"), "#14151a",
        "integer HSL sliders begin within one RGB step of the shell's dark colour");
});

test("custom menubar HSL is deterministic and persisted input is bounded", () => {
    assert.equal(H.hslToHex(0, 100, 50), "#ff0000");
    assert.equal(H.hslToHex(120, 100, 50), "#00ff00");
    assert.equal(H.hslToHex(240, 100, 50), "#0000ff");
    assert.equal(H.hslToHex(480, 100, 50), "#00ff00", "hue wraps for previews");
    assert.equal(H.hslToHex(17, 0, 50), "#808080");

    const merged = H.merge({
        v: H.VERSION,
        glassEnabled: false,
        barColorMode: "custom",
        barCustomHue: 999,
        barCustomSaturation: -4,
        barCustomLightness: 140
    });
    assert.equal(merged.glassEnabled, false);
    assert.equal(merged.barColorMode, "custom");
    assert.deepEqual(
        [merged.barCustomHue, merged.barCustomSaturation, merged.barCustomLightness],
        [359, 0, 100]);

    const invalid = H.merge({
        glassEnabled: "no", barColorMode: "neon", barCustomHue: "blue"
    });
    assert.equal(invalid.glassEnabled, false);
    assert.equal(invalid.barColorMode, "default");
    assert.equal(invalid.barCustomHue, 230);
});

test("the automatic menubar palette keeps copy at AA contrast", () => {
    const backgrounds = [
        "#161424", "#1d1d1f", "#000000", "#2c2c2e", "#344054",
        "#ffffff", "#f5f5f7", "#777777", "#00aaaa"
    ];
    for (const background of backgrounds) {
        const palette = H.barPalette(background);
        for (const key of ["textHi", "textMid", "textLow", "textDim", "textFaint", "icon"])
            assert.ok(H.contrastRatio(palette[key], background) >= 4.5,
                `${key} does not clear 4.5:1 on ${background}`);
        for (const semantic of ["#5e9bff", "#c22f2f", "#b5761e"])
            assert.ok(H.contrastRatio(H.ensureContrast(semantic, background, 4.5), background)
                >= 4.5, `${semantic} does not clear 4.5:1 on ${background}`);
    }
    assert.equal(H.foregroundFor("#000000"), "#ffffff");
    assert.equal(H.foregroundFor("#ffffff"), "#000000");
});

test("the automatic menubar palette keeps the shared icon brightness", () => {
    const dark = H.barPalette("#131419");
    const light = H.barPalette("#ffffff");

    assert.equal(dark.icon, "#c2c6d1",
        "the default dark bar must use the bright shared silver");
    assert.equal(light.icon, "#3a3850",
        "light bars need the established deep-ink counterpart");
    assert.ok(H.contrastRatio(dark.icon, dark.background) >= 10.5);
    assert.ok(H.contrastRatio(light.icon, light.background) >= 10.5);
});

test("normalizeModOpts drops unknown modules and keys", () => {
    const next = H.normalizeModOpts({
        flux: { on: true },
        wifi: { anything: 1 },
        clock: { seconds: true, bogus: "x" },
        t3: { showLabel: false, pulse: true },
        hermes: { showLabel: false, activityDetail: "private", pulse: true },
        vol: "not-an-object"
    });
    assert.ok(!("flux" in next) && !("wifi" in next));
    assert.equal(next.clock.seconds, true);
    assert.ok(!("bogus" in next.clock));
    assert.deepEqual(next.t3, { showLabel: false });
    assert.deepEqual(next.hermes, { showLabel: false, activityDetail: "verb" });
    assert.deepEqual(next.vol, H.defaultModOpts().vol);
    assert.deepEqual(H.normalizeModOpts(null), H.defaultModOpts());
    assert.deepEqual(H.normalizeModOpts("nope"), H.defaultModOpts());
});

test("normalizeModOpts clamps, snaps, and validates option values", () => {
    const next = H.normalizeModOpts({
        ws: { minSlots: 99, style: "triangles" },
        media: { maxWidth: 133, titleFormat: "title" },
        indicators: {
            mode: "sometimes",
            order: ["dnd", "bogus", "dnd", "dictation"],
            enabled: ["recording", "bogus", "recording"],
            dictationPrimaryLanguage: "not a language!",
            dictationSecondaryLanguage: "OFF",
            dictationModel: "enormous",
            recordingMode: "desktop",
            recordingShowElapsed: "yes",
            reminderDisplay: "badge",
            reminderClick: "create",
            reminderMinutes: 17,
            nightLightStartup: "sometimes",
            dndStartup: "sometimes",
            dndDefaultMode: "forever",
            idleStartup: "sometimes",
            idleDefaultMode: "2h",
            idleShowRemaining: "yes"
        },
        clock: { showEvents: "yes", daysAhead: 99, pollMins: 7 },
        weather: { lat: 200, lon: -12.34567, place: "  Emmen Centrum  ", pollMins: 7 },
        notes: {
            titleProvider: "automatic", codexModel: " bad model ",
            codexEffort: "minimal", claudeModel: "claude-fable-5",
            claudeEffort: "none"
        },
        hermes: { showLabel: "yes", activityDetail: "full" },
        usage: {
            warnAt: 8, critAt: 60, claude: "yes", claudeAutoRefresh: false,
            source: "unknown", cliproxyUrl: "  https://proxy.test/management.html  ",
            cliproxyTlsVerify: true, xai: false
        },
        gh: {
            badge: "flag", repos: 99, pollMins: 0,
            ciActivity: "sure", toasts: "sure"
        },
        notifications: { group: "anything" },
        vol: { step: 0, middleClick: "detonate" },
        batt: { warnAt: 33, critAt: 3 },
        updates: { pollMins: 5, flatpak: "sure" },
        tray: { expanded: true }
    });
    assert.equal(next.gh.badge, "dot");
    assert.equal(next.gh.repos, 15);
    assert.equal(next.gh.pollMins, 1);
    assert.equal(next.gh.ciActivity, true, "non-boolean falls back to default");
    assert.equal(next.gh.toasts, true, "non-boolean falls back to default");
    assert.equal(next.notifications.group, "status");
    assert.equal(H.normalizeModOpts({ notifications: { group: "solo" } })
        .notifications.group, "solo");
    assert.equal(H.normalizeModOpts({ gh: { ciActivity: false } }).gh.ciActivity, false,
        "an explicit CI opt-out survives normalization");
    assert.equal(next.ws.minSlots, 10);
    assert.equal(next.ws.style, "numbers");
    assert.equal(next.media.maxWidth, 140);
    assert.equal(next.media.titleFormat, "title");
    assert.equal(next.indicators.mode, "hover");
    assert.equal(H.normalizeModOpts({ indicators: { mode: "always" } }).indicators.mode,
        "always");
    assert.equal(H.normalizeModOpts({ indicators: { mode: "active" } }).indicators.mode,
        "active");
    assert.deepEqual(next.indicators.order,
        ["dnd", "dictation", "recording", "ocr", "reminder", "night-light", "stay-awake"]);
    assert.deepEqual(next.indicators.enabled, ["recording"]);
    assert.equal(next.indicators.dictationPrimaryLanguage, "en");
    assert.equal(next.indicators.dictationSecondaryLanguage, "off");
    assert.equal(next.indicators.dictationModel, "base");
    assert.equal(next.indicators.recordingMode, "region");
    assert.equal(next.indicators.recordingShowElapsed, true);
    assert.equal(next.indicators.reminderDisplay, "icon");
    assert.equal(next.indicators.reminderClick, "list");
    assert.equal(next.indicators.reminderMinutes, 15);
    assert.equal(next.indicators.nightLightStartup, "remember");
    assert.equal(next.indicators.dndStartup, "remember");
    assert.equal(next.indicators.dndDefaultMode, "always");
    assert.equal(next.indicators.idleStartup, "off");
    assert.equal(next.indicators.idleDefaultMode, "1h");
    assert.equal(next.indicators.idleShowRemaining, false);
    const configuredIndicators = H.normalizeModOpts({ indicators: {
        enabled: [], dictationPrimaryLanguage: "en,nl", dictationSecondaryLanguage: "de-de",
        dictationModel: "large-v3-turbo", recordingMode: "window",
        recordingShowElapsed: false, reminderDisplay: "count",
        reminderClick: "quick-add", reminderMinutes: 60,
        nightLightStartup: "on", dndStartup: "off",
        dndDefaultMode: "quiet-boundary", idleStartup: "remember",
        idleDefaultMode: "unplugged", idleShowRemaining: true
    } }).indicators;
    assert.deepEqual(configuredIndicators.enabled, []);
    assert.deepEqual([
        configuredIndicators.dictationPrimaryLanguage,
        configuredIndicators.dictationSecondaryLanguage,
        configuredIndicators.dictationModel,
        configuredIndicators.recordingMode,
        configuredIndicators.recordingShowElapsed,
        configuredIndicators.reminderDisplay,
        configuredIndicators.reminderClick,
        configuredIndicators.reminderMinutes,
        configuredIndicators.nightLightStartup,
        configuredIndicators.dndStartup,
        configuredIndicators.dndDefaultMode,
        configuredIndicators.idleStartup,
        configuredIndicators.idleDefaultMode,
        configuredIndicators.idleShowRemaining
    ], ["en,nl", "de-de", "large-v3-turbo", "window", false, "count",
        "quick-add", 60, "on", "off", "quiet-boundary", "remember",
        "unplugged", true]);
    assert.equal(next.clock.showEvents, true, "non-boolean falls back to default");
    assert.equal(next.clock.daysAhead, 31);
    assert.equal(next.clock.pollMins, 5);
    assert.equal(next.weather.lat, 90, "out-of-range latitude clamps like other numerics");
    assert.equal(next.weather.lon, -12.3457);
    assert.equal(next.weather.place, "Emmen Centrum");
    assert.equal(next.weather.pollMins, 5);
    assert.equal(next.notes.titleProvider, "off");
    assert.equal(next.notes.codexModel, "gpt-5.6-luna");
    assert.equal(next.notes.codexEffort, "none");
    assert.equal(next.notes.claudeModel, "fable");
    assert.equal(next.notes.claudeEffort, "low");
    const codex = H.normalizeModOpts({ notes: {
        titleProvider: "codex", codexModel: "gpt-5.6-sol", codexEffort: "max"
    } }).notes;
    assert.deepEqual([codex.titleProvider, codex.codexModel, codex.codexEffort],
        ["codex", "gpt-5.6-sol", "max"]);
    const claude = H.normalizeModOpts({ notes: {
        titleProvider: "claude", claudeModel: "opus", claudeEffort: "xhigh"
    } }).notes;
    assert.deepEqual([claude.titleProvider, claude.claudeModel, claude.claudeEffort],
        ["claude", "opus", "xhigh"]);
    assert.equal(next.hermes.showLabel, true, "non-boolean falls back to default");
    assert.equal(next.hermes.activityDetail, "full");
    assert.equal(H.normalizeModOpts({ hermes: { activityDetail: "generic" } })
        .hermes.activityDetail, "generic");
    assert.equal(next.usage.warnAt, 10);
    assert.equal(next.usage.critAt, 25);
    assert.equal(next.usage.claude, true, "non-boolean falls back to default");
    assert.equal(next.usage.claudeAutoRefresh, false);
    assert.equal(next.usage.source, "direct");
    assert.equal(next.usage.cliproxyUrl, "https://proxy.test/management.html");
    assert.equal(next.usage.cliproxyTlsVerify, true);
    assert.equal(next.usage.xai, false);
    assert.equal(next.vol.step, 1);
    assert.equal(next.vol.middleClick, "mute");
    assert.equal(next.batt.warnAt, 35, "snaps to step 5");
    assert.equal(next.batt.critAt, 5);
    assert.equal(next.updates.pollMins, 10, "clamps to the shortest useful interval");
    assert.equal(next.updates.flatpak, true, "non-boolean falls back to default");
    assert.equal(next.tray.expanded, true);
});

test("weather place rejects control characters and oversized strings", () => {
    const d = H.defaultModOpts().weather.place;
    assert.equal(H.normalizeModOpts({ weather: { place: "a\nb" } }).weather.place, d);
    assert.equal(H.normalizeModOpts({ weather: { place: "a\0b" } }).weather.place, d);
    assert.equal(H.normalizeModOpts({ weather: { place: "   " } }).weather.place, d);
    assert.equal(H.normalizeModOpts({ weather: { place: "x".repeat(41) } }).weather.place, d);
    assert.equal(H.normalizeModOpts({ weather: { place: "x".repeat(40) } }).weather.place,
        "x".repeat(40));
});

test("the GitHub watch list stores canonical slugs and nothing else", () => {
    // Storage is deliberately stricter than the settings field, which accepts
    // a pasted URL and canonicalises it before it ever reaches this store.
    // Anything else in the file was hand-written, and each entry costs a poll
    // an API call — hence the cap.
    const watch = raw => H.normalizeModOpts({ gh: { watch: raw } }).gh.watch;
    assert.deepEqual(watch(["hyprwm/Hyprland", "cli/cli"]),
        ["hyprwm/Hyprland", "cli/cli"]);
    assert.deepEqual(watch(["hyprwm/Hyprland", "HYPRWM/hyprland"]), ["hyprwm/Hyprland"],
        "one repository, two spellings, would be polled twice");
    assert.deepEqual(watch(["https://github.com/cli/cli", "a/b/c", "no-slash",
        "-bad/owner", "owner/..", 7, null, "a/b"]), ["a/b"]);
    assert.deepEqual(watch("owner/repo"), [], "a bare string is not a list");
    assert.deepEqual(watch([]), []);
    assert.equal(watch(Array.from({ length: 50 }, (_, i) => "o/r" + i)).length,
        H.MAX_WATCHED_REPOS);
    assert.deepEqual(H.repoListIn("nope", ["kept/value"]), ["kept/value"],
        "a non-list keeps whatever was there");
});

test("merge fills a missing modOpts from defaults and sanitizes a partial one", () => {
    assert.deepEqual(H.merge({ barHeight: 36 }).modOpts, H.defaultModOpts());
    const merged = H.merge({ modOpts: { batt: { showPct: false } } });
    assert.equal(merged.modOpts.batt.showPct, false);
    assert.equal(merged.modOpts.batt.warnAt, 20);
    assert.deepEqual(merged.modOpts.clock, H.defaultModOpts().clock);
});

test("merge over a partial object fills the rest from defaults", () => {
    const merged = H.merge({ v: H.VERSION, barHeight: 36, unit: "f" });
    assert.equal(merged.barHeight, 36);
    assert.equal(merged.unit, "f");
    assert.equal(merged.barRadius, 11);
    assert.equal(merged.accent, "#d3d283");
    assert.ok(!("v" in merged));
    assert.ok(!("bogus" in H.merge({ bogus: 1 })));
});

test("merge on null or garbage returns pure defaults", () => {
    assert.deepEqual(H.merge(null), H.defaults());
    assert.deepEqual(H.merge("nope"), H.defaults());
});

test("parse separates an absent settings file from an unreadable one", () => {
    // Both merge to defaults, but only "empty" may be saved over: a corrupt
    // file's bytes are the user's only copy and have to survive.
    for (const absent of ["", "   ", "\n\t\n", undefined, null])
        assert.equal(H.parse(absent).status, "empty", `${JSON.stringify(absent)} is absent`);

    // Unparseable, and valid JSON that is not a settings object. Both are
    // damage, not a first run.
    for (const corrupt of ["{broken", "42", "null", "[]", '"text"', "true", "{}}"])
        assert.equal(H.parse(corrupt).status, "corrupt", `${corrupt} is corrupt`);

    assert.equal(H.parse("{broken").value, null);
});

test("parse returns the settings object unchanged when it is readable", () => {
    const result = H.parse('{"v":4,"barHeight":36}');
    assert.equal(result.status, "ok");
    assert.deepEqual(result.value, { v: 4, barHeight: 36 });
    assert.equal(H.merge(result.value).barHeight, 36);

    // A truncated file must not merge as if it were the settings it came from.
    const truncated = H.parse('{"v":4,"barHeight":36');
    assert.equal(truncated.status, "corrupt");
    assert.deepEqual(H.merge(truncated.value), H.defaults());
});

test("merge clamps and snaps numeric ranges", () => {
    assert.equal(H.merge({ barHeight: 99 }).barHeight, 60);
    assert.equal(H.merge({ barHeight: 10 }).barHeight, 28);
    assert.equal(H.merge({ barHeight: 45.6 }).barHeight, 46);
    assert.equal(H.merge({ barHeight: "30" }).barHeight, 36);
    assert.equal(H.merge({ gap: 1 }).gap, 4);
    assert.equal(H.merge({ barRadius: -3 }).barRadius, 0);
    assert.equal(H.merge({ warmth: 3333 }).warmth, 3350);
    assert.equal(H.merge({ warmth: 100 }).warmth, 1900);
    assert.equal(H.merge({ warmth: NaN }).warmth, 3400);
    assert.equal(H.merge({ scrollFactor: 1.26 }).scrollFactor, 1.3);
    assert.equal(H.merge({ scrollFactor: 0.01 }).scrollFactor, 0.2);
    assert.equal(H.merge({ scrollFactor: 4 }).scrollFactor, 2.0);
    assert.equal(H.merge({ scrollFactor: "1.5" }).scrollFactor, 1.0);
});

test("merge falls back on invalid enums, colors and names", () => {
    assert.equal(H.merge({ font: "comic-sans" }).font, "mono");
    assert.equal(H.merge({ v: H.VERSION, font: "oppo" }).font, "oppo",
        "the previous menu face stays selectable");
    assert.equal(H.merge({ themeMode: "sepia" }).themeMode, "dark");
    assert.equal(H.merge({ v: H.VERSION, paletteMode: "auto" }).paletteMode,
        "wallpaper");
    assert.equal(H.merge({ v: H.VERSION, barStyle: "island" }).barStyle, "hug");
    assert.equal(H.merge({ position: "left" }).position, "top");
    const invalidAccessibility = H.merge({
        highContrast: "yes",
        reducedMotion: 1,
        textScale: "huge",
        interfaceDensity: "touch"
    });
    assert.equal(invalidAccessibility.highContrast, false);
    assert.equal(invalidAccessibility.reducedMotion, false);
    assert.equal(invalidAccessibility.textScale, "default");
    assert.equal(invalidAccessibility.interfaceDensity, "default");
    assert.equal(H.merge({ pollMax: 120 }).pollMax, 300);
    assert.equal(H.merge({ accent: "red" }).accent, "#d3d283");
    assert.equal(H.merge({ accent: "#a992e0" }).accent, "#a992e0");
    assert.equal(H.merge({ wall: "../../etc/passwd" }).wall, H.defaults().wall);
    assert.equal(H.merge({ wall: "" }).wall, H.defaults().wall);
    assert.ok(!("monitor" in H.merge({ monitor: "eDP-1" })),
        "the retired single-monitor setting must be ignored");
});

test("schema-5 bar modes migrate without losing customized geometry", () => {
    assert.equal(H.merge({
        v: 5, floating: true, barHeight: 46, barRadius: 23, gap: 10
    }).barStyle, "hug", "pristine floating geometry adopts the new default");
    assert.equal(H.merge({
        v: 5, floating: true, barHeight: 44, barRadius: 23, gap: 10
    }).barStyle, "floating", "a customized height remains floating");
    assert.equal(H.merge({
        v: 5, floating: true, barHeight: 46, barRadius: 18, gap: 10
    }).barStyle, "floating", "a customized radius remains floating");
    assert.equal(H.merge({
        v: 5, floating: false, barHeight: 46, barRadius: 23, gap: 10
    }).barStyle, "attached");
});

test("schema-5 colors select wallpaper or fixed mode and remain stored", () => {
    const pristine = H.merge({
        v: 5, accent: "#5e9bff", barColorMode: "default"
    });
    assert.equal(pristine.paletteMode, "wallpaper");

    const oldWallpaperAccent = H.merge({
        v: 5, accentWall: true, accent: "#a992e0", barColorMode: "black"
    });
    assert.equal(oldWallpaperAccent.paletteMode, "wallpaper");
    assert.equal(oldWallpaperAccent.accent, "#a992e0");
    assert.equal(oldWallpaperAccent.barColorMode, "black");

    const customAccent = H.merge({ v: 5, accent: "#a992e0" });
    assert.equal(customAccent.paletteMode, "fixed");
    assert.equal(customAccent.accent, "#a992e0");

    const customBar = H.merge({ v: 5, barColorMode: "graphite" });
    assert.equal(customBar.paletteMode, "fixed");
    assert.equal(customBar.barColorMode, "graphite");

    const dormantCustomBar = H.merge({
        v: 5, barColorMode: "default", barCustomHue: 120
    });
    assert.equal(dormantCustomBar.paletteMode, "fixed");
    assert.equal(dormantCustomBar.barCustomHue, 120);
});

test("schema-6 migration preserves module order and adds clock-side indicators", () => {
    const raw = H.defaultMods();
    raw.left = [raw.left[1], raw.left[0]];
    raw.right = raw.right.filter(mod => mod.id !== "control");
    raw.right = [raw.right.at(-1), ...raw.right.slice(0, -1)];
    const migrated = H.merge({ v: 5, floating: true, mods: raw });
    assert.deepEqual(migrated.mods.left.map(entry => entry.id), ["media", "ws"]);
    assert.deepEqual(migrated.mods.center.map(entry => entry.id),
        ["indicators", "clock", "weather", "notes"]);
    assert.equal(migrated.mods.right[0].id, "batt");
});

test("schema-7 adopts Google Sans only from the previous default", () => {
    assert.equal(H.merge({ v: 6, font: "urbanist" }).font, "google",
        "the old untouched default follows the softer typography pass");
    assert.equal(H.merge({ v: 6, font: "plex" }).font, "plex",
        "an explicit previous-schema choice survives");
    assert.equal(H.merge({ v: H.VERSION, font: "urbanist" }).font, "urbanist",
        "Urbanist remains selectable after migration");
});

test("normalizeMods drops unknown ids and dedupes across columns", () => {
    const next = H.normalizeMods({
        left: [{ id: "clock", on: true }, { id: "flux", on: true }, { id: "clock", on: false }],
        center: [{ id: "clock", on: false }],
        right: []
    });
    assert.deepEqual(next.left.map(m => m.id), ["clock", "ws", "media"],
        "flux dropped, duplicate clock collapsed, absent defaults appended");
    assert.equal(next.left[0].on, true, "first occurrence of a duplicate wins");
    assert.deepEqual(next.center.map(m => m.id), ["indicators", "weather", "notes"]);
    const all = [...next.left, ...next.center, ...next.right].map(m => m.id).sort();
    assert.deepEqual(all, [...H.MODULE_IDS].sort());
});

test("normalizeMods appends ids missing from the file at their default column", () => {
    const next = H.normalizeMods({ left: [{ id: "vol", on: false }], center: [], right: [] });
    assert.deepEqual(next.left.map(m => m.id), ["vol", "ws", "media"]);
    assert.equal(next.left[0].on, false);
    assert.deepEqual(next.center.map(m => m.id),
        ["indicators", "clock", "weather", "notes"]);
    assert.deepEqual(next.right.map(m => m.id),
        ["updates", "gh", "t3", "hermes", "usage", "tray", "notifications",
         "wifi", "bt", "batt", "control"]);
    assert.ok(next.right.some(m => m.id === "bt" && m.on === true),
        "appended module keeps its default enable flag");
});

test("normalizeMods falls back to the default flag for a non-boolean", () => {
    const next = H.normalizeMods({ left: [{ id: "bt", on: "yes" }], center: [], right: [] });
    assert.equal(next.left[0].on, true);
});

test("a schema-3 file adopts the redesign only where it was left untouched", () => {
    // The glass menubar changed the bar's proportions, and a settings file
    // written by the previous schema carries the old ones for every key. A
    // value the user never moved takes the new default; one they did is theirs.
    const untouched = H.merge({
        v: 3, barHeight: 30, barRadius: 9, gap: 8, accent: "#9ecbeb",
        font: "oppo", osd: "top",
        modOpts: { ws: { style: "numbers" }, media: { maxWidth: 220 } }
    });
    assert.equal(untouched.barHeight, 36);
    assert.equal(untouched.barRadius, 11);
    assert.equal(untouched.gap, 8);
    assert.equal(untouched.accent, "#d3d283");
    assert.equal(untouched.font, "google");
    assert.equal(untouched.osd, "bottom");
    assert.equal(untouched.modOpts.ws.style, "numbers");
    assert.equal(untouched.modOpts.media.maxWidth, 180);

    const chosen = H.merge({
        v: 3, barHeight: 36, accent: "#a992e0", font: "mono",
        modOpts: { ws: { style: "dots" }, media: { maxWidth: 300 } }
    });
    assert.equal(chosen.barHeight, 36);
    assert.equal(chosen.accent, "#a992e0");
    assert.equal(chosen.font, "mono");
    assert.equal(chosen.modOpts.ws.style, "dots");
    assert.equal(chosen.modOpts.media.maxWidth, 300);

    // A current-schema file is never rewritten, even where it matches an old
    // default exactly.
    const current = H.merge({ v: H.VERSION, barHeight: 30, accent: "#9ecbeb" });
    assert.equal(current.barHeight, 30);
    assert.equal(current.accent, "#9ecbeb");
});

test("schema-4 appearance choices survive later schema upgrades", () => {
    // Schema 4 already carried the glass redesign. Values equal to the older
    // v3 defaults can now be deliberate choices and must not be adopted a
    // second time when the new colour settings are filled from defaults.
    const previous = H.merge({
        v: 4,
        themeMode: "light",
        barHeight: 30,
        barRadius: 9,
        gap: 8,
        accent: "#9ecbeb",
        font: "oppo",
        osd: "top"
    });
    assert.equal(previous.themeMode, "light");
    assert.equal(previous.barHeight, 30);
    assert.equal(previous.barRadius, 9);
    assert.equal(previous.gap, 8);
    assert.equal(previous.accent, "#9ecbeb");
    assert.equal(previous.font, "oppo");
    assert.equal(previous.osd, "top");
    assert.equal(previous.glassEnabled, false);
    assert.equal(previous.barColorMode, "default");
    assert.equal(previous.barStyle, "floating");
    assert.equal(previous.paletteMode, "fixed");
    assert.equal(H.resolveBarColor(previous.barColorMode, previous.themeMode,
        previous.barCustomHue, previous.barCustomSaturation,
        previous.barCustomLightness), H.BAR_COLOR_PRESETS.default.light);
});

test("schema-9 adopts the classic bar only from untouched design values", () => {
    const untouched = H.merge({
        v: 9,
        glassEnabled: true,
        barHeight: 46,
        barRadius: 23,
        gap: 10,
        accent: "#5e9bff",
        barColorMode: "default",
        barCustomHue: 247,
        barCustomSaturation: 29,
        barCustomLightness: 11,
        modOpts: {
            ws: { style: "dots" },
            clock: { dateFormat: "ddd d MMM" }
        }
    });
    assert.equal(untouched.glassEnabled, false);
    assert.equal(untouched.barHeight, 36);
    assert.equal(untouched.barRadius, 11);
    assert.equal(untouched.gap, 8);
    assert.equal(untouched.accent, "#d3d283");
    assert.deepEqual([
        untouched.barCustomHue,
        untouched.barCustomSaturation,
        untouched.barCustomLightness
    ], [230, 14, 9]);
    assert.equal(untouched.modOpts.ws.style, "numbers");
    assert.equal(untouched.modOpts.clock.dateFormat, "ddd dd");

    const chosen = H.merge({
        v: 9,
        glassEnabled: false,
        barHeight: 40,
        barRadius: 17,
        gap: 12,
        accent: "#a992e0",
        barColorMode: "custom",
        barCustomHue: 247,
        barCustomSaturation: 29,
        barCustomLightness: 11,
        modOpts: {
            ws: { style: "numbers" },
            clock: { dateFormat: "dd-MM" }
        }
    });
    assert.equal(chosen.glassEnabled, false);
    assert.equal(chosen.barHeight, 40);
    assert.equal(chosen.barRadius, 17);
    assert.equal(chosen.gap, 12);
    assert.equal(chosen.accent, "#a992e0");
    assert.deepEqual([
        chosen.barCustomHue,
        chosen.barCustomSaturation,
        chosen.barCustomLightness
    ], [247, 29, 11], "an explicitly selected custom color remains exact");
    assert.equal(chosen.modOpts.ws.style, "numbers");
    assert.equal(chosen.modOpts.clock.dateFormat, "dd-MM");
});

test("the tray and the updates chip persist in any module column", () => {
    const raw = H.defaultMods();
    raw.right = raw.right.filter(m => m.id !== "tray" && m.id !== "updates");
    raw.left.unshift({ id: "updates", on: true });
    raw.center.push({ id: "tray", on: true });

    const next = H.normalizeMods(raw);
    assert.equal(next.left[0].id, "updates");
    assert.equal(next.center.at(-1).id, "tray");
    assert.ok(!next.right.some(m => m.id === "tray" || m.id === "updates"));
});

test("schema-11 adds notifications without rewriting a custom layout", () => {
    const oldIds = H.MODULE_IDS.filter(id => !["notifications", "control"].includes(id));
    const entry = (id, index) => ({
        id,
        on: index % 3 !== 0,
        detail: ["auto", "prefer", "compact"][index % 3]
    });
    const raw = {
        left: oldIds.slice(0, 5).reverse().map(entry),
        center: oldIds.slice(5, 9).map((id, index) => entry(id, index + 5)),
        right: oldIds.slice(9).map((id, index) => entry(id, index + 9))
    };

    const migrated = H.merge({ v: 10, mods: raw }).mods;
    for (const col of ["left", "center", "right"])
        assert.deepEqual(migrated[col].filter(mod => !["notifications", "control"].includes(mod.id)), raw[col],
            `${col} entries changed while adding notifications`);
    const added = migrated.right.filter(mod => mod.id === "notifications");
    assert.deepEqual(added, [{ id: "notifications", on: true, detail: "auto" }]);
    const all = [...migrated.left, ...migrated.center, ...migrated.right]
        .map(mod => mod.id);
    assert.equal(new Set(all).size, H.MODULE_IDS.length);
});

test("schema-11 inserts notifications before the first right-side status widget", () => {
    const raw = H.defaultMods();
    raw.right = raw.right.filter(mod => mod.id !== "notifications");
    const byId = Object.fromEntries(raw.right.map(mod => [mod.id, mod]));
    raw.right = [byId.updates, byId.tray, byId.gh, byId.wifi, byId.t3,
        byId.usage, byId.vol, byId.bt, byId.batt];

    const migrated = H.merge({ v: 10, mods: raw }).mods.right;
    assert.deepEqual(migrated.map(mod => mod.id),
        ["updates", "tray", "gh", "notifications", "wifi", "t3",
         "hermes", "usage", "vol", "bt", "batt", "control"]);
});

test("schema-11 appends notifications on the right when its status widgets moved", () => {
    const raw = H.defaultMods();
    raw.right = raw.right.filter(mod => mod.id !== "notifications");
    const statusIds = ["vol", "wifi", "bt", "batt"];
    const moved = raw.right.filter(mod => statusIds.includes(mod.id));
    raw.right = raw.right.filter(mod => !statusIds.includes(mod.id));
    raw.left = raw.left.concat(moved);

    const migrated = H.merge({ v: 10, mods: raw }).mods;
    assert.equal(migrated.right.at(-2).id, "notifications");
    assert.deepEqual(migrated.left, raw.left,
        "status widgets keep their custom column, order, flags and policies");
});

test("schema-14 inserts Hermes immediately after T3 without rewriting a custom layout", () => {
    const oldIds = H.MODULE_IDS.filter(id => !["hermes", "control"].includes(id));
    const entry = (id, index) => ({
        id,
        on: index % 2 === 0,
        detail: ["compact", "prefer", "auto"][index % 3]
    });
    const raw = {
        left: oldIds.slice(0, 4).reverse().map(entry),
        center: oldIds.slice(4, 8).map((id, index) => entry(id, index + 4)),
        right: oldIds.slice(8).map((id, index) => entry(id, index + 8))
    };
    const t3Col = ["left", "center", "right"].find(col =>
        raw[col].some(mod => mod.id === "t3"));
    const t3Index = raw[t3Col].findIndex(mod => mod.id === "t3");

    const migrated = H.merge({ v: 13, mods: raw }).mods;
    for (const col of ["left", "center", "right"])
        assert.deepEqual(migrated[col].filter(mod => !["hermes", "control"].includes(mod.id)), raw[col],
            `${col} entries changed while adding Hermes`);
    assert.deepEqual(migrated[t3Col][t3Index + 1],
        { id: "hermes", on: true, detail: "auto" });
    const all = [...migrated.left, ...migrated.center, ...migrated.right];
    assert.equal(all.filter(mod => mod.id === "hermes").length, 1);
});

test("an older layout that already places Hermes keeps that placement and flags", () => {
    const raw = H.defaultMods();
    raw.right = raw.right.filter(mod => mod.id !== "hermes");
    raw.left.unshift({ id: "hermes", on: false, detail: "compact" });

    const merged = H.merge({ v: 13, mods: raw }).mods;
    assert.deepEqual(merged.left[0],
        { id: "hermes", on: false, detail: "compact" });
    assert.equal([...merged.left, ...merged.center, ...merged.right]
        .filter(mod => mod.id === "hermes").length, 1);
});

test("bell and idle remain retired after Control Center returns", () => {
    // Schema 11 uses the new `notifications` id rather than resurrecting the
    // historical bell key. Stay awake remains an indicator action.
    for (const id of H.RETIRED_MODULE_IDS)
        assert.ok(!H.MODULE_IDS.includes(id), `${id} is still a module`);
    const next = H.normalizeMods({
        left: H.RETIRED_MODULE_IDS.map(id => ({ id, on: true })),
        center: [], right: []
    });
    const all = [...next.left, ...next.center, ...next.right].map(m => m.id);
    for (const id of H.RETIRED_MODULE_IDS)
        assert.ok(!all.includes(id), `${id} survived normalization`);
    assert.deepEqual([...all].sort(), [...H.MODULE_IDS].sort());
});

test("version one layouts insert usage after t3 with its column and enabled state", () => {
    const enabled = H.merge({
        v: 1,
        mods: {
            left: [{ id: "ws", on: true }],
            center: [{ id: "t3", on: true }, { id: "clock", on: true }],
            right: [{ id: "vol", on: true }]
        }
    }).mods;
    assert.deepEqual(enabled.center.slice(0, 5), [
        { id: "t3", on: true, detail: "auto" },
        { id: "hermes", on: true, detail: "auto" },
        { id: "usage", on: true, detail: "auto" },
        { id: "indicators", on: true, detail: "auto" },
        { id: "clock", on: true, detail: "auto" }
    ]);

    const disabled = H.merge({
        v: 1,
        mods: {
            left: [],
            center: [],
            right: [{ id: "vol", on: true }, { id: "t3", on: false }]
        }
    }).mods;
    assert.deepEqual(disabled.right.slice(0, 5), [
        { id: "notifications", on: true, detail: "auto" },
        { id: "vol", on: true, detail: "auto" },
        { id: "t3", on: false, detail: "auto" },
        { id: "hermes", on: true, detail: "auto" },
        { id: "usage", on: false, detail: "auto" }
    ]);
});

test("unversioned layouts receive the same composite t3 migration", () => {
    const mods = H.merge({
        mods: {
            left: [{ id: "t3", on: false }, { id: "media", on: true }],
            center: [],
            right: []
        }
    }).mods;
    assert.deepEqual(mods.left.slice(0, 4), [
        { id: "t3", on: false, detail: "auto" },
        { id: "hermes", on: true, detail: "auto" },
        { id: "usage", on: false, detail: "auto" },
        { id: "media", on: true, detail: "auto" }
    ]);
});

test("schema-8 inserts indicators immediately before the existing clock", () => {
    const raw = {
        left: [{ id: "media", on: false }],
        center: [{ id: "weather", on: false }],
        right: [
            { id: "vol", on: false, detail: "compact" },
            { id: "clock", on: true, detail: "prefer" },
            { id: "tray", on: false }
        ]
    };
    const migrated = H.merge({ v: 7, mods: raw }).mods;
    assert.deepEqual(migrated.right.slice(0, 5), [
        { id: "notifications", on: true, detail: "auto" },
        { id: "vol", on: false, detail: "compact" },
        { id: "indicators", on: true, detail: "auto" },
        { id: "clock", on: true, detail: "prefer" },
        { id: "tray", on: false, detail: "auto" }
    ]);
    assert.deepEqual(migrated.left[0], { id: "media", on: false, detail: "auto" });
    assert.deepEqual(migrated.center[0], { id: "weather", on: false, detail: "auto" });
});

test("schema-8 validates persisted action and system toggle state", () => {
    const valid = H.merge({
        v: 8, nightLight: true, idleInhibited: false,
        modOpts: { indicators: { mode: "always" } }
    });
    assert.equal(valid.nightLight, true);
    assert.equal(valid.idleInhibitMode, "off");
    assert.equal(valid.idleInhibitUntilMs, 0);
    assert.equal(valid.modOpts.indicators.mode, "always");

    const invalid = H.merge({
        v: 8, nightLight: "on", idleInhibited: 0,
        modOpts: { indicators: { mode: "visible" } }
    });
    assert.equal(invalid.nightLight, false);
    assert.equal(invalid.idleInhibitMode, "off");
    assert.equal(invalid.modOpts.indicators.mode, "hover");
});

test("pre-OCR action lists place OCR beside recording without overriding visibility", () => {
    const priorIds = [
        "dictation", "recording", "reminder", "night-light", "dnd", "stay-awake"
    ];
    const untouched = H.merge({
        v: H.VERSION,
        modOpts: { indicators: { order: priorIds, enabled: priorIds } }
    }).modOpts.indicators;
    assert.deepEqual(untouched.order, [
        "dictation", "recording", "ocr", "reminder", "night-light", "dnd", "stay-awake"
    ]);
    assert.deepEqual(untouched.enabled, [
        "dictation", "recording", "ocr", "reminder", "night-light", "dnd", "stay-awake"
    ]);

    const customized = H.merge({
        v: H.VERSION,
        modOpts: {
            indicators: {
                order: ["dnd", "recording", "dictation", "reminder",
                    "night-light", "stay-awake"],
                enabled: ["recording", "dnd"]
            }
        }
    }).modOpts.indicators;
    assert.deepEqual(customized.order, [
        "dnd", "recording", "ocr", "dictation", "reminder", "night-light", "stay-awake"
    ]);
    assert.deepEqual(customized.enabled, ["recording", "dnd"]);

    const explicitlyHidden = H.merge({
        v: H.VERSION,
        modOpts: {
            indicators: {
                order: H.INDICATOR_ACTION_IDS,
                enabled: priorIds
            }
        }
    }).modOpts.indicators;
    assert.deepEqual(explicitlyHidden.enabled, priorIds,
        "an order that already knows OCR makes its absent enabled id intentional");
});

test("schema-22 migrates and validates restart-safe timed toggle state", () => {
    const legacyOn = H.merge({ v: 21, idleInhibited: true });
    assert.equal(legacyOn.idleInhibitMode, "always");
    assert.equal(legacyOn.modOpts.indicators.idleStartup, "remember",
        "an existing persistent opt-in must survive the safer fresh-install policy");

    const timed = H.merge({
        v: 23,
        idleInhibitMode: "30m",
        idleInhibitUntilMs: 2000000000000,
        notifDnd: true,
        notifDndUntilMs: 2000000000123
    });
    assert.equal(timed.idleInhibitMode, "30m");
    assert.equal(timed.idleInhibitUntilMs, 2000000000000);
    assert.equal(timed.notifDndUntilMs, 2000000000123);

    const invalid = H.merge({
        v: 23,
        idleInhibitMode: "2h",
        idleInhibitUntilMs: -1,
        notifDnd: false,
        notifDndUntilMs: 2000000000123
    });
    assert.equal(invalid.idleInhibitMode, "off");
    assert.equal(invalid.idleInhibitUntilMs, 0);
    assert.equal(invalid.notifDndUntilMs, 0,
        "an inactive DND state cannot retain a deadline that later revives it");
});

test("version two normalization preserves usage independently and uniquely", () => {
    const mods = H.merge({
        v: 2,
        mods: {
            left: [{ id: "usage", on: false }, { id: "usage", on: true }],
            center: [{ id: "t3", on: true }],
            right: []
        }
    }).mods;
    assert.deepEqual(mods.left.slice(0, 1), [{ id: "usage", on: false, detail: "auto" }]);
    assert.deepEqual(mods.center.slice(0, 1), [{ id: "t3", on: true, detail: "auto" }]);
    assert.equal([...mods.left, ...mods.center, ...mods.right]
        .filter(m => m.id === "usage").length, 1);
});

test("serialize is stable, versioned, and round-trips through merge", () => {
    const d = H.defaults();
    const text = H.serialize(d);
    assert.match(text, new RegExp(`^\\{\\n  "v": ${H.VERSION},\\n  "wall":`));
    assert.ok(text.endsWith("\n"));
    const reparsed = H.merge(H.parse(text).value);
    assert.equal(H.serialize(reparsed), text);
});

test("selected Notes models and efforts survive a settings round trip", () => {
    const selected = H.merge({
        v: H.VERSION,
        modOpts: {
            notes: {
                titleProvider: "codex",
                codexModel: "gpt-5.6-sol",
                codexEffort: "high",
                claudeModel: "opus",
                claudeEffort: "max"
            }
        }
    });
    const restored = H.merge(H.parse(H.serialize(selected)).value);
    assert.deepEqual(restored.modOpts.notes, selected.modOpts.notes);
});

test("v1 and v2 layouts migrate to v3 detail policies without losing placement", () => {
    for (const v of [1, 2]) {
        const merged = H.merge({
            v,
            mods: {
                left: [{ id: "weather", on: false }],
                center: [{ id: "clock", on: true }],
                right: [{ id: "t3", on: true }, ...(v === 2 ? [{ id: "usage", on: false }] : [])]
            }
        });
        assert.equal(merged.mods.left[0].id, "weather");
        assert.equal(merged.mods.left[0].on, false);
        assert.ok([...merged.mods.left, ...merged.mods.center, ...merged.mods.right]
            .every(module => module.detail === "auto"));
    }
});

test("wallpaper paths and module detail policies are validated", () => {
    assert.equal(H.merge({ wallDir: "/mnt/Wall papers" }).wallDir, "/mnt/Wall papers");
    assert.equal(H.merge({ wallDir: "~/Pictures/Other" }).wallDir, "~/Pictures/Other");
    assert.equal(H.merge({ wallDir: "relative/path" }).wallDir, H.defaults().wallDir);
    assert.equal(H.merge({ wallDir: "~/Pictures/../Secrets" }).wallDir, H.defaults().wallDir);
    const mods = H.normalizeMods({ left: [
        { id: "media", on: true, detail: "prefer" },
        { id: "clock", on: true, detail: "invalid" }
    ]});
    assert.equal(mods.left[0].detail, "prefer");
    assert.equal(mods.left[1].detail, "auto");
});

test("notification settings are validated, clamped, and snapped", () => {
    assert.equal(H.merge({ notifDnd: "yes" }).notifDnd, false);
    assert.equal(H.merge({ notifDnd: false, notifDndUntilMs: 123 }).notifDndUntilMs, 0);
    assert.equal(H.merge({ notifDnd: true, notifDndUntilMs: -1 }).notifDndUntilMs, 0);
    assert.equal(H.merge({ notifQuiet: "sometimes" }).notifQuiet, "off");
    assert.equal(H.merge({ notifQuiet: "nights" }).notifQuiet, "nights");
    assert.equal(H.merge({ notifQuietStart: 1322 }).notifQuietStart, 1320);
    assert.equal(H.merge({ notifQuietStart: -10 }).notifQuietStart, 0);
    assert.equal(H.merge({ notifQuietEnd: 9999 }).notifQuietEnd, 1425);
    assert.equal(H.merge({ notifDuration: 1 }).notifDuration, 4);
    assert.equal(H.merge({ notifDuration: 99 }).notifDuration, 20);
    assert.equal(H.merge({ notifPosition: "middle" }).notifPosition, "top-right");
    assert.equal(H.merge({ notifPosition: "bottom-left" }).notifPosition, "bottom-left");
    assert.equal(H.merge({ notifDensity: "cozy" }).notifDensity, "default");
    assert.equal(H.merge({ notifBodyLines: 7 }).notifBodyLines, 3);
    assert.equal(H.merge({ notifBodyLines: -1 }).notifBodyLines, 0);
});

test("quiet hours resolve presets, wrap midnight, and format as HH:MM", () => {
    assert.equal(H.quietRange("off", 0, 0), null);
    assert.deepEqual(H.quietRange("nights", 600, 700), { start: 1320, end: 420 });
    assert.deepEqual(H.quietRange("custom", 600, 700), { start: 600, end: 700 });

    // Nights: 22:00 – 07:00 wraps midnight.
    assert.equal(H.quietActive("nights", 0, 0, 1320), true);
    assert.equal(H.quietActive("nights", 0, 0, 30), true);
    assert.equal(H.quietActive("nights", 0, 0, 419), true);
    assert.equal(H.quietActive("nights", 0, 0, 420), false);
    assert.equal(H.quietActive("nights", 0, 0, 720), false);
    assert.equal(H.quietActive("off", 0, 1439, 720), false);

    // Custom same-day range, and a degenerate empty range.
    assert.equal(H.quietActive("custom", 540, 1020, 720), true);
    assert.equal(H.quietActive("custom", 540, 1020, 1020), false);
    assert.equal(H.quietActive("custom", 600, 600, 600), false);

    assert.equal(H.formatMinutes(0), "00:00");
    assert.equal(H.formatMinutes(1320), "22:00");
    assert.equal(H.formatMinutes(425), "07:05");
});

test("hue conversion stays pastel and contrasts with accent text", () => {
    function luminance(hex) {
        const channels = [1, 3, 5].map(offset => parseInt(hex.slice(offset, offset + 2), 16) / 255)
            .map(value => value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4);
        return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722;
    }
    const foreground = luminance("#0e0f13");
    for (let hue = 0; hue < 360; hue += 15) {
        const color = H.hueToHex(hue);
        assert.match(color, /^#[0-9a-f]{6}$/);
        assert.ok((luminance(color) + 0.05) / (foreground + 0.05) >= 4.5);
    }
});

test("reset snapshots restore only the covered values", () => {
    const current = { accent: "#ffffff", font: "mono", gap: 20 };
    const snapshot = { accent: "#9ecbeb", font: "oppo" };
    assert.deepEqual(H.restoreSnapshot(current, snapshot), {
        accent: "#9ecbeb", font: "oppo", gap: 20
    });
    assert.deepEqual(snapshot, { accent: "#9ecbeb", font: "oppo" });
});


test("Sub2API connection settings round-trip independently of CLIProxyAPI", () => {
    const settings = H.defaults();
    settings.modOpts.usage.source = "sub2api";
    settings.modOpts.usage.sub2apiUrl = "https://models.test/sub2api";
    settings.modOpts.usage.sub2apiTlsVerify = false;
    settings.modOpts.usage.gemini = false;
    settings.modOpts.usage.cliproxyUrl = "https://existing.test";
    const restored = H.merge(JSON.parse(H.serialize(settings)));
    assert.equal(restored.modOpts.usage.source, "sub2api");
    assert.equal(restored.modOpts.usage.sub2apiUrl, "https://models.test/sub2api");
    assert.equal(restored.modOpts.usage.sub2apiTlsVerify, false);
    assert.equal(restored.modOpts.usage.gemini, false);
    assert.equal(restored.modOpts.usage.cliproxyUrl, "https://existing.test");
    assert.equal(H.defaults().modOpts.usage.source, "direct");
});

test("Bluetooth migrates beside Network without changing existing drawer preferences", () => {
    const old = [
        { id: "usage", on: false }, { id: "network", on: false },
        { id: "overview", on: true }, { id: "sound", on: true },
        { id: "notifications", on: true }, { id: "power", on: false }
    ];
    const migrated = H.normalizeDrawerTabs(old);
    assert.deepEqual(migrated.filter(t => t.id !== "bluetooth"), old);
    assert.deepEqual(migrated[2], { id: "bluetooth", on: true });
    const custom = [{ id: "bluetooth", on: false }, ...old];
    assert.deepEqual(H.normalizeDrawerTabs(custom), custom);
    assert.deepEqual(H.normalizeDrawerTabs(migrated), migrated);
});

test("typed quiet-hour times parse, snap to the step, and reject non-times", () => {
    for (const [text, minutes] of [["7", 420], ["7:30", 450], ["07:30", 450], ["0730", 450],
        ["730", 450], ["19.45", 1185], ["22:07", 1320], ["23:59", 0], [" 6:00 ", 360]])
        assert.equal(H.parseClockMinutes(text, 15), minutes, text);
    assert.equal(H.parseClockMinutes("7:05", 1), 425, "a step of 1 keeps the exact minute");
    for (const text of ["", "abc", "24:00", "7:60", "7:5", "12:345", null])
        assert.equal(H.parseClockMinutes(text, 15), -1, String(text));
    // Every accepted value round-trips through the stored grid.
    for (let m = 0; m < 1440; m += 15)
        assert.equal(H.parseClockMinutes(H.formatMinutes(m), 15), m);
});


test("schema 24 replaces fixed Control Center without changing other widgets", () => {
    const raw = H.defaultMods();
    raw.right = raw.right.filter(m => m.id !== "control");
    raw.left.reverse();
    raw.right.find(m => m.id === "usage").detail = "compact";
    const migrated = H.merge({ v: 23, mods: raw });
    assert.deepEqual(migrated.mods.right.at(-1), { id: "control", on: true, detail: "auto" });
    for (const col of ["left", "center", "right"])
        assert.deepEqual(migrated.mods[col].filter(m => m.id !== "control"), raw[col]);
    const stale = structuredClone(raw);
    stale.left.unshift({ id: "control", on: false, detail: "prefer" });
    assert.deepEqual(H.merge({ v: 3, mods: stale }).mods, migrated.mods);
});

test("Control Center and Model usage placement and visibility survive reload", () => {
    const L = load("LayoutHelpers.js");
    const E = load("WidgetEditor.js");
    const C = load("WidgetCatalog.js");
    const settings = H.defaults();
    for (const id of ["control", "usage"]) {
        settings.mods = L.moveWidget(settings.mods, "right", id, "left", 0).mods;
        settings.mods.left[0].on = false;
        const restored = H.merge(JSON.parse(H.serialize(settings)));
        assert.deepEqual(restored.mods, settings.mods);
        const entries = E.catalog(restored.mods, [], C.WIDGETS);
        assert.ok(E.search(entries, C.widgetName(id), "available").some(e => e.key === id));
        assert.ok(!E.sectionEntries(entries, "left").some(e => e.key === id));
        settings.mods.left[0].on = true;
        const added = H.merge(JSON.parse(H.serialize(settings)));
        assert.ok(E.sectionEntries(E.catalog(added.mods, [], C.WIDGETS), "left").some(e => e.key === id));
    }
});

test("Provider CLIs is the default without replacing configured or current source choices", () => {
    assert.equal(H.defaults().modOpts.usage.source, "direct");
    for (const usage of [{}, { source: "cliproxy" }, { source: "cliproxy", cliproxyUrl: "" }]) {
        const raw = { v: 23, modOpts: { usage } };
        const before = structuredClone(raw);
        const migrated = H.merge(raw);
        assert.equal(migrated.modOpts.usage.source, "direct");
        assert.deepEqual(raw, before);
        assert.deepEqual(H.merge(JSON.parse(H.serialize(migrated))), migrated);
    }
    for (const usage of [
        { source: "cliproxy", cliproxyUrl: "https://proxy.test/management.html" },
        { source: "sub2api", sub2apiUrl: "https://models.test" },
        { source: "direct" }
    ]) {
        assert.equal(H.merge({ v: 23, modOpts: { usage } }).modOpts.usage.source, usage.source);
    }
    assert.equal(H.merge({ v: 24, modOpts: { usage: { source: "cliproxy", cliproxyUrl: "" } } })
        .modOpts.usage.source, "cliproxy");
});
