// DXSpider Web 2.8.7
// Date: 2026-09-16
'use strict';
const $=id=>document.getElementById(id);
let ws=null, authenticated=false, logoutPending=false, authUser=null, authRegistered=false, passwordUsed=false, activeTab='spots';
let spotItems=[], spotCounts={human:0,rbn:0}, logs={ann:[],wwv:[],wcy:[],wx:[]};
let cmdHistory=[], historyPos=0, pendingCommandTargets=[];

function send(o){if(!(ws&&ws.readyState===WebSocket.OPEN))return false;ws.send(JSON.stringify(o));return true}
function esc(v){return String(v??'').replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]))}
function setCount(k,n){const e=document.querySelector(`[data-count="${k}"]`);if(e)e.textContent=String(n)}
function loginState(ok,m={}){
 authenticated=ok;document.body.classList.toggle('authenticated',ok);document.body.classList.toggle('anonymous',!ok); authUser=ok?(m.call||authUser):null;authRegistered=ok?Boolean(m.registered):false;passwordUsed=ok?Boolean(m.password_used):false;
 $('loginButton').textContent=ok?`Logout ${authUser}`:'Login';
 updateRegistrationAccess();
}
function updateRegistrationAccess(){
 const loggedIn=authenticated,registered=authenticated&&authRegistered;
 document.querySelectorAll('.tabs button[data-tab]').forEach(b=>b.classList.toggle('loginRestricted',!loggedIn&&(b.dataset.tab==='filters'||b.dataset.tab==='console')));
 document.querySelectorAll('.loginOnlyControl').forEach(e=>e.classList.toggle('loginRestricted',!loggedIn));
 const sr=$('spotRestricted'),ar=$('annRestricted');
 if(sr){sr.classList.toggle('loginRestricted',!loggedIn);sr.classList.toggle('restricted',loggedIn&&!registered)}
 if(ar){ar.classList.toggle('loginRestricted',!loggedIn);ar.classList.toggle('restricted',loggedIn&&!registered)}
 const spot=$('spotOpen'),ann=$('annSubmit');if(spot)spot.disabled=!registered;if(ann)ann.disabled=!registered;
 if($('showHuman'))$('showHuman').disabled=false;
 if($('showRbn'))$('showRbn').disabled=false;
 if(!loggedIn){if($('showHuman'))$('showHuman').checked=true;if($('showRbn'))$('showRbn').checked=true}
 const badge=$('anonymousBadge');if(badge)badge.hidden=loggedIn;
}

function notice(text){$('noticeText').textContent=text;$('noticeDialog').showModal()}
$('noticeClose').onclick=()=>$('noticeDialog').close();
$('registerButton').onclick=()=>{
 $('registerResult').textContent='';
 $('registerCall').value=authUser||$('loginCall').value.trim().toUpperCase();
 $('registerDialog').showModal();
 $('registerCall').focus();
};
$('registerCancel').onclick=()=>$('registerDialog').close();
function parseSsidSpec(spec){
 const out=[];
 for(const part of String(spec||'').split(',').map(x=>x.trim()).filter(Boolean)){
  let m;
  if(/^\d+$/.test(part)){out.push(Number(part));continue}
  if((m=part.match(/^(\d+)\s*-\s*(\d+)$/))){const a=Number(m[1]),b=Number(m[2]);if(a>b)throw new Error(`Invalid SSID range ${part}.`);for(let n=a;n<=b;n++)out.push(n);continue}
  throw new Error('Use SSIDs such as 1,2,3,4,5 or 1-5.');
 }
 const a=[...new Set(out)].sort((x,y)=>x-y);
 if(a.some(n=>!Number.isInteger(n)||n<1||n>99))throw new Error('SSID must be between 1 and 99.');
 return a;
}
function compactSsidSpec(values){
 if(!values.length)return '';
 const out=[];let start=values[0],prev=values[0];
 const flush=()=>out.push(start===prev?String(start):`${start}-${prev}`);
 for(let i=1;i<values.length;i++){const n=values[i];if(n===prev+1){prev=n;continue}flush();start=prev=n}
 flush();return out.join(',');
}
$('registerSsids').addEventListener('blur',()=>{try{const a=parseSsidSpec($('registerSsids').value);$('registerSsids').value=compactSsidSpec(a);$('registerResult').textContent=''}catch(err){$('registerResult').textContent=err.message}});
$('registerForm').addEventListener('submit',e=>{
 e.preventDefault();
 let ssids;
 try{ssids=parseSsidSpec($('registerSsids').value);$('registerSsids').value=compactSsidSpec(ssids)}
 catch(err){$('registerResult').textContent=err.message;return}
 $('registerSubmit').disabled=true;$('registerResult').textContent='Sending request…';
 if(!send({type:'reg_request',call:$('registerCall').value.trim().toUpperCase(),ssids,name:$('registerName').value.trim(),email:$('registerEmail').value.trim(),comment:$('registerComment').value.trim()})){$('registerSubmit').disabled=false;$('registerResult').textContent='DXSpider connection is not ready.'}
});

