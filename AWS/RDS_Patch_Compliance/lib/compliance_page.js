/* rds_patch_compliance_report.sh HTML filters + CSV export (inlined into the report; no network). */
(function(){
var el=document.getElementById('pc-data'); if(!el) return;
var D=JSON.parse(el.textContent), R=D.rows, F={a:'',r:'',e:'',s:'',q:''};
function $(id){return document.getElementById(id);}
function uniq(a){var o={},out=[];a.forEach(function(x){if(x!=null&&x!==''&&!o[x]){o[x]=1;out.push(x);}});return out.sort();}
function opt(sel,v,t){var o=document.createElement('option');o.value=v;o.textContent=t;sel.appendChild(o);}
D.accounts.slice().sort(function(a,b){return a.account<b.account?-1:1;}).forEach(function(a){opt($('f-acct'),a.account,a.account+' ('+a.profile+')');});
uniq(R.map(function(x){return x.region;})).forEach(function(v){opt($('f-region'),v,v);});
uniq(R.map(function(x){return x.engine;})).forEach(function(v){opt($('f-engine'),v,v);});
['COMPLIANT','NON-COMPLIANT','UNKNOWN'].forEach(function(v){opt($('f-status'),v,v);});
function active(){return !!(F.a||F.r||F.e||F.s||F.q);}
function match(x){return (!F.a||x.account_id===F.a)&&(!F.r||x.region===F.r)&&(!F.e||x.engine===F.e)&&(!F.s||x.compliance_status===F.s)
  &&(!F.q||((x.identifier||'')+' '+[].concat(x.members||[]).join(' ')).toLowerCase().indexOf(F.q)>=0);}
function cnt(rs){var c={total:rs.length,compliant:0,nc:0,unknown:0,wp:0,pt:0,past:0,near:0,aoff:0,dep:0};
  rs.forEach(function(x){var s=x.compliance_status;if(s==='COMPLIANT')c.compliant++;else if(s==='NON-COMPLIANT')c.nc++;else c.unknown++;
    if(x.pending_actions_count>0)c.wp++;c.pt+=x.pending_actions_count||0;if(x.past_standard_support)c.past++;if(x.nearing_end_of_support)c.near++;
    if(x.auto_minor_upgrade==='false'||x.auto_minor_upgrade==='mixed')c.aoff++;if(x.deprecated_version)c.dep++;});
  c.pct=c.total?Math.round(c.compliant*1000/c.total)/10:null;return c;}
function pctc(p){return p==null?'muted':p>=100?'ok':p>=80?'warn':'bad';}
function td(t,i,html,s,cls){var d=t.cells[i];d.innerHTML=html;d.setAttribute('data-s',s);d.className='n'+(cls?' '+cls:'');}
function setCells(t,c){td(t,3,'<b>'+c.total+'</b>',c.total);td(t,4,c.compliant,c.compliant,c.compliant>0?'ok':'');
  td(t,5,c.nc,c.nc,c.nc>0?'bad':'');td(t,6,c.unknown,c.unknown);
  td(t,7,c.pct==null?'-':c.pct+'%<div class="bar"><i class="'+pctc(c.pct)+'" style="width:'+c.pct+'%"></i></div>',c.pct==null?-1:c.pct,pctc(c.pct));
  td(t,8,c.wp+(c.pt>0?'<div class="sub">'+c.pt+' action(s)</div>':''),c.wp,c.wp>0?'warn':'');td(t,9,c.past,c.past,c.past>0?'bad':'');}
var saved=[];
function save(n){saved.push([n,n.innerHTML,n.className]);}
document.querySelectorAll('.card .v, .card .s, #regions tbody tr, #regions tfoot tr, #accounts tbody tr').forEach(save);
var cards={}; document.querySelectorAll('.card').forEach(function(c){cards[c.getAttribute('data-k')]=c;});
function setCard(k,v,sub){var c=cards[k];if(!c)return;var a=c.querySelector('.v'),b=c.querySelector('.s');if(a)a.textContent=v;if(b&&sub!=null)b.textContent=sub;}
function apply(){
  var on=active(), rs=on?R.filter(match):R, shown=0;
  document.querySelectorAll('table.main tbody tr[data-i]').forEach(function(t){var ok=!on||match(R[+t.getAttribute('data-i')]);t.style.display=ok?'':'none';if(ok)shown++;});
  document.querySelectorAll('table.main').forEach(function(tb){var sec=tb.closest('section');var any=tb.querySelector('tbody tr[data-i]:not([style*="none"])');if(sec)sec.style.display=any?'':'none';});
  document.body.classList.toggle('filtered',on);
  saved.forEach(function(x){x[0].innerHTML=x[1];x[0].className=x[2];x[0].style.display='';});
  $('f-count').textContent=on?('showing '+shown+' of '+R.length+' server(s)'):(R.length+' server(s)');
  if(!on) return;
  var c=cnt(rs), regs={};rs.forEach(function(x){regs[x.account_id+'|'+x.region]=1;});
  setCard('servers-clusters',c.total,'filtered');
  setCard('compliant',c.compliant,(c.pct==null?'-':c.pct+'%')+' of filtered');
  setCard('non-compliant',c.nc,null);setCard('unknown',c.unknown,null);
  setCard('regions',Object.keys(regs).length,'with databases (filtered; empty regions not shown)');
  setCard('extended-support',c.past,null);
  setCard('support-ending',c.near,null);setCard('auto-minor-upgrade-off',c.aoff,null);
  setCard('pending-maintenance',c.wp,c.pt+' action(s)');setCard('version-not-returned',c.dep,null);
  document.querySelectorAll('#regions tbody tr[data-k]').forEach(function(t){var k=t.getAttribute('data-k');
    var g=rs.filter(function(x){return x.account_id+'|'+x.region===k;});if(!g.length){t.style.display='none';return;}setCells(t,cnt(g));});
  var ft=document.querySelector('#regions tfoot tr');if(ft)setCells(ft,c);
  document.querySelectorAll('#accounts tbody tr[data-a]').forEach(function(t){var a=t.getAttribute('data-a');
    var g=rs.filter(function(x){return x.account_id===a;});if(!g.length){t.style.display='none';return;}setCells(t,cnt(g));
    var n={};g.forEach(function(x){n[x.region]=1;});t.cells[2].innerHTML=Object.keys(n).length;});
}
function bind(id,k,lower){var n=$(id);n.addEventListener(n.tagName==='INPUT'?'input':'change',function(){F[k]=lower?n.value.trim().toLowerCase():n.value;apply();});}
bind('f-acct','a');bind('f-region','r');bind('f-engine','e');bind('f-status','s');bind('q','q',true);
$('f-reset').addEventListener('click',function(){['f-acct','f-region','f-engine','f-status','q'].forEach(function(i){$(i).value='';});F={a:'',r:'',e:'',s:'',q:''};apply();});
/* CSV: RFC 4180 quoting, UTF-8 BOM, formula-injection guard (same as RDS_Inventory_Explorer). */
function csvCell(x){var s=x==null?'':Array.isArray(x)?x.join(' '):String(x);
  if(/^[=+\-@\t\r]/.test(s)&&!/^-?[0-9]+(\.[0-9]+)?$/.test(s)) s="'"+s;
  if(/[",\r\n]/.test(s)) s='"'+s.replace(/"/g,'""')+'"'; return s;}
function csvText(rows){return '\ufeff'+rows.map(function(r){return r.map(csvCell).join(',');}).join('\r\n')+'\r\n';}
function rowVals(x){return D.cols.map(function(c){if(c.indexOf('tag:')===0){var t=x.tags||{};return t[c.slice(4)];}return x[c];});}
window.__pcCsv=function(){return csvText([D.cols].concat((active()?R.filter(match):R).map(rowVals)));};
$('f-csv').addEventListener('click',function(){
  var ac=F.a||D.csv_acct;var name='rds_patch_compliance_'+(ac?ac+'_':(D.accounts.length>1?'all_accounts_':''))+D.csv_stamp+(active()?'_filtered':'')+'.csv';
  var b=new Blob([window.__pcCsv()],{type:'text/csv;charset=utf-8'}),a=document.createElement('a');
  a.href=URL.createObjectURL(b);a.download=name;document.body.appendChild(a);a.click();
  setTimeout(function(){URL.revokeObjectURL(a.href);a.remove();},500);});
apply();
})();
