// Pure rules for the NerdOS Assistant (docs/assistant.md): where the
// character stands, which side of it the box opens on, which agent answers,
// and how a turn snapshot from the service reads on screen. Shared by QML and
// Node tests, so no Qt APIs.

// Space kept between the character, its box and the edges of the output.
var EDGE = 12;
var GAP = 10;
// The box opens below unless it would get less than this and above has more.
var MIN_BELOW = 300;
// A press that moves less than this is a click, not a drag.
var DRAG_THRESHOLD = 4;
// Super+I held this long is push-to-talk; a shorter press is a tap.
var HOLD_MS = 280;

var AGENT_IDS = ["claude", "codex"];
var AGENT_LABELS = { claude: "Claude Code", codex: "Codex" };
// Brand marks bundled with the shell (BrandIcons.qml).
var AGENT_ICONS = { claude: "claude", codex: "openai" };

// The approval card's glyph for each kind of request.
var APPROVAL_GLYPHS = { command: "terminal", edit: "edit", apply: "deployed_code_update", other: "security" };

var ACTIVE_STATUSES = ["running", "waiting"];
var FINISHED_STATUSES = ["completed", "stopped", "failed"];

function clamp(value, low, high) {
    return Math.max(low, Math.min(high, value));
}

// Where the character stands on an output of width × height. A saved place
// of -1 is the default: the top-right corner, below the bar's reserve. A saved
// place from a larger output is pulled back inside this one.
function placement(saved, output, size, topReserve) {
    var width = Math.max(size, output.width || 0);
    var height = Math.max(size, output.height || 0);
    var reserve = Math.max(0, topReserve || 0);
    var x = typeof saved.x === "number" && saved.x >= 0 ? saved.x : width - size - EDGE * 2;
    var y = typeof saved.y === "number" && saved.y >= 0 ? saved.y : reserve + EDGE * 2;
    return {
        x: Math.round(clamp(x, 0, width - size)),
        y: Math.round(clamp(y, 0, height - size))
    };
}

// The box under (or over) the character. It flips above only when below is
// cramped and above is roomier; `room` is the height it may grow to, which
// the reply card scrolls within.
function dockPlacement(bubble, size, output, dockWidth, topReserve) {
    var width = output.width || 0;
    var height = output.height || 0;
    var reserve = Math.max(0, topReserve || 0);
    var w = Math.min(dockWidth, Math.max(0, width - EDGE * 2));
    var below = height - (bubble.y + size + GAP) - EDGE;
    var aboveRoom = bubble.y - GAP - Math.max(EDGE, reserve);
    var above = below < MIN_BELOW && aboveRoom > below;
    var x = clamp(bubble.x + size / 2 - w / 2, EDGE, Math.max(EDGE, width - w - EDGE));
    return {
        x: Math.round(x),
        width: Math.round(w),
        above: above,
        room: Math.max(0, Math.round(above ? aboveRoom : below)),
        // The edge the box grows from: its top when below, its bottom when above.
        anchorY: Math.round(above ? bubble.y - GAP : bubble.y + size + GAP)
    };
}

// The output under a point in global (compositor) coordinates, for a drag
// that ended on another display. Returns -1 when the point is on none.
function outputAt(outputs, x, y) {
    for (var i = 0; i < outputs.length; i++) {
        var o = outputs[i];
        if (x >= o.x && x < o.x + o.width && y >= o.y && y < o.y + o.height)
            return i;
    }
    return -1;
}

function dragged(dx, dy) {
    return Math.abs(dx) > DRAG_THRESHOLD || Math.abs(dy) > DRAG_THRESHOLD;
}

// "auto" follows the `nerd agent` default when it is one of ours and
// installed, then Claude Code, then Codex. An explicit choice that is not
// installed is still returned: the service reports it as missing, which
// tells the person what to install.
function resolveAgent(setting, agents, preferred) {
    var installed = function(id) {
        return !!(agents && agents[id] && agents[id].available);
    };
    if (setting === "claude" || setting === "codex")
        return setting;
    var ready = function(id) {
        return installed(id) && agents[id].auth === "ready";
    };
    if (AGENT_IDS.indexOf(preferred) !== -1 && ready(preferred))
        return preferred;
    for (var j = 0; j < AGENT_IDS.length; j++) {
        if (ready(AGENT_IDS[j]))
            return AGENT_IDS[j];
    }
    if (AGENT_IDS.indexOf(preferred) !== -1 && installed(preferred))
        return preferred;
    for (var i = 0; i < AGENT_IDS.length; i++) {
        if (installed(AGENT_IDS[i]))
            return AGENT_IDS[i];
    }
    return "claude";
}

