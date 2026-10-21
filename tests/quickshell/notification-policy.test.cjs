const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const {load, shellDir} = require('./shell.cjs');
const P = load('NotifPolicy.js'), S = load('NotifSmart.js'), H = load('NotifHelpers.js');
const Holds = load('NotifHolds.js');
const row = (changes = {}) => ({appName:'Chat', desktopEntry:'chat', summary:'Alice', body:'hello',
    displayAppName:'Chat', displaySummary:'Alice', displayBody:'hello', urgency:1,
    arrived:1000, occurrences:1, appIcon:'', image:'', ...changes});

test('source keys preserve exact native and website identity, including hostile object keys', () => {
    assert.notEqual(P.sourceKey(row()), P.sourceKey(row({desktopEntry:'chat-other'})));
    assert.notEqual(P.sourceKey(row({appName:'a-b'})), P.sourceKey(row({appName:'a b'})));
    assert.notEqual(P.sourceKey(row({webOrigin:'one.slack.com'})), P.sourceKey(row({webOrigin:'two.slack.com'})));
    assert.equal(P.groups([row({sourceKey:'__proto__'}), row({sourceKey:'constructor'})]).length,2);
    assert.equal(H.derivePresentation({appName:'Chromium', body:'<a href="https://evil.example/">bank.example</a>hello'}).webOrigin,'evil.example');
    assert.equal(H.derivePresentation({appName:'Signal', body:'<a href="https://evil.example/">bank.example</a>hello'}).webOrigin,'');
    for (const origin of ['https://bank.example@evil.example','javascript://bank.example','https://bank.example\\evil'])
        assert.equal(H.normalizeOrigin(origin), '', origin);
});

test('dedupe compares exact full content in a first-occurrence window; progress and restore never merge', () => {
    const first = row();
    assert.equal(P.duplicate([first],row(),11000,10),first);
    assert.equal(P.duplicate([first],row(),11001,10),null);
    for (const changes of [{body:'different'}, {summary:'ALICE'}, {appName:'Other'},
        {actionSignature:'new-action'}, {progress:true}, {oversized:true}, {urgency:2}, {image:'other'}])
        assert.equal(P.duplicate([first],row(changes),2000,10),null,JSON.stringify(changes));
    assert.equal(P.duplicate([row({restored:true})],row(),2000,10),null);
    assert.equal(P.duplicate([first],row(),2000,0),null);
});

test('a null action comparison disables dedupe on either side without changing source identity', () => {
    const bounded=row({actionSignature:'[]'}), overflow=row({actionSignature:null});
    assert.equal(P.signature(overflow),null);
    assert.equal(P.duplicate([bounded],overflow,2000,10),null);
    assert.equal(P.duplicate([overflow],bounded,2000,10),null);
    assert.equal(P.duplicate([overflow],overflow,2000,10),null);
    assert.equal(P.sourceKey(overflow),P.sourceKey(bounded));
    assert.equal(P.duplicate([bounded],bounded,2000,10),bounded);
});

test('dynamic images merge by verified pixels and never by unresolved provider handles', () => {
    const image = 'image://qsimage/1/2', next = 'image://qsimage/3/4';
    const fp = 'sha256:'+'a'.repeat(64), other = 'sha256:'+'b'.repeat(64);
    const first = row({image,imageFingerprint:fp});
    assert.equal(P.duplicate([first],row({image:next,imageFingerprint:fp}),2000,10),first);
    assert.equal(P.duplicate([first],row({image:next,imageFingerprint:other}),2000,10),null);
    for(const imageFingerprint of ['',undefined,'sha256:bad',image, 'sha256:'+'A'.repeat(64)]) {
        assert.equal(P.duplicate([first],row({image,imageFingerprint}),2000,10),null);
        assert.equal(P.duplicate([row({image,imageFingerprint})],first,2000,10),null);
    }
    assert.equal(P.duplicate([row({image})],row({image}),2000,10),null);
    for(const bad of [image+'?x',image+'\n','image://qsimage/../2','image://qsimageevil/1/2'])
        assert.equal(P.duplicate([row({image:bad,imageFingerprint:fp})],row({image:bad,imageFingerprint:fp}),2000,10),null);
    assert.equal(P.duplicate([row()],row(),2000,10).image,'');
    assert.equal(P.duplicate([row({appIcon:image,appIconFingerprint:fp})],
        row({appIcon:next,appIconFingerprint:fp}),2000,10).appIcon,image);
});

