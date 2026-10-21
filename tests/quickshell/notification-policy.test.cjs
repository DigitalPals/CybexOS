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