function clearSessionData(){
 spotItems=[];spotCounts={human:0,rbn:0};logs={ann:[],wwv:[],wcy:[],wx:[]};cmdHistory=[];historyPos=0;pendingCommandTargets=[];
 const set=(id,v='')=>{const e=$(id);if(e)e.value!==undefined?e.value=v:e.textContent=v};
 set('consoleOutput');set('consoleCommand');set('filterCommand');set('annText');set('annResult');set('spotResult');
 set('spotFreq');set('spotDx');set('spotComment');
 document.querySelectorAll('.commandOutput').forEach(e=>e.textContent='');
 renderSpots();for(const k of Object.keys(logs))renderLog(k);
}
function connect(){
 const proto=location.protocol==='https:'?'wss':'ws'; ws=new WebSocket(`${proto}://${location.host}/ws`);
 ws.onmessage=e=>{try{handle(JSON.parse(e.data))}catch(err){console.error('dxweb message handler error',err,e.data);$('status').textContent='ui-error'}};
 ws.onclose=()=>{logoutPending=false;$('loginSubmit').disabled=false;$('status').textContent='disconnected';loginState(false);setTimeout(connect,2000)};
}
function selectTab(id){
 activeTab=id; document.querySelectorAll('.tabs button').forEach(b=>b.classList.toggle('active',b.dataset.tab===id));
 document.querySelectorAll('.panel').forEach(p=>p.classList.toggle('active',p.id===id));
}
document.querySelectorAll('.tabs button').forEach(b=>b.onclick=()=>{if(!authenticated&&(b.dataset.tab==='filters'||b.dataset.tab==='console')){notice('Only users who have logged in can access this function.');return}selectTab(b.dataset.tab)});

