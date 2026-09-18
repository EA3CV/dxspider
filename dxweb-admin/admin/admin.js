// DXSpider Web Administration 0.10.0
// Date: 2026-09-16
'use strict';
const $=id=>document.getElementById(id);
let ws=null,authenticated=false,logoutPending=false,authUser=null,activeSection='operation',activePanel='spots';
let spotItems=[],spotCounts={human:0,rbn:0},logs={ann:[],wwv:[],wcy:[],wx:[]},cmdHistory=[],historyPos=0,pendingCommandTargets=[];
let pc92Previous=null;
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
function connect(){const proto=location.protocol==='https:'?'wss':'ws';ws=new WebSocket(`${proto}://${location.host}/ws`);ws.onmessage=e=>{try{handle(JSON.parse(e.data))}catch(err){console.error('admin message error',err,e.data)}};ws.onclose=()=>{authenticated=false;logoutPending=false;loginState(false);$('status').textContent='disconnected';setTimeout(connect,2000)}}
$('loginButton').onclick=()=>{if(authenticated){if(logoutPending)return;logoutPending=true;send({type:'logout'});$('loginButton').textContent='Logging out…'}else showLogin()};
$('loginForm').addEventListener('submit',e=>{e.preventDefault();const call=$('loginCall').value.trim().toUpperCase(),password=$('loginPass').value;if(!call||!password){$('loginError').textContent='Callsign and password are required.';return}$('loginSubmit').disabled=true;if(!send({type:'auth',call,password})){$('loginSubmit').disabled=false;$('loginError').textContent='DXSpider connection is not ready';return}$('loginPass').value=''});
function selectSection(id){activeSection=id;document.querySelectorAll('.mainTabs button').forEach(b=>b.classList.toggle('active',b.dataset.section===id));document.querySelectorAll('.section').forEach(s=>s.classList.toggle('active',s.id===id));if(authenticated&&id==='registration')loadPending();if(authenticated&&id==='supervision')selectSupervision(activeSupervisionPanel)}
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
function handle(m){if(m.type==='status'){$('status').textContent=m.state||'';if(m.node_call)$('nodeCall').textContent=m.node_call;if(m.authenticated===false&&!authenticated){setLocked(true);if(m.state==='ready')showLogin()}return}if(m.type==='auth'||m.type==='auth_result'){$('loginSubmit').disabled=false;if(m.status==='ok'){clearSessionContent();loginState(true,m);$('loginDialog').close();$('loginError').textContent='';loadPending()}else{loginState(false);$('loginError').textContent=m.error==='admin_privilege_required'?'SYSOP privilege 9 is required.':m.error==='password_required'?'A valid DXSpider password is required.':(m.error||'Authentication failed');showLogin($('loginError').textContent)}return}if(m.type==='logout_result'){logoutPending=false;loginState(false);showLogin();return}if(!authenticated)return;if(m.type==='reg_pending_result'){if(m.status==='ok')renderPending(m.result||[]);else notice(responseText(m));return}if(m.type==='reg_history_result'){if(m.status==='ok')renderHistory(m.result||[]);else notice(responseText(m));return}if(m.type==='reg_search_result'){if(m.status==='ok')renderHistory(m.result||[],'searchRows');else notice(responseText(m));return}if(m.type==='reg_accept_result'||m.type==='reg_reject_result'){const expected=decisionAction?`reg_${decisionAction}_result`:null;if(expected&&m.type!==expected){$('regActionResult').textContent=`Unexpected registration response: ${m.type}`;return}if(m.status==='ok'){const accepted=m.type==='reg_accept_result';const pw=accepted&&m.result&&m.result.password?` Password: ${m.result.password}`:'';$('regActionResult').textContent=(accepted?'Accepted.':'Rejected.')+pw;setTimeout(()=>{$('regActionDialog').close();decisionId=null;decisionAction=null;loadPending();loadHistory()},900)}else{$('regAccept').disabled=false;$('regReject').disabled=false;$('regActionResult').textContent=responseText(m)}return}if(m.type==='reg_delete_user_result'){$('deleteUserConfirm').disabled=false;if(m.status==='ok'){const calls=(m.result&&m.result.affected_calls)||[];$('deleteUserResult').textContent=`Deleted ${calls.length} DXUser record(s): ${calls.join(', ')}`;loadHistory();setTimeout(()=>$('deleteUserDialog').close(),1200)}else{$('deleteUserResult').textContent=(Array.isArray(m.messages)&&m.messages.length?m.messages.join('\n'):(m.error||'Delete failed'))}return}
 if(m.type==='feed'){acceptFeed(m);return}if(m.type==='command_result'){const target=pendingCommandTargets[0]||activePanel,t=responseText(m),out=target==='console'?$('consoleOutput'):document.querySelector(`#${target} .commandOutput`);if(logs[target]){if(t){logs[target].push(...t.split('\n'));renderLog(target)}}else if(out&&t){if(target==='console'){const b=document.createElement('div');b.className='consoleResponse';b.textContent=t;out.appendChild(b)}else out.textContent+=t+'\n';out.scrollTop=out.scrollHeight}if(m.final!==false){finishCommandTarget(target);pendingCommandTargets.shift()}}}
