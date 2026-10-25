const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {spawnSync} = require('node:child_process');
const {root, luaBinary} = require('./keybindings-support.cjs');
const lua = luaBinary();
// Hyprland 0.56.2 statically embeds Lua 5.5, which rejects at compile time what
// 5.4 accepts, such as assigning to a for-loop variable. The Lua tests must run
// the same language version as the compositor.
function luaFiles(directory) {
    return fs.readdirSync(directory, {withFileTypes: true}).flatMap(entry => {
        const file = path.join(directory, entry.name);
        return entry.isDirectory() ? luaFiles(file) : entry.name.endsWith('.lua') ? [file] : [];
    });
}
test('the Lua tests run the Lua version Hyprland embeds', () => {
    assert.ok(lua, 'Lua is required: run these tests through nix develop');
    const result = spawnSync(lua, ['-v'], {encoding: 'utf8'});
    assert.match(result.stdout + result.stderr, /^Lua 5\.5\./);
});
test('every Hyprland configuration and fixture Lua file compiles under Lua 5.5', () => {
    const files = [...luaFiles(path.join(root, 'desktop/hypr')), ...luaFiles(path.join(root, 'tests/fixtures'))];
    assert.ok(files.some(file => file.endsWith('keybinding_helpers.lua')));
    for (const file of files) {
        const result = spawnSync(lua, ['-', file], {input: 'assert(loadfile(arg[1]))', encoding: 'utf8'});
        assert.equal(result.status, 0, result.stderr);
    }
});
