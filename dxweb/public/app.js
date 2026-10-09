/*
 * DXSpider Web
 *
 * Client-side application for DXSpider web user access.
 *
 * Copyright (c) 2026 Dirk Koopman G1TLH
 */
// DXSpider Web 2.8.14
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
 if(!loggedIn){if($('showHuman'))$('showHuman').checked=true;if($('showRbn'))$('showRbn').checked=false}
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
 if(!send({type:'reg_request',call:$('registerCall').value.trim().toUpperCase(),ssids,name:$('registerName').value.trim(),email:$('registerEmail').value.trim(),language:$('registerLanguage').value||'EN',comment:$('registerComment').value.trim()})){$('registerSubmit').disabled=false;$('registerResult').textContent='DXSpider connection is not ready.'}
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
$('loginCancel').addEventListener('click',()=>{$('loginDialog').close();$('loginError').textContent=''});
$('loginForm').addEventListener('submit',e=>{
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
function spotFilterChanged(k){
 spotCounts[k]=0;
 spotItems=spotItems.filter(x=>x.type!==k);
 renderSpots();
}
$('showHuman').onchange=()=>spotFilterChanged('human');$('showRbn').onchange=()=>spotFilterChanged('rbn');


// Browser-only great-circle calculations; the prefix map is generated offline
// from DXSpider's authoritative prefix_data.pl, never queried in the spot path.
let geoPrefixMap=null,geoPrefixLoading=false;
function geoLocator(s){
 s=String(s||'').trim().toUpperCase();if(!/^[A-R]{2}[0-9]{2}(?:[A-X]{2}(?:[0-9]{2}(?:[A-X]{2})?)?)?$/.test(s))return null;
 let lon=-180,lat=-90,lonSpan=20,latSpan=10;
 const alph='ABCDEFGHIJKLMNOPQRSTUVWX';
 for(let i=0;i<s.length;i+=2){
  const n=i/2;
  if(n===0){lon+=(s.charCodeAt(i)-65)*20;lat+=(s.charCodeAt(i+1)-65)*10}
  else if(n===1){lonSpan/=10;latSpan/=10;lon+=Number(s[i])*lonSpan;lat+=Number(s[i+1])*latSpan}
  else if(n%2===0){lonSpan/=24;latSpan/=24;lon+=alph.indexOf(s[i])*lonSpan;lat+=alph.indexOf(s[i+1])*latSpan}
  else{lonSpan/=10;latSpan/=10;lon+=Number(s[i])*lonSpan;lat+=Number(s[i+1])*latSpan}
 }
 return {lat:lat+latSpan/2,lon:lon+lonSpan/2};
}
function geoPrefix(dx){
 if(!geoPrefixMap)return null;
 const call=String(dx||'').toUpperCase().replace(/-\d+$/,'');
 // Exact callsigns and slash-prefixes take precedence; then longest prefix.
 const keys=[`=${call}`,call];
 const parts=call.split('/');
 for(const part of parts)if(part&&part.length<=4)keys.push(part);
 for(const key of keys)if(Object.prototype.hasOwnProperty.call(geoPrefixMap,key))return geoPrefixMap[key];
 const candidates=[call,...parts.filter(x=>x.length>=2)];
 for(const candidate of candidates)for(let n=candidate.length;n>=1;n--){const key=candidate.slice(0,n);if(Object.prototype.hasOwnProperty.call(geoPrefixMap,key))return geoPrefixMap[key]}
 return null;
}
function geoCalculate(item){
 const origin=geoLocator(document.getElementById('userLocator')?.value);
 if(!origin)return {distance:'—',bearing:'—',source:''};
 let dest=geoLocator(item.locDx),approx=false;
 if(!dest){const fallback=geoPrefix(item.dx);if(fallback){dest={lat:fallback[0],lon:fallback[1]};approx=true}}
 if(!dest)return {distance:'—',bearing:'—',source:''};
 const rad=Math.PI/180,p1=origin.lat*rad,p2=dest.lat*rad,dl=(dest.lon-origin.lon)*rad;
 const cosine=Math.min(1,Math.max(-1,Math.sin(p1)*Math.sin(p2)+Math.cos(p1)*Math.cos(p2)*Math.cos(dl)));
 const km=Math.round(6371.0088*Math.acos(cosine));
 const y=Math.sin(dl)*Math.cos(p2),x=Math.cos(p1)*Math.sin(p2)-Math.sin(p1)*Math.cos(p2)*Math.cos(dl);
 const bearing=((Math.round(Math.atan2(y,x)/rad)%360)+360)%360;
 return {distance:String(km)+' km',bearing:String(bearing).padStart(3,'0')+'°',source:approx?'Approximate DXCC/prefix position':'DX locator'};
}
function geoRenderValue(item,key){const g=geoCalculate(item);return key==='distance'?g.distance:g.bearing}
function geoLoadPrefix(){
 if(geoPrefixLoading)return;geoPrefixLoading=true;
 fetch('/geo-prefix.json',{cache:'no-cache'}).then(r=>{if(!r.ok)throw Error('prefix map missing');return r.json()}).then(data=>{
  if(data&&data.version===1&&data.prefixes&&typeof data.prefixes==='object')geoPrefixMap=data.prefixes;
  renderSpots();
 }).catch(()=>{/* DX locator calculations remain available without a map */});
}
const geoInput=document.getElementById('userLocator');
geoInput.value='';
geoInput.addEventListener('input',()=>{
 const value=geoInput.value.trim().toUpperCase();
 geoInput.setCustomValidity(value&&!geoLocator(value)?'Enter a valid Maidenhead locator (4, 6, 8 or 10 characters).':'');
 if(!geoInput.validity.valid)return;
 updateSpotLayout();renderSpots();
});
geoLoadPrefix();

// Optional spot columns and bounded Comment resizing; presentation only.
const spotCore=[['type','C/R',44],['utc','UTC',58],['freq','Freq',120],['dx','DX',120],['spotter','Spotter',120],['comment','Comment',80]];
const spotExtras=[['loc','Locator',78],['cq','CQ Zone',65],['itu','ITU Zone',65]];
let spotVisibleColumns=[],spotCommentPreferred=null,spotResizeActive=false;
try{const v=Number(localStorage.getItem('dxweb.spots.commentWidth'));if(v>=80&&v<=1200)spotCommentPreferred=v}catch(_){}
function spotSelected(){return new Set([...document.querySelectorAll('[data-spot-group]:checked')].map(e=>e.dataset.spotGroup))}
function updateSpotLayout(){
 const table=document.querySelector('.spotTable'),area=table?.closest('.spotResultArea');if(!area)return;
 const style=getComputedStyle(area);
 const available=Math.max(0,area.clientWidth-parseFloat(style.paddingLeft)-parseFloat(style.paddingRight)-8),selected=spotSelected();
 // Hide complete groups in priority order: ITU, CQ, Locator. Never hide core fields.
 const geoEnabled=!!geoLocator(document.getElementById('userLocator')?.value);
 const coreWidth=spotCore.reduce((s,x)=>s+x[2],0)+(geoEnabled?176:0);
 const groups=spotExtras.map(([key,name,w])=>({key,name,w,fields:selected.has(key)?[['Dx','DX'],['Spotter','Spotter']]:[]}));
 let extraWidth=groups.reduce((s,g)=>s+g.fields.length*g.w,0);
 for(const g of [...groups].reverse())if(extraWidth+coreWidth>available&&g.fields.length){extraWidth-=g.fields.length*g.w;g.fields=[]}
 const commentMin=80,base=coreWidth-commentMin;
 const comment=Math.max(commentMin,spotCommentPreferred===null?available-base-extraWidth:Math.min(spotCommentPreferred,Math.max(commentMin,available-base-extraWidth)));
 const cols=spotCore.map(([key,title,w])=>({key,title,w:key==='comment'?comment:w}));
 if(geoEnabled)cols.push({key:'distance',title:'Distance',w:96},{key:'bearing',title:'Bearing',w:80});
 for(const g of groups)for(const [suffix,title] of g.fields)cols.push({key:g.key+suffix,title,w:g.w,group:g.name});
 const signature=cols.map(x=>x.key).join('|');const previous=spotVisibleColumns.map(x=>x.key).join('|');
 spotVisibleColumns=cols;
 const total=cols.reduce((s,x)=>s+x.w,0);table.style.width=total+'px';table.style.minWidth=total+'px';
 $('spotCols').innerHTML=cols.map(x=>`<col style="width:${x.w}px">`).join('');
 if(signature!==previous){
  const groupHeaders=groups.filter(g=>g.fields.length).map(g=>`<th colspan="${g.fields.length}">${g.name}</th>`).join('');
  const hasExtras=!!groupHeaders;
  $('spotHeaders').innerHTML=`<tr class="spotHeadGroup">${cols.filter(x=>!x.group).map(x=>`<th ${hasExtras?'rowspan="2"':''} class="${x.key==='comment'?'commentHeader':(x.key==='distance'||x.key==='bearing'?'spotGeoNumeric':'')}">${x.title}${x.key==='comment'?'<span class="commentResizeHandle" role="separator" aria-label="Resize Comment column" title="Drag to resize Comment"></span>':''}</th>`).join('')}${groupHeaders}</tr>${hasExtras?`<tr class="spotHeadSub">${groups.map(g=>g.fields.map(f=>`<th>${f[1]}</th>`).join('')).join('')}</tr>`:''}`;
  renderSpots();
 }
}
for(const box of document.querySelectorAll('[data-spot-group]'))box.addEventListener('change',updateSpotLayout);
const spotArea=document.querySelector('.spotResultArea');
if(typeof ResizeObserver!=='undefined')new ResizeObserver(()=>{if(!spotResizeActive)updateSpotLayout()}).observe(spotArea.parentElement);
else window.addEventListener('resize',updateSpotLayout);
$('spotHeaders').addEventListener('pointerdown',e=>{
 if(!e.target.classList.contains('commentResizeHandle'))return;
 e.preventDefault();spotResizeActive=true;
 const startX=e.clientX,startWidth=spotVisibleColumns.find(x=>x.key==='comment')?.w||80;
 const move=ev=>{spotCommentPreferred=Math.max(80,Math.min(1200,startWidth+ev.clientX-startX));updateSpotLayout()};
 const done=()=>{spotResizeActive=false;window.removeEventListener('pointermove',move);window.removeEventListener('pointerup',done);window.removeEventListener('pointercancel',done);try{localStorage.setItem('dxweb.spots.commentWidth',String(Math.round(spotCommentPreferred)))}catch(_){}updateSpotLayout()};
 window.addEventListener('pointermove',move);window.addEventListener('pointerup',done);window.addEventListener('pointercancel',done);
});
window.addEventListener('load',updateSpotLayout);
updateSpotLayout();
function renderSpots(){
 const human=$('showHuman').checked,rbn=$('showRbn').checked;
 const a=spotItems.filter(x=>(x.type==='human'&&human)||(x.type==='rbn'&&rbn));
 $('spotRows').innerHTML=a.slice(-250).reverse().map(x=>`<tr>${spotVisibleColumns.map(col=>`<td class="${col.key==='distance'||col.key==='bearing'?'spotGeoNumeric':''}" title="${col.key==='distance'||col.key==='bearing'?esc(geoCalculate(x).source):esc(x[col.key]??'')}">${col.key==='type'?(x.type==='human'?'C':'R'):col.key==='distance'||col.key==='bearing'?esc(geoRenderValue(x,col.key)):esc(x[col.key]??'')}</td>`).join('')}</tr>`).join('');
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
   const enabled=k==='human'?$('showHuman').checked:$('showRbn').checked;
   if(!enabled)return;
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
   if(m.final!==false){finishCommandTarget(target);pendingCommandTargets.shift()}return;
 }
 if(m.type==='spot_result'){$('spotResult').textContent=responseText(m)||(m.status==='ok'?'Spot accepted by DXSpider':'Spot rejected');if(m.status==='ok')setTimeout(()=>$('spotDialog').close(),500);return}
 if(m.type==='ann_result'){$('annResult').textContent=responseText(m)||(m.status==='ok'?'Announcement accepted by DXSpider':'Announcement rejected');if(m.status==='ok')$('annText').value='';return}
 if(m.type==='feed'){if(!logoutPending)acceptFeed(m);return}
}
loginState(false);
connect();

updateRegistrationAccess();