test('snooze, quiet and DND are independent gates; expiry admits only future arrivals', () => {
    const snoozes=[{key:'source',until:5000}];
    assert.equal(P.quietReason(false,false,snoozes,'source',4999),'snoozed');
    assert.equal(P.quietReason(false,false,snoozes,'source',5000),'');
    assert.equal(P.quietReason(true,false,snoozes,'source',6000),'dnd');
    assert.equal(P.quietReason(false,true,snoozes,'source',6000),'quiet');
    assert.deepEqual(P.activeSnoozes(snoozes,6000),[]);
});

test('source bursts and popup stacks are independently bounded without a replay queue', () => {
    let events=[];
    for(let i=0;i<5;i++){const r=P.burst(events,'a',1000,5); assert.ok(r.allowed); events=r.events;}
    assert.equal(P.burst(events,'a',2000,5).allowed,false);
    assert.equal(P.burst(events,'b',2000,5).allowed,true);
    assert.equal(P.burst(events,'a',11000,5).allowed,true);
    let toasts=[];
    for(let i=0;i<20;i++) toasts=P.popupPlan(toasts,row({key:String(i),sourceKey:'s'+i%4}),3,2);
    assert.ok(P.groups(toasts).length<=3);
    assert.ok(P.groups(toasts).every(group=>group.items.length<=2));
    const screens=[{name:'laptop'},{name:'external'}];
    assert.equal(P.targetScreen('laptop',screens,['laptop'],'away'),'external');
    assert.equal(P.targetScreen('laptop',screens,['laptop','external'],'away'),'');
    assert.equal(P.targetScreen('laptop',screens,['laptop'],'show'),'laptop');
    assert.equal(P.targetScreen('removed',screens,[],'away'),'laptop');
});

test('strict explicit URL offers reject alternate schemes, credentials, controls, numeric hosts and malformed escapes', () => {
    for(const url of ['javascript:alert(1)','file:///tmp/x','data:text/html,x','mailto:user@example.com?attach=x',
        'https://bank.example@evil.example','https://127.1','https://0x7f.0.0.0x1',
        'https://example.com/%0a','https://example.com/%250a','https://example.com/%zz',
        'https://example.com\\@evil.example','https://example.com:99999','https://[::1]',
        'https://example.com/\n','https://example.com/"hello'])
        assert.equal(S.safeExternalUrl(url),'',url);
    for(const url of ['https://example.com/','https://example.com/a?q=1&b=2','https://example.com/a%40b'])
        assert.equal(S.safeHttpUrl(url),url);
    assert.deepEqual(S.scan('Your verification code','is 482 913').codes,['482913']);
    assert.deepEqual(S.scan('Verification','A9F3K2').codes,['A9F3K2']);
    assert.deepEqual(S.scan('VS Code','build 482913').codes,[]);
    assert.deepEqual(S.scan('Order','482913').codes,[]);
});

test('persistence never copies code-bearing alternate fields, images or executable/live capabilities', () => {
    const secret=row({appName:'otp 482913',summary:'Your code',body:'482913',codes:['482913'],
        desktopEntry:'482913',webOrigin:'482913.example',webSourceIdentity:'https://482913.example:443',displaySummary:'482913',displayBody:'482913',
        rawBody:'482913',execArgv:['sh','-c','482913'],image:'data:482913',actions:[{text:'482913'}]});
    const stored=S.persistable(secret);
    assert.equal(stored.displaySummary,'Verification notification');
    assert.ok(!JSON.stringify(stored).includes('482913'));
    assert.deepEqual(Object.keys(stored).sort(),['appName','arrived','desktopEntry','displayAppName','displayBody','displaySummary','occurrences','urgency','webOrigin','webSourceIdentity'].sort());
    assert.equal(stored.webSourceIdentity,'');
    const normal=S.persistable(row({execArgv:['sh','-c','evil'],actions:[{}],notif:{},image:'data:image/png,x',
        imageFingerprint:'sha256:'+'a'.repeat(64),appIconFingerprint:'sha256:'+'b'.repeat(64)}));
    for(const field of ['execArgv','actions','notif','image','imageFingerprint','appIconFingerprint','summary','body','actionSignature','sourceKey','codes','links'])
        assert.equal(normal[field],undefined,field);
    const identityOnly=S.persistable(row({webOrigin:'code.example',webSourceIdentity:'https://code.example:48291'}));
    assert.equal(identityOnly.webSourceIdentity,'');
    assert.equal(identityOnly.displaySummary,'Verification notification');
});

