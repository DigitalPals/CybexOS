// Game mode's runtime state as the game-mode helper writes it to
// $XDG_RUNTIME_DIR/nerdos/game-mode.json. The file names the compositor
// instance it belongs to: lingering keeps the runtime directory across
// logins, and a file from an earlier login must never read as on.

var MAX_BYTES = 4096;

function isActive(text, instance) {
    if (typeof text !== "string" || text.length > MAX_BYTES
            || typeof instance !== "string" || instance === "")
        return false;
    try {
        var state = JSON.parse(text);
        return state !== null && typeof state === "object" && !Array.isArray(state)
            && state.active === true && state.instance === instance;
    } catch (error) {
        return false;
    }
}

var exported = {
    MAX_BYTES: MAX_BYTES,
    isActive: isActive
};

if (typeof module !== "undefined" && module.exports)
    module.exports = exported;