loginState(false);connect();


// 0.6.1 - permanent Login/Logout control.
// Esc may close the login dialog; the button remains available to reopen it.
(() => {
  const btn = document.getElementById('loginButton');
  const dlg = document.getElementById('loginDialog');
  if (!btn || !dlg) return;

  function syncLoginButton() {
    const logged = !!(window.authenticated || (typeof authenticated !== 'undefined' && authenticated));
    let who = '';
    try {
      who = (typeof authUser !== 'undefined' && authUser) ? authUser : '';
    } catch (_) {}
    btn.textContent = logged ? ('Logout' + (who ? ' ' + who : '')) : 'Login';
  }

  btn.addEventListener('click', () => {
    let logged = false;
    try { logged = !!authenticated; } catch (_) { logged = !!window.authenticated; }
    if (!logged) {
      if (!dlg.open) dlg.showModal();
      const call = document.getElementById('loginCall');
      if (call) call.focus();
      return;
    }
    const oldLogout = document.getElementById('logoutButton');
    if (oldLogout && oldLogout !== btn) oldLogout.click();
  });

  dlg.addEventListener('close', syncLoginButton);
  window.addEventListener('dxweb-auth-changed', syncLoginButton);
  setInterval(syncLoginButton, 500);
  syncLoginButton();
})();

