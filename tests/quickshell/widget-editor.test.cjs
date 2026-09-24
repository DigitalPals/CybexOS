const test = require('node:test');
const assert = require('node:assert/strict');
const { load } = require('./shell.cjs');
const E = load('WidgetEditor.js');
const L = load('LayoutHelpers.js');
const C = load('WidgetCatalog.js');
const mods = {
    left: [{id:'ws',on:true,detail:'auto'}, {id:'media',on:false,detail:'prefer'}, {id:'clock',on:true,detail:'compact'}],
    center: [], right: [{id:'batt',on:true,detail:'auto'}]
};
const plugins = [
    {id:'clock',key:'clock',name:'External clock',section:'left',enabled:true,settings:{},manifest:{}},
    {id:'external',key:'external#two',instanceName:'two',name:'External',section:'center',enabled:true,settings:{},manifest:{}},
    {id:'unused',key:'unused',name:'Unused',section:'right',enabled:false,settings:{},manifest:{}}
];
const entries = E.catalog(mods,plugins,C.WIDGETS);

test('catalog preserves disabled built-ins and plugin instance identity', () => {
    assert.equal(entries.length,7);
    assert.equal(entries.find(e => e.key === 'media').enabled,false);
    assert.equal(entries.find(e => e.key === 'plugin:external#two').descriptor,plugins[1]);
    assert.equal(new Set(entries.map(e => e.key)).size,entries.length);
});

test('section order matches native bar plugin blocks', () => {
    assert.deepEqual(E.sectionEntries(entries,'left').map(e=>e.key),['plugin:clock','ws','clock']);
    assert.deepEqual(E.sectionEntries(entries,'center').map(e=>e.key),['plugin:external#two']);
});

test('dragging built-ins preserves hidden entries, options and supported boundaries', () => {
    const clock = entries.find(e=>e.key==='clock');
    const plan = E.dropPlan(entries,mods,clock,'left',0);
    assert.equal(plan.gap,1); // cannot precede the plugin block
    const moved = L.moveWidget(mods,clock.section,clock.id,plan.section,plan.index);
    assert.deepEqual(moved.mods.left.map(e=>e.id),['clock','ws','media']);
    assert.equal(moved.mods.left[2].on,false);
    assert.equal(moved.mods.left[2].detail,'prefer');
    assert.equal(moved.mods.left[0].detail,'compact');
    assert.deepEqual(mods.left.map(e=>e.id),['ws','media','clock']);
});

test('plugin insertion indices exclude built-ins and honor center trailing placement', () => {
    const plugin = entries.find(e=>e.plugin);
    assert.deepEqual(E.dropPlan(entries,mods,plugin,'left',3),{section:'left',index:1,gap:1});
    const populated = {...mods, center: [{id:'clock',on:true,detail:'auto'}]};
    const all = E.catalog(populated,plugins,C.WIDGETS);
    assert.deepEqual(E.dropPlan(all,populated,plugin,'center',0),{section:'center',index:0,gap:1});
    assert.deepEqual(E.dropPlan(entries,mods,plugin,'right',1),{section:'right',index:0,gap:0});
});

test('available collection searches names, descriptions and origins without losing enabled state', () => {
    assert.deepEqual(E.search(entries,'','available').map(e=>e.key),['media','plugin:unused']);
    assert.deepEqual(E.search(entries,'external TWO','plugins').map(e=>e.key),['plugin:external#two']);
    assert.deepEqual(E.search(entries,'playback','all').map(e=>e.key),['media']);
    assert.equal(E.search(entries,'missing','all').length,0);
});

test('status distinguishes disabled, conditionally hidden and plugin-controlled widgets', () => {
    const battery = entries.find(e=>e.key==='batt');
    assert.equal(E.status(battery,{battery:false}),'Hidden · no battery detected');
    assert.equal(E.status({...battery,enabled:false},{}),'Available to add · settings are kept');
    assert.equal(E.status(battery,{battery:true}),'Ready · battery detected');
    assert.equal(E.status(entries.find(e=>e.plugin),{}),'On your bar · visibility controlled by plugin');
});


test('temporarily hidden widgets stay on the bar and out of available widgets', () => {
    const battery = entries.find(e=>e.key==='batt');
    assert.match(E.status(battery,{battery:false}),/^Hidden/);
    assert.ok(E.sectionEntries(entries,'right').some(e=>e.key==='batt'));
    assert.ok(!E.search(entries,'','available').some(e=>e.key==='batt'));
});

