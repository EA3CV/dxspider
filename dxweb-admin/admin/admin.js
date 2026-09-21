// DXSpider Web Administration 0.35.2
// Date: 2026-09-16
'use strict';
const $=id=>document.getElementById(id);
let ws=null,authenticated=false,logoutPending=false,authUser=null,activeSection='operation',activePanel='spots';
let spotItems=[],spotCounts={human:0,rbn:0},logs={ann:[],wwv:[],wcy:[],wx:[]},cmdHistory=[],historyPos=0,pendingCommandTargets=[];
let pc92Previous=null;
const supervisorInflight=new Set();
const send=o=>{if(!(ws&&ws.readyState===WebSocket.OPEN))return false;ws.send(JSON.stringify(o));return true};
const esc=v=>String(v??'').replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
function setCount(k,n){const e=document.querySelector(`[data-count="${k}"]`);if(e)e.textContent=String(n)}
function setLocked(v){document.body.classList.toggle('locked',v)}
function clearSessionContent(){
 for(const id of ['spotBody','annOutput','wwvOutput','wcyOutput','wxOutput','filtersOutput','consoleOutput','pendingRows','historyRows','searchRows']){
  const e=$(id);if(e)e.innerHTML='';
 }
 for(const k of Object.keys(logs||{})){logs[k]=[]}
 pendingCommandTargets.length=0;
 if($('regSearch'))$('regSearch').value='';
 if($('regActionResult'))$('regActionResult').textContent='';
}
function loginState(ok,m={}){authenticated=ok;document.body.classList.toggle('authenticated',ok);authUser=ok?(m.call||authUser):null;$('loginButton').textContent=ok?`Logout ${authUser}`:'Login';setLocked(!ok)}
function notice(t){$('noticeText').textContent=t;$('noticeDialog').showModal()}
$('noticeClose').onclick=()=>$('noticeDialog').close();
function showLogin(msg=''){if($('loginDialog').open)return;$('loginError').textContent=msg;$('loginDialog').showModal();$('loginCall').focus()}
function connect(){const proto=location.protocol==='https:'?'wss':'ws';ws=new WebSocket(`${proto}://${location.host}/ws`);ws.onmessage=e=>{try{handle(JSON.parse(e.data))}catch(err){console.error('admin message error',err,e.data)}};ws.onclose=()=>{supervisorInflight.clear();authenticated=false;logoutPending=false;loginState(false);$('status').textContent='disconnected';setTimeout(connect,2000)}}
$('loginButton').onclick=()=>{if(authenticated){if(logoutPending)return;logoutPending=true;send({type:'logout'});$('loginButton').textContent='Logging out…'}else showLogin()};
$('loginForm').addEventListener('submit',e=>{e.preventDefault();const call=$('loginCall').value.trim().toUpperCase(),password=$('loginPass').value;if(!call||!password){$('loginError').textContent='Callsign and password are required.';return}$('loginSubmit').disabled=true;if(!send({type:'auth',call,password})){$('loginSubmit').disabled=false;$('loginError').textContent='DXSpider connection is not ready';return}$('loginPass').value=''});
function selectSection(id){activeSection=id;document.querySelectorAll('.mainTabs button').forEach(b=>b.classList.toggle('active',b.dataset.section===id));document.querySelectorAll('.section').forEach(s=>s.classList.toggle('active',s.id===id));if(authenticated&&id==='registration')loadPending();if(authenticated&&id==='supervision')selectSupervision(activeSupervisionPanel);if(authenticated&&id==='metrics')requestMetrics()}
document.querySelectorAll('.mainTabs button[data-section]').forEach(b=>b.onclick=()=>selectSection(b.dataset.section));
$('quickConsole').onclick=()=>{selectSection('operation');selectPanel('console');$('consoleCommand').focus()};
function selectPanel(id){activePanel=id;document.querySelectorAll('#operationTabs button').forEach(b=>b.classList.toggle('active',b.dataset.panel===id));document.querySelectorAll('#operation .panel').forEach(p=>p.classList.toggle('active',p.id===id))}
document.querySelectorAll('#operationTabs button').forEach(b=>b.onclick=()=>selectPanel(b.dataset.panel));
function selectReg(id){document.querySelectorAll('#registrationTabs button').forEach(b=>b.classList.toggle('active',b.dataset.regpanel===id));document.querySelectorAll('.regPanel').forEach(p=>p.classList.toggle('active',p.id===id));if(authenticated&&id==='pending')loadPending();if(authenticated&&id==='history')loadHistory()}
document.querySelectorAll('#registrationTabs button').forEach(b=>b.onclick=()=>selectReg(b.dataset.regpanel));
function command(cmd,target='console'){if(!authenticated)return;cmd=cmd.trim();if(!cmd)return;if(!cmdHistory.length||cmdHistory.at(-1)!==cmd)cmdHistory.push(cmd);historyPos=cmdHistory.length;if(target==='console'){const l=document.createElement('div');l.className='consoleCommandLine';l.textContent=`> ${cmd}`;$('consoleOutput').appendChild(l)}pendingCommandTargets.push(target);send({type:'command',command:cmd})}
$('consoleForm').addEventListener('submit',e=>{e.preventDefault();const v=$('consoleCommand').value;$('consoleCommand').value='';command(v,'console')});
$('filterForm').addEventListener('submit',e=>{e.preventDefault();const v=$('filterCommand').value;$('filterCommand').value='';command(v,'filters')});
$('consoleCommand').addEventListener('keydown',e=>{if(e.key==='ArrowUp'){e.preventDefault();if(historyPos>0)historyPos--;$('consoleCommand').value=cmdHistory[historyPos]||''}if(e.key==='ArrowDown'){e.preventDefault();if(historyPos<cmdHistory.length)historyPos++;$('consoleCommand').value=cmdHistory[historyPos]||''}});
document.querySelectorAll('.runBtn').forEach(b=>b.onclick=()=>command(b.dataset.command,b.closest('.panel').id));
document.querySelectorAll('.clearBtn').forEach(b=>b.onclick=()=>{const k=b.dataset.clear;if(k==='spots'){spotItems=[];spotCounts={human:0,rbn:0};renderSpots();return}if(logs[k]){logs[k]=[];renderLog(k);return}const out=document.querySelector(`#${k} .commandOutput`);if(out)out.textContent='' });
$('showHuman').onchange=renderSpots;$('showRbn').onchange=renderSpots;
function renderSpots(){const human=$('showHuman').checked,rbn=$('showRbn').checked,a=spotItems.filter(x=>(x.type==='human'&&human)||(x.type==='rbn'&&rbn));$('spotRows').innerHTML=a.slice(-250).reverse().map(x=>`<tr><td>${x.type==='human'?'C':'R'}</td><td>${esc(x.utc)}</td><td>${esc(x.freq)}</td><td>${esc(x.dx)}</td><td>${esc(x.spotter)}</td><td>${esc(x.comment)}</td><td>${esc(x.locDx)}</td><td>${esc(x.locSpotter)}</td><td>${esc(x.cqDx)}</td><td>${esc(x.cqSpotter)}</td><td>${esc(x.ituDx)}</td><td>${esc(x.ituSpotter)}</td></tr>`).join('');setCount('spots',(human?spotCounts.human:0)+(rbn?spotCounts.rbn:0))}
function renderLog(k){const e=document.querySelector(`[data-kind="${k}"]`);if(!e)return;e.textContent=logs[k].slice(-250).join('\n');e.scrollTop=e.scrollHeight;setCount(k,logs[k].length)}
function parseCC11(payload){if(typeof payload!=='string')return null;const f=payload.split('^');if(f[0]!=='CC11'||f.length<7)return null;return{utc:(f[4]||'').replace(/Z$/i,'').replace(/[^0-9]/g,'').slice(0,4),freq:f[1]||'',dx:f[2]||'',comment:f[5]||'',spotter:f[6]||'',cqDx:f[10]||'',ituDx:f[11]||'',cqSpotter:f[12]||'',ituSpotter:f[13]||'',locDx:f[18]||'',locSpotter:f[19]||''}}
function acceptFeed(m){const k=(m.feed||'').toLowerCase();if(k==='human'||k==='rbn'){const p=parseCC11(m.payload);if(!p)return;spotItems.push({...p,type:k});spotCounts[k]=(spotCounts[k]||0)+1;if(spotItems.length>1000)spotItems.shift();renderSpots();return}if(logs[k]){logs[k].push(typeof m.payload==='string'?m.payload:JSON.stringify(m.payload));if(logs[k].length>500)logs[k].shift();renderLog(k)}}
function fmtTime(v){if(!v)return '-';const d=new Date(Number(v)*1000);return Number.isNaN(d.getTime())?'-':d.toLocaleString()}
function compactSsids(values){const a=[...new Set((Array.isArray(values)?values:[]).map(Number).filter(n=>Number.isInteger(n)&&n>=1&&n<=99))].sort((x,y)=>x-y);if(!a.length)return '-';const out=[];let start=a[0],prev=a[0];const flush=()=>out.push(start===prev?String(start):`${start}-${prev}`);for(let i=1;i<a.length;i++){const n=a[i];if(n===prev+1){prev=n;continue}flush();start=prev=n}flush();return out.join(',')}
function ssids(r){return compactSsids(r.accepted_ssids||r.requested_ssids||r.affected_ssids||[])}
function loadPending(){send({type:'reg_pending'})} function loadHistory(){send({type:'reg_history'})}
$('pendingRefresh').onclick=loadPending;$('historyRefresh').onclick=loadHistory;
$('regSearchForm').addEventListener('submit',e=>{e.preventDefault();const q=$('regSearch').value.trim();if(q)send({type:'reg_search',query:q})});
function renderPending(rows){$('pendingRows').innerHTML=(rows||[]).map(r=>`<tr><td>#${esc(r.id)}</td><td>${esc(r.call)}</td><td>${esc(compactSsids(r.requested_ssids||[]))}</td><td>${esc(r.name||'-')}</td><td>${esc(r.email||'-')}</td><td>${esc(r.ip||'-')}</td><td>${esc(fmtTime(r.created_at))}</td><td>${esc(r.comment||'-')}</td><td><div class="regActions"><button data-reg-id="${esc(r.id)}" data-reg-action="accept">Accept</button><button data-reg-id="${esc(r.id)}" data-reg-action="reject">Reject</button></div></td></tr>`).join('')||'<tr><td colspan="9">No pending registration requests.</td></tr>';document.querySelectorAll('[data-reg-action]').forEach(b=>b.onclick=()=>openDecision(b.dataset.regId,b.dataset.regAction,rows))}
function renderHistory(rows,target='historyRows'){$(target).innerHTML=(rows||[]).map(r=>`<tr><td>#${esc(r.id)}</td><td>${esc(r.call)}</td><td>${esc(ssids(r))}</td><td class="status-${esc(r.status)}">${esc(r.status||'-')}</td><td>${esc(r.name||'-')}</td><td>${esc(r.email||'-')}</td><td>${esc(fmtTime(r.created_at))}</td><td>${esc(fmtTime(r.processed_at))}</td><td>${esc(r.processed_by||'-')}</td><td>${esc(r.note??'-')}</td></tr>`).join('')||'<tr><td colspan="10">No matching registration records.</td></tr>'}
let decisionId=null;
let decisionAction=null;
function openDecision(id,action,rows){
 decisionId=Number(id);
 decisionAction=action==='reject'?'reject':'accept';
 const r=(rows||[]).find(x=>Number(x.id)===decisionId)||{};
 $('regActionTitle').textContent=decisionAction==='accept'?'Accept registration':'Reject registration';
 $('regActionSummary').textContent=`#${id} ${r.call||''} — ${r.email||''}${r.comment?'\n'+r.comment:''}`;
 $('regActionNote').value='';
 $('regActionResult').textContent='';
 $('regAccept').hidden=decisionAction!=='accept';
 $('regReject').hidden=decisionAction!=='reject';
 $('regAccept').disabled=false;
 $('regReject').disabled=false;
 $('regActionDialog').showModal();
}
$('regAccept').onclick=()=>decision('accept');
$('regReject').onclick=()=>decision('reject');
function decision(action){
 if(!decisionId||action!==decisionAction)return;
 $('regAccept').disabled=true;
 $('regReject').disabled=true;
 $('regActionResult').textContent=action==='accept'?'Accepting…':'Rejecting…';
 if(!send({type:`reg_${action}`,request_id:decisionId,note:$('regActionNote').value.trim()})){
  $('regAccept').disabled=false;
  $('regReject').disabled=false;
  $('regActionResult').textContent='DXSpider connection is not ready.';
 }
}
$('deleteUserOpen').onclick=()=>{
 $('deleteUserCall').value='';
 $('deleteUserNote').value='';
 $('deleteUserResult').textContent='';
 $('deleteUserDialog').showModal();
 $('deleteUserCall').focus();
};
$('deleteUserForm').addEventListener('submit',e=>{
 if(e.submitter&&e.submitter.value==='cancel')return;
 e.preventDefault();
 const target=$('deleteUserCall').value.trim().toUpperCase().replace(/-\d+$/,'');
 if(!target)return;
 $('deleteUserConfirm').disabled=true;
 $('deleteUserResult').textContent='Deleting…';
 if(!send({type:'reg_delete_user',target,note:$('deleteUserNote').value.trim()})){
  $('deleteUserConfirm').disabled=false;
  $('deleteUserResult').textContent='DXSpider connection is not ready.';
 }
});

