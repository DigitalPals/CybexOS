// Owner-scoped holds. Plain JS state changes immediately; QML publication is
// coalesced until bindings/delegate destruction have finished for this turn.
// Never read a QML property from set()/isHeld(): callers can run inside a
// model binding's dependency collection during delegate teardown.
function create(schedule, publish) {
    var owners = new Map();
    var published = Object.create(null);
    var queued = false;
    var disposed = false;

    function flush() {
        queued = false;
        if (disposed) return;
        var next = Object.create(null);
        owners.forEach(function(key) { next[key] = true; });
        var keys = Object.keys(next);
        if (keys.length === Object.keys(published).length
                && keys.every(function(key) { return published[key] === true; })) return;
        published = next;
        publish(next);
    }

    return {
        set: function(owner, key, held) {
            if (disposed || owner === null || owner === undefined || typeof key !== "string"
                    || key.length === 0 || key.length > 4096) return;
            if (held ? owners.get(owner) === key : !owners.has(owner)) return;
            if (held) owners.set(owner, key);
            else owners.delete(owner);
            if (!queued) {
                queued = true;
                schedule(flush);
            }
        },
        isHeld: function(key) {
            var held = false;
            owners.forEach(function(source) { if (source === key) held = true; });
            return held;
        },
        dispose: function() {
            disposed = true;
            owners.clear();
        }
    };
}

if (typeof module !== "undefined" && module.exports)
    module.exports = { create: create };
