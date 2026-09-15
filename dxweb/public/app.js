// DXSpider Web 2.5.0
// Date: 2026-09-15
'use strict';
const $=id=>document.getElementById(id);
let ws=null, authenticated=false, logoutPending=false, authUser=null, authRegistered=false, passwordUsed=false, activeTab='spots';
let spotItems=[], spotCounts={human:0,rbn:0}, logs={ann:[],wwv:[],wcy:[],wx:[]};
let cmdHistory=[], historyPos=0, pendingCommandTargets=[];

function send(o){if(!(ws&&ws.readyState===WebSocket.OPEN))return false;ws.send(JSON.stringify(o));return true}
function esc(v){return String(v??'').replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]))}
function setCount(k,n){const e=document.querySelector(`[data-count="${k}"]`);if(e)e.textContent=String(n)}
function loginState(ok,m={}){
 authenticated=ok; authUser=ok?(m.call||authUser):null;authRegistered=ok?Boolean(m.registered):false;passwordUsed=ok?Boolean(m.password_used):false;
 $('loginButton').textContent=ok?`Logout ${authUser}`:'Login';
}
function notice(text){$('noticeText').textContent=text;$('noticeDialog').showModal()}
$('noticeClose').onclick=()=>$('noticeDialog').close();
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
 ws.onclose=()=>{authPending=false;logoutPending=false;$('loginSubmit').disabled=false;$('status').textContent='disconnected';loginState(false);setTimeout(connect,2000)};
}
function selectTab(id){
 activeTab=id; document.querySelectorAll('.tabs button').forEach(b=>b.classList.toggle('active',b.dataset.tab===id));
 document.querySelectorAll('.panel').forEach(p=>p.classList.toggle('active',p.id===id));
}
document.querySelectorAll('.tabs button').forEach(b=>b.onclick=()=>selectTab(b.dataset.tab));

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
$('spotOpen').onclick=()=>{if(!authenticated){notice('To send a spot you must be a registered user of this DXSpider node and log in first.');return}$('spotResult').textContent='';$('spotDialog').showModal()};
$('spotForm').addEventListener('submit',e=>{
 if(e.submitter&&e.submitter.value==='cancel')return;e.preventDefault();
 send({type:'spot',freq:$('spotFreq').value.trim(),dxcall:$('spotDx').value.trim().toUpperCase(),comment:$('spotComment').value.trim()});
});
$('annForm').addEventListener('submit',e=>{
 e.preventDefault();if(!authenticated){notice('To send an announcement you must be a registered user of this DXSpider node and log in first.');return}
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
 $('spotRows').innerHTML=a.slice(-250).reverse().map(x=>`<tr><td>${esc(x.type||'')}</td><td>${esc(x.time||x.utc||'')}</td><td>${esc(x.freq||'')}</td><td>${esc(x.dx||x.dxcall||'')}</td><td>${esc(x.spotter||'')}</td><td>${esc(x.comment||'')}</td></tr>`).join('');
 const visibleCount=(human?spotCounts.human:0)+(rbn?spotCounts.rbn:0);
 setCount('spots',visibleCount);
}
function renderLog(k){
 const e=document.querySelector(`[data-kind="${k}"]`);if(!e)return;
 e.textContent=logs[k].slice(-250).map(x=>typeof x==='string'?x:(x.text||x.message||JSON.stringify(x))).join('\n');
 e.scrollTop=e.scrollHeight;setCount(k,logs[k].length);
}
function responseText(m){const a=Array.isArray(m.messages)?m.messages.filter(x=>x!==undefined&&x!==null):[];return a.join('\n')+(m.error?`${a.length?'\n':''}ERROR: ${m.error}`:'')}
function parseCC11(payload){
 if(typeof payload!=='string')return null;
 const f=payload.split('^');
 if(f[0]!=='CC11'||f.length<7)return null;
 return {utc:[f[3],(f[4]||'').replace(/Z$/i,'')].filter(Boolean).join(' '),
         freq:f[1]||'',dx:f[2]||'',comment:f[5]||'',spotter:f[6]||''};
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
 if(m.type==='feed'){if(authenticated&&!logoutPending)acceptFeed(m);return}
}
connect();
