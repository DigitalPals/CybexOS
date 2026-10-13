// Kept free of Qt APIs so the page's actual draft behavior runs under QtTest.
function clone(value) { return JSON.parse(JSON.stringify(value)); }
function patch(current, original, keys) {
    var result = {};
    keys.forEach(function(key) {
        if (JSON.stringify(current[key]) !== JSON.stringify(original[key])) result[key] = clone(current[key]);
    });
    return result;
}
function changeLayout(layouts, index, layout, variant) {
    var result = clone(layouts);
    result[index] = {layout: layout, variant: variant || ""};
    return result;
}
function move(layouts, index, delta) {
    var result = clone(layouts);
    var other = index + delta;
    if (index >= 0 && index < result.length && other >= 0 && other < result.length) {
        var value = result[index]; result[index] = result[other]; result[other] = value;
    }
    return result;
}
function filtered(choices, query, selected) {
    var text = query.trim().toLowerCase();
    var result = choices.filter(function(choice) {
        return choice.value === selected || (choice.label + " " + choice.value).toLowerCase().indexOf(text) !== -1;
    });
    if (selected && !choices.some(function(choice) { return choice.value === selected; }))
        result.unshift({value: selected, label: selected + " (current)"});
    return result;
}
if (typeof module !== "undefined") module.exports = {clone: clone, patch: patch, changeLayout: changeLayout, move: move, filtered: filtered};
