/*
 * DXSpider Web
 *
 * Client-side application for DXSpider web user access.
 *
 * Copyright (c) 2026 Dirk Koopman G1TLH
 */
// DXSpider Web 2.8.30
// Date: 2026-09-16
'use strict';
const $=id=>document.getElementById(id);
let ws=null, authenticated=false, logoutPending=false, authUser=null, authRegistered=false, passwordUsed=false, activeTab='spots';
let spotItems=[], spotCounts={human:0,rbn:0}, logs={ann:[],wwv:[],wcy:[],wx:[]};
let cmdHistory=[], historyPos=0, pendingCommandTargets=[], pendingCommandNames=[];

function send(o){if(!(ws&&ws.readyState===WebSocket.OPEN))return false;ws.send(JSON.stringify(o));return true}
function esc(v){return String(v??'').replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]))}
function setCount(k,n){const e=document.querySelector(`[data-count="${k}"]`);if(e)e.textContent=String(n)}
// Spot font preference is per authenticated callsign and per web application.
const spotFontKeyBase='dxspider.dxweb.spotFont.';
let spotFontPercent=100;
function spotFontApply(value,save=false){
 spotFontPercent=Math.max(70,Math.min(150,Math.round(value/10)*10));
 const area=document.querySelector('#spots .spotResultArea');
 if(area)area.style.setProperty('--spot-font-scale',String(spotFontPercent/100));
 const reset=$('spotFontReset');if(reset)reset.textContent=spotFontPercent+' %';
 if(save&&authenticated&&authUser){try{localStorage.setItem(spotFontKeyBase+authUser.toUpperCase(),String(spotFontPercent))}catch(_){}}
 if(typeof updateSpotLayout==='function')updateSpotLayout();
 if(save&&typeof spotPresentationSave==='function')spotPresentationSave();
}
function spotFontForSession(){
 let value=100;
 if(authenticated&&authUser){try{const saved=Number(localStorage.getItem(spotFontKeyBase+authUser.toUpperCase()));if(saved>=70&&saved<=150)value=saved}catch(_){}}
 spotFontApply(value,false);
}
$('spotFontDown').onclick=()=>spotFontApply(spotFontPercent-10,true);
$('spotFontUp').onclick=()=>spotFontApply(spotFontPercent+10,true);
$('spotFontReset').onclick=()=>spotFontApply(100,true);
const spotFeedKeyBase='dxspider.dxweb.spotFeeds.';
function spotFeedSave(){
 if(!authenticated||!authUser)return;
 try{localStorage.setItem(spotFeedKeyBase+authUser.toUpperCase(),JSON.stringify({human:$('showHuman').checked,rbn:$('showRbn').checked}))}catch(_){}
}
function spotFeedRestore(){
 let human=true,rbn=false;
 if(authenticated&&authUser){
  try{const raw=localStorage.getItem(spotFeedKeyBase+authUser.toUpperCase());if(raw!==null){const v=JSON.parse(raw);if(v&&typeof v.human==='boolean'&&typeof v.rbn==='boolean'){human=v.human;rbn=v.rbn}}}catch(_){}
 }
 $('showHuman').checked=human;$('showRbn').checked=rbn;
 spotCounts={human:0,rbn:0};spotItems=[];renderSpots();
}

