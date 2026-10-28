// The header's Changes chip and its review (2026-10 Settings redesign): every
// edit that waits for Apply, on whichever page it was made. Most settings
// apply as they change and never appear here. Each item names its apply
// `group`, the unit one Apply settles; `system` groups build a deployment
// that needs an administrator and a restart.
//
// Kept free of Qt APIs so settings-changes.test.cjs runs it under Node.

var TOUCHPAD = {
    tap: "Tap to click",
    naturalScroll: "Natural scrolling",
    workspaceSwipe: "Swipe between workspaces",
    sensitivity: "Pointer sensitivity"
};
var SWITCH = {
    "": "None",
    "grp:alt_shift_toggle": "Alt + Shift",
    "grp:ctrl_shift_toggle": "Ctrl + Shift",
    "grp:caps_toggle": "Caps Lock"
};
// One deployment at a time: the updater keeps a regional change and a
// cleanup policy in separate previews, as it does software changes.
var SYSTEM_ORDER = ["region", "retention"];
var LIVE_ORDER = ["touchpad", "keyboard", "shortcuts"];

function value(v) {
    if (typeof v === "boolean")
        return v ? "On" : "Off";
    if (typeof v === "number")
        return (Math.round(v * 10) / 10).toFixed(1);
    return String(v === undefined || v === null ? "" : v);
}

function touchpadItems(original, draft, changes) {
    return Object.keys(changes || {}).filter(function(key) { return key in TOUCHPAD; }).map(function(key) {
        return { id: "touchpad." + key, group: "touchpad", page: "touchpad", tab: "", pageLabel: "Touchpad",
            label: TOUCHPAD[key], before: value(original[key]), after: value(draft[key]), system: false };
    });
}

function layouts(list) {
    return (list || []).map(function(entry) {
        return entry.variant ? entry.layout + " (" + entry.variant + ")" : entry.layout;
    }).join(", ");
}

function keyboardItems(original, draft, changes) {
    var out = [];
    if (changes && "layouts" in changes)
        out.push({ id: "keyboard.layouts", group: "keyboard", page: "keyboard", tab: "layouts",
            pageLabel: "Keyboard", label: "Layouts", before: layouts(original.layouts),
            after: layouts(draft.layouts), system: false });
    if (changes && "shortcut" in changes)
        out.push({ id: "keyboard.shortcut", group: "keyboard", page: "keyboard", tab: "layouts",
            pageLabel: "Keyboard", label: "Switch layouts",
            before: SWITCH[original.shortcut] || value(original.shortcut),
            after: SWITCH[draft.shortcut] || value(draft.shortcut), system: false });
    return out;
}

function shortcutItems(changes) {
    var list = changes || [];
    if (list.length === 0)
        return [];
    var names = list.map(function(change) { return change.label; });
    var shown = names.slice(0, 3).join(", ") + (names.length > 3 ? " and " + (names.length - 3) + " more" : "");
    return [{ id: "shortcuts", group: "shortcuts", page: "keyboard", tab: "shortcuts", pageLabel: "Keyboard",
        label: list.length === 1 ? "Shortcut" : list.length + " shortcuts", before: "", after: shown, system: false }];
}

function regionItems(region, localeName) {
    var name = localeName || function(code) { return code; };
    var out = [];
    if (region.timezone !== region.originalTimezone)
        out.push({ id: "region.timezone", group: "region", page: "region", tab: "",
            pageLabel: "Region & language", label: "Timezone",
            before: region.originalTimezone.replace(/_/g, " "), after: region.timezone.replace(/_/g, " "), system: true });
    if (region.locale !== region.originalLocale)
        out.push({ id: "region.locale", group: "region", page: "region", tab: "",
            pageLabel: "Region & language", label: "Language and region",
            before: name(region.originalLocale), after: name(region.locale), system: true });
    return out;
}

function retentionSummary(policy) {
    return policy.keepConfirmed + " deployments · " + policy.keepDays + " days · weekly cleanup "
        + (policy.automatic ? "on" : "off");
}

function retentionItems(draft, baseline, dirty) {
    if (!dirty)
        return [];
    return [{ id: "retention", group: "retention", page: "backup", tab: "recovery",
        pageLabel: "Backup & storage", label: "Recovery point cleanup",
        before: retentionSummary(baseline), after: retentionSummary(draft), system: true }];
}

function pagesOf(items) {
    var pages = [];
    (items || []).forEach(function(item) {
        if (pages.indexOf(item.page) === -1)
            pages.push(item.page);
    });
    return pages;
}

// What one Apply does: every live group, in a fixed order, then at most one
// system group. A second system group waits for the first deployment to be
// settled; so do all of them while another deployment is in flight.
function plan(items, systemBusy) {
    var groups = [];
    (items || []).forEach(function(item) {
        if (groups.indexOf(item.group) === -1)
            groups.push(item.group);
    });
    var live = LIVE_ORDER.filter(function(group) { return groups.indexOf(group) !== -1; });
    var system = SYSTEM_ORDER.filter(function(group) { return groups.indexOf(group) !== -1; });
    var now = systemBusy ? "" : (system[0] || "");
    return { live: live, system: now, waiting: system.filter(function(group) { return group !== now; }),
        steps: live.concat(now ? [now] : []) };
}

var exported = {
    TOUCHPAD: TOUCHPAD,
    SWITCH: SWITCH,
    touchpadItems: touchpadItems,
    keyboardItems: keyboardItems,
    shortcutItems: shortcutItems,
    regionItems: regionItems,
    retentionItems: retentionItems,
    retentionSummary: retentionSummary,
    pagesOf: pagesOf,
    plan: plan
};

if (typeof module !== "undefined" && module.exports)
    module.exports = exported;
