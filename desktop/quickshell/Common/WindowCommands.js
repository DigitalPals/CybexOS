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

// A renamed numbered workspace retains its positive ID. Preserve its native
// name separately from display labels; ID sign alone cannot select an API.
function workspaceKind(workspace) {
    if (workspace === null || workspace === undefined)
        return "special";
    var object = typeof workspace === "object";
    var id = object ? workspace.id : workspace;
    var name = object ? String(workspace.workspaceName !== undefined
        ? workspace.workspaceName : workspace.name || "") : "";
    if ((object && workspace.kind === "special") || /^special(?::|$)/.test(name)
            || id === 0 || (id < 0 && id >= -99))
        return "special";
    if (object && workspace.kind === "named")
        return "named";
    if (object && workspace.kind === "numbered")
        return "numbered";
    return name !== "" && name !== String(id) ? "named" : id > 0 ? "numbered" : "named";
}

// Special workspaces are overlays, never a destination here. Named selectors
// are quoted as Lua data, including quotes and backslashes in native names.
function workspaceArgument(workspace) {
    var kind = workspaceKind(workspace);
    if (kind === "special")
        return "";
    if (kind === "numbered")
        return regularWorkspaceId(workspace);
    var name = typeof workspace === "object" ? String(workspace.workspaceName !== undefined
        ? workspace.workspaceName : workspace.name || "") : "";
    return name !== "" ? luaString("name:" + name) : "";
}

function focusWindow(address) {
    var selector = windowSelector(address);
    return selector === "" ? "" : "hl.dsp.focus({ window = " + selector + " })";
}

function closeWindow(address) {
    var selector = windowSelector(address);
    return selector === "" ? "" : "hl.dsp.window.close({ window = " + selector + " })";
}

function maximizeWindow(address) {
    var selector = windowSelector(address);
    return selector === "" ? "" : 'hl.dsp.window.fullscreen({ mode = "maximized", action = "toggle", window = '
        + selector + ' })';
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

// The compositor owns workspace IDs and minimized-window restoration. These
// builders expose a fixed operation list and quote data as Lua string bytes,
// never executable source. No builder passes through an operation name.
function luaString(value) {
    if (typeof value !== "string" || value.length > 256 || /[\x00-\x1f\x7f]/.test(value))
        return "";
    return '"' + value.replace(/\\/g, "\\\\").replace(/"/g, '\\"') + '"';
}

function regularWorkspaceId(value) {
    if (workspaceKind(value) !== "numbered")
        return "";
    var id = value && typeof value === "object" ? value.id : value;
    return typeof id === "number" && Number.isInteger(id) && id > 0 && id < 2147483647 ? String(id) : "";
}

function desktopFocus(workspace) {
    var id = regularWorkspaceId(workspace);
    return id ? 'require("workspaces").focus_id(' + id + ')' : "";
}

function desktopMove(address, workspace) {
    var key = bareAddress(address), id = regularWorkspaceId(workspace);
    return key && id ? 'require("workspaces").move_id("0x' + key + '", ' + id + ')' : "";
}

function desktopActivate(address) {
    var key = bareAddress(address);
    return key ? 'require("workspaces").activate("0x' + key + '")' : "";
}

function desktopMinimize(address) {
    var key = bareAddress(address);
    return key ? 'require("workspaces").minimize("0x' + key + '")' : "";
}

function desktopNew(monitor) {
    var name = luaString(monitor);
    return name ? 'require("workspaces").new_workspace(' + name + ')' : "";
}

function desktopNewAndMove(address, monitor) {
    var key = bareAddress(address), name = luaString(monitor);
    // Allocation and move are one compositor operation: there is no guessed
    // ID and no file-watcher race between creating a tile and dropping on it.
    return key && name ? 'require("workspaces").move_id("0x' + key
        + '", require("workspaces").new_workspace(' + name + '))' : "";
}

function desktopNext(direction, monitor) {
    var name = luaString(monitor);
    return (direction === 1 || direction === -1) && name
        ? 'require("workspaces").next(' + direction + ', ' + name + ')' : "";
}

function desktopLayout(workspace, layout) {
    var id = regularWorkspaceId(workspace);
    return id && ["default", "dwindle", "scrolling", "floating"].indexOf(layout) !== -1
        ? 'require("workspaces").set_layout(' + id + ', "' + layout + '")' : "";
}

function desktopCycleLayout(workspace) {
    var id = regularWorkspaceId(workspace);
    return id ? 'require("workspaces").cycle_layout(' + id + ')' : "";
}

function desktopMode(mode) {
    return ["shared", "per-monitor"].indexOf(mode) !== -1
        ? 'require("workspaces").set_mode("' + mode + '")' : "";
}

function desktopDefaultLayout(layout) {
    return ["dwindle", "scrolling", "floating"].indexOf(layout) !== -1
        ? 'require("workspaces").set_default_layout("' + layout + '")' : "";
}

function desktopTitlebars(enabled) {
    return typeof enabled === "boolean"
        ? 'require("workspaces").set_titlebars_enabled(' + (enabled ? "true" : "false") + ')' : "";
}

var exported = {
    bareAddress: bareAddress,
    windowSelector: windowSelector,
    workspaceKind: workspaceKind,
    workspaceArgument: workspaceArgument,
    focusWindow: focusWindow,
    closeWindow: closeWindow,
    maximizeWindow: maximizeWindow,
    moveWindow: moveWindow,
    focusWorkspace: focusWorkspace,
    luaString: luaString,
    regularWorkspaceId: regularWorkspaceId,
    desktopFocus: desktopFocus,
    desktopMove: desktopMove,
    desktopActivate: desktopActivate,
    desktopMinimize: desktopMinimize,
    desktopNew: desktopNew,
    desktopNewAndMove: desktopNewAndMove,
    desktopNext: desktopNext,
    desktopLayout: desktopLayout,
    desktopCycleLayout: desktopCycleLayout,
    desktopMode: desktopMode,
    desktopDefaultLayout: desktopDefaultLayout,
    desktopTitlebars: desktopTitlebars
};

if (typeof module !== "undefined" && module.exports)
    module.exports = exported;