// Execute the actual service functions and notification subscriptions, with
// fake QObject signals. This tests lifecycle logic, not QML or compositor load.
function service(){
    const source=fs.readFileSync(path.join(shellDir,'Common/Notifs.qml'),'utf8');
    const queue=[];
    const context={Helpers:H,Policy:P,Smart:S,Format:load('Format.js'),console,Date, NotificationUrgency:{Normal:1,Critical:2},
        BrandIcons:{has:()=>false},Settings:{notifHistoryCount:50,notifDedupeSeconds:10,notifBurstLimit:5,
            notifPopupGroups:3,notifPopupPerGroup:3,notifFullscreen:'away',notifDuration:8},
        Screens:{focused:{name:'one'}},Quickshell:{screens:[{name:'one'}]},Qt:{callLater:fn=>{if(!queue.includes(fn))queue.push(fn);}},
        entries:[],toasts:[],snoozes:[],burstEvents:[],heldGroups:{},fullscreenOutputs:[],dnd:false,quietActive:false,
        localSerial:0,historyGeneration:0,historyProcess:{running:false},historyWrite:{stop(){}},fingerprintImage:()=>'',
        I18n:{tr:s=>s},queue};
    context.root=context;
    context.groupHoldQueue=Holds.create(context.Qt.callLater,groups=>{context.heldGroups=groups;});
    context.historyRetention={stop(){},start(){}};
    context.snoozeTimer={stop(){},start(){}};
    context.dndTimer={stop(){},start(){}};
    context.Settings.notifHistoryHours=24;
    context.Settings.set=(name,value)=>{context.Settings[name]=value;if(name==='notifDnd')context.dnd=value;};
    vm.createContext(context);
    for(const name of ['describe','remoteSource','publish','updateEntry','removeEntry','hideToast','dismiss','invoke',
        'defaultAction','secondaryActions','canActivate','invokeDefault','timeoutFor','send','clearAll',
        'historyReply','queueHistory','pruneHistory','scheduleRetention','setDndMode','setDnd','scheduleDndTick',
        'snoozeSource','unsnooze','scheduleSnoozes','holdGroup']){
        const match=source.match(new RegExp('^    function '+name+'\\([^]*?^    }','m'));
        assert.ok(match,name);
        vm.runInContext(match[0],context);
    }
    context.replaceableSignals=['appNameChanged','appIconChanged','desktopEntryChanged','hintsChanged','imageChanged',
        'summaryChanged','bodyChanged','urgencyChanged','expireTimeoutChanged','actionsChanged'];
    const start=source.indexOf('        onNotification: notif => {')+'        onNotification: '.length;
    const end=source.indexOf('\n        }\n    }',start)+'\n        }'.length;
    context.receive=vm.runInContext('('+source.slice(start,end)+')',context);
    context.flush=()=>{while(queue.length)queue.shift()();};
    return context;
}
function sender(summary='Hello',body='Message',extra={}){
    const value={appName:'Chat',desktopEntry:'chat',summary,body,urgency:1,actions:[],hints:{},expireTimeout:-1,...extra};
    for(const name of ['closed','appNameChanged','appIconChanged','desktopEntryChanged','hintsChanged','imageChanged',
        'summaryChanged','bodyChanged','urgencyChanged','expireTimeoutChanged','actionsChanged']){
        const handlers=[];
        value[name]={connect:fn=>handlers.push(fn),disconnect:fn=>{const i=handlers.indexOf(fn);if(i>=0)handlers.splice(i,1);},
            emit:()=>handlers.slice().forEach(fn=>fn())};
    }
    value.expire=()=>value.closed.emit(); value.dismiss=value.expire;
    return value;
}

test('service hold updates defer QML writes but gate arrivals immediately during delegate churn',()=>{
    const c=service(),owner={},replacement={};
    const key=P.sourceKey(row());
    let inBinding=true,writes=0,snapshot=c.heldGroups;
    Object.defineProperty(c,'heldGroups',{get(){return snapshot;},set(value){
        assert.equal(inBinding,false,'reactive publication reentered screenGroups model evaluation');
        writes++;snapshot=value;
    }});
    c.holdGroup(key,false,owner);
    c.holdGroup(key,true,owner);
    c.receive(sender('Held before the deferred publish','message'));
    assert.equal(c.toasts.length,0);assert.equal(c.entries.length,1);assert.equal(writes,0);
    inBinding=false;c.flush();assert.equal(snapshot[key],true);assert.equal(writes,1);
    inBinding=true;
    c.holdGroup(key,true,replacement);c.holdGroup(key,false,owner);
    c.receive(sender('Still held after old deck destruction','message'));
    assert.equal(c.toasts.length,0);
    inBinding=false;c.flush();assert.equal(writes,1,'replacement must preserve one aggregate hold');
    c.holdGroup(key,false,replacement);c.flush();assert.equal(snapshot[key],undefined);
    assert.equal(c.toasts.length,0,'released holds never replay history');
    c.receive(sender('New after release','message'));assert.equal(c.toasts.length,1);
});