function responseText(m){const a=Array.isArray(m.messages)?m.messages.filter(x=>x!=null):[];return a.join('\n')+(m.error?`${a.length?'\n':''}ERROR: ${m.error}`:'')}
function finishCommandTarget(target){
 if(logs[target]){
  logs[target].push('');
  if(logs[target].length>500)logs[target]=logs[target].slice(-500);
  renderLog(target);
  return;
 }
 const out=target==='console'?$('consoleOutput'):document.querySelector(`#${target} .commandOutput`);
 if(!out)return;
 if(target==='console'){
  const spacer=document.createElement('div');
  spacer.className='commandSeparator';
  spacer.textContent='\u00a0';
  out.appendChild(spacer);
 }else{
  out.textContent+='\n';
 }
 out.scrollTop=out.scrollHeight;
}
function handle(m){if(m.type==='status'){$('status').textContent=m.state||'';if(m.node_call)$('nodeCall').textContent=m.node_call;if(m.authenticated===false){logoutPending=false;if(authenticated)clearSessionContent();loginState(false);setLocked(true);if(m.state==='ready'&&!$('loginDialog').open)showLogin()}return}if(m.type==='auth'||m.type==='auth_result'){$('loginSubmit').disabled=false;if(m.status==='ok'){clearSessionContent();loginState(true,m);$('loginDialog').close();$('loginError').textContent='';loadPending()}else{loginState(false);$('loginError').textContent=m.error==='admin_privilege_required'?'SYSOP privilege 9 is required.':m.error==='password_required'?'A valid DXSpider password is required.':(m.error||'Authentication failed');showLogin($('loginError').textContent)}return}if(m.type==='logout_result'){logoutPending=false;loginState(false);showLogin();return}if(!authenticated)return;if(m.type==='reg_pending_result'){if(m.status==='ok')renderPending(m.result||[]);else notice(responseText(m));return}if(m.type==='reg_history_result'){if(m.status==='ok')renderHistory(m.result||[]);else notice(responseText(m));return}if(m.type==='reg_search_result'){if(m.status==='ok')renderHistory(m.result||[],'searchRows');else notice(responseText(m));return}if(m.type==='reg_accept_result'||m.type==='reg_reject_result'){const expected=decisionAction?`reg_${decisionAction}_result`:null;if(expected&&m.type!==expected){$('regActionResult').textContent=`Unexpected registration response: ${m.type}`;return}if(m.status==='ok'){const accepted=m.type==='reg_accept_result';const pw=accepted&&m.result&&m.result.password?` Password: ${m.result.password}`:'';$('regActionResult').textContent=(accepted?'Accepted.':'Rejected.')+pw;setTimeout(()=>{$('regActionDialog').close();decisionId=null;decisionAction=null;loadPending();loadHistory()},900)}else{$('regAccept').disabled=false;$('regReject').disabled=false;$('regActionResult').textContent=responseText(m)}return}if(m.type==='reg_delete_user_result'){$('deleteUserConfirm').disabled=false;if(m.status==='ok'){const calls=(m.result&&m.result.affected_calls)||[];$('deleteUserResult').textContent=`Deleted ${calls.length} DXUser record(s): ${calls.join(', ')}`;loadHistory();setTimeout(()=>$('deleteUserDialog').close(),1200)}else{$('deleteUserResult').textContent=(Array.isArray(m.messages)&&m.messages.length?m.messages.join('\n'):(m.error||'Delete failed'))}return}
 if(m.type==='feed'){acceptFeed(m);return}if(m.type==='command_result'){const target=pendingCommandTargets[0]||activePanel,t=responseText(m),out=target==='console'?$('consoleOutput'):document.querySelector(`#${target} .commandOutput`);if(logs[target]){if(t){logs[target].push(...t.split('\n'));renderLog(target)}}else if(out&&t){if(target==='console'){const b=document.createElement('div');b.className='consoleResponse';b.textContent=t;out.appendChild(b)}else out.textContent+=t+'\n';out.scrollTop=out.scrollHeight}if(m.final!==false){finishCommandTarget(target);pendingCommandTargets.shift()}}}
loginState(false);connect();


// 0.6.1 - permanent Login/Logout control.


let metricsWindow='15m',metricsData=null,metricsInflight=false;
function requestMetrics(){if(!authenticated||!ws||ws.readyState!==WebSocket.OPEN||metricsInflight)return;metricsInflight=true;setText('metricsState','Loading historical series…');if(!send({type:'history_metrics',window:metricsWindow})){metricsInflight=false;setText('metricsState','Admin link is not ready.')}}
function metricLineChart(id,defs,opt={}){const host=$(id);if(!host)return;const vals=[];for(const d of defs)for(const p of(d.points||[]))if(Number.isFinite(Number(p.v)))vals.push(Number(p.v));if(!vals.length){host.innerHTML='<div class="emptyState metricEmpty">No samples for this window.</div>';return}const W=720,H=220,L=52,R=14,T=12,B=28,iw=W-L-R,ih=H-T-B;let ymin=0,ymax=Math.max(...vals);if(ymax<=0)ymax=1;const from=Number(metricsData.from_at),to=Number(metricsData.to_at),sx=t=>L+(Number(t)-from)/(to-from)*iw,sy=v=>T+ih-(Number(v)-ymin)/(ymax-ymin)*ih,fmt=opt.fmt||((v)=>v>=1000?v.toLocaleString(undefined,{maximumFractionDigits:0}):v.toFixed(v<10?2:1));let svg=`<svg viewBox="0 0 ${W} ${H}">`;for(let i=0;i<=4;i++){const y=T+ih*i/4,v=ymax*(1-i/4);svg+=`<line class="chartGrid" x1="${L}" y1="${y}" x2="${W-R}" y2="${y}"/><text class="chartAxis" x="${L-6}" y="${y+4}" text-anchor="end">${esc(fmt(v))}</text>`}for(const d of defs){const pts=(d.points||[]).filter(p=>Number.isFinite(Number(p.v)));if(!pts.length)continue;let path='';let prev=null;for(const q of pts){const gap=prev&&Number(q.t)-Number(prev.t)>Number(metricsData.bucket_seconds||1)*1.8;path+=(path&&!gap?' L':' M')+sx(q.t).toFixed(1)+','+sy(q.v).toFixed(1);prev=q}svg+=`<path class="chartSeries ${d.cls||''}" d="${path}"/>`}svg+=`<text class="chartAxis" x="${L}" y="${H-7}">${esc(new Date(from*1000).toLocaleTimeString([],{hour:'2-digit',minute:'2-digit'}))}</text><text class="chartAxis" x="${W-R}" y="${H-7}" text-anchor="end">${esc(new Date(to*1000).toLocaleTimeString([],{hour:'2-digit',minute:'2-digit'}))}</text></svg>`;host.innerHTML=svg+`<div class="chartLegend">${defs.map(d=>`<span><i class="${d.cls||''}"></i>${esc(d.name)}</span>`).join('')}</div>`}
function renderPeerMetric(){if(!metricsData)return;const s=metricsData.series||{},peer=$('metricsPeer')?.value||'',peers=metricsData.peers||[];if(peer){metricLineChart('chartPeer',[{name:`${peer} IN`,points:s[`peer:${peer}:in`]||[],cls:'s1'},{name:`${peer} OUT`,points:s[`peer:${peer}:out`]||[],cls:'s2'}]);return}const merge=d=>{const b=new Map;for(const p of peers)for(const x of(s[`peer:${p}:${d}`]||[]))b.set(Number(x.t),(b.get(Number(x.t))||0)+Number(x.v||0));return[...b].sort((a,c)=>a[0]-c[0]).map(([t,v])=>({t,v}))};metricLineChart('chartPeer',[{name:'All IN',points:merge('in'),cls:'s1'},{name:'All OUT',points:merge('out'),cls:'s2'}])}
function renderMetrics(r){metricsData=r||{};metricsInflight=false;const ratio=Math.max(0,Math.min(1,Number(r.coverage_ratio||0)));setHealth('metricsCoverage',`coverage ${(ratio*100).toFixed(ratio<.1?1:0)}%`,ratio>.9?'ok':ratio>.25?'warn':'unknown');setText('metricsBucket',`bucket ${fmtDuration(r.bucket_seconds||0)}`);setText('metricsBoots',`boots ${Number(r.boot_count||0)}`);setText('metricsState',`${fmtDuration(r.coverage_seconds||0)} historical coverage in ${r.window}`);const peers=Array.isArray(r.peers)?r.peers:[],sel=$('metricsPeer'),old=sel.value;sel.innerHTML='<option value="">All peers</option>'+peers.map(x=>`<option value="${esc(x)}">${esc(x)}</option>`).join('');if(peers.includes(old))sel.value=old;const s=r.series||{},P=k=>s[k]||[];metricLineChart('chartTransport',[{name:'RX',points:P('transport_rx_bps'),cls:'s1'},{name:'TX',points:P('transport_tx_bps'),cls:'s2'}],{fmt:v=>fmtBytes(v)+'/s'});metricLineChart('chartSpots',[{name:'Total',points:P('spots_per_s'),cls:'s3'}]);metricLineChart('chartPc92',[{name:'A',points:P('pc92_received_A'),cls:'s1'},{name:'C',points:P('pc92_received_C'),cls:'s2'},{name:'D',points:P('pc92_received_D'),cls:'s3'},{name:'K',points:P('pc92_received_K'),cls:'s4'}]);metricLineChart('chartNodeState',[{name:'Users',points:P('users'),cls:'s1'},{name:'Nodes',points:P('nodes'),cls:'s2'},{name:'Channels',points:P('channels'),cls:'s3'},{name:'RBN',points:P('rbn'),cls:'s4'},{name:'Web',points:P('web'),cls:'s5'}]);metricLineChart('chartCpu',[{name:'DXSpider',points:P('cpu_self_ratio').map(x=>({t:x.t,v:Number(x.v)*100})),cls:'s2'}],{fmt:v=>v.toFixed(1)+'%'});renderPeerMetric()}
document.querySelectorAll('#metricsWindows button[data-window]').forEach(b=>b.onclick=()=>{metricsWindow=b.dataset.window;document.querySelectorAll('#metricsWindows button').forEach(x=>x.classList.toggle('active',x===b));requestMetrics()});$('metricsRefresh').onclick=requestMetrics;$('metricsPeer').onchange=renderPeerMetric;

