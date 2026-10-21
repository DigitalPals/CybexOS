const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {spawnSync} = require('node:child_process');
const {shellDir} = require('./shell.cjs');
const helper=path.join(shellDir,'scripts/notification-history.py');
const row=(extra={})=>({arrived:Date.now(),appName:'Chat',desktopEntry:'chat',webOrigin:'',displayAppName:'Chat',
    displaySummary:'Hello',displayBody:'Safe message',occurrences:1,urgency:1,...extra});
function fixture(t){
    const base=fs.mkdtempSync(path.join(os.tmpdir(),'cybexos-notification-history-'));
    t.after(()=>fs.rmSync(base,{force:true,recursive:true}));
    const directory=path.join(base,'cybexos/notifications');
    return {base,directory,file:path.join(directory,'history.json')};
}
function run(env,requests){
    const child=spawnSync('python3',['-B','-u',helper],{encoding:'utf8',env:{...process.env,XDG_STATE_HOME:env.base},
        input:requests.map((r,i)=>JSON.stringify({id:i,count:50,hours:24,bytes:262144,...r})).join('\n')+'\n'});
    assert.equal(child.status,0,child.stderr);
    assert.equal(child.stderr,'');
    return child.stdout.trim().split('\n').filter(Boolean).map(line=>JSON.parse(line));
}

test('one long-lived helper writes atomically, restores across process restart and keeps all data private',t=>{
    const env=fixture(t);
    const replies=run(env,[{op:'write',entries:[row()]},{op:'read'}]);
    assert.ok(replies.every(r=>r.ok)); assert.equal(replies[1].entries[0].displayBody,'Safe message');
    assert.equal(fs.statSync(env.directory).mode & 0o777,0o700);
    assert.equal(fs.statSync(env.file).mode & 0o777,0o600);
    assert.deepEqual(fs.readdirSync(env.directory),['history.json']);
    const restarted=run(env,[{op:'read'}]); assert.equal(restarted[0].entries.length,1);
    for(const field of ['live','notif','actions','image','code','codes','links','execArgv','senderPid'])
        assert.ok(!Object.hasOwn(restarted[0].entries[0],field),field);
});

test('code redaction covers raw, displayed, encoded, alternate, nested and sensitive derived fields',t=>{
    const env=fixture(t);
    const cases=[
        row({displaySummary:'Your verification code is 482913',displayBody:'482913',appName:'482913',desktopEntry:'482913',webOrigin:'482913.example',webSourceIdentity:'https://482913.example:443'}),
        row({rawBody:'Your OTP is &#52;&#56;&#50;&#57;&#49;&#51;',displayBody:'482913'}),
        row({summary:'Your code',body:'482913',displayBody:'482913'}),
        row({codes:['482913'],appName:'482913',displayBody:'482913'}),
        row({derived:{nested:{body:'verification code 482913'}},displaySummary:'482913'}),
        row({summary:'Your code',alternate:'482913',displaySummary:'482913'}),
        row({webOrigin:'code.example',webSourceIdentity:'https://code.example:48291'}),
    ];
    const replies=run(env,[{op:'write',entries:cases},{op:'read'}]);
    assert.ok(replies.every(r=>r.ok));
    const disk=fs.readFileSync(env.file,'utf8'); assert.ok(!disk.includes('482913'));
    for(const entry of replies[1].entries){
        assert.equal(entry.displaySummary,'Verification notification');
        assert.equal(entry.appName,'Notification'); assert.equal(entry.desktopEntry,''); assert.equal(entry.webOrigin,'');
        assert.equal(entry.webSourceIdentity,'');
    }
});

test('restart preserves qualified origins, migrates old hosts without guessing and drops unsafe identity data',t=>{
    const env=fixture(t);
    const cases=[
        row({webOrigin:'chat.example',webSourceIdentity:'https://chat.example:443'}),
        row({webOrigin:'chat.example',webSourceIdentity:'https://chat.example:8443'}),
        row({webOrigin:'chat.example',webSourceIdentity:'http://chat.example:80'}),
        row({webOrigin:'chat.example'}),
        row({webOrigin:'chat.example',webSourceIdentity:'unqualified:chat.example:8443'}),
        row({webOrigin:'[2001:db8:0:0:0:0:0:1]',webSourceIdentity:'https://[2001:db8:0:0:0:0:0:1]:443'}),
        row({webOrigin:'chat.example',webSourceIdentity:'https://chat.example.:443'}),
        row({webOrigin:'chat.example',webSourceIdentity:'https://chat.example:443/private?token=do-not-store#secret'}),
        row({webOrigin:'chat.example',webSourceIdentity:'https://user:pass@chat.example:443'}),
        row({webOrigin:'chat.example',webSourceIdentity:'https://other.example:443'}),
        row({webOrigin:'chat.example',webSourceIdentity:'https://chat.example:0'}),
        row({webOrigin:'chat.example',webSourceIdentity:'https://chat.example:65536'}),
        row({webOrigin:'chat.example',webSourceIdentity:'x'.repeat(10000)}),
    ];
    const now=Date.now();cases.forEach(entry=>{entry.arrived=now;});
    assert.ok(run(env,[{op:'write',entries:cases}])[0].ok);
    const entries=run(env,[{op:'read'}])[0].entries;
    assert.deepEqual(entries.map(e=>e.webSourceIdentity),[
        'https://chat.example:443','https://chat.example:8443','http://chat.example:80',
        'unqualified:chat.example','unqualified:chat.example:8443',
        'https://[2001:db8:0:0:0:0:0:1]:443','https://chat.example.:443',...Array(6).fill('unqualified:chat.example')]);
    const disk=fs.readFileSync(env.file,'utf8');
    for(const secret of ['do-not-store','/private','user:pass','other.example','x'.repeat(321)])assert.ok(!disk.includes(secret));
    // Read an actual earlier v1 store lacking the additive identity field.
    fs.writeFileSync(env.file,JSON.stringify({v:1,entries:[row({webOrigin:'chat.example'})]}));
    const legacy=run(env,[{op:'read'}])[0].entries[0];
    assert.equal(legacy.webSourceIdentity,'unqualified:chat.example');
    assert.equal(JSON.parse(fs.readFileSync(env.file,'utf8')).entries[0].webSourceIdentity,legacy.webSourceIdentity);
});