test('qualified origins separate dedupe, popup groups and snoozes while default ports agree', () => {
    const c=service();
    const web=(origin,summary='Hello')=>sender(summary,'Message',{appName:'Chromium',desktopEntry:'chromium',
        hints:{'x-kde-origin-name':origin}});
    c.receive(web('https://chat.example'));
    const secure=c.entries[0];
    c.receive(web('HTTPS://CHAT.EXAMPLE:443/'));
    assert.equal(c.entries.length,1);assert.equal(c.entries[0].occurrences,2);
    for(const origin of ['https://chat.example:8443','http://chat.example','chat.example','https://chat.example.'])c.receive(web(origin));
    assert.equal(c.entries.length,5);
    assert.equal(new Set(c.entries.map(e=>e.sourceKey)).size,5);
    assert.equal(P.groups(c.entries).length,5);
    c.snoozeSource(secure.sourceKey,'https://chat.example:443',15);
    assert.equal(c.toasts.some(e=>e.sourceKey===secure.sourceKey),false);
    c.receive(web('https://chat.example:443','Muted'));
    assert.equal(c.toasts.some(e=>e.sourceKey===secure.sourceKey),false);
    c.receive(web('https://chat.example:8443','Other port'));
    assert.equal(c.toasts[0].webSourceIdentity,'https://chat.example:8443');
    c.unsnooze(secure.sourceKey);
    assert.equal(c.toasts.some(e=>e.sourceKey===secure.sourceKey),false);
    c.receive(web('https://chat.example','Future arrival'));
    assert.equal(c.toasts[0].sourceKey,secure.sourceKey);
});

test('restored origin identity preserves qualified sources and migrates legacy hosts conservatively', () => {
    const c=service();c.historyGeneration=1;c.Settings.notifHistoryPersist=true;
    c.historyReply(JSON.stringify({id:1,ok:true,op:'read',entries:[
        row({webOrigin:'chat.example',webSourceIdentity:'https://chat.example:443'}),
        row({webOrigin:'chat.example',webSourceIdentity:'https://chat.example:8443'}),
        row({webOrigin:'chat.example'}),
        row({webOrigin:'chat.example',webSourceIdentity:'https://chat.example:443/private?token=secret'}),
        row({webOrigin:'chat.example',webSourceIdentity:'https://other.example:443'}),
    ].map(item=>({...item,arrived:Date.now()}))}));
    assert.deepEqual(Array.from(c.entries,e=>e.webSourceIdentity),[
        'https://chat.example:443','https://chat.example:8443','unqualified:chat.example',
        'unqualified:chat.example','unqualified:chat.example']);
    assert.equal(new Set(c.entries.map(e=>e.sourceKey)).size,3);
    c.snoozeSource(c.entries[0].sourceKey,'secure',15);
    assert.equal(P.quietReason(false,false,c.snoozes,c.entries[1].sourceKey,Date.now()),'');
    assert.equal(P.quietReason(false,false,c.snoozes,c.entries[2].sourceKey,Date.now()),'');
    assert.ok(c.entries.every(e=>!c.canActivate(e)));
});

test('service obtains content identities and preserves distinct or unresolved attached images', () => {
    const c=service(), fp='sha256:'+'a'.repeat(64), other='sha256:'+'b'.repeat(64);
    const identities={'image://qsimage/1/2':fp,'image://qsimage/3/4':fp,'image://qsimage/5/6':other};
    c.fingerprintImage=source=>identities[source]||'';
    c.receive(sender('Hello','Message',{image:'image://qsimage/1/2'}));
    c.receive(sender('Hello','Message',{image:'image://qsimage/3/4'}));
    assert.equal(c.entries.length,1);
    assert.equal(c.entries[0].occurrences,2);
    assert.equal(c.entries[0].image,'image://qsimage/3/4');
    c.receive(sender('Hello','Message',{image:'image://qsimage/5/6'}));
    assert.equal(c.entries.length,2);
    c.receive(sender('Hello','Message',{image:'image://qsimage/9/9'}));
    c.receive(sender('Hello','Message',{image:'image://qsimage/9/9'}));
    assert.equal(c.entries.length,4);
});

