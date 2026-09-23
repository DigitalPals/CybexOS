// A plugin's declared settings, turned into rows the settings dialog can draw.
//
// Omarchy's manifest schema 1 has no settings format of its own. Plugins
// declare one as `barWidget.schema`: an array of { key, type, label,
// description, defaultValue, ... } entries. The types understood here are
//
//   boolean                          a switch
//   enum         options             one choice from a short list
//   multiselect  options             any subset of a short list
//   integer      min, max, step      a slider when bounded, else a number field
//   number       min, max, step      the same, without rounding to integers
//   string                           a text field
//
// `options` may be plain strings or { value, label } objects. An entry this
// file cannot draw faithfully (unknown type, no options, a stored value of
// another type) is left out, and its key stays in the dialog's raw editor
// instead, so nothing a plugin saved ever disappears from view.

var TYPES = ["boolean", "enum", "multiselect", "integer", "number", "string"];

function isFiniteNumber(value) {
    return typeof value === "number" && isFinite(value);
}

function optionLabel(value) {
    var text = String(value);
    return text.charAt(0).toUpperCase() + text.slice(1);
}

function normalizeOptions(options) {
    if (!Array.isArray(options))
        return [];
    var seen = {};
    var result = [];
    options.forEach(function(option) {
        var entry = null;
        if (typeof option === "string" || isFiniteNumber(option))
            entry = { value: option, label: optionLabel(option) };
        else if (option && typeof option === "object"
                && (typeof option.value === "string" || isFiniteNumber(option.value)))
            entry = { value: option.value,
                label: typeof option.label === "string" && option.label !== ""
                    ? option.label : optionLabel(option.value) };
        var id = entry ? typeof entry.value + ":" + entry.value : "";
        if (entry && !seen[id]) {
            seen[id] = true;
            result.push(entry);
        }
    });
    return result;
}

function hasOption(options, value) {
    return options.some(function(option) { return option.value === value; });
}

// Whether `value` can be shown by a field's control without losing anything.
function fits(field, value) {
    switch (field.type) {
    case "boolean":
        return typeof value === "boolean";
    case "enum":
        return hasOption(field.options, value);
    case "multiselect":
        return Array.isArray(value) && value.every(function(item) {
            return hasOption(field.options, item);
        });
    case "integer":
    case "number":
        // Out of range would be silently clamped by a slider.
        return isFiniteNumber(value)
            && (field.type === "number" || Math.round(value) === value)
            && (field.min === null || value >= field.min)
            && (field.max === null || value <= field.max);
    case "string":
        return typeof value === "string";
    }
    return false;
}

function same(a, b) {
    return JSON.stringify(a) === JSON.stringify(b);
}

// Rows for every drawable schema entry, plus the saved keys left for the raw
// editor. `defaults` is the manifest's `barWidget.defaults`; a schema entry's
// own `defaultValue` wins over it.
function fields(manifest, settings, defaults) {
    var widget = manifest && manifest.barWidget;
    var schema = widget && Array.isArray(widget.schema) ? widget.schema : [];
    var saved = settings && typeof settings === "object" ? settings : {};
    var fallback = defaults && typeof defaults === "object" ? defaults : {};
    var taken = {};
    var result = [];

    schema.forEach(function(entry) {
        if (!entry || typeof entry !== "object" || typeof entry.key !== "string"
                || entry.key === "" || taken[entry.key] || TYPES.indexOf(entry.type) < 0)
            return;
        var field = {
            key: entry.key,
            type: entry.type,
            label: typeof entry.label === "string" && entry.label !== "" ? entry.label : entry.key,
            description: typeof entry.description === "string" ? entry.description : "",
            options: normalizeOptions(entry.options),
            emptyText: typeof entry.noSelectionText === "string" ? entry.noSelectionText : "",
            min: isFiniteNumber(entry.min) ? entry.min : null,
            max: isFiniteNumber(entry.max) ? entry.max : null,
            step: isFiniteNumber(entry.step) && entry.step > 0 ? entry.step
                : entry.type === "integer" ? 1 : 0
        };
        if ((field.type === "enum" || field.type === "multiselect") && field.options.length === 0)
            return;
        field.slider = (field.type === "integer" || field.type === "number")
            && field.min !== null && field.max !== null && field.max > field.min;

        var declared = "defaultValue" in entry ? entry.defaultValue : fallback[entry.key];
        field.hasDefault = declared !== undefined && fits(field, declared);
        field.defaultValue = field.hasDefault ? declared : undefined;
        var value = entry.key in saved ? saved[entry.key] : field.defaultValue;
        if (value === undefined) {
            // Nothing saved and nothing declared: start from the control's
            // empty state rather than refusing to draw the row.
            value = field.type === "boolean" ? false
                : field.type === "multiselect" ? []
                : field.type === "string" ? ""
                : field.type === "enum" ? field.options[0].value
                : field.min !== null ? field.min : 0;
        }
        if (!fits(field, value))
            return;
        field.value = value;
        field.dirty = field.hasDefault && !same(value, field.defaultValue);
        taken[entry.key] = true;
        result.push(field);
    });

    var other = Object.keys(saved).filter(function(key) { return !taken[key]; }).sort();
    return { fields: result, other: other };
}

// A multiselect after toggling one option, kept in the schema's option order.
function toggled(field, current, value) {
    var chosen = Array.isArray(current) ? current : [];
    var on = chosen.indexOf(value) >= 0;
    return field.options.map(function(option) { return option.value; })
        .filter(function(item) { return item === value ? !on : chosen.indexOf(item) >= 0; });
}

// A typed number for a field, or null when the text is not one it accepts.
function parseNumber(field, text) {
    var trimmed = String(text).trim();
    if (!/^-?(\d+\.?\d*|\.\d+)$/.test(trimmed))
        return null;
    var value = Number(trimmed);
    if (!isFiniteNumber(value) || (field.type === "integer" && Math.round(value) !== value))
        return null;
    if ((field.min !== null && value < field.min) || (field.max !== null && value > field.max))
        return null;
    return value;
}

// What a number field accepts, for the error line under it.
function numberHint(field) {
    var kind = field.type === "integer" ? "a whole number" : "a number";
    if (field.min !== null && field.max !== null)
        return "Enter " + kind + " from " + field.min + " to " + field.max;
    if (field.min !== null)
        return "Enter " + kind + " of at least " + field.min;
    if (field.max !== null)
        return "Enter " + kind + " of at most " + field.max;
    return "Enter " + kind;
}

var exported = { fields: fields, toggled: toggled, parseNumber: parseNumber,
    numberHint: numberHint, fits: fits };
if (typeof module !== "undefined" && module.exports) module.exports = exported;