// DXSpider supervision v0.3: readable, navigable, read-only dashboard. No background polling.
let activeSupervisionPanel='overview',supervisorLastCollectedAt=0,supervisorStatusCache=null;
let supervisorConnectionsCache=[],supervisorTrafficCache=null,connectionKind='all',trafficPrevious=null;
function setHealth(id,text,state='unknown'){const e=$(id);if(!e)return;e.textContent=text;e.className=`healthPill ${state}`}
function setText(id,v){const e=$(id);if(e)e.textContent=v}
function updateSupervisorBanner(r){
 if(r&&r.node){$('supervisionNode').textContent=r.node;supervisorStatusCache=r}
 const st=supervisorStatusCache;
 if(st){$('supervisionNode').textContent=st.node||'—';$('supervisionUptime').textContent=`uptime ${fmtDuration(st.uptime_seconds||0)}`;setHealth('supervisionDxsState','DXS UP','ok')}
 setHealth('supervisionAdminState',ws&&ws.readyState===WebSocket.OPEN?'ADMIN LINK UP':'ADMIN LINK DOWN',ws&&ws.readyState===WebSocket.OPEN?'ok':'bad');
 if(supervisorLastCollectedAt){const age=Math.max(0,Date.now()/1000-supervisorLastCollectedAt);$('supervisionAge').textContent=`data age ${age<10?age.toFixed(1)+'s':Math.floor(age)+'s'}`}
}
function fmtDuration(v){let s=Math.max(0,Math.floor(Number(v)||0));const d=Math.floor(s/86400);s%=86400;const h=Math.floor(s/3600);s%=3600;const m=Math.floor(s/60);return d?`${d}d ${h}h`:h?`${h}h ${m}m`:`${m}m`}
function supervisorKindsFor(panel){return panel==='overview'?['overview']:panel==='diagnostics'?['self_health']:panel==='system'?['system']:panel==='nodes'?['connections']:panel==='users'?['connections']:panel==='peers'?['connections','traffic']:[panel]}
function supervisorRequest(panel=activeSupervisionPanel){if(!authenticated||!ws||ws.readyState!==WebSocket.OPEN)return;const todo=supervisorKindsFor(panel).filter(what=>!supervisorInflight.has(what));if(!todo.length)return;$('supervisionState').textContent=`Collecting ${panel} snapshot…`;for(const what of todo){supervisorInflight.add(what);if(!send({type:`supervisor_${what}`}))supervisorInflight.delete(what)}}
function selectSupervision(id){activeSupervisionPanel=id||'overview';document.querySelectorAll('#supervisionTabs button[data-superpanel]').forEach(b=>b.classList.toggle('active',b.dataset.superpanel===activeSupervisionPanel));document.querySelectorAll('#supervision .superPanel').forEach(p=>p.classList.toggle('active',p.id===activeSupervisionPanel));if(authenticated)supervisorRequest(activeSupervisionPanel)}
document.querySelectorAll('#supervisionTabs button[data-superpanel]').forEach(b=>b.onclick=()=>selectSupervision(b.dataset.superpanel));
if($('supervisionRefresh'))$('supervisionRefresh').onclick=()=>supervisorRequest(activeSupervisionPanel);
function fmtBytes(n){n=Number(n)||0;for(const u of ['B','KiB','MiB','GiB','TiB']){if(Math.abs(n)<1024||u==='TiB')return `${n.toFixed(u==='B'?0:1)} ${u}`;n/=1024}}
function valueUnit(value,unit=''){return `<span class=\"vu\"><span class=\"vuValue\">${esc(value)}</span><span class=\"vuUnit\">${esc(unit)}</span></span>`}
function bytesVU(n,suffix=''){const p=fmtBytes(n).split(' ');return valueUnit(p[0],`${p[1]||''}${suffix}`)}
function metricRowsHtml(rows){return rows.map(([k,v,cls=''])=>`<div class=\"metricRow\"><dt>${esc(k)}</dt><dd class=\"${cls}\">${v}</dd></div>`).join('')}
function fmtAge(ts){const n=Number(ts)||0;if(!n)return '-';return fmtDuration(Date.now()/1000-n)}
function metricRows(rows){return rows.map(([k,v,cls=''])=>`<div class="metricRow"><dt>${esc(k)}</dt><dd class="${cls}">${esc(v)}</dd></div>`).join('')}
function statusBadge(text,state='neutral'){return `<span class="stateBadge ${state}">${esc(text)}</span>`}
function yn(v){return v===true||v===1?'Yes':v===false||v===0?'No':'—'}
function dash(v){return v===undefined||v===null||v===''?'—':String(v)}
function renderConnections(){
 const q=($('connSearch')?.value||'').trim().toUpperCase();
 const all=supervisorConnectionsCache,online=all.filter(x=>x.online).length,offline=all.filter(x=>!x.online).length,repeated=all.filter(x=>Number(x.connect_count||0)>1).length,too=all.filter(x=>Number(x.too_many_count||0)>0).length;
 setText('connAllCount',all.length);setText('connConnectedCount',online);setText('connDisconnectedCount',offline);setText('connRepeatedCount',repeated);setText('connTooManyCount',too);
 const match=x=>connectionKind==='all'||(connectionKind==='connected'&&x.online)||(connectionKind==='disconnected'&&!x.online)||(connectionKind==='repeated'&&Number(x.connect_count)>1)||(connectionKind==='too_many'&&Number(x.too_many_count)>0);
 const rows=all.filter(x=>match(x)&&(!q||String(x.call||'').toUpperCase().includes(q)));
 $('supervisorConnections').innerHTML=rows.map(x=>`<tr><td class="callCell">${esc(x.call)}</td><td>${statusBadge(x.online?'ONLINE':'OFFLINE',x.online?'ok':'neutral')}</td><td>${statusBadge(x.kind||'-','neutral')}</td><td>${esc(x.outbound===true||x.outbound===1?'OUT':x.outbound===false||x.outbound===0?'IN':'—')}</td><td>${esc(dash(x.ip))}</td><td>${esc(yn(x.registered))}</td><td>${esc(yn(x.password_configured))}</td><td>${esc(x.state||'-')}</td><td>${x.online?esc(fmtAge(x.connected_since)):'—'}</td><td>${esc(dash(x.cnum))}</td><td class="${Number(x.queue_depth)>0?'warnText':''}">${esc(x.queue_depth||0)}</td><td class="${Number(x.errors)>0?'badText':''}">${esc(x.errors||0)}</td><td>${Number(x.connect_count||0).toLocaleString()}</td><td>${Number(x.disconnect_count||0).toLocaleString()}</td><td>${x.last_event?esc(fmtAge(x.last_event)):'—'}</td><td class="${Number(x.too_many_count)>0?'badText':''}">${Number(x.too_many_count||0).toLocaleString()}</td><td class="unitCell">${x.online?bytesVU(x.bytes_in):'—'}</td><td class="unitCell">${x.online?bytesVU(x.bytes_out):'—'}</td></tr>`).join('')||'<tr><td colspan="18" class="emptyCell">No matching connections.</td></tr>';
 renderNodes();
}

let userKind='online';
function userConnectionRows(){return supervisorConnectionsCache.filter(x=>String(x.kind||'').toLowerCase()==='user')}
function renderUsers(){
 const body=$('supervisorUsers');if(!body)return;
 const all=userConnectionRows(),online=all.filter(x=>x.online),q=($('userSearch')?.value||'').trim().toUpperCase();
 setText('userOnlineCount',online.length);setText('userObservedCount',all.length);
 setText('userKpiOnline',online.length);
 setText('userKpiRegistered',online.filter(x=>x.registered===true||x.registered===1).length);
 setText('userKpiPassword',online.filter(x=>x.password_configured===true||x.password_configured===1).length);
 setText('userKpiReconnects',all.reduce((n,x)=>n+Math.max(0,Number(x.connect_count||0)-1),0));
 const rows=all.filter(x=>(userKind==='all'||x.online)&&(!q||String(x.call||'').toUpperCase().includes(q)));
 body.innerHTML=rows.map(x=>`<tr><td class="callCell">${esc(x.call)}</td><td>${statusBadge(x.online?'ONLINE':'OFFLINE',x.online?'ok':'neutral')}</td><td>${esc(x.outbound===true||x.outbound===1?'OUT':x.outbound===false||x.outbound===0?'IN':'—')}</td><td>${esc(dash(x.ip))}</td><td>${esc(yn(x.registered))}</td><td>${esc(yn(x.password_configured))}</td><td>${x.online?esc(fmtAge(x.connected_since)):'—'}</td><td>${esc(dash(x.state))}</td><td>${esc(dash(x.cnum))}</td><td class="${Number(x.queue_depth)>0?'warnText':''}">${esc(x.queue_depth||0)}</td><td class="${Number(x.errors)>0?'badText':''}">${esc(x.errors||0)}</td><td>${Number(x.connect_count||0).toLocaleString()}</td><td>${Number(x.disconnect_count||0).toLocaleString()}</td><td>${x.last_event?esc(fmtAge(x.last_event)):'—'}</td><td class="unitCell">${x.online?bytesVU(x.bytes_in):'—'}</td><td class="unitCell">${x.online?bytesVU(x.bytes_out):'—'}</td></tr>`).join('')||'<tr><td colspan="16" class="emptyCell">No matching user connections.</td></tr>';
}
document.querySelectorAll('.userFilter').forEach(b=>b.onclick=()=>{userKind=b.dataset.kind;document.querySelectorAll('.userFilter').forEach(x=>x.classList.toggle('active',x===b));renderUsers()});
if($('userSearch'))$('userSearch').oninput=renderUsers;