test('service keeps opaque action IDs exact without merging or expiring distinct senders', () => {
    for (const [firstId, secondId] of [['OPEN','open'], ['open',' open'], ['open','open '],
        ['open item','open  item'], ['open','<b>open</b>'], ['a&b','a&amp;b'], ['caf\u00e9','cafe\u0301']]) {
        const c=service(); c.Date={now:()=>1000};
        const first=sender('Hello','Message',{actions:[{identifier:firstId,text:'Open'}]});
        const second=sender('Hello','Message',{actions:[{identifier:secondId,text:'Open'}]});
        let expired=0; first.closed.connect(()=>expired++);
        c.receive(first); const firstKey=c.entries[0].key;
        c.receive(second);
        assert.equal(c.entries.length,2,JSON.stringify([firstId,secondId]));
        assert.equal(c.toasts.length,2);
        assert.equal(expired,0,'a distinct action must not expire the earlier sender');
        const retained=c.entries.find(entry=>entry.notif===first);
        assert.equal(retained.key,firstKey); assert.equal(retained.live,true);
        assert.notEqual(c.entries[0].key,firstKey);
        assert.ok(c.entries.every(entry=>entry.occurrences===1 && entry.arrived===1000));
        assert.equal(retained.actionSignature,JSON.stringify([[firstId,'Open']]));
        assert.equal(c.entries[0].actionSignature,JSON.stringify([[secondId,'Open']]));
    }
});

test('service dedupes identical opaque action IDs with equivalent visible labels and transfers live actions', () => {
    const c=service(); c.Date={now:()=>1000};
    let expired=0,invoked=0;
    const first=sender('Hello','Message',{actions:[{identifier:'OPEN',text:'<b>Open</b>',invoke:()=>invoked++}]});
    const second=sender('Hello','Message',{actions:[{identifier:'OPEN',text:' Open ',invoke:()=>invoked++}]});
    first.closed.connect(()=>expired++);
    c.receive(first); const key=c.entries[0].key;
    c.Date={now:()=>2000}; c.receive(second);
    assert.equal(c.entries.length,1); assert.equal(c.toasts.length,1);
    const entry=c.entries[0];
    assert.equal(entry.key,key); assert.equal(entry.arrived,1000); assert.equal(entry.occurrences,2);
    assert.equal(entry.actionSignature,JSON.stringify([['OPEN','Open']]));
    assert.equal(entry.notif,second); assert.equal(entry.live,true); assert.equal(expired,1);
    assert.equal(entry.actions,second.actions);
    c.invoke(entry,first.actions[0]); assert.equal(invoked,0,'superseded action handles stay invalid');
    c.invoke(entry,second.actions[0]); assert.equal(invoked,1);
});

test('service replacements update exact action IDs in place before later dedupe', () => {
    const c=service(); c.Date={now:()=>1000};
    const first=sender('Hello','Message',{actions:[{identifier:'OPEN',text:'Open'}]});
    let expired=0; first.closed.connect(()=>expired++);
    c.receive(first); const key=c.entries[0].key;
    first.actions=[{identifier:'open',text:'Open'}];
    first.actionsChanged.emit(); first.actionsChanged.emit(); c.flush();
    assert.equal(c.entries.length,1); assert.equal(c.entries[0].key,key);
    assert.equal(c.entries[0].occurrences,1); assert.equal(c.entries[0].revision,1);
    assert.equal(c.entries[0].actionSignature,JSON.stringify([['open','Open']]));
    assert.equal(c.entries[0].actions,first.actions); assert.equal(expired,0);
    const distinct=sender('Hello','Message',{actions:[{identifier:'OPEN',text:'Open'}]});
    c.receive(distinct); assert.equal(c.entries.length,2); assert.equal(expired,0);
    const duplicate=sender('Hello','Message',{actions:[{identifier:'open',text:'Open'}]});
    c.receive(duplicate); assert.equal(c.entries.length,2); assert.equal(expired,1);
    const updated=c.entries.find(entry=>entry.key===key);
    assert.equal(updated.notif,duplicate); assert.equal(updated.live,true); assert.equal(updated.occurrences,2);
    assert.ok(c.entries.some(entry=>entry.notif===distinct && entry.live && entry.occurrences===1));
});

