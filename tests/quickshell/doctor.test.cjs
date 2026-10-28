const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {load, shellDir} = require('./shell.cjs');
const D = load('DoctorHelpers.js');

function report(states, overall = 'suggestion') {
    return {version: 1, checkedAt: '2026-10-28T12:00:00Z', overall,
        counts: {}, scope: '', checks: D.IDS.map(id => ({id, state: states[id] || 'ok', title: id,
            summary: id + ' summary', detail: '', facts: {}}))};
}

test('a report this shell can read keeps every check, in order', () => {
    const value = D.parse(JSON.stringify(report({graphics: 'suggestion'})));
    assert.deepEqual(value.checks.map(check => check.id), D.IDS);
    assert.equal(value.overall, 'suggestion');
    assert.equal(value.checks[0].summary, 'graphics summary');
});

test('malformed, newer or unknown reports are refused rather than half-shown', () => {
    for (const bad of ['', '{', 'null', '[]', JSON.stringify({...report({}), version: 2}),
        JSON.stringify({...report({}), overall: 'fine'}), JSON.stringify({...report({}), checks: 'x'}),
        JSON.stringify(report({graphics: 'broken'})),
        JSON.stringify({...report({}), checks: [...report({}).checks, {id: 'future', state: 'ok'}]})])
        assert.equal(D.parse(bad), null, bad.slice(0, 60));
});

test('problems come before suggestions; info and unknown never need the person', () => {
    const value = D.parse(report({graphics: 'suggestion', 'firmware-files': 'info', services: 'problem',
        'firmware-updates': 'suggestion', battery: 'unknown', storage: 'problem'}, 'problem'));
    assert.deepEqual(D.attention(value).map(check => check.id + ':' + check.state),
        ['services:problem', 'storage:problem', 'graphics:suggestion', 'firmware-updates:suggestion']);
    assert.deepEqual(D.attention(null), []);
});

test('every check id the shell counts has its own translated sentence', () => {
    const qml = fs.readFileSync(path.join(shellDir, 'Common/Doctor.qml'), 'utf8');
    for (const id of D.IDS.filter(id => id !== 'firmware-files'))
        assert.match(qml, new RegExp('case "' + id + '":'), id);
    assert.match(qml, /command: \["cybex", "doctor", "--json"\]/);
});