function renderConnectionAttention(){
 const items=[];
 supervisorConnectionsCache.filter(x=>Number(x.too_many_count)>0).sort((a,b)=>Number(b.last_too_many)-Number(a.last_too_many)).slice(0,8).forEach(x=>items.push(`<div class="attentionRow"><b>${esc(x.call)}</b><span>Too many connections ×${esc(x.too_many_count)}</span><span>${esc(fmtAge(x.last_too_many))}</span></div>`));
 supervisorConnectionsCache.filter(x=>Number(x.connect_count)>1&&!Number(x.too_many_count)).sort((a,b)=>Number(b.connect_count)-Number(a.connect_count)).slice(0,8).forEach(x=>items.push(`<div class="attentionRow"><b>${esc(x.call)}</b><span>Repeated successful connections ×${esc(x.connect_count)}</span><span>${esc(fmtAge(x.last_event))}</span></div>`));
 $('connectionAttentionRows').innerHTML=items.join('')||'<div class="emptyCell">No connection events need attention.</div>';
}
function renderNodes(){
 const body=$('supervisorNodes');if(!body)return;const proto=supervisorTrafficCache?.protocol||{},pp=proto.peers||{},by=new Map();
 for(const x of supervisorConnectionsCache){if(x.is_self||x.kind!=='node')continue;by.set(String(x.call||'').toUpperCase(),x)}
 const q=($('nodeSearch')?.value||'').trim().toUpperCase(),rows=[];for(const [call,c] of [...by.entries()].sort((a,b)=>a[0].localeCompare(b[0]))){if(q&&!call.includes(q))continue;const pcs=pp[call]||pp[c.call]||{};let ip=0,op=0,ib=0,ob=0,types=0;for(const v of Object.values(pcs)){const i=v?.in||{},o=v?.out||{},a=Number(i.packets||0),b=Number(o.packets||0);ip+=a;op+=b;ib+=Number(i.bytes||0);ob+=Number(o.bytes||0);if(a||b)types++}rows.push({call,c,ip,op,ib,ob,types,reconnects:Math.max(0,Number(c.connect_count||0)-1)})}
 const vals=[...by.values()];setText('nodeKpiTotal',by.size);setText('nodeKpiOnline',vals.filter(c=>c.online).length);setText('nodeKpiPc9x',vals.filter(c=>c.online&&(c.do_pc9x===true||c.do_pc9x===1)).length);setText('nodeKpiReconnects',vals.reduce((a,c)=>a+Math.max(0,Number(c.connect_count||0)-1),0));
 body.innerHTML=rows.map(({call,c,ip,op,ib,ob,types,reconnects})=>`<tr><td class="callCell">${esc(call)}</td><td>${statusBadge(c.online?'ONLINE':'OFFLINE',c.online?'ok':'neutral')}</td><td>${esc(c.outbound===true||c.outbound===1?'OUT':c.outbound===false||c.outbound===0?'IN':'—')}</td><td>${esc(dash(c.ip))}</td><td>${c.online?esc(fmtAge(c.connected_since)):'—'}</td><td>${esc(yn(c.do_pc9x))}</td><td>${esc(dash(c.dxspider_version))}</td><td>${esc(dash(c.build))}</td><td>${esc(dash(c.git_version))}</td><td>${ip.toLocaleString()}</td><td>${op.toLocaleString()}</td><td class="unitCell">${bytesVU(ib)}</td><td class="unitCell">${bytesVU(ob)}</td><td>${types}</td><td class="${reconnects?'warnText':''}">${reconnects}</td><td>${c.pingave!=null?esc(Number(c.pingave).toFixed(3)):'—'}</td></tr>`).join('')||'<tr><td colspan="16" class="emptyCell">No matching direct node peers.</td></tr>';
}
if($('nodeSearch'))$('nodeSearch').oninput=renderNodes;
document.querySelectorAll('.connFilter').forEach(b=>b.onclick=()=>{connectionKind=b.dataset.kind;document.querySelectorAll('.connFilter').forEach(x=>x.classList.toggle('active',x===b));renderConnections()});
if($('connSearch'))$('connSearch').oninput=renderConnections;
let updateStatusCache=null;async function refreshUpdateStatus(){try{const r=await fetch(`update-status.json?_=${Date.now()}`,{cache:'no-store'});if(!r.ok)throw new Error(String(r.status));updateStatusCache=await r.json()}catch(e){updateStatusCache={status:'CHECK_FAILED',error:String(e)}}renderUpdateStatus()}
function renderUpdateStatus(){const b=$('updateStatusBadge'),r=updateStatusCache;if(!b)return;if(!r){b.textContent='UPDATE CHECK…';b.className='stateBadge neutral';return}const st=r.status||'CHECK_FAILED';b.textContent=st.replaceAll('_',' ');b.className=`stateBadge ${st==='UPDATED'?'ok':st==='NOT_UPDATED'?'warn':'neutral'}`;b.title=[r.source?`source: ${r.source}`:'',r.branch?`branch: ${r.branch}`:'',r.local_commit?`local: ${r.local_commit}`:'',r.remote_commit?`remote: ${r.remote_commit}`:'',r.checked_at?`checked: ${r.checked_at}`:'',r.error||''].filter(Boolean).join('\n');for(const n of ['branch','version','build','commit'])document.querySelectorAll(`.update${n[0].toUpperCase()+n.slice(1)}Field`).forEach(e=>e.classList.toggle('updateMismatch',r?.comparisons?.[n]?.comparable===true&&r.comparisons[n].match===false))}
refreshUpdateStatus();setInterval(refreshUpdateStatus,60000);

let topologyState={nodes:[],edges:[],byCall:new Map(),adj:new Map(),positions:new Map(),root:'',selected:null,hops:'all',baseBox:{x:0,y:0,w:1400,h:900},box:{x:0,y:0,w:1400,h:900},drag:null};
function topologySetBox(box){const svg=$('topologyGraph');if(!svg)return;topologyState.box={...box};svg.setAttribute('viewBox',`${box.x} ${box.y} ${box.w} ${box.h}`);const ratio=box.w/topologyState.baseBox.w;svg.classList.toggle('labelsCompact',ratio>0.72);svg.classList.toggle('labelsSparse',ratio>0.42&&ratio<=0.72)}
function topologyFit(){const b=topologyState.baseBox;topologySetBox({...b})}
function topologyZoom(factor,cx=.5,cy=.5){const b=topologyState.box,base=topologyState.baseBox;let nw=b.w*factor,nh=b.h*factor;const minW=base.w*.08,maxW=base.w*3;if(nw<minW){nh*=minW/nw;nw=minW}if(nw>maxW){nh*=maxW/nw;nw=maxW}topologySetBox({x:b.x+(b.w-nw)*cx,y:b.y+(b.h-nh)*cy,w:nw,h:nh})}
function topologyNeighbours(call,maxHops=1){const seen=new Set([call]),q=[[call,0]];while(q.length){const [a,d]=q.shift();if(d>=maxHops)continue;for(const b of topologyState.adj.get(a)||[])if(!seen.has(b)){seen.add(b);q.push([b,d+1])}}return seen}
function topologyApplyFocus(){const svg=$('topologyGraph'),sel=topologyState.selected;if(!svg)return;const hops=topologyState.hops==='all'?null:Number(topologyState.hops),visible=sel&&hops?topologyNeighbours(sel,hops):null,near=sel?topologyNeighbours(sel,1):new Set();svg.querySelectorAll('.topoNode').forEach(g=>{const c=g.dataset.call;g.classList.toggle('selected',c===sel);g.classList.toggle('neighbour',!!sel&&c!==sel&&near.has(c));g.classList.toggle('dim',!!visible&&!visible.has(c))});svg.querySelectorAll('.topoEdge').forEach(l=>{const a=l.dataset.from,b=l.dataset.to;const active=!!sel&&(a===sel||b===sel);l.classList.toggle('selected',active);l.classList.toggle('dim',!!visible&&(!visible.has(a)||!visible.has(b)))})}
function topologyInspector(call){const box=$('topologyInspector'),n=topologyState.byCall.get(call);if(!box||!n)return;const rel=[...(topologyState.adj.get(call)||[])].sort();const type=n.self?'Local node':n.direct?'Direct neighbour':n.do_pc9x?'PC9X node':'Non-PC9X node';box.innerHTML=`<div class="topologyInspectorTitle"><h3>${esc(n.call)}</h3><strong class="topoType">${esc(type)}</strong></div><dl><dt>Connection</dt><dd>${n.self?'Local':n.direct?'Direct':'Known route'}</dd><dt>Protocol</dt><dd>${n.do_pc9x?'PC9X':'Other'}</dd><dt>PC92K users</dt><dd><strong>${n.pc92_users==null?'—':Number(n.pc92_users).toLocaleString()}</strong></dd><dt>Known users</dt><dd>${Number(n.user_count||0).toLocaleString()}</dd><dt>PC92K nodes</dt><dd><strong>${n.pc92_nodes==null?'—':Number(n.pc92_nodes).toLocaleString()}</strong></dd><dt>Known children</dt><dd>${Number(n.child_count||0).toLocaleString()}</dd><dt>Adjacent links</dt><dd>${rel.length.toLocaleString()}</dd></dl><div class="topoRelations"><strong>Adjacent nodes</strong><div class="topoRelationList">${rel.slice(0,80).map(c=>`<button type="button" class="topoRelation" data-call="${esc(c)}">${esc(c)}</button>`).join('')||'<span class="panelSub">None in this snapshot</span>'}</div></div>`;box.querySelectorAll('.topoRelation').forEach(b=>b.onclick=()=>topologySelect(b.dataset.call,true))}
function topologySelect(call,center=false){if(!topologyState.byCall.has(call))return false;topologyState.selected=call;topologyInspector(call);topologyApplyFocus();if(center){const p=topologyState.positions.get(call),b=topologyState.box;if(p)topologySetBox({x:p[0]-b.w/2,y:p[1]-b.h/2,w:b.w,h:b.h})}return true}
function topologyFind(){const input=$('topologySearch');if(!input)return;const q=input.value.trim().toUpperCase(),box=$('topologyInspector');if(!q)return;const exact=topologyState.nodes.find(n=>String(n.call).toUpperCase()===q),partial=topologyState.nodes.find(n=>String(n.call).toUpperCase().includes(q)),n=exact||partial;if(!n){if(box)box.innerHTML=`<div class="topologyInspectorEmpty">No node matching <strong>${esc(q)}</strong> in this snapshot.</div>`;return}topologySelect(n.call,true);const g=$('topologyGraph')?.querySelector(`.topoNode[data-call="${CSS.escape(n.call)}"]`);if(g){g.classList.add('searchHit');setTimeout(()=>g.classList.remove('searchHit'),1200)}}
function topologyBindControls(){const svg=$('topologyGraph');if(!svg||svg.dataset.interactive==='1')return;svg.dataset.interactive='1';$('topologyZoomIn').onclick=()=>topologyZoom(.72);$('topologyZoomOut').onclick=()=>topologyZoom(1.38);$('topologyFit').onclick=topologyFit;$('topologyReset').onclick=()=>{const b=topologyState.baseBox;topologySetBox({x:b.x+b.w*.25,y:b.y+b.h*.25,w:b.w*.5,h:b.h*.5})};$('topologyFind').onclick=topologyFind;$('topologySearch').addEventListener('keydown',e=>{if(e.key==='Enter'){e.preventDefault();topologyFind()}});document.querySelectorAll('.topologyHop').forEach(b=>b.onclick=()=>{topologyState.hops=b.dataset.hops;document.querySelectorAll('.topologyHop').forEach(x=>x.classList.toggle('active',x===b));topologyApplyFocus()});const om=$('topologyOpenMap');if(om)om.onclick=topologyOpenMap;svg.addEventListener('wheel',e=>{e.preventDefault();const r=svg.getBoundingClientRect(),cx=(e.clientX-r.left)/r.width,cy=(e.clientY-r.top)/r.height;topologyZoom(e.deltaY<0?.82:1.22,cx,cy)},{passive:false});svg.addEventListener('pointerdown',e=>{if(e.target.closest('.topoNode'))return;svg.setPointerCapture(e.pointerId);topologyState.drag={x:e.clientX,y:e.clientY,box:{...topologyState.box}};svg.parentElement.classList.add('dragging')});svg.addEventListener('pointermove',e=>{const d=topologyState.drag;if(!d)return;const r=svg.getBoundingClientRect(),dx=(e.clientX-d.x)*d.box.w/r.width,dy=(e.clientY-d.y)*d.box.h/r.height;topologySetBox({x:d.box.x-dx,y:d.box.y-dy,w:d.box.w,h:d.box.h})});const endDrag=e=>{if(topologyState.drag){topologyState.drag=null;svg.parentElement.classList.remove('dragging')}};svg.addEventListener('pointerup',endDrag);svg.addEventListener('pointercancel',endDrag)}