test('service never dedupes incoming or existing action overflow or expires either live sender', () => {
    const actions=count=>Array.from({length:count},(_,i)=>({identifier:'action-'+i,text:'Action '+i}));
    const label=text=>[{identifier:'OPEN',text}];
    const id=identifier=>[{identifier,text:'Open'}];
    const seventeenthId=actions(17); seventeenthId[16].identifier='different';
    const seventeenthLabel=actions(17); seventeenthLabel[16].text='Different';
    for (const [name, firstActions, secondActions, firstOverflow, secondOverflow] of [
        ['action 17 ID',actions(17),seventeenthId,true,true],
        ['action 17 label',actions(17),seventeenthLabel,true,true],
        ['incoming action 17',actions(16),actions(17),false,true],
        ['existing action 17',actions(17),actions(16),true,false],
        ['label suffix after 256',label('x'.repeat(256)+'A'),label('x'.repeat(256)+'B'),true,true],
        ['incoming label overflow',label('x'.repeat(256)),label('x'.repeat(257)),false,true],
        ['existing label overflow',label('x'.repeat(257)),label('x'.repeat(256)),true,false],
        ['incoming cleaned label overflow',label('&'.repeat(256)),label('<b>'+'&amp;'.repeat(257)+'</b>'),false,true],
        ['existing cleaned label overflow',label('<b>'+'&amp;'.repeat(257)+'</b>'),label('&'.repeat(256)),true,false],
        ['incoming ID overflow',id('I'.repeat(256)),id('I'.repeat(257)),false,true],
        ['existing ID overflow',id('I'.repeat(257)),id('I'.repeat(256)),true,false],
    ]) {
        const c=service(); c.Date={now:()=>1000};
        const invoked=[0,0];
        firstActions[0].invoke=()=>invoked[0]++;
        secondActions[0].invoke=()=>invoked[1]++;
        const first=sender('Hello','Message',{actions:firstActions});
        const second=sender('Hello','Message',{actions:secondActions});
        let expired=0; first.closed.connect(()=>expired++); second.closed.connect(()=>expired++);
        c.receive(first); const firstKey=c.entries[0].key;
        c.Date={now:()=>2000}; c.receive(second);
        assert.equal(c.entries.length,2,name);
        assert.equal(c.toasts.length,2,name);
        assert.equal(expired,0,name+': distinct live senders must not expire');
        const retained=c.entries.find(entry=>entry.notif===first), incoming=c.entries[0];
        assert.equal(retained.key,firstKey); assert.equal(retained.arrived,1000);
        assert.notEqual(incoming.key,firstKey); assert.equal(incoming.arrived,2000);
        assert.equal(retained.actionSignature===null,firstOverflow,name);
        assert.equal(incoming.actionSignature===null,secondOverflow,name);
        assert.ok(c.entries.every(entry=>entry.live && entry.occurrences===1 && !entry.oversized));
        assert.equal(retained.sourceKey,incoming.sourceKey,'action overflow must not alter source routing');
        assert.equal(retained.actions,firstActions); assert.equal(incoming.actions,secondActions);
        assert.equal(P.duplicate([incoming],retained,2000,10),null,name+': reverse comparison');
        c.invoke(retained,firstActions[0]); c.invoke(incoming,secondActions[0]);
        assert.deepEqual(invoked,[1,1],name+': original action handles remain usable');
        assert.equal(expired,0);
    }
});

test('service compares action 16 and cleaned character 256 exactly and dedupes at both limits', () => {
    const actions=()=>Array.from({length:16},(_,i)=>({identifier:'action-'+i,text:'Open'}));
    for (const field of ['identifier','text']) {
        const c=service(); c.Date={now:()=>1000};
        const firstActions=actions(), secondActions=actions();
        firstActions[15][field]='x'.repeat(255)+'A';
        secondActions[15][field]='x'.repeat(255)+'B';
        const first=sender('Hello','Message',{actions:firstActions});
        let expired=0; first.closed.connect(()=>expired++);
        c.receive(first); c.receive(sender('Hello','Message',{actions:secondActions}));
        assert.equal(c.entries.length,2,field+': character 256 of action 16 differs');
        assert.equal(expired,0); assert.ok(c.entries.every(entry=>entry.actionSignature!==null));
    }
    const c=service(); c.Date={now:()=>1000};
    const firstActions=actions(), secondActions=actions();
    firstActions[15]={identifier:'I'.repeat(256),text:'&'.repeat(256)};
    secondActions[15]={identifier:'I'.repeat(256),text:' <b>'+'&amp;'.repeat(256)+'</b>\u200b '};
    const first=sender('Hello','Message',{actions:firstActions});
    const second=sender('Hello','Message',{actions:secondActions});
    let expired=0; first.closed.connect(()=>expired++);
    c.receive(first); const key=c.entries[0].key;
    c.Date={now:()=>2000}; c.receive(second);
    assert.equal(c.entries.length,1); assert.equal(c.toasts.length,1); assert.equal(expired,1);
    const entry=c.entries[0];
    assert.equal(entry.key,key); assert.equal(entry.arrived,1000); assert.equal(entry.occurrences,2);
    assert.equal(entry.notif,second); assert.equal(entry.actions,secondActions);
    assert.equal(JSON.parse(entry.actionSignature).length,16);
    assert.deepEqual(JSON.parse(entry.actionSignature)[15],['I'.repeat(256),'&'.repeat(256)]);
});