test('count, age and actual encoded storage bytes apply together, including malicious numbers',t=>{
    const env=fixture(t),now=Date.now();
    const entries=Array.from({length:100},(_,i)=>row({arrived:now-i,displayBody:'🙂'.repeat(4096)}));
    entries.push(row({arrived:now-48*3600000}),row({arrived:now+120000}));
    const result=run(env,[{op:'write',count:10,hours:1,bytes:16384,entries},{op:'read',count:10,hours:1,bytes:16384}]);
    assert.ok(result.every(r=>r.ok));
    assert.ok(result[1].entries.length<=10); assert.ok(fs.statSync(env.file).size<=16384);
    assert.ok(result[1].entries.every(entry=>entry.arrived>=now-100));
    run(env,[{op:'write',entries:[row({arrived:now-2*3600000}),row({arrived:now}),row({arrived:'bad'}),row({arrived:true})]}]);
    assert.equal(run(env,[{op:'read',hours:1}])[0].entries.length,1);
});

test('corrupt, oversized, wrong-shape and unsafe-permission files recover to a bounded empty store',t=>{
    const env=fixture(t); fs.mkdirSync(env.directory,{recursive:true});
    for(const contents of ['{broken','[]','{"v":9,"entries":[]}','x'.repeat(1048577),'{"v":1,"entries":{}}']){
        fs.writeFileSync(env.file,contents,{mode:0o600}); fs.chmodSync(env.file,0o600);
        const reply=run(env,[{op:'read'}])[0]; assert.ok(reply.ok); assert.deepEqual(reply.entries,[]);
        assert.deepEqual(JSON.parse(fs.readFileSync(env.file,'utf8')),{v:1,entries:[]});
    }
    run(env,[{op:'write',entries:[row()]}]); fs.chmodSync(env.file,0o644);
    const reply=run(env,[{op:'read'}])[0]; assert.deepEqual(reply.entries,[]);
    assert.equal(fs.statSync(env.file).mode&0o777,0o600);
});

test('symlinked files are replaced safely, directory symlinks fail closed and clear never follows links',t=>{
    const env=fixture(t); fs.mkdirSync(env.directory,{recursive:true});
    const outside=path.join(env.base,'outside'); fs.writeFileSync(outside,'untouched'); fs.symlinkSync(outside,env.file);
    assert.ok(run(env,[{op:'write',entries:[row()]}])[0].ok);
    assert.equal(fs.readFileSync(outside,'utf8'),'untouched'); assert.equal(fs.lstatSync(env.file).isSymbolicLink(),false);
    fs.unlinkSync(env.file); fs.symlinkSync(outside,env.file);
    assert.ok(run(env,[{op:'clear'}])[0].ok); assert.equal(fs.existsSync(env.file),false);
    assert.equal(fs.readFileSync(outside,'utf8'),'untouched');
    fs.rmdirSync(env.directory); fs.symlinkSync(env.base,env.directory);
    assert.equal(run(env,[{op:'write',entries:[row()]}])[0].ok,false);
    assert.equal(fs.existsSync(path.join(env.base,'history.json')),false);
});

test('disabling history creates no storage, clear deletes only owned history and strips all executable/image payloads',t=>{
    const env=fixture(t);
    assert.ok(run(env,[{op:'clear'}])[0].ok); assert.equal(fs.existsSync(env.directory),false);
    const malicious=row({actions:[{text:'Run',command:'evil'}],execArgv:['sh','-c','evil'],
        image:'data:image/png;evildata',appIcon:'https://evil.example/a',rawBody:'secret alternate',
        links:['file:///etc/passwd'],notif:{id:55},key:'__proto__',sourceKey:'forged'});
    assert.ok(run(env,[{op:'write',entries:[malicious]}])[0].ok);
    const contents=fs.readFileSync(env.file,'utf8');
    for(const value of ['evil','secret alternate','file:///etc/passwd','forged','__proto__'])assert.ok(!contents.includes(value),value);
    fs.writeFileSync(path.join(env.directory,'keep'),'user data');
    run(env,[{op:'clear'}]); assert.equal(fs.existsSync(env.file),false);
    assert.equal(fs.readFileSync(path.join(env.directory,'keep'),'utf8'),'user data');
});