// The agent chip cycles through the installed agents only.
function nextAgent(current, agents) {
    var installed = AGENT_IDS.filter(function(id) {
        return !!(agents && agents[id] && agents[id].available);
    });
    if (installed.length === 0)
        return current;
    var index = installed.indexOf(current);
    return installed[(index + 1) % installed.length];
}

function anyAgent(agents) {
    return AGENT_IDS.some(function(id) {
        return !!(agents && agents[id] && agents[id].available);
    });
}

// The model sent with a turn; "default" leaves it to the agent's own config.
function modelFor(agent, claudeModel, codexModel) {
    var value = agent === "codex" ? codexModel : claudeModel;
    return value && value !== "default" ? value : "";
}

function active(turn) {
    return !!turn && ACTIVE_STATUSES.indexOf(turn.status) !== -1;
}

function finished(turn) {
    return !!turn && FINISHED_STATUSES.indexOf(turn.status) !== -1;
}

// What the character's face and ring show, in priority order.
function mood(state) {
    if (!state.connected)
        return "asleep";
    if (state.listening)
        return "listening";
    if (state.waiting)
        return "alert";
    if (state.busy || state.transcribing)
        return "thinking";
    if (state.dragging || state.speaking || state.celebrating)
        return "happy";
    if (state.failed)
        return "sorry";
    if (state.composing)
        return "attentive";
    return "idle";
}

// "8 s", "1 min 05 s", "12 min": the worker pill's elapsed time.
function elapsedLabel(ms) {
    var seconds = Math.max(0, Math.floor((ms || 0) / 1000));
    if (seconds < 60)
        return seconds + " s";
    var minutes = Math.floor(seconds / 60);
    if (minutes >= 10)
        return minutes + " min";
    var rest = seconds % 60;
    return minutes + " min " + (rest < 10 ? "0" : "") + rest + " s";
}

// A ~/-relative path reads better in a narrow card than the full home path.
function displayPath(path, home) {
    var value = String(path || "");
    if (home && (value === home || value.indexOf(home + "/") === 0))
        return "~" + value.slice(home.length);
    return value;
}

// Closure changes from `nix store diff-closures` as rows for the review card:
// "obsidian: ∅ → 1.9.12, +148.2 MiB" becomes {name, change, kind}.
function closureChanges(text, limit) {
    var rows = [];
    String(text || "").split("\n").forEach(function(line) {
        var match = /^\s*([^:]+):\s*(.+?)\s*$/.exec(line);
        if (!match)
            return;
        var change = match[2];
        var kind = /∅ →/.test(change) ? "added" : /→ ∅/.test(change) ? "removed" : "changed";
        rows.push({ name: match[1].trim(), change: change, kind: kind });
    });
    var max = limit || 8;
    return { rows: rows.slice(0, max), more: Math.max(0, rows.length - max) };
}

// Turns a service failure into the one action that would fix it.
function errorAction(kind, agent) {
    switch (kind) {
    case "auth": return { label: "Sign in", auth: true };
    case "missing": return { label: "Settings", page: "assistant" };
    case "service": return { label: "Start the assistant", unit: "nerdos-assistant.service" };
    default: return null;
    }
}

// A finished turn's reply as it is copied: the text, without the trailing
// whitespace Markdown leaves behind.
function copyText(turn) {
    return String(turn && turn.text || "").replace(/\s+$/, "");
}

var exported = {
    EDGE: EDGE,
    GAP: GAP,
    MIN_BELOW: MIN_BELOW,
    DRAG_THRESHOLD: DRAG_THRESHOLD,
    HOLD_MS: HOLD_MS,
    AGENT_IDS: AGENT_IDS,
    AGENT_LABELS: AGENT_LABELS,
    AGENT_ICONS: AGENT_ICONS,
    APPROVAL_GLYPHS: APPROVAL_GLYPHS,
    clamp: clamp,
    placement: placement,
    dockPlacement: dockPlacement,
    outputAt: outputAt,
    dragged: dragged,
    resolveAgent: resolveAgent,
    nextAgent: nextAgent,
    anyAgent: anyAgent,
    modelFor: modelFor,
    active: active,
    finished: finished,
    mood: mood,
    elapsedLabel: elapsedLabel,
    displayPath: displayPath,
    closureChanges: closureChanges,
    errorAction: errorAction,
    copyText: copyText
};

if (typeof module !== "undefined" && module.exports)
    module.exports = exported;