let topologyPopout=null;
function topologyPopoutPayload(){
 return {
  nodes:topologyState.nodes.map(n=>({...n})),
  edges:topologyState.edges.map(e=>({...e})),
  selected:topologyState.selected||null,
  hops:topologyState.hops,
  root:topologyState.root||''
 };
}
function topologySyncPopout(){
 if(!topologyPopout||topologyPopout.closed){topologyPopout=null;return}
 try{if(typeof topologyPopout.receiveTopology==='function')topologyPopout.receiveTopology(topologyPopoutPayload())}catch(e){}
}
function topologyOpenMap(){
 if(topologyPopout&&!topologyPopout.closed){topologyPopout.focus();topologySyncPopout();return}
 topologyPopout=window.open('','dxspider-topology-map','popup=yes,width=1500,height=950,resizable=yes,scrollbars=no');
 if(!topologyPopout)return;
 const d=topologyPopout.document;
 d.open();
 d.write(`<!doctype html><html><head><meta charset="utf-8"><title>DXSpider Topology Map</title>
 <style>
 *{box-sizing:border-box}html,body{margin:0;width:100%;height:100%;overflow:hidden;font:13px system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;color:#173f55;background:#f4f8fa}
 body{display:grid;grid-template-rows:auto minmax(0,1fr) auto}
 button,input{font:inherit}button{border:1px solid #b9cbd5;background:#fff;color:#173f55;border-radius:5px;padding:6px 9px;cursor:pointer}button:hover{background:#eef6f9}button.active{background:#174f6b;color:#fff;border-color:#174f6b}
 .bar{display:flex;align-items:center;gap:6px;white-space:nowrap;padding:8px 10px;border-bottom:1px solid #ccd9e2;background:#fff}
 .bar input{width:20ch;max-width:20ch;padding:6px 8px;border:1px solid #b9cbd5;border-radius:5px}
 .spacer{flex:1}.legend{display:flex;gap:10px;margin-left:8px;color:#607681;font-size:11px}.legend span{display:flex;gap:4px;align-items:center}.dot{width:10px;height:10px;border-radius:50%;display:inline-block;border:1px solid rgba(0,0,0,.12)}.self{background:#083b66}.direct{background:#007c91}.pc92{background:#5b50a6}.legacy{background:#a96b00}
 #stage{position:relative;min-height:0;background:#fbfdfe;overflow:hidden;cursor:grab;user-select:none}#stage.dragging{cursor:grabbing}svg{display:block;width:100%;height:100%}
 .edge{stroke:#cbd8df;stroke-width:1;opacity:.72}.edge.pc92{stroke:#8d86bd}.edge.direct{stroke:#00849a;stroke-width:2;opacity:.95}.edge.dim{opacity:.05}.edge.selected{stroke:#d45500;stroke-width:2.8;opacity:1}
 .node{cursor:pointer}.node circle{stroke:#fff;stroke-width:1.5}.node.self circle{fill:#083b66;stroke-width:3}.node.direct circle{fill:#007c91}.node.pc92 circle{fill:#5b50a6}.node.legacy circle{fill:#a96b00}.node text{font-size:10px;fill:#314f5f;paint-order:stroke;stroke:#fff;stroke-width:3px;stroke-linejoin:round;pointer-events:none}.node.self text,.node.direct text{font-weight:750;fill:#173f55}.node.selected circle{stroke:#e75b00;stroke-width:4}.node.neighbour circle{stroke:#00a0b8;stroke-width:3}.node.dim{opacity:.13}
 .hint{position:absolute;left:10px;bottom:8px;padding:4px 7px;border-radius:4px;background:rgba(255,255,255,.9);color:#718590;font-size:10px;pointer-events:none}
 #info{border-top:1px solid #ccd9e2;background:#fff;padding:8px 10px;min-height:44px;max-height:112px;overflow:auto}
 .infoTop{display:flex;align-items:baseline;gap:16px;white-space:nowrap}.infoTop h3{font-size:18px;margin:0}.type{margin-left:auto;font-weight:750}.metrics{display:flex;gap:20px;margin-left:8px}.metrics b{font-weight:750}.adj{display:flex;align-items:center;gap:6px;flex-wrap:wrap;margin-top:6px}.adj strong{margin-right:3px}.adj button{font-size:13px;font-weight:650;padding:3px 7px}
 </style></head><body>
 <div class="bar"><input id="q" type="search" autocomplete="off" placeholder="Find CALL"><button id="find">Find</button><button id="zin">+</button><button id="zout">−</button><button id="fit">Fit</button><button id="reset">100%</button><button class="hop active" data-hops="all">All</button><button class="hop" data-hops="1">1 hop</button><button class="hop" data-hops="2">2 hops</button><span class="spacer"></span><div class="legend"><span><i class="dot self"></i>Local</span><span><i class="dot direct"></i>Direct</span><span><i class="dot pc92"></i>PC9X</span><span><i class="dot legacy"></i>Non-PC9X</span></div><button id="refresh">Refresh</button></div>
 <div id="stage"><svg id="g"></svg><div class="hint">Wheel: zoom · Drag: pan · Click: inspect · Double click: focus</div></div>
 <div id="info">Select a node to inspect it.</div>
 <script>
 let st={nodes:[],edges:[],by:new Map(),adj:new Map(),pos:new Map(),selected:null,hops:'all',base:{x:0,y:0,w:1400,h:900},box:{x:0,y:0,w:1400,h:900},drag:null};
 const $=id=>document.getElementById(id), esc=x=>String(x??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
 function box(b){st.box={...b};$('g').setAttribute('viewBox',b.x+' '+b.y+' '+b.w+' '+b.h)}
 function fit(){box({...st.base})} function zoom(f,cx=.5,cy=.5){let b=st.box,nw=b.w*f,nh=b.h*f,min=st.base.w*.08,max=st.base.w*3;if(nw<min){nh*=min/nw;nw=min}if(nw>max){nh*=max/nw;nw=max}box({x:b.x+(b.w-nw)*cx,y:b.y+(b.h-nh)*cy,w:nw,h:nh})}
 function neighbours(call,max=1){const seen=new Set([call]),q=[[call,0]];while(q.length){const [a,d]=q.shift();if(d>=max)continue;for(const b of st.adj.get(a)||[])if(!seen.has(b)){seen.add(b);q.push([b,d+1])}}return seen}
 function focus(){const sel=st.selected,h=st.hops==='all'?null:Number(st.hops),vis=sel&&h?neighbours(sel,h):null,near=sel?neighbours(sel,1):new Set();document.querySelectorAll('.node').forEach(g=>{let c=g.dataset.call;g.classList.toggle('selected',c===sel);g.classList.toggle('neighbour',!!sel&&c!==sel&&near.has(c));g.classList.toggle('dim',!!vis&&!vis.has(c))});document.querySelectorAll('.edge').forEach(l=>{let a=l.dataset.from,b=l.dataset.to;l.classList.toggle('selected',!!sel&&(a===sel||b===sel));l.classList.toggle('dim',!!vis&&(!vis.has(a)||!vis.has(b)))})}
 function inspect(call){const n=st.by.get(call);if(!n)return;const rel=[...(st.adj.get(call)||[])].sort(),type=n.self?'Local node':n.direct?'Direct neighbour':n.do_pc9x?'PC9X node':'Non-PC9X node';$('info').innerHTML='<div class="infoTop"><h3>'+esc(n.call)+'</h3><div class="metrics"><span>Connection <b>'+(n.self?'Local':n.direct?'Direct':'Known route')+'</b></span><span>Protocol <b>'+(n.do_pc9x?'PC9X':'Other')+'</b></span><span>PC92K users <b>'+(n.pc92_users==null?'—':Number(n.pc92_users).toLocaleString())+'</b></span><span>Known users <b>'+Number(n.user_count||0).toLocaleString()+'</b></span><span>PC92K nodes <b>'+(n.pc92_nodes==null?'—':Number(n.pc92_nodes).toLocaleString())+'</b></span><span>Known children <b>'+Number(n.child_count||0).toLocaleString()+'</b></span><span>Adjacent links <b>'+rel.length.toLocaleString()+'</b></span></div><strong class="type">'+esc(type)+'</strong></div><div class="adj"><strong>Adjacent nodes</strong>'+ (rel.slice(0,80).map(c=>'<button data-call="'+esc(c)+'">'+esc(c)+'</button>').join('')||'<span>None in this snapshot</span>')+'</div>';$('info').querySelectorAll('button[data-call]').forEach(b=>b.onclick=()=>select(b.dataset.call,true))}
 function select(call,center=false){if(!st.by.has(call))return;st.selected=call;inspect(call);focus();if(center){let p=st.pos.get(call),b=st.box;if(p)box({x:p[0]-b.w/2,y:p[1]-b.h/2,w:b.w,h:b.h})}}
 function find(){let q=$('q').value.trim().toUpperCase();if(!q)return;let n=st.nodes.find(n=>String(n.call).toUpperCase()===q)||st.nodes.find(n=>String(n.call).toUpperCase().includes(q));if(n)select(n.call,true)}
 function draw(){const nodes=st.nodes,edges=st.edges,W=1400,H=Math.max(760,Math.min(1400,540+nodes.length*.95)),cx=W/2,cy=H/2,root=st.root||nodes.find(n=>n.self)?.call||'';st.by=new Map(nodes.map(n=>[n.call,n]));st.adj=new Map(nodes.map(n=>[n.call,new Set()]));for(const e of edges)if(st.adj.has(e.from)&&st.adj.has(e.to)){st.adj.get(e.from).add(e.to);st.adj.get(e.to).add(e.from)}const depth=new Map(),q=[];if(root&&st.by.has(root)){depth.set(root,0);q.push(root)}while(q.length){let a=q.shift(),d=depth.get(a);for(const b of st.adj.get(a)||[])if(!depth.has(b)){depth.set(b,d+1);q.push(b)}}let maxd=Math.max(1,...depth.values());for(const n of nodes)if(!depth.has(n.call))depth.set(n.call,maxd+1);maxd=Math.max(...depth.values());const rings=new Map();for(const n of nodes){let d=depth.get(n.call);if(!rings.has(d))rings.set(d,[]);rings.get(d).push(n)}st.pos=new Map();for(const [d,arr] of [...rings.entries()].sort((a,b)=>a[0]-b[0])){arr.sort((a,b)=>String(a.call).localeCompare(String(b.call)));if(d===0){for(const n of arr)st.pos.set(n.call,[cx,cy]);continue}let rad=Math.min(W*.43,H*.43)*(d/Math.max(1,maxd));arr.forEach((n,i)=>{let a=-Math.PI/2+2*Math.PI*i/arr.length;st.pos.set(n.call,[cx+Math.cos(a)*rad,cy+Math.sin(a)*rad])})}st.base={x:0,y:0,w:W,h:H};st.box={...st.base};const NS='http://www.w3.org/2000/svg',svg=$('g');svg.innerHTML='';let ge=document.createElementNS(NS,'g'),gn=document.createElementNS(NS,'g');svg.append(ge,gn);for(const e of edges){let a=st.pos.get(e.from),b=st.pos.get(e.to);if(!a||!b)continue;let l=document.createElementNS(NS,'line');l.setAttribute('x1',a[0]);l.setAttribute('y1',a[1]);l.setAttribute('x2',b[0]);l.setAttribute('y2',b[1]);l.dataset.from=e.from;l.dataset.to=e.to;l.setAttribute('class','edge'+(e.direct?' direct':'')+(e.pc92?' pc92':''));ge.append(l)}for(const n of nodes){let p=st.pos.get(n.call);if(!p)continue;let g=document.createElementNS(NS,'g'),cls=n.self?'self':n.direct?'direct':n.do_pc9x?'pc92':'legacy';g.setAttribute('class','node '+cls);g.dataset.call=n.call;g.setAttribute('transform','translate('+p[0]+' '+p[1]+')');let c=document.createElementNS(NS,'circle');c.setAttribute('r',n.self?10:n.direct?8:5);let t=document.createElementNS(NS,'text');t.setAttribute('x',n.self?14:n.direct?12:8);t.setAttribute('y','4');t.textContent=n.call;g.append(c,t);g.onclick=e=>{e.stopPropagation();select(n.call)};g.ondblclick=e=>{e.stopPropagation();select(n.call,true);zoom(.55)};gn.append(g)}fit();if(st.selected&&st.by.has(st.selected))select(st.selected);else if(root)select(root)}
 window.receiveTopology=p=>{let old=st.selected;st.nodes=p.nodes||[];st.edges=p.edges||[];st.root=p.root||'';st.hops=p.hops||'all';st.selected=p.selected||old;document.querySelectorAll('.hop').forEach(b=>b.classList.toggle('active',b.dataset.hops===st.hops));draw()}
 $('find').onclick=find;$('q').onkeydown=e=>{if(e.key==='Enter'){e.preventDefault();find()}};$('zin').onclick=()=>zoom(.72);$('zout').onclick=()=>zoom(1.38);$('fit').onclick=fit;$('reset').onclick=()=>{let b=st.base;box({x:b.x+b.w*.25,y:b.y+b.h*.25,w:b.w*.5,h:b.h*.5})};document.querySelectorAll('.hop').forEach(b=>b.onclick=()=>{st.hops=b.dataset.hops;document.querySelectorAll('.hop').forEach(x=>x.classList.toggle('active',x===b));focus()});$('refresh').onclick=()=>{if(window.opener&&!window.opener.closed)window.opener.supervisorRequest('topology')};
 const svg=$('g');svg.onwheel=e=>{e.preventDefault();let r=svg.getBoundingClientRect();zoom(e.deltaY<0?.82:1.22,(e.clientX-r.left)/r.width,(e.clientY-r.top)/r.height)};svg.onpointerdown=e=>{if(e.target.closest('.node'))return;svg.setPointerCapture(e.pointerId);st.drag={x:e.clientX,y:e.clientY,box:{...st.box}};$('stage').classList.add('dragging')};svg.onpointermove=e=>{if(!st.drag)return;let r=svg.getBoundingClientRect(),dx=(e.clientX-st.drag.x)*st.drag.box.w/r.width,dy=(e.clientY-st.drag.y)*st.drag.box.h/r.height;box({x:st.drag.box.x-dx,y:st.drag.box.y-dy,w:st.drag.box.w,h:st.drag.box.h})};svg.onpointerup=svg.onpointercancel=()=>{st.drag=null;$('stage').classList.remove('dragging')};
 if(window.opener&&!window.opener.closed)window.opener.topologySyncPopout();
 <\/script></body></html>`);
 d.close();
 topologyPopout.focus();
}

