const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const {load,shellDir} = require('./shell.cjs');
const Holds=load('NotifHolds.js');

function fixture(){
    const pending=[],published=[];
    const holds=Holds.create(callback=>pending.push(callback),snapshot=>published.push(snapshot));
    return {holds,pending,published,flush(){while(pending.length)pending.shift()();}};
}

test('delegate construction/destruction coalesces holds without synchronous QML publication',()=>{
    const f=fixture(),owner={};
    f.holds.set(owner,'source',false);
    assert.equal(f.pending.length,0,'unheld teardown must be an idempotent no-op');
    f.holds.set(owner,'source',true);
    f.holds.set(owner,'source',true);
    assert.equal(f.holds.isHeld('source'),true,'admission sees a hold before publication');
    assert.equal(f.pending.length,1);
    assert.equal(f.published.length,0,'never publish during model binding evaluation');
    f.holds.set(owner,'source',false);
    assert.equal(f.holds.isHeld('source'),false);
    f.flush();
    assert.equal(f.published.length,0,'create/destroy in one turn leaves no observable hold');
    f.holds.set(owner,'source',true);f.flush();
    assert.deepEqual(Object.keys(f.published[0]),['source']);
    f.holds.set(owner,'source',false);f.flush();
    assert.deepEqual(Object.keys(f.published[1]),[]);
});

test('old output/delegate cleanup cannot release a replacement owner of the same source',()=>{
    const f=fixture(),old={},replacement={};
    f.holds.set(old,'source',true);f.flush();
    f.holds.set(replacement,'source',true);
    f.holds.set(old,'source',false);f.flush();
    assert.equal(f.holds.isHeld('source'),true);
    assert.equal(f.published.length,1,'aggregate hold does not flicker during replacement');
    f.holds.set(replacement,'source',false);f.flush();
    assert.equal(f.holds.isHeld('source'),false);
    assert.deepEqual(Object.keys(f.published[1]),[]);
});

test('keyboard focus transfers preserve the aggregate pause and release only the last owner',()=>{
    const f=fixture(),button={},card={},otherCard={};
    f.holds.set(button,'focus',true);f.flush();
    f.holds.set(button,'focus',false);
    f.holds.set(card,'focus',true);f.flush();
    assert.equal(f.published.length,1,'button-to-card transfer must not collapse the deck');
    f.holds.set(otherCard,'focus',true);
    f.holds.set(card,'focus',false);f.flush();
    assert.equal(f.holds.isHeld('focus'),true);
    f.holds.set(otherCard,'focus',false);f.flush();
    assert.equal(f.published.length,2);
    assert.deepEqual(Object.keys(f.published[1]),[]);
});

test('queued publication is cancelled on component destruction and hostile source keys remain inert',()=>{
    const f=fixture(),owner={};
    f.holds.set(owner,'__proto__',true);f.flush();
    assert.equal(f.published[0].__proto__,true);
    assert.equal(Object.getPrototypeOf(f.published[0]),null);
    f.holds.set(owner,'constructor',true);
    assert.equal(f.holds.isHeld('__proto__'),false);
    f.holds.dispose();f.flush();
    assert.equal(f.published.length,1,'destroyed QML publisher must never run');
    f.holds.set(owner,'source',true);f.flush();
    assert.equal(f.holds.isHeld('source'),false);
});

test('production decks use owner claims for teardown/focus and retain paused countdowns',()=>{
    const source=fs.readFileSync(path.join(shellDir,'NotificationToasts.qml'),'utf8');
    assert.match(source,/onExpandedChanged:\s*Notifs\.holdGroup\(modelData, expanded, deck\)/);
    assert.match(source,/focusHolds\.dispose\(\);\s*Notifs\.holdGroup\(modelData, false, deck\)/);
    assert.match(source,/onHoldsFocusChanged:\s*deck\.focusHolds\.set\(card, "focus", holdsFocus\)/);
    assert.doesNotMatch(source,/focusedSlots|focusedWithin\s*=\s*activeFocus/);
    assert.match(source,/paused:\s*!slot\.critical && deck\.expanded/);
});

test('production screen selection follows the assigned output without reading the live window screen',()=>{
    const source=fs.readFileSync(path.join(shellDir,'NotificationToasts.qml'),'utf8');
    const expression=source.match(/readonly property var screenGroups:\s*([\s\S]*?)\n\s*readonly property var groupKeys:/)?.[1];
    assert.ok(expression,'evaluate the production screenGroups expression');
    const a={key:'a',screenName:'A'},b={key:'b',screenName:'B'},c={key:'c',screenName:'B'};
    const root={modelData:{screen:{name:'A'}}};
    Object.defineProperty(root,'screen',{get(){
        assert.fail('native screenChanged during visibility mapping must not invalidate screenGroups');
    }});
    const context=vm.createContext({root,Notifs:{toastGroups:[
        {key:'source-one',app:'One',items:[a,b]},
        {key:'source-two',app:'Two',items:[c]}
    ]}});
    const select=()=>JSON.parse(JSON.stringify(vm.runInContext(expression,context)));
    assert.deepEqual(select(),[{key:'source-one',app:'One',items:[a]}]);
    // Reassignment/hotplug follows authoritative output identity, preserving
    // group/card order without acquiring the native window dependency.
    root.modelData={screen:{name:'B'}};
    assert.deepEqual(select(),[
        {key:'source-one',app:'One',items:[b]},
        {key:'source-two',app:'Two',items:[c]}
    ]);
    root.modelData={screen:null};
    assert.deepEqual(select(),[]);
    root.modelData={screen:{name:'disconnected'}};
    assert.deepEqual(select(),[]);
});
