// DXSpider Web Administration 0.6.0
// Date: 2026-09-16
'use strict';
const $=id=>document.getElementById(id);
let ws=null,authenticated=false,logoutPending=false,authUser=null,activeSection='operation',activePanel='spots';
let spotItems=[],spotCounts={human:0,rbn:0},logs={ann:[],wwv:[],wcy:[],wx:[]},cmdHistory=[],historyPos=0,pendingCommandTargets=[];
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
function selectSection(id){activeSection=id;document.querySelectorAll('.mainTabs button').forEach(b=>b.classList.toggle('active',b.dataset.section===id));document.querySelectorAll('.section').forEach(s=>s.classList.toggle('active',s.id===id));if(authenticated&&id==='registration')loadPending()}
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
function openDecision(id,action,rows){decisionId=Number(id);const r=(rows||[]).find(x=>Number(x.id)===decisionId)||{};$('regActionTitle').textContent=action==='accept'?'Accept registration':'Reject registration';$('regActionSummary').textContent=`#${id} ${r.call||''} — ${r.email||''}${r.comment?'\n'+r.comment:''}`;$('regActionNote').value='';$('regActionResult').textContent='';$('regActionDialog').showModal()}
$('regAccept').onclick=()=>decision('accept');$('regReject').onclick=()=>decision('reject');
function decision(action){if(!decisionId)return;$('regActionResult').textContent='Processing…';send({type:`reg_${action}`,request_id:decisionId,note:$('regActionNote').value.trim()})}
function responseText(m){const a=Array.isArray(m.messages)?m.messages.filter(x=>x!=null):[];return a.join('\n')+(m.error?`${a.length?'\n':''}ERROR: ${m.error}`:'')}
function handle(m){if(m.type==='status'){$('status').textContent=m.state||'';if(m.node_call)$('nodeCall').textContent=m.node_call;if(m.authenticated===false&&!authenticated){setLocked(true);if(m.state==='ready')showLogin()}return}if(m.type==='auth'||m.type==='auth_result'){$('loginSubmit').disabled=false;if(m.status==='ok'){clearSessionContent();loginState(true,m);$('loginDialog').close();$('loginError').textContent='';loadPending()}else{loginState(false);$('loginError').textContent=m.error==='admin_privilege_required'?'SYSOP privilege 9 is required.':m.error==='password_required'?'A valid DXSpider password is required.':(m.error||'Authentication failed');showLogin($('loginError').textContent)}return}if(m.type==='logout_result'){logoutPending=false;loginState(false);showLogin();return}if(!authenticated)return;if(m.type==='reg_pending_result'){if(m.status==='ok')renderPending(m.result||[]);else notice(responseText(m));return}if(m.type==='reg_history_result'){if(m.status==='ok')renderHistory(m.result||[]);else notice(responseText(m));return}if(m.type==='reg_search_result'){if(m.status==='ok')renderHistory(m.result||[],'searchRows');else notice(responseText(m));return}if(m.type==='reg_accept_result'||m.type==='reg_reject_result'){if(m.status==='ok'){const pw=m.type==='reg_accept_result'&&m.result&&m.result.password?` Password: ${m.result.password}`:'';$('regActionResult').textContent='Completed.'+pw;setTimeout(()=>{$('regActionDialog').close();loadPending();loadHistory()},900)}else $('regActionResult').textContent=responseText(m);return}if(m.type==='feed'){acceptFeed(m);return}if(m.type==='command_result'){const target=pendingCommandTargets[0]||activePanel,t=responseText(m),out=target==='console'?$('consoleOutput'):document.querySelector(`#${target} .commandOutput`);if(logs[target]){if(t){logs[target].push(...t.split('\n'));renderLog(target)}}else if(out&&t){if(target==='console'){const b=document.createElement('div');b.className='consoleResponse';b.textContent=t;out.appendChild(b)}else out.textContent+=t+'\n';out.scrollTop=out.scrollHeight}if(m.final!==false)pendingCommandTargets.shift()}}
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