function renderTopology(r){
 const rawNodes=Array.isArray(r.nodes)?r.nodes:[],rawEdges=Array.isArray(r.edges)?r.edges:[];
 const compact=r.wire_format==='compact-v1'||r.wire_format==='compact-v2';
 const nodes=compact?rawNodes.map(n=>({call:n[0],self:!!n[1],direct:!!n[2],do_pc9x:n[3],user_count:Number(n[4]||0),child_count:Number(n[5]||0),pc92_users:r.wire_format==='compact-v2'&&n[6]!=null?Number(n[6]):null,pc92_nodes:r.wire_format==='compact-v2'&&n[7]!=null?Number(n[7]):null})):rawNodes;
 const edges=compact?rawEdges.map(e=>({from:rawNodes[e[0]]?.[0],to:rawNodes[e[1]]?.[0],direct:!!e[2],pc92:!!e[3]})):rawEdges;
 const svg=$('topologyGraph'),empty=$('topologyEmpty');
 setText('topoNodes',Number(r.node_count??nodes.length).toLocaleString());setText('topoEdges',`${Number(r.edge_count??edges.length).toLocaleString()} links`);setText('topoDirect',Number(r.direct_count||0).toLocaleString());setText('topoPc9x',Number(r.pc92_count||0).toLocaleString());setText('topoNonPc9x',Number(r.non_pc92_count||0).toLocaleString());setText('topoTruncated',r.truncated?'snapshot truncated':'known nodes');
 if(!svg)return;if(!nodes.length){svg.innerHTML='';if(empty)empty.style.display='flex';return}if(empty)empty.style.display='none';
 const W=1400,H=Math.max(760,Math.min(1400,540+nodes.length*.95)),cx=W/2,cy=H/2,root=r.root||nodes.find(n=>n.self)?.call||'';
 const byCall=new Map(nodes.map(n=>[n.call,n])),adj=new Map(nodes.map(n=>[n.call,new Set()]));for(const e of edges){if(adj.has(e.from)&&adj.has(e.to)){adj.get(e.from).add(e.to);adj.get(e.to).add(e.from)}}
 const depth=new Map(),q=[];if(root&&byCall.has(root)){depth.set(root,0);q.push(root)};while(q.length){const a=q.shift(),d=depth.get(a);for(const b of adj.get(a)||[])if(!depth.has(b)){depth.set(b,d+1);q.push(b)}}
 let maxd=Math.max(1,...depth.values());for(const n of nodes)if(!depth.has(n.call))depth.set(n.call,maxd+1);maxd=Math.max(...depth.values());const rings=new Map();for(const n of nodes){const d=depth.get(n.call);if(!rings.has(d))rings.set(d,[]);rings.get(d).push(n)};const pos=new Map();
 for(const [d,arr] of [...rings.entries()].sort((a,b)=>a[0]-b[0])){arr.sort((a,b)=>String(a.call).localeCompare(String(b.call)));if(d===0){for(const n of arr)pos.set(n.call,[cx,cy]);continue}const rad=Math.min(W*.43,H*.43)*(d/Math.max(1,maxd));arr.forEach((n,i)=>{const a=-Math.PI/2+2*Math.PI*i/arr.length;pos.set(n.call,[cx+Math.cos(a)*rad,cy+Math.sin(a)*rad])})}
 topologyState={...topologyState,nodes,edges,byCall,adj,positions:pos,root,selected:topologyState.selected&&byCall.has(topologyState.selected)?topologyState.selected:null,baseBox:{x:0,y:0,w:W,h:H},box:{x:0,y:0,w:W,h:H}};
 const NS='http://www.w3.org/2000/svg';svg.innerHTML='';const gE=document.createElementNS(NS,'g'),gN=document.createElementNS(NS,'g');gE.setAttribute('class','topoEdges');gN.setAttribute('class','topoNodes');svg.append(gE,gN);
 for(const e of edges){const a=pos.get(e.from),b=pos.get(e.to);if(!a||!b)continue;const l=document.createElementNS(NS,'line');l.setAttribute('x1',a[0]);l.setAttribute('y1',a[1]);l.setAttribute('x2',b[0]);l.setAttribute('y2',b[1]);l.setAttribute('data-from',e.from);l.setAttribute('data-to',e.to);l.setAttribute('class',`topoEdge${e.direct?' direct':''}${e.pc92?' pc92':''}`);gE.append(l)}
 for(const n of nodes){const p=pos.get(n.call);if(!p)continue;const g=document.createElementNS(NS,'g'),cls=n.self?'self':n.direct?'direct':n.do_pc9x?'pc92':'legacy';g.setAttribute('class',`topoNode ${cls}`);g.setAttribute('data-call',n.call);g.setAttribute('transform',`translate(${p[0]} ${p[1]})`);const c=document.createElementNS(NS,'circle');c.setAttribute('r',n.self?10:n.direct?8:5);const t=document.createElementNS(NS,'text');t.setAttribute('x',n.self?14:n.direct?12:8);t.setAttribute('y','4');t.textContent=n.call;const title=document.createElementNS(NS,'title');title.textContent=`${n.call} · ${n.direct?'direct · ':''}${n.do_pc9x?'PC9X':'non-PC9X'} · children ${n.child_count||0} · users ${n.user_count||0}`;g.append(c,t,title);g.addEventListener('click',e=>{e.stopPropagation();topologySelect(n.call,false)});g.addEventListener('dblclick',e=>{e.stopPropagation();topologySelect(n.call,true);topologyZoom(.55)});gN.append(g)}
 topologyBindControls();topologyFit();if(topologyState.selected)topologySelect(topologyState.selected,false);else if(root)topologySelect(root,false);topologySyncPopout();
}

function renderProtocolInputDiagnostics(proto){
 const d=proto?.input_diagnostics||{},mal=d.malformed||{},unk=d.unknown_protocol||{},byPc=mal.by_pc||{},peers=d.peers||{};
 const pcNames=Object.keys(byPc).sort((a,b)=>Number(a.slice(2))-Number(b.slice(2))),peerNames=Object.keys(peers).sort();
 setText('diagMalformed',Number(mal.packets||0).toLocaleString());setText('diagUnknown',Number(unk.packets||0).toLocaleString());setText('diagAffectedPc',pcNames.length);setText('diagAffectedPeers',peerNames.length);
 const pcBody=$('diagPcRows');if(pcBody)pcBody.innerHTML=pcNames.map(name=>{const v=byPc[name]||{},fields=v.fields||{};const fs=Object.keys(fields).sort((a,b)=>Number(a)-Number(b)).map(f=>`#${esc(f)} ×${Number(fields[f]||0).toLocaleString()}`).join(', ')||'—';return `<tr><td class="callCell">${esc(name)}</td><td>${Number(v.packets||0).toLocaleString()}</td><td class="unitCell">${bytesVU(Number(v.bytes||0))}</td><td>${fs}</td></tr>`}).join('')||'<tr><td colspan="4" class="emptyCell">No malformed protocol input observed.</td></tr>';
 const peerBody=$('diagPeerRows');if(peerBody)peerBody.innerHTML=peerNames.map(peer=>{const v=peers[peer]||{},m=v.malformed||{},u=v.unknown_protocol||{},pcs=Object.keys(m.by_pc||{}).sort((a,b)=>Number(a.slice(2))-Number(b.slice(2))).map(x=>`${esc(x)} ×${Number(m.by_pc[x]?.packets||0).toLocaleString()}`).join(', ')||'—';return `<tr><td class="callCell">${esc(peer)}</td><td>${Number(m.packets||0).toLocaleString()}</td><td>${Number(u.packets||0).toLocaleString()}</td><td>${pcs}</td></tr>`}).join('')||'<tr><td colspan="4" class="emptyCell">No protocol input faults observed.</td></tr>';
}

function renderOverviewSnapshot(r){
 const snaps=r?.snapshots||{},st=snaps.status||{},tr=snaps.traffic||{},h=snaps.self_health||{},hist=r?.history||{},sys=r?.system||{};
 const bi=Number(tr.transport?.bytes_in||0),bo=Number(tr.transport?.bytes_out||0),li=Number(tr.transport?.lines_in||0),lo=Number(tr.transport?.lines_out||0),sp=Number(tr.spots?.total||0);
 setText('ovChannels',st.channels??'—');setText('ovChannelMix',`${st.users||0} users · ${st.nodes||0} nodes · ${st.rbn||0} RBN · ${st.web||0} Web`);
 setText('ovTraffic',`${fmtBytes(bi)} / ${fmtBytes(bo)}`);setText('ovLines',`${li.toLocaleString()} RX · ${lo.toLocaleString()} TX lines`);
 setText('ovSpots',sp.toLocaleString());setText('ovSpotMix',`${tr.spots?.hf||0} HF · ${tr.spots?.vhf||0} VHF`);
 setText('ovQueues',st.input_queue_max??'—');setText('ovQueueDetail',`${st.input_queue_total||0} total · ${st.pending_connects||0} pending connects`);
 setText('ovRbn',`${st.rbn||0} feeds`);setText('ovRbnDetail','latest stored status');setText('ovWeb',`${st.web||0} channels`);setText('ovWebDetail','latest stored status');
 const age=Math.max(...Object.values(r?.snapshot_age_seconds||{}).map(Number).filter(Number.isFinite),0);supervisorLastCollectedAt=Date.now()/1000-age;
 $('supervisorStatus').innerHTML=metricRows([['Node',st.node||'-'],['Branch',dash(st.git_branch),`updateBranchField${updateStatusCache?.comparisons?.branch?.comparable===true&&updateStatusCache.comparisons.branch.match===false?' updateMismatch':''}`],['Version',dash(st.version??st.dxspider_version),`updateVersionField${updateStatusCache?.comparisons?.version?.comparable===true&&updateStatusCache.comparisons.version.match===false?' updateMismatch':''}`],['Build',dash(st.build),`updateBuildField${updateStatusCache?.comparisons?.build?.comparable===true&&updateStatusCache.comparisons.build.match===false?' updateMismatch':''}`],['Git commit',dash(st.git_version),`updateCommitField${updateStatusCache?.comparisons?.commit?.comparable===true&&updateStatusCache.comparisons.commit.match===false?' updateMismatch':''}`],['Uptime',fmtDuration(st.uptime_seconds||0)],['Channels',st.channels||0],['Users / Nodes',`${st.users||0} / ${st.nodes||0}`],['RBN / Web',`${st.rbn||0} / ${st.web||0}`],['Pending connects',st.pending_connects||0],['Input queue',`${st.input_queue_total||0} total / ${st.input_queue_max||0} max`]]);
 $('supervisorOverviewTraffic').innerHTML=metricRows([['RX bytes',fmtBytes(bi)],['RX lines',li.toLocaleString()],['TX bytes',fmtBytes(bo)],['TX lines',lo.toLocaleString()],['Spots total',sp.toLocaleString()],['History coverage',fmtDuration(hist.window_coverage_seconds||0)]]);
 $('supervisorOverviewRbn').innerHTML=`<div class="compactRow"><strong>${Number(st.rbn||0)}</strong><span>RBN channels</span><span>stored snapshot ${age.toFixed(1)}s old</span></div>`;
 $('supervisorOverviewWeb').innerHTML=`<div class="compactRow"><strong>${Number(st.web||0)}</strong><span>Web channels</span><span>Admin RSS ${fmtBytes(sys.admin_rss_bytes||0)}</span></div>`;
 updateSupervisorBanner(st);updateSupervisorBanner();
}