test('action overflow preserves native and web snoozes, popup groups and burst accounting', () => {
    for (const identity of [{}, {appName:'Chromium',desktopEntry:'chromium',
        hints:{'x-kde-origin-name':'https://chat.example:8443'}}]) {
        const c=service(); c.Date={now:()=>1000};
        const actions=Array.from({length:17},(_,i)=>({identifier:'action-'+i,text:'Open'}));
        c.receive(sender('Hello','Message',{...identity,actions}));
        const key=c.entries[0].sourceKey;
        c.receive(sender('Hello','Message',{...identity,actions:actions.slice(0,16)}));
        assert.equal(c.entries.length,2); assert.equal(c.toasts.length,2);
        assert.equal(P.groups(c.entries).length,1);
        assert.ok(c.entries.every(entry=>entry.sourceKey===key && !entry.oversized));
        assert.equal(c.burstEvents.length,2); assert.ok(c.burstEvents.every(event=>event.key===key));
        c.snoozeSource(key,'Chat',15);
        assert.equal(c.toasts.length,0);
        c.receive(sender('During snooze','Message',{...identity,actions}));
        assert.equal(c.entries.length,3); assert.equal(c.toasts.length,0);
        assert.ok(c.entries.every(entry=>entry.sourceKey===key && entry.live));
        assert.equal(c.burstEvents.length,2,'snoozed arrivals do not consume another burst slot');
    }
});

test('replacement action overflow disables dedupe until a complete bounded signature is restored', () => {
    const c=service(); c.Date={now:()=>1000};
    const first=sender('Hello','Message',{actions:[{identifier:'OPEN',text:'Open'}]});
    let expired=0; first.closed.connect(()=>expired++);
    c.receive(first); const original=c.entries[0];
    first.actions=[{identifier:'OPEN',text:'Open'+'x'.repeat(253)}];
    first.actionsChanged.emit(); c.flush();
    const overflow=c.entries[0];
    assert.equal(overflow.key,original.key); assert.equal(overflow.sourceKey,original.sourceKey);
    assert.equal(overflow.revision,1); assert.equal(overflow.occurrences,1);
    assert.equal(overflow.actionSignature,null); assert.equal(overflow.actions,first.actions);
    c.receive(sender('Hello','Message',{actions:[{identifier:'OPEN',text:'Open'+'x'.repeat(252)}]}));
    assert.equal(c.entries.length,2); assert.equal(expired,0);
    first.actions=[{identifier:'OPEN',text:'<b>Open</b>'}];
    first.actionsChanged.emit(); c.flush();
    const restored=c.entries.find(entry=>entry.key===original.key);
    assert.equal(restored.revision,2); assert.equal(restored.actionSignature,JSON.stringify([['OPEN','Open']]));
    const duplicate=sender('Hello','Message',{actions:[{identifier:'OPEN',text:' Open '}]});
    c.receive(duplicate);
    assert.equal(c.entries.length,2); assert.equal(expired,1);
    const merged=c.entries.find(entry=>entry.key===original.key);
    assert.equal(merged.notif,duplicate); assert.equal(merged.occurrences,2);
    assert.equal(merged.arrived,original.arrived); assert.equal(merged.sourceKey,original.sourceKey);
});