// DXSpider supervision v0.3: readable, navigable, read-only dashboard. No background polling.
let activeSupervisionPanel='overview',supervisorLastCollectedAt=0,supervisorStatusCache=null;
let supervisorConnectionsCache=[],connectionKind='all',trafficPrevious=null;
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
function supervisorKindsFor(panel){return panel==='overview'?['status','traffic','web','rbn']:panel==='diagnostics'?['self_health']:panel==='system'?['system']:panel==='nodes'?['connections']:[panel]}
function supervisorRequest(panel=activeSupervisionPanel){if(!authenticated)return;$('supervisionState').textContent=`Collecting ${panel} snapshot…`;for(const what of supervisorKindsFor(panel))send({type:`supervisor_${what}`})}
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
 const rows=supervisorConnectionsCache.filter(x=>(connectionKind==='all'||x.kind===connectionKind)&&(!q||String(x.call||'').toUpperCase().includes(q)));
 $('supervisorConnections').innerHTML=rows.map(x=>`<tr>
  <td class="callCell">${esc(x.call)}</td><td>${statusBadge(x.kind||'-','neutral')}</td>
  <td>${esc(x.outbound===true||x.outbound===1?'OUT':x.outbound===false||x.outbound===0?'IN':'—')}</td>
  <td>${esc(dash(x.ip??x.peer_ip??x.hostname))}</td><td>${esc(yn(x.registered))}</td><td>${esc(yn(x.password_configured))}</td><td>${esc(yn(x.password_used))}</td>
  <td>${esc(x.state||'-')}</td><td>${esc(fmtAge(x.connected_since))}</td><td>${esc(dash(x.cnum))}</td>
  <td class="${Number(x.queue_depth)>0?'warnText':''}">${esc(x.queue_depth||0)}</td>
  <td class="${Number(x.errors)>0?'badText':''}">${esc(x.errors||0)}</td><td class="unitCell">${bytesVU(x.bytes_in)}</td><td class="unitCell">${bytesVU(x.bytes_out)}</td>
 </tr>`).join('')||'<tr><td colspan="14" class="emptyCell">No matching connections.</td></tr>';
 renderNodes();
}
function renderNodes(){
 const body=$('supervisorNodes'); if(!body)return;
 const rows=supervisorConnectionsCache.filter(x=>x.kind==='node'&&!x.is_self);
 body.innerHTML=rows.map(x=>`<tr><td class="callCell">${esc(x.call)}</td>
 <td>${esc(x.outbound===true||x.outbound===1?'OUT':x.outbound===false||x.outbound===0?'IN':'—')}</td>
 <td>${esc(dash(x.ip??x.peer_ip??x.hostname))}</td><td>${esc(yn(x.registered))}</td><td>${esc(yn(x.password_configured))}</td>
 <td>${esc(fmtAge(x.connected_since))}</td><td>${esc(dash(x.git_branch))}</td><td>${esc(dash(x.dxspider_version))}</td>
 <td>${esc(dash(x.build))}</td><td>${esc(dash(x.git_version))}</td><td>${esc(yn(x.pc9x??x.do_pc9x))}</td><td>${esc(yn(x.via_pc92))}</td>
 <td>${x.pingave!=null?esc(Number(x.pingave).toFixed(3)):'—'}</td><td>${esc(x.state||'—')}</td></tr>`).join('')||
 '<tr><td colspan="14" class="emptyCell">No direct node channels in the current snapshot.</td></tr>';
}
document.querySelectorAll('.connFilter').forEach(b=>b.onclick=()=>{connectionKind=b.dataset.kind;document.querySelectorAll('.connFilter').forEach(x=>x.classList.toggle('active',x===b));renderConnections()});
if($('connSearch'))$('connSearch').oninput=renderConnections;
function renderSupervisor(kind,r){
 if(!r)return;
 supervisorLastCollectedAt=Number(r.collected_at)||Date.now()/1000;
 $('supervisionState').textContent=`Last ${kind} snapshot: ${new Date(supervisorLastCollectedAt*1000).toLocaleString()}${r.generation_ms!=null?` — ${Number(r.generation_ms||0).toFixed(3)} ms`:''}`;
 if(r.generation_ms!=null)setText('supervisionSnapshotCost',`snapshot ${Number(r.generation_ms||0).toFixed(3)} ms`);
 if(kind==='status'){
  updateSupervisorBanner(r);
  $('supervisorStatus').innerHTML=metricRows([['Node',r.node||'-'],['Branch',dash(r.git_branch)],['Version',dash(r.version??r.dxspider_version)],['Build',dash(r.build)],['Git commit',dash(r.git_version)],['Uptime',fmtDuration(r.uptime_seconds||0)],['Channels',r.channels||0],['Users / Nodes',`${r.users||0} / ${r.nodes||0}`],['RBN / Web',`${r.rbn||0} / ${r.web||0}`],['Pending connects',r.pending_connects||0],['Input queue',`${r.input_queue_total||0} total / ${r.input_queue_max||0} max`],['CPU self / children',`${Number(r.cpu_self_seconds||0).toFixed(1)} / ${Number(r.cpu_children_seconds||0).toFixed(1)} s`]]);
  setText('ovChannels',r.channels||0);setText('ovChannelMix',`${r.users||0} users · ${r.nodes||0} nodes · ${r.rbn||0} RBN · ${r.web||0} Web`);
  setText('ovQueues',r.input_queue_max||0);setText('ovQueueDetail',`${r.input_queue_total||0} total · ${r.pending_connects||0} pending connects`);
 }
 if(kind==='traffic'){
  const bi=Number(r.transport?.bytes_in)||0,bo=Number(r.transport?.bytes_out)||0,li=Number(r.transport?.lines_in)||0,lo=Number(r.transport?.lines_out)||0,sp=Number(r.spots?.total)||0;
  const rows=[['RX bytes',fmtBytes(bi)],['RX lines',li.toLocaleString()],['TX bytes',fmtBytes(bo)],['TX lines',lo.toLocaleString()],['Spots total',sp.toLocaleString()],['HF / VHF',`${r.spots?.hf||0} / ${r.spots?.vhf||0}`]];
  $('supervisorTraffic').innerHTML=metricRowsHtml([['RX',bytesVU(bi)],['RX lines',valueUnit(li.toLocaleString(),'lines')],['TX',bytesVU(bo)],['TX lines',valueUnit(lo.toLocaleString(),'lines')],['Spots',valueUnit(sp.toLocaleString(),'spots')],['HF / VHF',valueUnit(`${r.spots?.hf||0} / ${r.spots?.vhf||0}`,'spots')]]);$('supervisorOverviewTraffic').innerHTML=metricRows(rows);
  setText('ovTraffic',`${fmtBytes(bi)} / ${fmtBytes(bo)}`);setText('ovLines',`${li.toLocaleString()} RX · ${lo.toLocaleString()} TX lines`);setText('ovSpots',sp.toLocaleString());setText('ovSpotMix',`${r.spots?.hf||0} HF · ${r.spots?.vhf||0} VHF`);
  setText('trRx',fmtBytes(bi));setText('trRxLines',`${li.toLocaleString()} lines`);setText('trTx',fmtBytes(bo));setText('trTxLines',`${lo.toLocaleString()} lines`);setText('trSpots',sp.toLocaleString());setText('trSpotMix',`${r.spots?.hf||0} HF · ${r.spots?.vhf||0} VHF`);
  const pcs=r.pc_spots;
  if(pcs){
   const p11=$('pc11Stats');if(p11)p11.innerHTML=metricRowsHtml([
    ['Received',valueUnit(Number(pcs.pc11_received||0).toLocaleString(),'pkt')],['Promoted by PC61',valueUnit(Number(pcs.pc11_promoted_by_pc61||0).toLocaleString(),'pkt')],['Promoted route / IP',valueUnit(Number(pcs.pc11_promoted_by_route||0).toLocaleString(),'pkt')],['Promotions total',valueUnit(Number(pcs.pc11_promotions||0).toLocaleString(),'pkt')],['PC11 share',valueUnit(Number(pcs.pc11_percent||0).toFixed(1),'%')],['Promotion rate',valueUnit(Number(pcs.promotions_percent||0).toFixed(1),'%')]]);
   const p61=$('pc61Stats');if(p61)p61.innerHTML=metricRowsHtml([['Received',valueUnit(Number(pcs.pc61_received||0).toLocaleString(),'pkt')],['OUT','<span class=\"naValue\">—</span>']]);
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
   $('pc92NeighbourRowsA').innerHTML=names.slice(0,cut).map(renderNeighbour).join('')||(names.length?empty:'<tr><td colspan="9" class="emptyCell">No direct PC92 A/D/C/K traffic observed since node start.</td></tr>');
   $('pc92NeighbourRowsB').innerHTML=names.slice(cut).map(renderNeighbour).join('')||empty;
  }
  if(trafficPrevious&&Number(r.collected_at)>trafficPrevious.t){const dt=Number(r.collected_at)-trafficPrevious.t;setText('trRate',`${fmtBytes(Math.max(0,bi-trafficPrevious.bi)/dt)}/s RX`);setText('trRateDetail',`${fmtBytes(Math.max(0,bo-trafficPrevious.bo)/dt)}/s TX · ${((Math.max(0,li-trafficPrevious.li))/dt).toFixed(1)} / ${((Math.max(0,lo-trafficPrevious.lo))/dt).toFixed(1)} lines/s`)}
  trafficPrevious={t:Number(r.collected_at)||Date.now()/1000,bi,bo,li,lo};
 }
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
  const c=k=>supervisorConnectionsCache.filter(x=>x.kind===k).length;
  setText('connAllCount',supervisorConnectionsCache.length);setText('connNodeCount',c('node'));setText('connUserCount',c('user'));setText('connRbnCount',c('rbn'));setText('connWebCount',c('web'));renderConnections();
 }
 if(kind==='self_health'){
  const h=r.health||{},errors=Number(h.errors)||0;setHealth('diagHealth',errors?'ATTENTION':'HEALTHY',errors?'bad':'ok');
  $('supervisorDiagnostics').innerHTML=metricRows([['Schema',r.schema_version??'-'],['Supervisor',r.supervisor_version??'-'],['Requests',h.requests??'-'],['Errors',errors],['Last request',h.last_request?new Date(Number(h.last_request)*1000).toLocaleString():'-'],['Boot ID',r.boot_id||'-']]);
  $('supervisorPerformance').innerHTML=metricRows([['Current snapshot',`${Number(r.generation_ms||0).toFixed(3)} ms`],['Last generation',`${Number(h.last_generation_ms||0).toFixed(3)} ms`],['Maximum generation',`${Number(h.max_generation_ms||0).toFixed(3)} ms`],['Collected',new Date(Number(r.collected_at||0)*1000).toLocaleString()]]);
  $('supervisorDiagnosticsRaw').textContent=JSON.stringify(r,null,2);
 }
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
 if(authenticated&&/^supervisor_(status|connections|traffic|web|rbn|self_health|system)_result$/.test(m.type||'')){
  const kind=RegExp.$1;if(m.status==='ok')renderSupervisor(kind,m.result);else $('supervisionState').textContent=`Supervisor error: ${m.error||'unknown'}`;return;
 }
 return _dxwebSupervisorHandle(m);
};