// Run the production membership handlers with storage and timer boundaries stubbed.
function membershipHarness() {
    const fs = require('node:fs');
    const path = require('node:path');
    const vm = require('node:vm');
    const { shellDir } = require('./shell.cjs');
    const editor = fs.readFileSync(path.join(shellDir,'Settings/ModulesPage.qml'),'utf8');
    const settings = fs.readFileSync(path.join(shellDir,'Common/Settings.qml'),'utf8');
    const timer = { restart() {}, stop() {} };
    const context = vm.createContext({
        mods: structuredClone(mods), clearUndo() {}, migrationPending: false,
        LayoutHelpers: L, membershipBusy: false, subPage: '', search: { text: '' }, detailPage: { contentY: 0 },
        pendingMembership: null, undoRemoved: null, notice: '', announcement: '',
        membershipTimeout: timer, noticeTimer: timer, membershipFocus: { ...timer },
        UserPlugins: { configureWidget() {}, moveWidget() {} }, entries: [],
        sectionEntries: section => E.sectionEntries(entries, section)
    });
    function install(source,name) {
        const match = source.match(new RegExp('    function '+name+'\\([^]*?^    }','m'));
        assert.ok(match, name);
        vm.runInContext(match[0],context);
    }
    install(settings,'setModuleEnabled');
    context.Settings = { get mods() { return context.mods; }, setModuleEnabled: context.setModuleEnabled,
        setModuleOrder(left,center,right) { context.mods = {left,center,right}; } };
    for (const name of ['setEnabled','finishMembership','confirmMembership','commitDrag']) install(editor,name);
    return context;
}

test('remove and Undo retain placement, options and intervening changes to other widgets', () => {
    const h = membershipHarness();
    const clock = entries.find(e=>e.key==='clock');
    h.setEnabled(clock,false);
    assert.equal(h.mods.left[2].on,false);
    assert.equal(h.undoRemoved.key,'clock');
    h.setModuleEnabled('batt',false);
    h.setEnabled({...clock,enabled:false},true,true);
    assert.equal(h.mods.left[2].on,true);
    assert.equal(h.mods.left[2].detail,'compact');
    assert.equal(h.mods.right[0].on,false);
    assert.equal(h.undoRemoved,null);
    assert.equal(h.notice,'Clock restored to your bar');
});

test('plugin removal offers Undo only after write acknowledgment and refreshed membership agree', () => {
    const h = membershipHarness();
    const plugin = entries.find(e=>e.plugin);
    h.entries = entries;
    h.setEnabled(plugin,false);
    assert.equal(h.undoRemoved,null);
    h.pendingMembership.acknowledged = true;
    h.confirmMembership();
    assert.equal(h.undoRemoved,null);
    h.entries = entries.map(e=>e.key===plugin.key ? {...e,enabled:false} : e);
    h.confirmMembership();
    assert.equal(h.undoRemoved.key,plugin.key);
    assert.equal(h.pendingMembership,null);
});

test('a later add never displays an Undo action for an unrelated earlier removal', () => {
    const h = membershipHarness();
    h.setEnabled(entries.find(e=>e.key==='clock'),false);
    h.setEnabled(entries.find(e=>e.key==='media'),true);
    assert.equal(h.undoRemoved,null);
});

test('a refreshed plugin list alone cannot report a successful write', () => {
    const h = membershipHarness();
    const plugin = entries.find(e=>e.plugin);
    h.setEnabled(plugin,false);
    h.entries = entries.map(e=>e.key===plugin.key ? {...e,enabled:false} : e);
    h.confirmMembership();
    assert.equal(h.undoRemoved,null);
    h.pendingMembership.acknowledged = true;
    h.confirmMembership();
    assert.equal(h.undoRemoved.key,plugin.key);
});


test('wrapped grid drop gaps follow both axes, clamp edges and handle empty sections', () => {
    const gap = (x,y,count=7,columns=3) => E.gridGap(count,columns,100,40,10,x,y);
    assert.equal(gap(0,20),0);
    assert.equal(gap(80,20),1);
    assert.equal(gap(140,20),1);
    assert.equal(gap(200,20),2);
    assert.equal(gap(0,60),3);
    assert.equal(gap(280,60),6);
    assert.equal(gap(280,110),7);
    assert.equal(gap(-50,60),3);
    assert.equal(gap(1000,20),3);
    assert.equal(gap(20,-30),0);
    assert.equal(gap(20,900),7);
    assert.equal(gap(30,30,0),0);
    assert.equal(gap(80,60,4,1),2);
});

test('adding a built-in to a chosen section preserves options and does not change other widgets', () => {
    const h = membershipHarness();
    h.setEnabled(entries.find(e=>e.key==='media'),true,false,'center');
    assert.deepEqual(Array.from(h.mods.center,e=>e.id),['media']);
    assert.equal(h.mods.center[0].on,true);
    assert.equal(h.mods.center[0].detail,'prefer');
    assert.deepEqual(Array.from(h.mods.left,e=>e.id),['ws','clock']);
    assert.equal(h.mods.right[0].on,true);
});

