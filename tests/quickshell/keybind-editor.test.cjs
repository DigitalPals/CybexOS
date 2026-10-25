const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {load, plain, root} = require('./keybindings-support.cjs');
const E = load('KeybindEditor.js');
const fixture = name => JSON.parse(fs.readFileSync(path.join(root, 'tests/fixtures/keybindings', name + '.json')));
test('canonical keys and equality use the shared Lua/JS vectors', () => {
    for (const vector of fixture('normalize')) assert.equal(E.normalize(vector.input), vector.output);
    for (const vector of fixture('same')) assert.equal(E.same(vector.a, vector.b), vector.equal);
});
const meta = 0x10000000, shift = 0x02000000, keypad = 0x20000000;
test('recorder maps letters, digits, function, navigation, punctuation and keypad keys', () => {
    const record = (key, modifiers = meta, nativeScanCode = 0, text = '') => plain(E.fromKeyEvent({key, modifiers, nativeScanCode, text}));
    for (let key = 65; key <= 90; key++) assert.equal(record(key).keys, 'SUPER + ' + String.fromCharCode(key));
    for (let key = 48; key <= 57; key++) assert.equal(record(key).keys, 'SUPER + ' + String.fromCharCode(key));
    assert.deepEqual(record(0x01000038, 0), {keys:'F9', complete:true});
    assert.equal(record(0x01000012).keys, 'SUPER + Left');
    assert.equal(record(44).keys, 'SUPER + comma');
    assert.equal(record(0x01000003).keys, 'SUPER + BackSpace');
    assert.equal(record(49, meta | keypad).keys, 'SUPER + KP_1');
    assert.equal(record(43, meta | keypad).keys, 'SUPER + KP_Add');
    assert.equal(record(0x01000005, meta | keypad).keys, 'SUPER + KP_Enter');
    assert.equal(record(0x01000070, 0).keys, 'XF86AudioLowerVolume');
    assert.equal(record(0x010000b2, 0).keys, 'XF86MonBrightnessUp');
    assert.equal(record(0x01000113, 0).keys, 'XF86AudioMicMute');
});
test('shifted number rows and unknown symbols use unchanged Wayland xkb keycodes', () => {
    for (const key of [33, 49, 38, 233, 0x00a3]) {
        const event = E.fromKeyEvent({key, modifiers:meta | shift, nativeScanCode:10, text:String.fromCharCode(key)});
        assert.equal(event.keys, 'SUPER + SHIFT + code:10');
        assert.equal(event.complete, true);
    }
    assert.equal(E.fromKeyEvent({key:0x010000ff, modifiers:meta, nativeScanCode:200}).keys, 'SUPER + code:200');
    assert.equal(E.fromKeyEvent({key:0x010000ff, modifiers:meta, nativeScanCode:0}).complete, false);
    assert.equal(E.fromKeyEvent({key:0x01000020, modifiers:shift, nativeScanCode:50}).complete, false);
    assert.equal(E.fromKeyEvent({key:0x01001103, modifiers:0, nativeScanCode:108}).complete, false);
    assert.equal(E.fromKeyEvent({key:65, modifiers:meta | 0x40000000, nativeScanCode:38}).complete, false);
});
test('reservations preserve typing, recovery and hardware power keys; display reuses sheet caps', () => {
    for (const key of ['B','Return','code:10','CTRL + ALT + F1','CTRL + ALT + Delete','Sys_Req','XF86PowerOff','SUPER + mouse:272']) {
        assert.equal(E.isReserved(key), true, key);
    }
    for (const key of ['F9','XF86AudioMute','SUPER + B','SUPER + SHIFT + code:10']) assert.equal(E.isReserved(key), false, key);
    assert.deepEqual(plain(E.display('SUPER + SHIFT + B')), ['Super','Shift','B']);
    assert.deepEqual(plain(E.display('SUPER + comma')), ['Super',',']);
});
// The maps are the parser's output for `xkbcli compile-keymap --layout us|fr`
// (tests/nixos/test_keybindings_keymap.py reads the .xkb the maps come from).
const keymap = name => JSON.parse(fs.readFileSync(path.join(root, 'tests/fixtures/keybindings', 'keymap-' + name + '.json'), 'utf8'));
test('Shift combinations record the base keysym when the layout map is known', () => {
    const us = keymap('us'), fr = keymap('fr');
    const record = (map, key, nativeScanCode, modifiers = meta | shift) => plain(E.fromKeyEvent({key, modifiers, nativeScanCode}, map));
    // US: Qt reports the shifted symbol; the vendor binds are written with the base one.
    assert.equal(record(us, 33, 10).keys, 'SUPER + SHIFT + 1');
    assert.equal(record(us, 64, 11).keys, 'SUPER + SHIFT + 2');
    assert.equal(record(us, 95, 20, shift).keys, 'SHIFT + minus');
    assert.equal(record(us, 126, 49, shift).keys, 'SHIFT + grave');
    assert.equal(record(us, 63, 61, shift).keys, 'SHIFT + slash');
    assert.equal(record(us, 33, 10).complete, true);
    // AZERTY: the unshifted number-row key is ampersand and Shift produces the digit.
    assert.equal(record(fr, 49, 10).keys, 'SUPER + SHIFT + ampersand');
    assert.equal(record(fr, 50, 11).keys, 'SUPER + SHIFT + eacute');
    assert.equal(record(fr, 63, 61, shift).keys, 'SHIFT + exclam');
    // Without a map the keycode fallback is unchanged, and an unknown code stays a code.
    assert.equal(record(undefined, 33, 10).keys, 'SUPER + SHIFT + code:10');
    assert.equal(record({}, 33, 10).keys, 'SUPER + SHIFT + code:10');
    assert.equal(record({'11': '2'}, 33, 10).keys, 'SUPER + SHIFT + code:10');
    // Hostile or malformed map values are ignored, and unrelated keys are untouched.
    for (const value of ['; rm', '', 7, null, 'a b']) assert.equal(record({'10': value}, 33, 10).keys, 'SUPER + SHIFT + code:10');
    assert.equal(record({'__proto__': 'x', 'constructor': 'y'}, 33, 10).keys, 'SUPER + SHIFT + code:10');
    assert.equal(record(us, 66, 56, meta | shift).keys, 'SUPER + SHIFT + B');
    assert.equal(record(us, 0x01000004, 36).keys, 'SUPER + SHIFT + Return');
    // An unshifted record needs no map; the map never rewrites a key with a known name.
    assert.equal(plain(E.fromKeyEvent({key: 49, modifiers: meta, nativeScanCode: 10}, us)).keys, 'SUPER + 1');
    assert.equal(plain(E.fromKeyEvent({key: 38, modifiers: meta, nativeScanCode: 10}, fr)).keys, 'SUPER + ampersand');
});
