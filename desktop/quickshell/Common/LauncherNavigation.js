// Pure launcher selection math shared by QML and Node tests. Keeping the
// empty-list behavior here avoids sprinkling modulo and clamp edge cases
// through the keyboard handler.

function countFor(value) {
    return Math.max(0, Math.floor(Number(value) || 0));
}

function clampSelection(selected, count) {
    var length = countFor(count);
    if (length === 0)
        return 0;
    return Math.max(0, Math.min(length - 1, Math.floor(Number(selected) || 0)));
}

function wrapSelection(selected, count, offset) {
    var length = countFor(count);
    if (length === 0)
        return 0;
    var current = clampSelection(selected, length);
    var next = current + Math.floor(Number(offset) || 0);
    return ((next % length) + length) % length;
}

function pageSelection(selected, count, offset) {
    var length = countFor(count);
    if (length === 0)
        return 0;
    var current = clampSelection(selected, length);
    return clampSelection(current + Math.floor(Number(offset) || 0), length);
}

var exported = {
    clampSelection: clampSelection,
    wrapSelection: wrapSelection,
    pageSelection: pageSelection
};

if (typeof module !== "undefined" && module.exports)
    module.exports = exported;