test('real service replaces in place, counts duplicates and ignores superseded sender close/update signals', () => {
    const c=service(), first=sender(); c.receive(first);
    first.body='Progress changed'; first.bodyChanged.emit(); first.summaryChanged.emit(); c.flush();
    assert.equal(c.entries.length,1); assert.equal(c.entries[0].body,'Progress changed');
    assert.equal(c.entries[0].occurrences,1); assert.equal(c.entries[0].revision,1);
    const second=sender('Hello','Progress changed'); c.receive(second);
    assert.equal(c.entries.length,1); assert.equal(c.entries[0].occurrences,2);
    assert.equal(c.entries[0].notif,second); assert.equal(c.entries[0].live,true);
    first.closed.emit(); first.bodyChanged.emit(); c.flush();
    assert.equal(c.entries[0].notif,second);
    second.closed.emit(); assert.equal(c.entries[0].live,false); assert.equal(c.entries[0].actions.length,0);
});

test('real service preserves distinct messages, bounds bursts, honors all quiet gates and rejects dead actions', () => {
    const c=service();
    for(let i=0;i<8;i++)c.receive(sender('Same title','Message '+i));
    assert.equal(c.entries.length,8); assert.ok(c.toasts.length<=3);
    const sent=sender('Quiet','Your code 482913'); c.dnd=true; c.receive(sent);
    assert.equal(c.entries[0].summary,'Quiet'); assert.ok(!c.toasts.some(e=>e.summary==='Quiet'));
    c.dnd=false; assert.ok(!c.toasts.some(e=>e.summary==='Quiet'));
    c.quietActive=true; c.receive(sender('Scheduled','message')); assert.ok(!c.toasts.some(e=>e.summary==='Scheduled'));
    c.quietActive=false;
    c.snoozes=[{key:P.sourceKey(row()),until:Date.now()+10000}]; c.receive(sender('Snoozed','message'));
    assert.ok(!c.toasts.some(e=>e.summary==='Snoozed'));
    let invoked=0; const action={identifier:'default',text:'Open',invoke:()=>invoked++};
    const actionable=sender('Action','message',{actions:[action]}); c.receive(actionable);
    const old=c.entries[0]; actionable.closed.emit(); c.invoke(old,action);
    assert.equal(invoked,0);
});


test('actual service expires timed DND and snoozes independently of quiet hours without replay', () => {
    const c=service(); c.startupApplied=true;
    c.setDndMode('1h'); assert.ok(c.dnd); assert.ok(c.Settings.notifDndUntilMs>Date.now());
    c.receive(sender('Held by DND','message'));
    c.Settings.notifDndUntilMs=Date.now()-1; c.scheduleDndTick();
    assert.equal(c.dnd,false); assert.equal(c.Settings.notifDndUntilMs,0);
    assert.equal(c.toasts.length,0);
    const key=P.sourceKey(row()); c.snoozeSource(key,'Chat',15);
    c.receive(sender('Held by snooze','message')); assert.equal(c.toasts.length,0);
    c.snoozes=c.snoozes.map(s=>({...s,until:Date.now()-1})); c.quietActive=true;c.scheduleSnoozes();
    assert.equal(c.snoozes.length,0); c.receive(sender('Held by quiet','message'));assert.equal(c.toasts.length,0);
    c.quietActive=false; assert.equal(c.toasts.length,0);
    c.receive(sender('New after expiry','message')); assert.equal(c.toasts.length,1);
});

test('actual restore has no dead handles, ignores obsolete reads, retains current arrivals and redacts again', () => {
    const c=service(); c.historyGeneration=3;c.Settings.notifHistoryPersist=true;
    c.receive(sender('Live while reading','message'));
    c.historyReply(JSON.stringify({id:2,ok:true,op:'read',entries:[row()]}));assert.equal(c.entries.length,1);
    const secret=row({arrived:Date.now(),displaySummary:'Your verification code 482913',displayBody:'482913',actions:[{text:'Run'}],
        execArgv:['sh','-c','482913'],image:'data:482913'});
    c.historyReply(JSON.stringify({id:3,ok:true,op:'read',entries:[secret]}));
    assert.equal(c.entries.length,2);assert.equal(c.entries[0].summary,'Live while reading');
    const restored=c.entries[1];assert.equal(restored.live,false);assert.equal(restored.notif,null);
    assert.equal(restored.actions.length,0);assert.equal(restored.codes.length,0);assert.equal(restored.links.length,0);
    assert.equal(restored.image,'');assert.equal(c.canActivate(restored),false);
    assert.ok(!JSON.stringify(restored).includes('482913'));
    assert.ok(c.secondaryActions(restored).every(a=>a.kind==='snooze'));
});
