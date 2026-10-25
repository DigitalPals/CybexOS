.pragma library
.import "KeybindHelpers.js" as KeybindHelpers

// Pure recorder logic. Numeric constants are Qt's public Key/KeyboardModifier
// values, so a draft and a recording can be tested without a running shell.
var MODIFIERS = ["SUPER", "CTRL", "ALT", "SHIFT"];
function normalize(value) {
    if (typeof value !== "string" || value.length > 128)
        return "";
    var parts = value.split("+").map(function(part) { return part.trim(); });
    var key = parts.pop();
    if (!key || MODIFIERS.indexOf(key.toUpperCase()) >= 0
            || !/^(?:[A-Za-z0-9_]+|code:[0-9]+|mouse:[0-9]+)$/i.test(key)
            || parts.some(function(part) { return MODIFIERS.indexOf(part.toUpperCase()) < 0; }))
        return "";
    var mods = parts.map(function(part) { return part.toUpperCase(); });
    if (key.length === 1)
        key = key.toUpperCase();
    else if (/^(code|mouse):/i.test(key))
        key = key.toLowerCase();
    return MODIFIERS.filter(function(mod) { return mods.indexOf(mod) >= 0; }).concat([key]).join(" + ");
}
function same(a, b) {
    var left = normalize(a);
    return left !== "" && left.toLowerCase() === normalize(b).toLowerCase();
}
var NAMED = {
    0x01000000: "Escape", 0x01000001: "Tab", 0x01000002: "Tab",
    0x01000003: "BackSpace", 0x01000004: "Return", 0x01000005: "KP_Enter",
    0x01000006: "Insert", 0x01000007: "Delete", 0x01000008: "Pause",
    0x01000009: "Print", 0x0100000b: "Clear", 0x01000010: "Home",
    0x01000011: "End", 0x01000012: "Left", 0x01000013: "Up",
    0x01000014: "Right", 0x01000015: "Down", 0x01000016: "Prior",
    0x01000017: "Next", 0x01000055: "Menu",
    0x01000070: "XF86AudioLowerVolume", 0x01000071: "XF86AudioMute",
    0x01000072: "XF86AudioRaiseVolume", 0x01000080: "XF86AudioPlay",
    0x01000081: "XF86AudioStop", 0x01000082: "XF86AudioPrev", 0x01000083: "XF86AudioNext",
    0x01000085: "XF86AudioPause", 0x01000086: "XF86AudioPlay",
    0x010000b2: "XF86MonBrightnessUp", 0x010000b3: "XF86MonBrightnessDown",
    0x010000b4: "XF86KbdLightOnOff", 0x010000b7: "XF86PowerOff",
    0x01000108: "XF86Hibernate", 0x0100010c: "XF86Suspend",
    0x01000113: "XF86AudioMicMute", 0x01020004: "XF86Sleep"
};
var PUNCTUATION = {
    " ": "space", "!": "exclam", '"': "quotedbl", "#": "numbersign", "$": "dollar",
    "%": "percent", "&": "ampersand", "'": "apostrophe", "(": "parenleft", ")": "parenright",
    "*": "asterisk", "+": "plus", ",": "comma", "-": "minus", ".": "period", "/": "slash",
    ":": "colon", ";": "semicolon", "<": "less", "=": "equal", ">": "greater", "?": "question",
    "@": "at", "[": "bracketleft", "\\": "backslash", "]": "bracketright", "^": "asciicircum",
    "_": "underscore", "`": "grave", "{": "braceleft", "|": "bar", "}": "braceright", "~": "asciitilde"
};
// keymap: optional { "<xkb keycode>": "<level-1 keysym>" } of the active layout
// (Keybindings.keymap). Hyprland matches the unmodified keysym, so a code:N
// fallback is translated to it whenever the layout is known.
function fromKeyEvent(event, keymap) {
    event = event || {};
    var key = Number(event.key), mask = Number(event.modifiers) || 0;
    var mods = [];
    [[0x10000000, "SUPER"], [0x04000000, "CTRL"], [0x08000000, "ALT"], [0x02000000, "SHIFT"]]
        .forEach(function(pair) { if (mask & pair[0]) mods.push(pair[1]); });
    var lone = (key >= 0x01000020 && key <= 0x01000026)
        || (key >= 0x01000053 && key <= 0x01000054) || key === 0x01001103;
    if (lone)
        return { keys: mods.join(" + "), complete: false };
    var scan = Number(event.nativeScanCode);
    var code = Number.isInteger(scan) && scan >= 8 && scan <= 0xffffffff ? "code:" + scan : "";
    var name = "";
    var keypad = !!(mask & 0x20000000);
    if (keypad) {
        if (key >= 48 && key <= 57)
            name = "KP_" + String.fromCharCode(key);
        else {
            var pad = { 43: "KP_Add", 45: "KP_Subtract", 42: "KP_Multiply", 47: "KP_Divide",
                46: "KP_Decimal", 44: "KP_Separator", 61: "KP_Equal", 0x01000004: "KP_Enter",
                0x01000005: "KP_Enter", 0x01000010: "KP_Home", 0x01000011: "KP_End",
                0x01000012: "KP_Left", 0x01000013: "KP_Up", 0x01000014: "KP_Right",
                0x01000015: "KP_Down", 0x01000016: "KP_Prior", 0x01000017: "KP_Next",
                0x01000006: "KP_Insert", 0x01000007: "KP_Delete", 0x0100000b: "KP_Begin" };
            name = pad[key] || code;
        }
    } else if (key >= 0x01000030 && key <= 0x01000052) {
        name = "F" + (key - 0x01000030 + 1);
    } else if (NAMED[key]) {
        name = NAMED[key];
    } else if (key >= 65 && key <= 90) {
        name = String.fromCharCode(key);
    } else if (key === 32) {
        name = "space";
    } else if ((mask & 0x02000000) && code) {
        // Qt reports the shifted symbol, not the level-zero keysym. Guessing
        // US punctuation here breaks AZERTY and other number rows. Both Qt
        // Wayland and Hyprland code:N use xkb keycodes (evdev + 8), unchanged.
        name = code;
    } else if (key >= 48 && key <= 57) {
        name = String.fromCharCode(key);
    } else {
        name = PUNCTUATION[String.fromCharCode(key)] || code;
    }
    // AltGr is a layout level selector, not one of our four bind modifiers.
    // It cannot be represented by the four-modifier contract. Let the user
    // release it and record again instead of saving a combination that fails.
    if (mask & 0x40000000)
        return { keys: mods.join(" + "), complete: false };
    if (keymap && /^code:[0-9]+$/.test(name)) {
        var base = Object.prototype.hasOwnProperty.call(keymap, name.slice(5)) ? keymap[name.slice(5)] : "";
        if (typeof base === "string" && /^[A-Za-z0-9_]+$/.test(base))
            name = base;
    }
    var keys = name ? normalize(mods.concat([name]).join(" + ")) : "";
    return { keys: keys, complete: keys !== "" };
}
function isReserved(keys) {
    var normal = normalize(keys);
    if (!normal || /mouse/i.test(normal))
        return true;
    var parts = normal.split(" + "), key = parts.pop().toLowerCase();
    if (parts.length === 0 && !/^f[1-9][0-9]*$|^xf86/.test(key))
        return true;
    if (/^(shift_l|shift_r|control_l|control_r|alt_l|alt_r|super_l|super_r|caps_lock|num_lock|scroll_lock)$/.test(key))
        return true;
    // Keep VT recovery, SysRq and secure attention out of the recorder. The
    // resolver separately protects the lock/exit/settings/shortcuts defaults.
    return key === "sys_req" || (parts.indexOf("CTRL") >= 0 && parts.indexOf("ALT") >= 0
        && (/^f(?:[1-9]|1[0-2])$/.test(key) || key === "delete" || key === "backspace"))
        || /^(xf86poweroff|xf86sleep|xf86suspend|xf86hibernate)$/.test(key);
}
function display(keys) {
    var normal = normalize(keys);
    if (!normal)
        return [];
    var parts = normal.split(" + "), key = parts.pop();
    var names = { SUPER: "Super", CTRL: "Ctrl", ALT: "Alt", SHIFT: "Shift" };
    return parts.map(function(mod) { return names[mod]; }).concat([KeybindHelpers.keyName(key)]);
}
var exported = { normalize: normalize, same: same, fromKeyEvent: fromKeyEvent,
    isReserved: isReserved, display: display };
if (typeof module !== "undefined" && module.exports)
    module.exports = exported;