$('loginButton').onclick=()=>{
 if(authenticated){if(logoutPending)return;logoutPending=true;clearSessionData();send({type:'logout'});$('loginButton').textContent='Logging out…';return}
 $('loginError').textContent='';$('loginDialog').showModal();$('loginCall').focus();
};
$('loginForm').addEventListener('submit',e=>{
 if(e.submitter&&e.submitter.value==='cancel')return;
 e.preventDefault();if(authenticated)return;
 const call=$('loginCall').value.trim().toUpperCase();if(!call)return;
 $('loginSubmit').disabled=true;
 if(!send({type:'auth',call,password:$('loginPass').value})){$('loginSubmit').disabled=false;$('loginError').textContent='DXSpider connection is not ready';return}
 $('loginPass').value='';
});
$('spotOpen').onclick=()=>{if(!authenticated){notice('Only users who have logged in can access this function.');return}if(!authRegistered){notice('You must be registered on this node to use this function. Use the Register option.');return}$('spotResult').textContent='';$('spotDialog').showModal()};
$('spotForm').addEventListener('submit',e=>{
 if(e.submitter&&e.submitter.value==='cancel')return;e.preventDefault();
 if(!(authenticated&&authRegistered)){notice('You must be registered on this node to use this function. Use the Register option.');return}
 send({type:'spot',freq:$('spotFreq').value.trim(),dxcall:$('spotDx').value.trim().toUpperCase(),comment:$('spotComment').value.trim()});
});
$('annForm').addEventListener('submit',e=>{
 e.preventDefault();if(!(authenticated&&authRegistered)){notice('You must be registered on this node to use this function. Use the Register option.');return}
 $('annResult').textContent='Sending...';send({type:'ann',scope:$('annScope').value,text:$('annText').value.trim()});
});
function command(cmd,target='console'){
 if(!authenticated)return;
 cmd=cmd.trim();if(!cmd)return;
 if(!cmdHistory.length||cmdHistory[cmdHistory.length-1]!==cmd)cmdHistory.push(cmd);
 historyPos=cmdHistory.length;
 if(target==='console'){const line=document.createElement('div');line.className='consoleCommandLine';line.textContent=`> ${cmd}`;$('consoleOutput').appendChild(line);$('consoleOutput').scrollTop=$('consoleOutput').scrollHeight}
 pendingCommandTargets.push(target);send({type:'command',command:cmd});
}
$('consoleForm').addEventListener('submit',e=>{e.preventDefault();const v=$('consoleCommand').value; $('consoleCommand').value='';command(v,'console')});
$('filterForm').addEventListener('submit',e=>{e.preventDefault();const v=$('filterCommand').value;$('filterCommand').value='';command(v,'filters')});
$('consoleCommand').addEventListener('keydown',e=>{
 if(e.key==='ArrowUp'){e.preventDefault();if(historyPos>0)historyPos--;$('consoleCommand').value=cmdHistory[historyPos]||''}
 if(e.key==='ArrowDown'){e.preventDefault();if(historyPos<cmdHistory.length)historyPos++;$('consoleCommand').value=cmdHistory[historyPos]||''}
});
document.querySelectorAll('.runBtn').forEach(b=>b.onclick=()=>command(b.dataset.command,b.closest('.panel').id));
document.querySelectorAll('.clearBtn').forEach(b=>b.onclick=()=>{
 const k=b.dataset.clear;
 if(k==='spots'){spotItems=[];spotCounts={human:0,rbn:0};renderSpots();return}
 if(logs[k]){logs[k]=[];renderLog(k);return}
 const out=document.querySelector(`#${k} .commandOutput`);if(out)out.textContent='';
});
$('showHuman').onchange=renderSpots;$('showRbn').onchange=renderSpots;