function renderSupervisor(kind,r){
 if(!r)return;
 supervisorLastCollectedAt=Number(r.collected_at)||Date.now()/1000;
 $('supervisionState').textContent='';
 if(r.generation_ms!=null)setText('supervisionSnapshotCost',`snapshot ${Number(r.generation_ms||0).toFixed(3)} ms`);
 if(kind==='status'){
  updateSupervisorBanner(r);
  $('supervisorStatus').innerHTML=metricRows([['Node',r.node||'-'],['Branch',dash(r.git_branch),`updateBranchField${updateStatusCache?.comparisons?.branch?.comparable===true&&updateStatusCache.comparisons.branch.match===false?' updateMismatch':''}`],['Version',dash(r.version??r.dxspider_version)],['Build',dash(r.build),`updateBuildField${updateStatusCache?.comparisons?.build?.comparable===true&&updateStatusCache.comparisons.build.match===false?' updateMismatch':''}`],['Git commit',dash(r.git_version),`updateCommitField${updateStatusCache?.comparisons?.commit?.comparable===true&&updateStatusCache.comparisons.commit.match===false?' updateMismatch':''}`],['Uptime',fmtDuration(r.uptime_seconds||0)],['Channels',r.channels||0],['Users / Nodes',`${r.users||0} / ${r.nodes||0}`],['RBN / Web',`${r.rbn||0} / ${r.web||0}`],['Pending connects',r.pending_connects||0],['Input queue',`${r.input_queue_total||0} total / ${r.input_queue_max||0} max`],['CPU self / children',`${Number(r.cpu_self_seconds||0).toFixed(1)} / ${Number(r.cpu_children_seconds||0).toFixed(1)} s`]]);
  setText('ovChannels',r.channels||0);setText('ovChannelMix',`${r.users||0} users · ${r.nodes||0} nodes · ${r.rbn||0} RBN · ${r.web||0} Web`);
  setText('ovQueues',r.input_queue_max||0);setText('ovQueueDetail',`${r.input_queue_total||0} total · ${r.pending_connects||0} pending connects`);
 }
 if(kind==='traffic'){
  supervisorTrafficCache=r;
  renderProtocolInputDiagnostics(r.protocol);
  const bi=Number(r.transport?.bytes_in)||0,bo=Number(r.transport?.bytes_out)||0,li=Number(r.transport?.lines_in)||0,lo=Number(r.transport?.lines_out)||0,sp=Number(r.spots?.total)||0;
  const rows=[['RX bytes',fmtBytes(bi)],['RX lines',li.toLocaleString()],['TX bytes',fmtBytes(bo)],['TX lines',lo.toLocaleString()],['Spots total',sp.toLocaleString()],['HF / VHF',`${r.spots?.hf||0} / ${r.spots?.vhf||0}`]];
  $('supervisorTraffic').innerHTML=metricRowsHtml([['RX',bytesVU(bi)],['RX lines',valueUnit(li.toLocaleString(),'lines')],['TX',bytesVU(bo)],['TX lines',valueUnit(lo.toLocaleString(),'lines')],['Spots',valueUnit(sp.toLocaleString(),'spots')],['HF / VHF',valueUnit(`${r.spots?.hf||0} / ${r.spots?.vhf||0}`,'spots')]]);$('supervisorOverviewTraffic').innerHTML=metricRows(rows);
  setText('ovTraffic',`${fmtBytes(bi)} / ${fmtBytes(bo)}`);setText('ovLines',`${li.toLocaleString()} RX · ${lo.toLocaleString()} TX lines`);setText('ovSpots',sp.toLocaleString());setText('ovSpotMix',`${r.spots?.hf||0} HF · ${r.spots?.vhf||0} VHF`);
  setText('trRx',fmtBytes(bi));setText('trRxLines',`${li.toLocaleString()} lines`);setText('trTx',fmtBytes(bo));setText('trTxLines',`${lo.toLocaleString()} lines`);setText('trSpots',sp.toLocaleString());setText('trSpotMix',`${r.spots?.hf||0} HF · ${r.spots?.vhf||0} VHF`);
  const pcs=r.pc_spots;
  const proto=r.protocol;
  const protoPackets=(name,dir)=>Number(proto?.protocols?.[name]?.[dir]?.packets||0);
  const logicalPackets=(name,kind)=>Number(proto?.logical?.[name]?.[kind]?.packets||0);
  const logicalSupported=(name,kind)=>!!proto?.capabilities?.[name]?.[kind];
  const logicalSummary=(name,kind)=>logicalSupported(name,kind)?valueUnit(logicalPackets(name,kind).toLocaleString(),'pkt'):'<span class="naValue">—</span>';
  if(pcs){
   const p11=$('pc11Stats');if(p11)p11.innerHTML=metricRowsHtml([
    ['Physical IN',valueUnit(protoPackets('PC11','in').toLocaleString(),'pkt')],['Accepted',logicalSummary('PC11','accepted')],['Physical OUT',valueUnit(protoPackets('PC11','out').toLocaleString(),'pkt')],['Promoted by PC61',valueUnit(Number(pcs.pc11_promoted_by_pc61||0).toLocaleString(),'pkt')],['Promoted route / IP',valueUnit(Number(pcs.pc11_promoted_by_route||0).toLocaleString(),'pkt')],['Promotions total',valueUnit(Number(pcs.pc11_promotions||0).toLocaleString(),'pkt')],['PC11 share',valueUnit(Number(pcs.pc11_percent||0).toFixed(1),'%')],['Promotion rate',valueUnit(Number(pcs.promotions_percent||0).toFixed(1),'%')]]);
   const p61=$('pc61Stats');if(p61)p61.innerHTML=metricRowsHtml([['Physical IN',valueUnit(protoPackets('PC61','in').toLocaleString(),'pkt')],['Accepted',logicalSummary('PC61','accepted')],['Physical OUT',valueUnit(protoPackets('PC61','out').toLocaleString(),'pkt')]]);
  }
  if(proto&&typeof proto==='object'){
   const protocols=proto.protocols||{},names=Object.keys(protocols).sort((a,b)=>Number(a.slice(2))-Number(b.slice(2)));
   let tip=0,tib=0,top=0,tob=0;const logicalTotals={generated:0,accepted:0,forwarded:0,reply:0};
   const logical=proto.logical||{},caps=proto.capabilities||{};
   const logicalCell=(name,kind)=>{
    if(name==='PC92'){const m={generated:'generated',accepted:'received',forwarded:'forwarded'}[kind];if(!m)return '<span class="naValue">—</span>';const b=r.pc92?.logical?.[m]||{};const n=['A','D','C','K'].reduce((a,x)=>a+Number(b?.[x]?.packets||0),0);return n.toLocaleString()}
    if(!caps?.[name]?.[kind])return '<span class="naValue">—</span>';return Number(logical?.[name]?.[kind]?.packets||0).toLocaleString();
   };
   const rows=names.map(name=>{const v=protocols[name]||{},i=v.in||{},o=v.out||{};const ip=Number(i.packets||0),ib=Number(i.bytes||0),op=Number(o.packets||0),ob=Number(o.bytes||0);tip+=ip;tib+=ib;top+=op;tob+=ob;for(const kind of Object.keys(logicalTotals)){if(name==='PC92'){const m={generated:'generated',accepted:'received',forwarded:'forwarded'}[kind];if(m)logicalTotals[kind]+=['A','D','C','K'].reduce((a,x)=>a+Number(r.pc92?.logical?.[m]?.[x]?.packets||0),0)}else if(caps?.[name]?.[kind])logicalTotals[kind]+=Number(logical?.[name]?.[kind]?.packets||0)}return `<tr><td class="callCell">${esc(name)}</td><td>${ip.toLocaleString()}</td><td class="unitCell">${bytesVU(ib)}</td><td>${op.toLocaleString()}</td><td class="unitCell">${bytesVU(ob)}</td><td>${logicalCell(name,'generated')}</td><td>${logicalCell(name,'accepted')}</td><td>${logicalCell(name,'forwarded')}</td><td>${logicalCell(name,'reply')}</td></tr>`}).join('');
   const pg=$('protocolGlobalRows');if(pg)pg.innerHTML=rows||'<tr><td colspan="9" class="emptyCell">No PC protocol traffic observed yet.</td></tr>';
   setText('protocolActiveCount',`${names.length} active`);setText('protocolTotalInPackets',tip.toLocaleString());const tibE=$('protocolTotalInBytes');if(tibE)tibE.innerHTML=bytesVU(tib);setText('protocolTotalOutPackets',top.toLocaleString());const tobE=$('protocolTotalOutBytes');if(tobE)tobE.innerHTML=bytesVU(tob);setText('protocolTotalGenerated',logicalTotals.generated.toLocaleString());setText('protocolTotalAccepted',logicalTotals.accepted.toLocaleString());setText('protocolTotalForwarded',logicalTotals.forwarded.toLocaleString());setText('protocolTotalReply',logicalTotals.reply.toLocaleString());
   setText('localGeneratedSpots',`Local user spots: ${Number(proto.local_spots_generated||0).toLocaleString()}`);
   const peers=proto.peers||{},peerRows=[];
   for(const peer of Object.keys(peers).sort())for(const name of Object.keys(peers[peer]||{}).sort((a,b)=>Number(a.slice(2))-Number(b.slice(2)))){const v=peers[peer][name]||{},i=v.in||{},o=v.out||{};peerRows.push(`<tr><td class="callCell">${esc(peer)}</td><td class="callCell">${esc(name)}</td><td>${Number(i.packets||0).toLocaleString()}</td><td class="unitCell">${bytesVU(Number(i.bytes||0))}</td><td>${Number(o.packets||0).toLocaleString()}</td><td class="unitCell">${bytesVU(Number(o.bytes||0))}</td></tr>`)}
   const pp=$('protocolPeerRows');if(pp)pp.innerHTML=peerRows.join('')||'<tr><td colspan="6" class="emptyCell">No per-neighbour PC traffic observed yet.</td></tr>';
  }
  const p92=r.pc92;
  if(p92){
   const sorts=['A','D','C','K'];
   const logical=[['gen','generated'],['recv','received'],['fwd','forwarded']];
   const slot=(bucket,x)=>bucket?.[x]||{};
   const cell=s=>`${valueUnit(Number(s?.packets||0).toLocaleString(),'pkt')}<small>${bytesVU(Number(s?.bytes||0))}</small>`;
   for(const [pfx,key] of logical)for(const x of sorts){const e=$(`pc92${pfx}${x}`);if(e)e.innerHTML=cell(slot(p92.logical?.[key],x))}
   for(const x of sorts){const ei=$(`pc92pin${x}`),eo=$(`pc92pout${x}`);if(ei)ei.innerHTML=cell(slot(p92.totals?.in,x));if(eo)eo.innerHTML=cell(slot(p92.totals?.out,x))}

   const sum=bucket=>sorts.reduce((a,x)=>({packets:a.packets+Number(bucket?.[x]?.packets||0),bytes:a.bytes+Number(bucket?.[x]?.bytes||0)}),{packets:0,bytes:0});
   const current={
    generated:sum(p92.logical?.generated),
    accepted:sum(p92.logical?.received),
    forwarded:sum(p92.logical?.forwarded),
    physical_in:sum(p92.totals?.in),
    physical_out:sum(p92.totals?.out)
   };
   const now=Number(r.collected_at)||Date.now()/1000,boot=(r.boot_id??null);
   let rateOK=false,dt=0;
   if(pc92Previous&&now>pc92Previous.t){
    dt=now-pc92Previous.t;
    const sameBoot=boot==null||pc92Previous.boot==null||boot===pc92Previous.boot;
    const monotonic=Object.keys(current).every(k=>current[k].packets>=pc92Previous.values[k].packets&&current[k].bytes>=pc92Previous.values[k].bytes);
    rateOK=sameBoot&&monotonic;
   }
   for(const [key,pfx] of [['generated','Gen'],['accepted','Acc'],['forwarded','Fwd'],['physical_in','Pin'],['physical_out','Pout']]){
    const v=current[key],prev=pc92Previous?.values?.[key];
    const ep=$(`pc92Total${pfx}Packets`),eb=$(`pc92Total${pfx}Bytes`),er=$(`pc92Total${pfx}Pps`),ebr=$(`pc92Total${pfx}Bps`);
    if(ep)ep.innerHTML=valueUnit(v.packets.toLocaleString(),'pkt');if(eb)eb.innerHTML=bytesVU(v.bytes);
    if(er)er.innerHTML=rateOK?valueUnit(((v.packets-prev.packets)/dt).toFixed(2),'pkt/s'):'—';
    if(ebr)ebr.innerHTML=rateOK?bytesVU((v.bytes-prev.bytes)/dt,'/s'):'—';
   }
   pc92Previous={t:now,boot,values:current};

   const neighbours=new Set([...Object.keys(p92.physical?.in||{}),...Object.keys(p92.physical?.out||{})]);
   const names=[...neighbours].sort();const renderNeighbour=n=>{let cells=`<td class="callCell">${esc(n)}</td>`;for(const x of sorts){cells+=`<td class="pc92CountCell">${cell(slot(p92.physical?.in?.[n],x))}</td><td class="pc92CountCell">${cell(slot(p92.physical?.out?.[n],x))}</td>`}return `<tr>${cells}</tr>`};
   const cut=Math.ceil(names.length/2),empty='<tr><td colspan="9" class="emptyCell">—</td></tr>';
   const left=$('pc92NeighbourRowsA'),right=$('pc92NeighbourRowsB');
   if(left)left.innerHTML=names.slice(0,cut).map(renderNeighbour).join('')||(names.length?empty:'<tr><td colspan="9" class="emptyCell">No direct PC92 A/D/C/K traffic observed since node start.</td></tr>');
   if(right)right.innerHTML=names.slice(cut).map(renderNeighbour).join('')||empty;
  }
  if(trafficPrevious&&Number(r.collected_at)>trafficPrevious.t){const dt=Number(r.collected_at)-trafficPrevious.t;setText('trRate',`${fmtBytes(Math.max(0,bi-trafficPrevious.bi)/dt)}/s RX`);setText('trRateDetail',`${fmtBytes(Math.max(0,bo-trafficPrevious.bo)/dt)}/s TX · ${((Math.max(0,li-trafficPrevious.li))/dt).toFixed(1)} / ${((Math.max(0,lo-trafficPrevious.lo))/dt).toFixed(1)} lines/s`)}
  trafficPrevious={t:Number(r.collected_at)||Date.now()/1000,bi,bo,li,lo};
 }
 renderNodes();
 if(kind==='web'){
  const rows=r.channels||[];const dropped=rows.reduce((a,x)=>a+(Number(x.feed_dropped)||0),0),pending=rows.reduce((a,x)=>a+(Number(x.bytes_waiting)||0),0),sat=rows.filter(x=>x.feed_saturated).length;
  const table=rows.map(x=>`<tr><td class="callCell">${esc(x.call)}</td><td>${esc(x.role||'-')}</td><td>${esc(x.logical_users||0)}</td><td>${esc(fmtBytes(x.bytes_waiting))}</td><td class="${Number(x.feed_dropped)>0?'warnText':''}">${esc(x.feed_dropped||0)}</td><td>${x.feed_saturated?statusBadge('YES','bad'):statusBadge('No','ok')}</td><td>${statusBadge(x.feed_saturated?'SATURATED':'OK',x.feed_saturated?'bad':'ok')}</td></tr>`).join('')||'<tr><td colspan="7" class="emptyCell">No Web channels.</td></tr>';
  $('supervisorWeb').innerHTML=table;
  $('supervisorOverviewWeb').innerHTML=rows.map(x=>`<div class="compactRow"><strong>${esc(x.call)}</strong><span>${esc(x.role||'-')}</span><span>${fmtBytes(x.bytes_waiting)} queued</span>${statusBadge(x.feed_saturated?'SATURATED':'OK',x.feed_saturated?'bad':'ok')}</div>`).join('')||'<div class="emptyCell">No Web channels.</div>';
  setText('ovWeb',`${rows.length} channels`);setText('ovWebDetail',`${fmtBytes(pending)} queued · ${dropped} dropped · ${sat} saturated`);
  const users=rows.flatMap(ch=>(ch.users||[]).map(u=>({...u,channel:ch.call})));
  const bc=r.browser_clients||{};
  const summary=$('webSessionSummary');
  if(summary) summary.innerHTML=metricRows([
   ['Clients',Number(bc.clients||0)],['Anonymous',Number(bc.anonymous||0)],['Authenticated',Number(bc.authenticated||0)],
   ['DXSpider logical users',users.length],['Registered',users.filter(u=>u.registered).length],
   ['Password configured',users.filter(u=>u.password_configured).length],['Unique real IPs',new Set(users.map(u=>u.ip).filter(Boolean)).size]
  ]);
  const body=$('webLogicalUsers');
  if(body) body.innerHTML=users.map(u=>`<tr><td>${esc(u.channel||'—')}</td><td class="callCell">${esc(u.call||'—')}</td><td>${esc(dash(u.ip))}</td><td>${esc(yn(u.registered))}</td><td>${esc(yn(u.password_configured))}</td><td>${esc(yn(u.password_used))}</td><td>${esc(yn(u.authenticated))}</td><td>${esc(dash(u.priv))}</td><td>${esc(fmtAge(u.startt))}</td></tr>`).join('')||'<tr><td colspan="9" class="emptyCell">No logical Web users in the current snapshot.</td></tr>';
 }
 if(kind==='rbn'){
  const rows=r.channels||[],q=rows.reduce((a,x)=>a+(Number(x.queue_depth)||0),0);
  $('supervisorRbn').innerHTML=rows.map(x=>`<div class="rbnCard"><div class="rbnHead"><strong>${esc(x.call)}</strong><span>Queue ${esc(x.queue_depth||0)}</span></div><table class="miniTable"><thead><tr><th>Window</th><th>Raw</th><th>Retrieved</th><th>Delivered</th><th>Users</th></tr></thead><tbody>${[['1 min',x.minute],['10 min',x.ten_minute||x['10_minute']],['1 hour',x.hour]].map(([w,v])=>`<tr><td>${w}</td><td>${Number(v?.raw||0).toLocaleString()}</td><td>${Number(v?.retrieved||0).toLocaleString()}</td><td>${Number(v?.delivered||0).toLocaleString()}</td><td>${Number(v?.users||0).toLocaleString()}</td></tr>`).join('')}</tbody></table></div>`).join('')||'<div class="emptyCell">No RBN channels.</div>';
  $('supervisorOverviewRbn').innerHTML=rows.map(x=>`<div class="compactRow"><strong>${esc(x.call)}</strong><span>queue ${esc(x.queue_depth||0)}</span><span>${Number(x.minute?.raw||0).toLocaleString()} raw/min</span><span>${Number(x.minute?.delivered||0).toLocaleString()} delivered/min</span></div>`).join('')||'<div class="emptyCell">No RBN channels.</div>';
  setText('ovRbn',`${rows.length} feeds`);setText('ovRbnDetail',`${q} queued · ${rows.reduce((a,x)=>a+(Number(x.minute?.raw)||0),0).toLocaleString()} raw/min`);
 }
 if(kind==='connections'){
  supervisorConnectionsCache=r.connections||[];
  const totals=r.connection_totals||{};
  const connected=supervisorConnectionsCache.filter(x=>x.online).length, disconnected=supervisorConnectionsCache.filter(x=>!x.online).length, repeated=supervisorConnectionsCache.filter(x=>Number(x.connect_count)>1).length, tooMany=supervisorConnectionsCache.filter(x=>Number(x.too_many_count)>0).length;
  setText('connAllCount',supervisorConnectionsCache.length);setText('connConnectedCount',connected);setText('connDisconnectedCount',disconnected);setText('connRepeatedCount',repeated);setText('connTooManyCount',tooMany);
  setText('connKpiConnected',connected);setText('connKpiConnects',totals.connects??0);setText('connKpiDisconnects',totals.disconnects??0);setText('connKpiTooMany',totals.too_many??0);renderConnections();renderConnectionAttention();renderNodes();renderUsers();
 }
 if(kind==='self_health'){
  const h=r.health||{},errors=Number(h.errors)||0;setHealth('diagHealth',errors?'ATTENTION':'HEALTHY',errors?'bad':'ok');
  $('supervisorDiagnostics').innerHTML=metricRows([['Schema',r.schema_version??'-'],['Supervisor',r.supervisor_version??'-'],['Requests',h.requests??'-'],['Errors',errors],['Last request',h.last_request?new Date(Number(h.last_request)*1000).toLocaleString():'-'],['Boot ID',r.boot_id||'-']]);
  $('supervisorPerformance').innerHTML=metricRows([['Current snapshot',`${Number(r.generation_ms||0).toFixed(3)} ms`],['Last generation',`${Number(h.last_generation_ms||0).toFixed(3)} ms`],['Maximum generation',`${Number(h.max_generation_ms||0).toFixed(3)} ms`],['Collected',new Date(Number(r.collected_at||0)*1000).toLocaleString()]]);
  $('supervisorDiagnosticsRaw').textContent=JSON.stringify(r,null,2);
 }
 if(kind==='topology'){renderTopology(r)}
 if(kind==='system'){
  $('systemHost').innerHTML=metricRows([['Uptime',fmtDuration(r.host_uptime_seconds||0)],['Load 1 min',Number(r.load1||0).toFixed(2)],['Load 5 min',Number(r.load5||0).toFixed(2)],['Load 15 min',Number(r.load15||0).toFixed(2)]]);
  $('systemMemory').innerHTML=metricRows([['RAM used',fmtBytes(r.mem_used_bytes)],['RAM available',fmtBytes(r.mem_available_bytes)],['RAM total',fmtBytes(r.mem_total_bytes)],['Swap used',fmtBytes(r.swap_used_bytes)],['Swap total',fmtBytes(r.swap_total_bytes)]]);
  $('systemAdmin').innerHTML=metricRows([['RSS',fmtBytes(r.admin_rss_bytes)],['Collector','dxweb-admin'],['DXSpider host reads','None']]);
 }
 updateSupervisorBanner();
}
// Extend the existing message handler without changing its authentication path.
const _dxwebSupervisorHandle=handle;
handle=function(m){
 if(m.type==='history_metrics_result'){metricsInflight=false;if(!authenticated)return;if(m.status==='ok')renderMetrics(m.result||{});else setText('metricsState',`History error: ${m.error||'unknown'}`);return;}
 if(/^supervisor_(overview|status|connections|traffic|web|rbn|self_health|system|topology)_result$/.test(m.type||'')){
  const kind=RegExp.$1;supervisorInflight.delete(kind);if(!authenticated)return;if(m.status==='ok'){if(kind==='overview')renderOverviewSnapshot(m.result);else renderSupervisor(kind,m.result)}else $('supervisionState').textContent=`Supervisor error: ${m.error||'unknown'}`;return;
 }
 return _dxwebSupervisorHandle(m);
};
