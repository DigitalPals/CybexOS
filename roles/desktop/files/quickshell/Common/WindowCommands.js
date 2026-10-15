// Hyprland dispatch strings for the window overview and the dock, built only
// from validated parts. Under the Lua configuration every dispatch is a Lua
// expression, so a window title or workspace name spliced in unchecked would
// be code. Each builder returns "" for input it will not quote, and callers
// skip the dispatch then.
//
// Callers must also check that the window still exists right before they
// dispatch: Hyprland falls back to the *active* window when a window selector
// does not resolve, so closing or moving a window that has just gone away
// would act on whatever has focus instead.
//
// Keep this file free of Qt APIs; tests/quickshell/window-commands.test.cjs
// holds it to that.

// Quickshell reports HyprlandToplevel.address as bare hex, while Hyprland's
// `address:` selector wants the 0x prefix. Accept either form.
function bareAddress(value) {
    var text = String(value === undefined || value === null ? "" : value).trim();
    if (/^0x/i.test(text))
        text = text.slice(2);
    return /^[0-9a-fA-F]{1,16}$/.test(text) ? text.toLowerCase() : "";
}

function windowSelector(address) {
    var bare = bareAddress(address);
    return bare === "" ? "" : "\"address:0x" + bare + "\"";
}

// A workspace argument: a positive id as a Lua number, or a named regular
// workspace as a quoted `name:` selector. Special workspaces (the scratchpad)
// are toggled overlays, never a destination here.
function workspaceArgument(workspace) {
    if (workspace === null || workspace === undefined)
        return "";
    var id = typeof workspace === "object" ? Number(workspace.id) : Number(workspace);
    if (Number.isInteger(id) && id > 0 && id < 100000)
        return String(id);
    var name = typeof workspace === "object" ? String(workspace.name || "") : "";
    if (/^special(?::|$)/.test(name) || !/^[A-Za-z0-9][A-Za-z0-9 _.-]{0,63}$/.test(name))
        return "";
    return "\"name:" + name + "\"";
}

function focusWindow(address) {
    var selector = windowSelector(address);
    return selector === "" ? "" : "hl.dsp.focus({ window = " + selector + " })";
}

function closeWindow(address) {
    var selector = windowSelector(address);
    return selector === "" ? "" : "hl.dsp.window.close({ window = " + selector + " })";
}

// `follow = false` is the old movetoworkspacesilent: the window moves and the
// person stays where they are, which is what dragging a thumbnail means.
function moveWindow(address, workspace) {
    var selector = windowSelector(address);
    var target = workspaceArgument(workspace);
    if (selector === "" || target === "")
        return "";
    return "hl.dsp.window.move({ workspace = " + target + ", follow = false, window = "
        + selector + " })";
}

function focusWorkspace(workspace) {
    var target = workspaceArgument(workspace);
    return target === "" ? "" : "hl.dsp.focus({ workspace = " + target + " })";
}

var exported = {
    bareAddress: bareAddress,
    windowSelector: windowSelector,
    workspaceArgument: workspaceArgument,
    focusWindow: focusWindow,
    closeWindow: closeWindow,
    moveWindow: moveWindow,
    focusWorkspace: focusWorkspace
};

if (typeof module !== "undefined" && module.exports)
    module.exports = exported;