function loginState(ok,m={}){
 authenticated=ok;document.body.classList.toggle('authenticated',ok);document.body.classList.toggle('anonymous',!ok); authUser=ok?(m.call||authUser):null;authRegistered=ok?Boolean(m.registered):false;passwordUsed=ok?Boolean(m.password_used):false;
 $('loginButton').textContent=ok?`Logout ${authUser}`:'Login';
 updateRegistrationAccess();
 spotFontForSession();
 spotFeedRestore();
 spotPresentationRestore();
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
 const register=$('registerButton');if(register){const hide=loggedIn&&passwordUsed;const wrapper=register.closest('.registerHelp');if(wrapper)wrapper.hidden=hide;register.hidden=hide;}
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
 spotItems=[];spotCounts={human:0,rbn:0};logs={ann:[],wwv:[],wcy:[],wx:[]};cmdHistory=[];historyPos=0;pendingCommandTargets=[];pendingCommandNames=[];
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
function spotCancelPending(){const d=$('spotDialog');d.close();$('spotResult').textContent='';$('spotForm').reset()}
$('spotCancel').onclick=spotCancelPending;
$('spotDialog').addEventListener('cancel',()=>{$('spotResult').textContent='';$('spotForm').reset()});
$('spotOpen').onclick=()=>{if(!authenticated){notice('Only users who have logged in can access this function.');return}if(!authRegistered){notice('You must be registered on this node to use this function. Use the Register option.');return}$('spotResult').textContent='';$('spotDialog').showModal()};
$('spotForm').addEventListener('submit',e=>{
 e.preventDefault();
 if(e.submitter&&e.submitter.value==='cancel'){spotCancelPending();return}
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
 if(!send({type:'command',command:cmd}))return;
 pendingCommandTargets.push(target);pendingCommandNames.push(cmd);
}
$('consoleForm').addEventListener('submit',e=>{e.preventDefault();const v=$('consoleCommand').value; $('consoleCommand').value='';command(v,'console')});
$('filterForm').addEventListener('submit',e=>{e.preventDefault();const v=$('filterCommand').value;$('filterCommand').value='';command(v,'filters')});
const filterBandCatalog={"bands":{"73khz":["band"],"136khz":["band"],"500khz":["band"],"160m":["band","cw","data","ft8","rtty","ssb"],"80m":["band","cw","data","ft4","ft8","rtty","ssb","sstv"],"60m":["band","cw","data","ssb"],"40m":["band","cw","data","ft4","ft8","rtty","ssb"],"30m":["band","cw","data","ft4","ft8","rtty"],"20m":["band","beacon","cw","data","ft4","ft8","rtty","ssb","sstv"],"17m":["band","beacon","cw","data","ft4","ft8","rtty","ssb"],"15m":["band","beacon","cw","data","ft4","ft8","rtty","ssb"],"12m":["band","beacon","cw","data","ft4","ft8","rtty","ssb"],"10m":["band","beacon","cw","data","ft4","ft8","rtty","space","ssb"],"8m":["band"],"6m":["band","beacon","cw","data","ft4","ft8","ssb"],"5m":["band"],"4m":["band","beacon","cw","ssb"],"2m":["band","beacon","cw","ssb"],"220":["band"],"70cm":["band"],"902":["band"],"23cm":["band"],"13cm":["band"],"9cm":["band","beacon","sat"],"6cm":["band","beacon","data","sat"],"3cm":["band"],"12mm":["band"],"6mm":["band","beacon"],"4mm":["band","beacon"],"122g":["band"],"134g":["band","beacon"],"241g":["band","beacon"],"band1":["band"],"band2":["band"],"band3":["band"],"band4":["band"],"band5":["band"],"military":["band"],"aircraft":["band"],"pmrlow":["band"],"pmrmid":["band"],"pmrhigh":["band"],"pmruhf":["band"],"hf":["band"],"vhf":["band"],"lband":["band"],"sband":["band"],"cband":["band"],"xband":["band"],"kuband":["band"],"kband":["band"],"kaband":["band"],"vband":["band"],"wband":["band"],"gband":["band"],"630m":["band"],"24g":["band"],"47g":["band","beacon"],"76g":["band","beacon"]},"regions":{"vlf":["73khz","136khz","630m"],"hf":["160m","80m","60m","40m","30m","20m","17m","15m","12m","10m"],"contesthf":["160m","80m","40m","20m","15m","10m"],"vhf":["8m","6m","5m","4m","2m","220"],"vhfradio":["band1","band2"],"vhftv":["band1","band3"],"uhf":["70cm","902","23cm","13cm"],"uhftv":["band4","band5"],"shf":["9cm","6cm","3cm","24g"],"ehf":["47g","76g","134g","241g"],"pmr":["pmrlow","pmrmid","pmrhigh","pmruhf"],"spe":["10m","8m","6m","5m","4m","2m"],"warc":["60m","30m","17m","12m"],"dsn":["23cm","9cm","6cm","3cm","24g","47g","76g","134g","241g"],"all":["73khz","136khz","630m","160m","80m","60m","40m","30m","20m","17m","15m","12m","10m","8m","6m","5m","4m","2m","220","70cm","902","23cm","9cm","6cm","3cm","24g","47g","76g","134g","241g"]},"aliases":{"630m":"500khz","24g":"12mm","47g":"6mm","76g":"4mm"}};
// Compact filter editor. Local drafts are never sent until Save/Delete.
let vfRules=[],vfCurrent=null,vfHistory=[],vfReadLines=[],vfReadActive=false,vfSeq=1;
// Native Spot::$filterdef tags, not UI-invented aliases. RBN-only controls are a UI restriction.
const vfCommonFields=[
 ['call','DX · Callsign'],['call_dxcc','DX · DXCC'],['call_zone','DX · CQ Zone'],['call_itu','DX · ITU Zone'],
 ['spotter','Spotter · Callsign'],['by_dxcc','Spotter · DXCC'],['by_zone','Spotter · CQ Zone'],['by_itu','Spotter · ITU Zone'],
 ['on','Frequency · Band'],['freq','Frequency · Range'],['info','Comment']
];
const vfRbnFields=[['db','RBN · dB'],['q','RBN · Q']];
const vfFields=()=>vfCommonFields.concat($('filterFamily').value==='rbn'?vfRbnFields:[]);
const vfNativeAlias={dxcc:'call_dxcc',cq:'call_zone',zone:'call_zone',itu:'call_itu',by:'spotter',byzone:'by_zone',bycq:'by_zone',byitu:'by_itu'};
const vfSimple=/^([a-z_]+)\s+([^\s()]+)$/i;
const vfClone=x=>JSON.parse(JSON.stringify(x));
function vfSnapshot(){vfHistory.push({rules:vfClone(vfRules),current:vfClone(vfCurrent)});if(vfHistory.length>60)vfHistory.shift();$('vfUndo').disabled=false}
// Parse native AND/OR/NOT with balanced parentheses into an editable tree.
function vfParse(expr){
 const tokens=String(expr).match(/\(|\)|\b(?:and|or|not)\b|[^\s()]+/gi)||[];let pos=0;
 const atom=()=>{if(tokens[pos]==='('){pos++;const v=disjunction();if(tokens[pos++]!==')')throw Error('Unbalanced parentheses');return v}
  if(/^not$/i.test(tokens[pos]||'')){pos++;return {type:'not',child:atom()}}
  const field=tokens[pos++],value=tokens[pos++];if(!field||!value||/[()]/.test(value)||/^(and|or|not)$/i.test(value))throw Error('Invalid condition');
  const native=field.toLowerCase(),canonical=vfNativeAlias[native]||native;
  if(!vfFields().some(f=>f[0]===canonical))throw Error('Unsupported native field');
  return {type:'term',id:vfSeq++,field:native,value};};
 const conjunction=()=>{let parts=[atom()];while(/^and$/i.test(tokens[pos]||'')){pos++;parts.push(atom())}return parts.length===1?parts[0]:{type:'group',op:'and',children:parts}};
 const disjunction=()=>{let parts=[conjunction()];while(/^or$/i.test(tokens[pos]||'')){pos++;parts.push(conjunction())}return parts.length===1?parts[0]:{type:'group',op:'or',children:parts}};
 try{const tree=disjunction();if(pos!==tokens.length)throw Error('Trailing tokens');return tree}catch(_){return null}
}
function vfSerialize(node){if(!node)return '';if(node.type==='term')return `${node.field} ${node.value.trim()}`;
 if(node.type==='not')return `not ( ${vfSerialize(node.child)} )`;
 return node.children.map(n=>{const value=vfSerialize(n);return n.type==='group'?`(${value})`:`( ${value} )`}).join(` ${node.op} `);}
function vfBandOrder(a,b){
 const classify=s=>/^[0-9]+m$/.test(s)?0:/^[0-9]+cm$/.test(s)?1:/^[0-9]+mm$/.test(s)?2:/^[0-9]+g$/.test(s)?3:/^[0-9]+khz$/.test(s)?4:/^[0-9]+$/.test(s)?5:6;
 const x=classify(a),y=classify(b);return x-y||(x===6?a.localeCompare(b):Number.parseInt(a,10)-Number.parseInt(b,10));
}
function vfNodeTerm(){return {type:'term',id:vfSeq++,field:'call',value:''}}
function vfWalk(root,id,cb){if(!root)return root;if(root.id===id)return cb(root);if(root.type==='group')root.children=root.children.map(n=>vfWalk(n,id,cb)).filter(Boolean);else if(root.type==='not')root.child=vfWalk(root.child,id,cb);return root}
function vfPopulateExisting(lines){
 const family=$('filterFamily').value;let seenFamily='',input=false;const found=[];
 for(const line of lines){
  const hd=line.match(/^\s*(\S+)\s+:\s+(spots|rbn)(?:\s+(input))?\s*$/i);
  if(hd){seenFamily=hd[2].toLowerCase();input=!!hd[3];continue}
  const m=line.match(/^\s*filter([0-9])\s+(accept|reject)\s+(.+)$/i);
  if(m&&seenFamily===family&&!input&&Number(m[1])>=1)found.push({id:vfSeq++,position:m[1],action:m[2].toLowerCase(),expression:m[3].trim()});
 }
 vfRules=found;vfCurrent=null;vfHistory=[];$('vfUndo').disabled=true;vfRender();
}
function vfRender(){
 const box=$('vfRules');box.replaceChildren();
 if(!vfRules.length){const e=document.createElement('span');e.textContent='No output rules loaded for this family';box.append(e)}
 for(const r of vfRules){const row=document.createElement('div');row.className='vf-rule';
  const edit=document.createElement('button');edit.type='button';edit.textContent=`#${r.position} ${r.action.toUpperCase()}  ${r.expression}`;edit.title='Edit this rule';edit.onclick=()=>vfOpen(r);row.append(edit);
  const del=document.createElement('button');del.type='button';del.textContent='×';del.title='Delete rule';del.onclick=()=>vfDeleteRule(r);row.append(del);box.append(row)}
 $('vfEditor').hidden=!vfCurrent;if(!vfCurrent)return;
 $('vfTitle').textContent=vfCurrent.existing?'Edit rule':'New rule';$('filterPosition').value=vfCurrent.position;$('filterAction').value=vfCurrent.action;
 $('vfAdvancedArea').hidden=!vfCurrent.advanced;$('vfAdvancedDiscard').hidden=true;$('vfAdvanced').textContent=vfCurrent.advanced?'← Back to visual editor':'Advanced';$('filterExpression').value=vfCurrent.expression;
 vfRenderConditions();vfPreview();
}
function vfOpen(r){vfSnapshot();vfCurrent={...vfClone(r),existing:true,tree:vfParse(r.expression),advanced:false};vfCurrent.advanced=!vfCurrent.tree;vfRender()}
function vfNew(){vfSnapshot();const used=new Set(vfRules.map(r=>r.position));const position=Array.from({length:9},(_,i)=>String(i+1)).find(n=>!used.has(n));if(!position){$('vfStatus').textContent='All 9 positions are in use';return}
 vfCurrent={id:vfSeq++,position,action:'reject',expression:'',tree:null,advanced:false,existing:false};vfRender()}
function vfExpression(){return vfCurrent.advanced?$('filterExpression').value.trim():vfSerialize(vfCurrent.tree)}
// Locate balanced parenthesis pairs which contain a top-level AND/OR.
// Leaf term parentheses are intentionally not decorated.
function vfPreviewGroups(expression){
 const stack=[],groups=[];let quote=null,escaped=false;
 for(let i=0;i<expression.length;i++){
  const c=expression[i];
  if(quote){if(escaped)escaped=false;else if(c==='\\')escaped=true;else if(c===quote)quote=null;continue}
  if(c==='"'||c==="'"){quote=c;continue}
  if(c==='(')stack.push(i);
  else if(c===')'&&stack.length){const start=stack.pop(),inside=expression.slice(start+1,i);
   let depth=0,operator=false,token='';
   const flush=()=>{if(depth===0&&/^(and|or)$/i.test(token))operator=true;token=''};
   for(const ch of inside){if(ch==='('){flush();depth++}else if(ch===')'){flush();depth--}else if(/\s/.test(ch)){flush()}else if(depth===0)token+=ch}
   flush();if(operator)groups.push({start:start+1,end:i});
  }
 }
 // The outermost boolean group is serialized without enclosing parentheses.
 // Draw its span as well, excluding the command header (reject/spots N).
 const header=expression.match(/^\s*(?:accept|reject)\/(?:spots|rbn)\s+[0-9]+\s+/i);
 if(header){
  let start=header[0].length,end=expression.length;
  while(start<end&&/\s/.test(expression[start]))start++;
  while(end>start&&/\s/.test(expression[end-1]))end--;
  // Only a composite expression has a root group to draw.
  let depth=0,hasRootOperator=false,token='';
  const flushRoot=()=>{if(depth===0&&/^(and|or)$/i.test(token))hasRootOperator=true;token=''};
  for(let i=start;i<end;i++){
   const c=expression[i];
   if(c==='('){flushRoot();depth++}
   else if(c===')'){flushRoot();depth--}
   else if(/\s/.test(c)){flushRoot()}
   else if(depth===0)token+=c;
  }
  flushRoot();
  if(hasRootOperator&&!groups.some(g=>g.start===start&&g.end===end))groups.push({start,end,root:true});
 }
 return groups.sort((a,b)=>(a.end-a.start)-(b.end-b.start));
}
function vfDrawPreview(expression){
 const host=$('vfPreviewVisual');host.replaceChildren();
 const groups=vfPreviewGroups(expression),line=document.createElement('div');
 line.className='vf-preview-line';line.textContent=expression;
 const top=Math.max(1,...groups.filter((_,i)=>i%2===1).map((_,i)=>i+1));
 const bottom=Math.max(1,...groups.filter((_,i)=>i%2===0).map((_,i)=>i+1));
 // One lane per alternating side; overlapping nested spans never hide each other.
 const above=groups.filter((_,i)=>i%2===1).length,below=groups.filter((_,i)=>i%2===0).length;
 line.style.marginTop=`${above*7+4}px`;line.style.marginBottom=`${below*7+4}px`;
 host.append(line);
 const palette=['#0066ff','#ff0000','#ffff00','#000000','#808080'];
 groups.forEach((g,i)=>{if(g.end<=g.start)return;const bar=document.createElement('span');bar.className='vf-preview-bar';
  const side=i%2===0?'bottom':'top',lane=Math.floor(i/2);
  bar.style.left=`${g.start}ch`;bar.style.width=`${g.end-g.start}ch`;
  bar.style.backgroundColor=palette[i%palette.length];if(i%palette.length===2)bar.style.boxShadow='0 0 0 0.5px #a68b00';bar.style[side]=`${-8-lane*7}px`;
  bar.title=`Group ${i+1}: ${expression.slice(g.start,g.end)}`;line.append(bar);
 });
}
function vfPreview(){if(!vfCurrent)return;vfCurrent.expression=vfExpression();const expression=vfCurrent.expression?`${vfCurrent.action}/${$('filterFamily').value} ${vfCurrent.position} ${vfCurrent.expression}`:'Add a condition';$('filterPreviewText').textContent=expression;vfDrawPreview(expression);}
function vfRenderConditions(){const box=$('vfConditions');box.replaceChildren();if(vfCurrent.advanced)return;
 const addButton=(parent,label,fn)=>{const b=document.createElement('button');b.type='button';b.textContent=label;b.onclick=()=>{vfSnapshot();fn();vfRender()};parent.append(b)};
 const renderNode=(node,host,parent=null,index=0)=>{
  const row=document.createElement('div');row.className='vf-node '+(node.type==='group'?'vf-group':'');if(node.type==='group'){const depth=(()=>{let d=0,p=host;while(p&&p!==box){if(p.classList?.contains('vf-group'))d++;p=p.parentElement}return d})();row.style.setProperty('--vf-depth',String(depth));row.dataset.logic=node.op.toUpperCase();}host.append(row);
  if(node.type==='group'){
   const header=document.createElement('div');header.className='vf-grouphead';header.dataset.label='GROUP';row.append(header);
   const op=document.createElement('select');for(const x of ['and','or'])op.add(new Option(x.toUpperCase(),x));op.value=node.op;op.onchange=()=>{vfSnapshot();node.op=op.value;row.dataset.logic=node.op.toUpperCase();vfPreview()};header.append(op);
   addButton(header,'+ Condition',()=>node.children.push(vfNodeTerm()));
   addButton(header,'+ Group',()=>node.children.push({type:'group',op:'or',children:[vfNodeTerm(),vfNodeTerm()]}));
   if(parent)addButton(header,'×',()=>parent.children.splice(index,1));
   node.children.forEach((child,i)=>renderNode(child,row,node,i));return;
  }
  if(node.type==='not'){
   const label=document.createElement('strong');label.textContent='NOT';row.append(label);renderNode(node.child,row);return;
  }
  const field=document.createElement('select');for(const [id,label] of vfFields())field.add(new Option(label,id));if(!vfFields().some(f=>f[0]===node.field))field.add(new Option(node.field+' (native)',node.field));field.value=node.field;row.append(field);
  const slot=document.createElement('span');slot.className='vf-value';row.append(slot);
  const renderValue=()=>{slot.replaceChildren();if(node.field==='on'){
   const details=document.createElement('details');const summary=document.createElement('summary');summary.textContent=node.value||'Select bands';details.append(summary);
   const choices=document.createElement('div');choices.className='vf-bandchoices';const selected=new Set(node.value.split(',').filter(Boolean));
   for(const band of Object.keys(filterBandCatalog.bands).sort(vfBandOrder)){const label=document.createElement('label'),cb=document.createElement('input');cb.type='checkbox';cb.checked=selected.has(band);cb.onchange=()=>{vfSnapshot();if(cb.checked)selected.add(band);else selected.delete(band);node.value=[...selected].join(',');summary.textContent=node.value||'Select bands';vfPreview()};label.append(cb,document.createTextNode(band));choices.append(label)}details.append(choices);slot.append(details);
  }else if(/(?:zone|itu)/.test(node.field)){
   const select=document.createElement('select');select.add(new Option('Zone…',''));const max=/(?:itu)/.test(node.field)?90:40;for(let n=1;n<=max;n++)select.add(new Option(String(n),String(n)));if(node.value&&!Array.from(select.options).some(o=>o.value===node.value))select.add(new Option(node.value,node.value));select.value=node.value;select.onchange=()=>{vfSnapshot();node.value=select.value;vfPreview()};slot.append(select);
  }else{const input=document.createElement('input');input.value=node.value;input.size=/^(call|spotter)$/.test(node.field)?20:/dxcc/.test(node.field)?6:/(?:^db$|^q$)/.test(node.field)?5:12;input.maxLength=/^(call|spotter)$/.test(node.field)?20:256;input.placeholder=/dxcc/.test(node.field)?'Prefix / number':'Value';input.onfocus=()=>vfSnapshot();input.oninput=()=>{node.value=input.value;vfPreview()};slot.append(input)}};
  field.onchange=()=>{vfSnapshot();node.field=field.value;node.value='';renderValue();vfPreview()};renderValue();
  addButton(row,'×',()=>{if(parent)parent.children.splice(index,1);else vfCurrent.tree=null});
  if(parent&&parent.type==='group'&&parent.children.length>1){addButton(row,'↑',()=>{if(index>0)[parent.children[index-1],parent.children[index]]=[parent.children[index],parent.children[index-1]]});addButton(row,'↓',()=>{if(index<parent.children.length-1)[parent.children[index+1],parent.children[index]]=[parent.children[index],parent.children[index+1]]});}
 };
 if(vfCurrent.tree)renderNode(vfCurrent.tree,box);
 else{const hint=document.createElement('small');hint.textContent='Empty rule — add a condition or group';box.append(hint)}
}
function vfDeleteRule(r){if(!confirm(`Delete ${$('filterFamily').value} rule ${r.position} (${r.action})?`))return;if(!authenticated){notice('Log in first.');return}command(`clear/${$('filterFamily').value} ${r.position}`,'filters');vfRules=vfRules.filter(x=>x.id!==r.id);if(vfCurrent?.id===r.id)vfCurrent=null;vfHistory=[];$('vfUndo').disabled=true;vfRender()}
$('filterLoad').onclick=()=>{vfCurrent=null;vfRender();command(`show/filter ${$('filterFamily').value}`,'filters')};
$('filterFamily').onchange=()=>{vfRules=[];vfCurrent=null;vfHistory=[];$('vfUndo').disabled=true;vfRender();command(`show/filter ${$('filterFamily').value}`,'filters')};
$('vfNew').onclick=vfNew;
$('vfUndo').onclick=()=>{const last=vfHistory.pop();if(!last)return;vfRules=last.rules;vfCurrent=last.current;$('vfUndo').disabled=!vfHistory.length;vfRender()};
$('vfDiscard').onclick=()=>{vfCurrent=null;vfRender()};
$('filterPosition').onchange=()=>{vfSnapshot();vfCurrent.position=$('filterPosition').value;vfPreview()};
$('filterAction').onchange=()=>{vfSnapshot();vfCurrent.action=$('filterAction').value;vfPreview()};
$('vfAdd').onclick=()=>{if(!vfCurrent)return;if(vfCurrent.advanced){$('vfStatus').textContent='Advanced expressions cannot be edited as visual blocks';return}vfSnapshot();if(!vfCurrent.tree)vfCurrent.tree=vfNodeTerm();else if(vfCurrent.tree.type==='group'&&vfCurrent.tree.op===$('vfJoin').value)vfCurrent.tree.children.push(vfNodeTerm());else if(vfCurrent.tree.type==='group')vfCurrent.tree={type:'group',op:$('vfJoin').value,children:[vfCurrent.tree,vfNodeTerm()]};else vfCurrent.tree={type:'group',op:$('vfJoin').value,children:[vfCurrent.tree,vfNodeTerm()]};vfRender()};
$('vfWrapAnd').onclick=()=>{if(!vfCurrent||vfCurrent.advanced)return;vfSnapshot();if(!vfCurrent.tree){vfCurrent.tree=vfNodeTerm()}else{vfCurrent.tree={type:'group',op:'and',children:[vfCurrent.tree,vfNodeTerm()]}};vfRender()};
$('vfAddGroup').onclick=()=>{if(!vfCurrent||vfCurrent.advanced)return;vfSnapshot();const group={type:'group',op:'or',children:[vfNodeTerm(),vfNodeTerm()]};if(!vfCurrent.tree)vfCurrent.tree=group;else vfCurrent.tree={type:'group',op:'and',children:[vfCurrent.tree,group]};vfRender()};
$('vfAdvanced').onclick=()=>{if(!vfCurrent)return;
 if(!vfCurrent.advanced){vfSnapshot();vfCurrent.expression=vfExpression();vfCurrent.visualBackup=vfClone(vfCurrent.tree);vfCurrent.advancedOriginal=vfCurrent.expression;vfCurrent.advanced=true;vfRender();return}
 const expr=$('filterExpression').value.trim();
 if(expr===vfCurrent.advancedOriginal){vfCurrent.advanced=false;vfCurrent.tree=vfClone(vfCurrent.visualBackup);$('vfStatus').textContent='Visual editor';vfRender();return}
 const tree=vfParse(expr);
 if(tree){vfSnapshot();vfCurrent.tree=tree;vfCurrent.advanced=false;vfCurrent.expression=expr;$('vfStatus').textContent='Advanced expression converted';vfRender();return}
 $('vfStatus').textContent='Cannot convert this expression. Keep editing in Advanced, or use Discard advanced changes.';
 $('vfAdvancedDiscard').hidden=false;
};
$('vfAdvancedDiscard').onclick=()=>{if(!vfCurrent)return;vfCurrent.tree=vfClone(vfCurrent.visualBackup);vfCurrent.advanced=false;vfCurrent.expression=vfSerialize(vfCurrent.tree);$('vfStatus').textContent='Advanced changes discarded';$('vfAdvancedDiscard').hidden=true;vfRender()};
$('filterExpression').oninput=()=>{if(vfCurrent){vfCurrent.expression=$('filterExpression').value;vfPreview()}};
$('filterSend').onclick=()=>{if(!vfCurrent||!authenticated){notice('Log in and select a rule first.');return}vfPreview();if(!vfCurrent.expression||/[\r\n]/.test(vfCurrent.expression)){ $('vfStatus').textContent='Invalid or empty expression';return}if(vfRules.some(r=>r.id!==vfCurrent.id&&r.position===vfCurrent.position)){$('vfStatus').textContent='Position already occupied';return}
 const cmd=$('filterPreviewText').textContent;command(cmd,'filters');vfHistory=[];$('vfUndo').disabled=true;$('vfStatus').textContent='Command sent; reload to confirm';};
$('vfDelete').onclick=()=>{if(vfCurrent?.existing)vfDeleteRule(vfCurrent);else{vfCurrent=null;vfRender()}};
$('vfClearAll').onclick=()=>{if(!confirm(`Delete ALL ${$('filterFamily').value} output rules? This cannot be undone after sending.`))return;if(!authenticated){notice('Log in first.');return}command(`clear/${$('filterFamily').value} all`,'filters');vfRules=[];vfCurrent=null;vfHistory=[];$('vfUndo').disabled=true;vfRender()};
vfRender();
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
$('showHuman').onchange=()=>{spotFilterChanged('human');spotFeedSave()};$('showRbn').onchange=()=>{spotFilterChanged('rbn');spotFeedSave()};


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

function spotSelected(){return new Set([...document.querySelectorAll('[data-spot-group]:checked')].map(e=>e.dataset.spotGroup))}
function updateSpotLayout(){
 const table=document.querySelector('.spotTable'),area=table?.closest('.spotResultArea');if(!area)return;
 const style=getComputedStyle(area);
 const available=Math.max(0,area.clientWidth-parseFloat(style.paddingLeft)-parseFloat(style.paddingRight)-8),selected=spotSelected();
 // Hide complete groups in priority order: ITU, CQ, Locator. Never hide core fields.
 const geoEnabled=!!geoLocator(document.getElementById('userLocator')?.value);
 const scale=spotFontPercent/100;
 const coreWidth=spotCore.reduce((s,x)=>s+Math.ceil(x[2]*scale),0)+(geoEnabled?Math.ceil(176*scale):0);
 const groups=spotExtras.map(([key,name,w])=>({key,name,w,fields:selected.has(key)?[['Dx','DX'],['Spotter','Spotter']]:[]}));
 let extraWidth=groups.reduce((s,g)=>s+g.fields.length*Math.ceil(g.w*scale),0);
 for(const g of [...groups].reverse())if(extraWidth+coreWidth>available&&g.fields.length){extraWidth-=g.fields.length*Math.ceil(g.w*scale);g.fields=[]}
 const commentMin=Math.ceil(80*scale),base=coreWidth-commentMin;
 const comment=Math.max(commentMin,spotCommentPreferred===null?available-base-extraWidth:Math.min(spotCommentPreferred,Math.max(commentMin,available-base-extraWidth)));
 const cols=spotCore.map(([key,title,w])=>({key,title,w:key==='comment'?comment:Math.ceil(w*scale)}));
 if(geoEnabled)cols.push({key:'distance',title:'Distance',w:Math.ceil(96*scale)},{key:'bearing',title:'Bearing',w:Math.ceil(80*scale)});
 for(const g of groups)for(const [suffix,title] of g.fields)cols.push({key:g.key+suffix,title,w:Math.ceil(g.w*scale),group:g.name});
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
 const done=()=>{spotResizeActive=false;window.removeEventListener('pointermove',move);window.removeEventListener('pointerup',done);window.removeEventListener('pointercancel',done);spotPresentationSave();updateSpotLayout()};
 window.addEventListener('pointermove',move);window.addEventListener('pointerup',done);window.addEventListener('pointercancel',done);
});
window.addEventListener('load',updateSpotLayout);
updateSpotLayout();
function renderSpots(){
 const human=$('showHuman').checked,rbn=$('showRbn').checked;
 const a=spotItems.filter(x=>(x.type==='human'&&human)||(x.type==='rbn'&&rbn));
 $('spotRows').innerHTML=a.slice(-250).reverse().map(x=>`<tr class="${x._newUntil>Date.now()?'spotFresh':''}" style="${x._newUntil>Date.now()?'animation-delay:-'+((3000-(x._newUntil-Date.now()))/1000).toFixed(2)+'s':''}">${spotVisibleColumns.map(col=>`<td class="${col.key==='distance'||col.key==='bearing'?'spotGeoNumeric':''}" title="${col.key==='distance'||col.key==='bearing'?esc(geoCalculate(x).source):esc(x[col.key]??'')}">${col.key==='type'?(x.type==='human'?'C':'R'):col.key==='distance'||col.key==='bearing'?esc(geoRenderValue(x,col.key)):esc(x[col.key]??'')}</td>`).join('')}</tr>`).join('');
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
   spotItems.push({...p,type:k,_newUntil:Date.now()+3000});
   setTimeout(()=>{if(spotItems.some(x=>x._newUntil&&x._newUntil<=Date.now()))renderSpots()},3100);
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
   const issued=pendingCommandNames[0]||'';
   const isFilterRead=target==='filters'&&/^show\/filter(?:\s|$)/i.test(issued);
   if(isFilterRead){if(!vfReadActive){vfReadActive=true;vfReadLines=[]}if(t)vfReadLines.push(...t.split('\n'))}
   if(m.final!==false){
     if(isFilterRead){vfPopulateExisting(vfReadLines);vfReadActive=false;vfReadLines=[]}
     finishCommandTarget(target);pendingCommandTargets.shift();pendingCommandNames.shift();
     // Re-read the authoritative filter after editing. Never infer success from status=ok.
     if(target==='filters'&&/^(?:(?:accept|reject)\/(?:spots|rbn)\s|clear\/(?:spots|rbn)\s)/i.test(issued)){
       const family=issued.match(/^(?:accept|reject)\/(spots|rbn)\s/i)[1];
       command(`show/filter ${family}`,'filters');
     }
   }return;
 }
 if(m.type==='spot_result'){if(!$('spotDialog').open)return;$('spotResult').textContent=responseText(m)||(m.status==='ok'?'Spot accepted by DXSpider':'Spot rejected');if(m.status==='ok')setTimeout(()=>$('spotDialog').close(),500);return}
 if(m.type==='ann_result'){$('annResult').textContent=responseText(m)||(m.status==='ok'?'Announcement accepted by DXSpider':'Announcement rejected');if(m.status==='ok')$('annText').value='';return}
 if(m.type==='feed'){if(!logoutPending)acceptFeed(m);return}
}
loginState(false);
connect();

