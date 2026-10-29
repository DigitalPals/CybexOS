const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { shellDir } = require('./shell.cjs');
const read = name => fs.readFileSync(path.join(shellDir, name), 'utf8');

test('a successful status containing a domain error still settles and publishes its snapshot', () => {
    const source = read('Common/JsonCommand.qml');
    const handler = source.match(/onCompleted: (\(code, body, diagnostics\) => \{[\s\S]*?)\n        }\n    }/)[1] + '\n}';
    const completions = [], failures = [];
    const root = {completed: value => completions.push(value), failed: value => failures.push(value)};
    const complete = vm.runInNewContext('(' + handler + ')', {root});
    complete(0, '{"state":"failed","error":"Review is stale","recoveryPending":true}', '');
    assert.equal(completions.length, 1);
    assert.equal(completions[0].recoveryPending, true);
    assert.equal(failures.length, 0);
    complete(1, '', '{"error":"Authentication cancelled"}');
    assert.deepEqual(failures, ['Authentication cancelled']);
});

test('refreshing Software preserves an edited draft and detects an external baseline change', () => {
    const source = read('Common/Software.qml');
    const handler = source.match(/id: loader\s+onCompleted: (value => \{[\s\S]*?)\n        }\n    }/)[1] + '\n}';
    const root = {dirty:true, conflict:false, inventory:{desired:[]}, draft:['hello']};
    const complete = vm.runInNewContext('(' + handler + ')', {root});
    complete({desired:['git'], packages:[]});
    assert.equal(root.conflict, true);
    assert.deepEqual(root.draft, ['hello']);
    assert.deepEqual(Array.from(root.inventory.desired), ['git']);
});

test('cleanup preference drafts retain their original policy until explicitly discarded', () => {
    // The draft outlives the Recovery points tab (RetentionDraft), so the
    // header's Changes review sees it too.
    const source = read('Settings/RetentionDraft.qml');
    const root = {policyBaseline:{automatic:false, keepConfirmed:5, keepDays:30}, draft:{automatic:true, keepConfirmed:5, keepDays:30},
        status:{policy:{automatic:false, keepConfirmed:10, keepDays:60}}};
    root.configuredPolicy = root.status.policy;
    vm.createContext(root);
    for (const name of ['same', 'discard', 'edit'])
        vm.runInContext(source.match(new RegExp(`^    function ${name}\\([^]*?^    }`, 'm'))[0], root);
    assert.equal(root.same(root.policyBaseline, root.status.policy), false);
    root.edit({keepDays:90});
    assert.equal(root.policyBaseline.keepDays, 30);
    root.discard();
    assert.equal(root.draft.keepConfirmed, 10);
    assert.equal(root.same(root.draft, root.policyBaseline), true);
});