function renderSpots(){
 const human=$('showHuman').checked,rbn=$('showRbn').checked;
 const a=spotItems.filter(x=>(x.type==='human'&&human)||(x.type==='rbn'&&rbn));
 $('spotRows').innerHTML=a.slice(-250).reverse().map(x=>`<tr><td>${x.type==='human'?'C':x.type==='rbn'?'R':''}</td><td>${esc(x.utc||'')}</td><td>${esc(x.freq||'')}</td><td>${esc(x.dx||x.dxcall||'')}</td><td>${esc(x.spotter||'')}</td><td>${esc(x.comment||'')}</td><td>${esc(x.locDx||'')}</td><td>${esc(x.locSpotter||'')}</td><td>${esc(x.cqDx||'')}</td><td>${esc(x.cqSpotter||'')}</td><td>${esc(x.ituDx||'')}</td><td>${esc(x.ituSpotter||'')}</td></tr>`).join('');
 const visibleCount=(human?spotCounts.human:0)+(rbn?spotCounts.rbn:0);
 setCount('spots',visibleCount);
}
function renderLog(k){
 const e=document.querySelector(`[data-kind="${k}"]`);if(!e)return;
 e.textContent=logs[k].slice(-250).map(x=>typeof x==='string'?x:(x.text||x.message||JSON.stringify(x))).join('\n');
 e.scrollTop=e.scrollHeight;setCount(k,logs[k].length);
}
function responseText(m){const a=Array.isArray(m.messages)?m.messages.filter(x=>x!==undefined&&x!==null):[];return a.join('\n')+(m.error?`${a.length?'\n':''}ERROR: ${m.error}`:'')}
function pair(a,b){a=String(a||'');b=String(b||'');return a&&b?`${a}/${b}`:(a||b)}
function parseCC11(payload){
 if(typeof payload!=='string')return null;
 const f=payload.split('^');
 if(f[0]!=='CC11'||f.length<7)return null;
 const utc=(f[4]||'').replace(/Z$/i,'').replace(/[^0-9]/g,'').slice(0,4);
 return {utc,
         freq:f[1]||'',dx:f[2]||'',comment:f[5]||'',spotter:f[6]||'',
         cqDx:f[10]||'',ituDx:f[11]||'',cqSpotter:f[12]||'',ituSpotter:f[13]||'',
         locDx:f[18]||'',locSpotter:f[19]||''};
}
function acceptFeed(m){
 const k=(m.feed||'').toLowerCase();
 if(k==='human'||k==='rbn'){
   const p=parseCC11(m.payload);
   if(!p)return;
   spotItems.push({...p,type:k});
   spotCounts[k]=(spotCounts[k]||0)+1;
   if(spotItems.length>1000)spotItems.shift();
   renderSpots();
   return;
 }
 if(logs[k]){
   logs[k].push(typeof m.payload==='string'?m.payload:JSON.stringify(m.payload));
   if(logs[k].length>500)logs[k].shift();
   renderLog(k);
 }
}
function handle(m){
 if(m.type==='reg_request_result'){$('registerSubmit').disabled=false;if(m.status==='ok'){const r=m.result||{};$('registerResult').textContent=`Request #${r.id||'?'} sent successfully.`;setTimeout(()=>{$('registerDialog').close()},900)}else{$('registerResult').textContent=(Array.isArray(m.messages)&&m.messages.length?m.messages.join('\n'):(m.error||'Registration request failed'))}return}
 if(m.type==='status'){$('status').textContent=m.state||'';if(m.node_call)$('nodeCall').textContent=m.node_call;if(m.authenticated===true)loginState(true,m);else if(m.authenticated===false&&!logoutPending)loginState(false);return}
 if(m.type==='logout_result'){logoutPending=false;if(m.status==='ok'){loginState(false);clearSessionData()}else notice(`Logout failed: ${m.error||'unknown error'}`);return}
 if(m.type==='auth'||m.type==='auth_result'){
   $('loginSubmit').disabled=false;
   if(m.status==='ok'){loginState(true,m);$('loginDialog').close();$('loginError').textContent='';clearSessionData()}
   else {$('loginError').textContent=m.error||'Authentication failed';loginState(false)}
   return;
 }
 if(m.type==='command_result'){
   const target=pendingCommandTargets[0]||activeTab;const t=responseText(m);
   if(logs[target]){if(t){for(const line of t.split('\n'))logs[target].push(line);if(logs[target].length>500)logs[target]=logs[target].slice(-500);renderLog(target)}}
   else{const out=target==='console'?$('consoleOutput'):document.querySelector(`#${target} .commandOutput`);if(out&&t){if(target==='console'){const block=document.createElement('div');block.className='consoleResponse';block.textContent=t;out.appendChild(block)}else out.textContent+=t+'\n';out.scrollTop=out.scrollHeight}}
   if(m.final!==false)pendingCommandTargets.shift();return;
 }
 if(m.type==='spot_result'){$('spotResult').textContent=responseText(m)||(m.status==='ok'?'Spot accepted by DXSpider':'Spot rejected');if(m.status==='ok')setTimeout(()=>$('spotDialog').close(),500);return}
 if(m.type==='ann_result'){$('annResult').textContent=responseText(m)||(m.status==='ok'?'Announcement accepted by DXSpider':'Announcement rejected');if(m.status==='ok')$('annText').value='';return}
 if(m.type==='feed'){if(!logoutPending)acceptFeed(m);return}
}
loginState(false);
connect();

updateRegistrationAccess();