updateRegistrationAccess();

// Per-callsign presentation settings; browser-local and independent for each application.
const spotPresentationKeyBase='dxspider.dxweb.spotPresentation.';
function spotPresentationSave(){
 if(!authenticated||!authUser)return;
 const settings={human:$('showHuman').checked,rbn:$('showRbn').checked,
  font:spotFontPercent,locator:$('userLocator').value.trim().toUpperCase(),
  groups:[...document.querySelectorAll('[data-spot-group]:checked')].map(x=>x.dataset.spotGroup),
  commentWidth:spotCommentPreferred};
 try{localStorage.setItem(spotPresentationKeyBase+authUser.toUpperCase(),JSON.stringify(settings))}catch(_){}
}
function spotPresentationRestore(){
 let saved=null;
 if(authenticated&&authUser){try{saved=JSON.parse(localStorage.getItem(spotPresentationKeyBase+authUser.toUpperCase()))}catch(_){}}
 const groups=new Set(saved&&Array.isArray(saved.groups)?saved.groups:[]);
 for(const box of document.querySelectorAll('[data-spot-group]'))box.checked=groups.has(box.dataset.spotGroup);
 const loc=saved&&typeof saved.locator==='string'?saved.locator:'';
 $('userLocator').value=geoLocator(loc)?loc:'';
 spotCommentPreferred=saved&&Number.isFinite(saved.commentWidth)&&saved.commentWidth>=80&&saved.commentWidth<=1200?saved.commentWidth:null;
 if(saved&&typeof saved.human==='boolean'&&typeof saved.rbn==='boolean'){
  $('showHuman').checked=saved.human;$('showRbn').checked=saved.rbn;
 }else{$('showHuman').checked=true;$('showRbn').checked=false}
 spotFontApply(saved&&Number.isFinite(saved.font)?saved.font:100,false);
 spotItems=[];spotCounts={human:0,rbn:0};
 updateSpotLayout();renderSpots();
}
function spotPresentationBind(){
 for(const id of ['showHuman','showRbn'])$(id).addEventListener('change',spotPresentationSave);
 for(const box of document.querySelectorAll('[data-spot-group]'))box.addEventListener('change',spotPresentationSave);
 $('userLocator').addEventListener('input',()=>{if($('userLocator').validity.valid)spotPresentationSave()});
}

spotPresentationBind();
