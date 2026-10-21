const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const {load, shellDir} = require('./shell.cjs');
const Helpers = load('NotifHelpers.js');
const source = fs.readFileSync(path.join(shellDir, 'Common/NotifActions.qml'), 'utf8');

// Standalone qmltestrunner cannot load Quickshell's static core plugin.
// Check the production pill binding and execute its expression with the same
// helper the service uses; native rendering remains a separate qualification.
test('action pills render cleaned comparison labels as plain text with the same accessible name', () => {
    const text = source.match(/id:\s*pillText\b([^]*?)\n                }/)[1];
    const binding = text.match(/^\s*text:\s*(.+)$/m)[1];
    const rendered = [];
    for (const [raw, expected] of [
        ['Open', 'Open'], ['<b>Open</b>', 'Open'], ['A&B', 'A&B'], ['A&amp;B', 'A&B'],
        [' \tA<br>B\u200b ', 'A B'], ['&lt;b&gt;Open&lt;/b&gt;', '<b>Open</b>'],
        ['<b>' + '&amp;'.repeat(256) + '</b>', '&'.repeat(256)],
        ['<b>' + 'x'.repeat(257) + '</b>', 'x'.repeat(257)],
    ]) {
        const action = {identifier: ' OPEN &<b> ', text: raw};
        const actual = vm.runInNewContext(binding, {Helpers, pill: {modelData: action}});
        assert.equal(actual, expected, raw);
        rendered.push({action, actual});
        assert.equal(action.text, raw, 'presentation must not mutate sender data');
    }
    assert.match(source, /import "NotifHelpers\.js" as Helpers/);
    assert.match(text, /textFormat:\s*Text\.PlainText/);
    assert.match(source, /Accessible\.name:\s*pillText\.text/);
    for (const {action, actual} of rendered) {
        const signature = Helpers.actionSignature([action]);
        if (actual.length <= 256)
            assert.equal(JSON.parse(signature)[0][1], actual);
        else
            assert.equal(signature, null, 'the complete rendered label must fit to allow dedupe');
    }
});

test('pointer, keyboard and accessible action paths invoke the original model object', () => {
    assert.match(source, /items = Notifs\.secondaryActions\(entry\)/);
    assert.match(source, /Accessible\.onPressAction:\s*Notifs\.invoke\(root\.entry, pill\.modelData\)/);
    assert.equal((source.match(/Notifs\.invoke\(root\.entry, pill\.modelData\)/g) || []).length, 3);
    assert.doesNotMatch(source, /modelData\.(?:identifier|id|key)\s*=/);
});