test('plugin add waits for both membership and chosen destination to be refreshed', () => {
    const h = membershipHarness();
    let requested;
    h.UserPlugins.configureWidget = (_, changes) => { requested = changes; };
    const plugin = entries.find(e=>e.key==='plugin:unused');
    h.setEnabled(plugin,true,false,'left');
    assert.equal(requested.enabled,true);
    assert.equal(requested.section,'left');
    h.pendingMembership.acknowledged = true;
    h.entries = entries.map(e=>e.key===plugin.key ? {...e,enabled:true} : e);
    h.confirmMembership();
    assert.ok(h.pendingMembership);
    h.entries = h.entries.map(e=>e.key===plugin.key ? {...e,section:'left'} : e);
    h.confirmMembership();
    assert.equal(h.pendingMembership,null);
    assert.equal(h.notice,'Unused added to your bar');
});

// ---- dragging out of the Add widgets tray -------------------------------

test('a tray widget dropped into a lane is added at the drop marker, keeping its options', () => {
    const h = membershipHarness();
    const media = entries.find(e=>e.key==='media');
    let moved = null;
    h.cancelDrag = () => { h.dragMod = null; h.dropAt = null; };
    h.move = () => { moved = true; };
    h.dragMod = media;
    h.dropAt = E.dropPlan(entries,mods,media,'right',0);
    h.commitDrag();
    assert.equal(moved,null,'a disabled widget is added, not moved');
    assert.deepEqual(Array.from(h.mods.right,e=>e.id),['media','batt']);
    assert.equal(h.mods.right[0].on,true);
    assert.equal(h.mods.right[0].detail,'prefer');
    assert.deepEqual(Array.from(h.mods.left,e=>e.id),['ws','clock']);
    assert.equal(h.notice,'Media added to your bar');
});

test('a placed widget dragged between lanes still moves rather than re-adding', () => {
    const h = membershipHarness();
    const clock = entries.find(e=>e.key==='clock');
    let moved = null;
    h.cancelDrag = () => {};
    h.move = (entry,section,gap) => { moved = [entry.key,section,gap]; };
    h.dragMod = clock;
    h.dropAt = E.dropPlan(entries,mods,clock,'center',0);
    h.commitDrag();
    assert.deepEqual(moved,['clock','center',0]);
});

test('a plugin widget dropped ahead of its peers is enabled and then moved to the marker', () => {
    const h = membershipHarness();
    const writes = [];
    h.UserPlugins.configureWidget = (descriptor,changes) => writes.push(['configure',descriptor.key,changes]);
    h.UserPlugins.moveWidget = (key,section,index) => writes.push(['move',key,section,index]);
    const plugin = entries.find(e=>e.key==='plugin:unused');
    h.cancelDrag = () => {};
    h.dragMod = plugin;
    h.dropAt = E.dropPlan(entries,mods,plugin,'left',0);
    h.commitDrag();
    // The changes object comes from the page's own realm; compare its content.
    assert.deepEqual(JSON.parse(JSON.stringify(writes)),[['configure','unused',{enabled:true,section:'left'}],['move','unused','left',0]]);

    // Dropped after the section's last plugin widget, adding alone puts it there.
    const later = membershipHarness();
    const laterWrites = [];
    later.UserPlugins.configureWidget = (descriptor,changes) => laterWrites.push(['configure',descriptor.key,changes]);
    later.UserPlugins.moveWidget = (key,section,index) => laterWrites.push(['move',key,section,index]);
    later.cancelDrag = () => {};
    later.dragMod = plugin;
    later.dropAt = E.dropPlan(entries,mods,plugin,'left',3);
    later.commitDrag();
    assert.deepEqual(JSON.parse(JSON.stringify(laterWrites)),[['configure','unused',{enabled:true,section:'left'}]]);
});

test('tray chips drag through the same drop plan and ghost as the lanes', () => {
    const fs = require('node:fs');
    const path = require('node:path');
    const { shellDir } = require('./shell.cjs');
    const editor = fs.readFileSync(path.join(shellDir,'Settings/ModulesPage.qml'),'utf8');
    const pill = fs.readFileSync(path.join(shellDir,'Settings/WidgetPill.qml'),'utf8');
    const tray = editor.slice(editor.indexOf('title: "Add widgets"'));
    assert.match(tray, /draggable: !page\.membershipBusy/);
    assert.match(tray, /onDragStarted: page\.dragMod = modelData\s+onDragMoved: \(x, y\) => page\.updateDrop\(trayChip, x, y\)\s+onDragFinished: page\.commitDrag\(\)\s+onDragCanceled: page\.cancelDrag\(\)/);
    assert.match(editor, /if \(entry\.enabled\) move\(entry, target\.section, target\.gap\);\s+else setEnabled\(entry, true, false, target\.section, target\.index\);/);
    // A tray chip can start a drag; only the lanes' chips wear the open hand.
    assert.match(pill, /if \(!\(pressedButtons & Qt\.LeftButton\) \|\| canceled \|\| !root\.draggable\) return;/);
    assert.match(pill, /root\.draggable && root\.placed \? Qt\.OpenHandCursor : Qt\.PointingHandCursor/);
});
