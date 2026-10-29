// Headless browser check of the explorer page (used by run_tests.sh when puppeteer-core + Chrome are available).
// Usage: node browser_check.js <explorer.html> [screenshot-dir]   -> prints JSON {fails, r}; exit 1 on any failure.
// Covers: type-ahead search (name / endpoint / tag / account / version), keyboard selection, dropdown filters, single
// detail card, cross-links instance <-> cluster <-> global, URL hash (reload / back), Copy JSON, dark mode
// (mg-theme localStorage), errors panel, HTML-escaping of AWS values, no JS errors and no network requests.
// v1.1: Inventory | Pending maintenance tabs + URL hash, pending filters / search / sort / count strip, "N pending" badge,
// CSV export (intercepted blob bytes compared with the --csv files from CSV_DIR; a real Chrome download as well),
// empty state (EMPTY_HTML), narrow-width layout and mobile dark mode. SHOTS_V110=<dir> saves the v1.1 screenshots.
const p = require('puppeteer-core');
const path = require('path');
const r = {}, fails = []; let nchk = 0; const ok = (c, m) => { nchk++; if (!c) fails.push(m); };
const sleep = ms => new Promise(x => setTimeout(x, ms));
const fs = require('fs'), os = require('os');
function parseCsv(t) {   // RFC 4180 parser (test oracle)
  const rows = []; let row = [], f = '', q = false, i = 0;
  for (; i < t.length; i++) {
    const c = t[i];
    if (q) { if (c === '"') { if (t[i + 1] === '"') { f += '"'; i++; } else q = false; } else f += c; }
    else if (c === '"' && f === '') q = true;
    else if (c === ',') { row.push(f); f = ''; }
    else if (c === '\r' && t[i + 1] === '\n') { row.push(f); rows.push(row); row = []; f = ''; i++; }
    else f += c;
  }
  if (f !== '' || row.length) { row.push(f); rows.push(row); }
  return rows;
}
(async () => {
  const file = path.resolve(process.argv[2]), shots = process.argv[3];
  const b = await p.launch({executablePath: process.env.CHROME || '/usr/bin/google-chrome', args: ['--no-sandbox', '--allow-file-access-from-files']});
  const g = await b.newPage(); const errs = [], net = [];
  g.on('pageerror', e => errs.push(e.message)); g.on('console', m => m.type() === 'error' && errs.push(m.text()));
  await g.setRequestInterception(true);
  g.on('request', r => { if (!/^(file|blob):/.test(r.url())) net.push(r.url()); r.continue(); });
  await g.evaluateOnNewDocument(() => {   // capture "Copy JSON" without touching the real clipboard
    const cap = t => { window.__copied = t; return Promise.resolve(); };
    try { Object.defineProperty(navigator, 'clipboard', {value: {writeText: cap}, configurable: true}); } catch (e) {}
    // capture CSV downloads: keep each Blob, record <a download> clicks instead of saving
    window.__dl = []; window.__blobOf = {};
    const oc = URL.createObjectURL.bind(URL);
    URL.createObjectURL = b => { const u = oc(b); window.__blobOf[u] = b; return u; };
    const ck = HTMLAnchorElement.prototype.click;
    HTMLAnchorElement.prototype.click = function () { if (this.download) { window.__dl.push({name: this.download, href: this.href}); return; } return ck.call(this); };
  });
  await g.emulateMediaFeatures([{name: 'prefers-color-scheme', value: 'light'}]);
  await g.setViewport({width: 1440, height: 1000});
  const url = 'file://' + file;
  await g.goto(url);
    const st = () => g.evaluate(() => ({
    hash: decodeURIComponent(location.hash),
    rows: [...document.querySelectorAll('#list tbody tr')].map(t => t.querySelector('td:nth-child(2)').textContent),
    card: (document.getElementById('card') || {}).dataset ? (document.getElementById('card').dataset.type || null) : null,
    cards: document.querySelectorAll('#card').length,
    title: (document.querySelector('#card h2') || {}).textContent || null,
    sugg: [...document.querySelectorAll('#sugg.open .sg[data-i] .nm')].map(e => e.textContent)}));
  const type = async v => { await g.click('#q', {clickCount: 3}); await g.keyboard.press('Backspace'); await g.keyboard.type(v); await sleep(150); return st(); };
  const text = () => g.evaluate(() => (document.getElementById('card') || document.body).innerText);
  const go = async id => { await g.evaluate(id => { location.hash = '#id=' + encodeURIComponent(id); }, id); await sleep(150); return st(); };
  const ids = await g.evaluate(() => Object.fromEntries(JSON.parse(document.getElementById('explorer-data').textContent).resources.map(x => [x.name, x.id])));

  // ---- initial list, header
  r.init = await st(); ok(r.init.rows.length === Object.keys(ids).length && r.init.cards === 0, 'initial: full list, no card');
  r.header = await g.evaluate(() => document.querySelector('header').innerText);
  ok(/2\s+accounts/.test(r.header) && /1\s+global cluster/.test(r.header) && /4\s+cluster/.test(r.header) && /14\s+instance/.test(r.header), 'header counts');
  ok(/UTC/.test(r.header) && /IST/.test(r.header), 'generated time in UTC + IST');
  ok(!/eu-west-1|ap-south-1|us-east-1/.test(r.header), 'header lists no region names');
  r.regionOpts = await g.evaluate(() => [...document.querySelectorAll('#f-region option')].map(o => o.value).filter(Boolean));
  ok(r.regionOpts.join() === 'ap-south-1,us-east-1', 'region dropdown: only regions with databases (no empty / errored region)');
  r.typeOpts = await g.evaluate(() => [...document.querySelectorAll('#f-type option')].map(o => o.textContent));
  ok(r.typeOpts.includes('Global cluster') && r.typeOpts.includes('Aurora / Multi-AZ cluster') && r.typeOpts.includes('RDS instance'), 'type dropdown');

  // ---- search + keyboard select
  await g.keyboard.press('/'); ok(await g.evaluate(() => document.activeElement.id) === 'q', "'/' focuses search");
  r.s_orders = await type('orders');
  ok(r.s_orders.sugg[0] === 'orders-aurora' && r.s_orders.sugg.includes('orders-2') && r.s_orders.sugg.includes('qa-mysql'), 'search by name + tag value: ' + r.s_orders.sugg);
  if (shots) await g.screenshot({path: path.join(shots, '01_search_suggestions.png')});
  await g.keyboard.press('ArrowDown'); await g.keyboard.press('Enter'); await sleep(150);
  r.sel = await st(); ok(r.sel.card === 'cluster' && r.sel.title === 'orders-aurora' && r.sel.cards === 1 && r.sel.rows.length === 0, 'Enter selects -> only that card');
  ok(r.sel.hash === '#id=' + ids['orders-aurora'], 'selection kept in URL hash');
  let t = await text();
  ok(/orders-aurora\.cluster-cxyzabc123/.test(t) && /orders-aurora\.cluster-ro-cxyzabc123/.test(t) && /orders-reporting\.cluster-custom/.test(t) && /static: orders-3/.test(t), 'cluster endpoints: writer, reader, custom');
  r.members = await g.evaluate(() => { const s = [...document.querySelectorAll('#card .sec')].find(s => /^Instances/.test(s.querySelector('h3').textContent)); return s ? s.querySelectorAll('tbody tr').length : -1; });
  ok(r.members === 3 && /orders-1\.cxyzabc123\.us-east-1\.rds\.amazonaws\.com:3306/.test(t), 'member instances with endpoint:port');
  ok(/admin/.test(t) && /Backup retention\s+\d+ days/.test(t) && /UTC\s+·\s+\w{3}:\d\d:\d\d-\w{3}:\d\d:\d\d IST/.test(t), 'master user, backup retention, maintenance window UTC + IST');
  ok(/db-upgrade/.test(t) && /system-update/.test(t) && /next-maintenance/.test(t), 'pending maintenance (cluster + member) with opt-in');

  // ---- managed secret + KMS + global links
  await go(ids['pay-aurora-use1']); t = await text();
  ok(/secret:rds!pay-aurora-use1/.test(t) && /key\/5ec7/.test(t) && /key\/9e1f/.test(t), 'master secret ARN + secret KMS + PI KMS');
  ok(/Earliest restorable/.test(t) && /Copy tags to snapshot/.test(t), 'backup detail rows');
  r.amv = await g.evaluate(() => document.getElementById('card').innerText.match(/Auto minor version upgrade\s+([^\n]+)/)[1]);
  ok(/1 of 2 instance\(s\) off/.test(r.amv), 'auto minor upgrade summary: ' + r.amv);
  await g.click('#card a[data-link="' + ids['pay-global'] + '"]'); await sleep(150);
  r.glob = await st(); t = await text();
  ok(r.glob.card === 'global' && /Primary region\s+us-east-1/.test(t) && /Secondary regions\s+ap-south-1/.test(t) && /Write forwarding\s+Enabled on pay-aurora-aps1/.test(t), 'global card: regions + write forwarding');
  ok(/pay-global\.global-abc123xyz/.test(t) && /Deletion protection\s+Yes/.test(t) && /Storage encrypted\s+Yes/.test(t), 'global card: endpoint / protection');
  await g.click('#card a[data-link="' + ids['pay-aurora-aps1'] + '"]'); await sleep(150);
  r.sec = await st(); ok(r.sec.title === 'pay-aurora-aps1', 'global -> secondary cluster link');
  await g.click('#card a[data-link="' + ids['pay-aps1-1'] + '"]'); await sleep(150);
  r.mem = await st(); t = await text(); ok(r.mem.card === 'member' && /Cluster pay-aurora-aps1 \(reader\)/.test(t) && /Global pay-global/.test(t), 'cluster -> member instance, back-links to cluster + global');

  // ---- copy JSON
  await g.click('#copy-json'); await sleep(100);
  r.copied = await g.evaluate(() => { try { return JSON.parse(window.__copied).DBInstanceIdentifier; } catch (e) { return 'ERR ' + e; } });
  ok(r.copied === 'pay-aps1-1', 'Copy JSON copies the raw AWS description');
  ok(/copied/.test(await g.evaluate(() => document.getElementById('toast').textContent)), 'copy toast');

  // ---- standalone instance card
  r.s_crm = await type('crm-pg'); ok(r.s_crm.sugg[0] === 'crm-pg', 'exact name ranks first');
  await g.keyboard.press('Enter'); await sleep(150); t = await text();
  ok((await st()).card === 'instance' && /500 GiB/.test(t) && /Provisioned IOPS\s+12000/.test(t) && /500 MiB\/s/.test(t) && /Multi-AZ\s+Yes/.test(t), 'instance storage / Multi-AZ');
  ok(/crm-pg-rr1/.test(t) && /crm-pg-replica-aps1/.test(t) && /secret:rds!crm-pg/.test(t) && /IAM DB authentication\s+Yes/.test(t), 'replicas + secret + IAM auth');
  ok(/system-update/.test(t) && /rds-ca-rsa2048-g1/.test(t) && /mon:03:30-mon:04:00 IST/.test(t), 'pending + CA + window IST day wrap');
  if (shots) await g.screenshot({path: path.join(shots, '03_instance_card.png'), fullPage: true});
  await g.click('#card a[data-link="' + ids['crm-pg-replica-aps1'] + '"]'); await sleep(150); t = await text();
  ok(/Source\s+crm-pg/.test(t) && (await st()).title === 'crm-pg-replica-aps1', 'cross-region replica -> source link');
  await go(ids['hr-sqlserver']); t = await text();
  ok(/Auto minor version upgrade\s+No/.test(t) && /rds-ca-2019 expires [0-9-]+ \(40 d\)/.test(t) && /thu:05:00-thu:05:30 IST/.test(t), 'sqlserver: auto minor off, CA expiry, window wrap');

  // ---- search by endpoint / account / version / escaping
  r.s_ep = await type('global-abc123xyz'); ok(r.s_ep.sugg.join() === 'pay-global', 'search by endpoint');
  r.s_acct = await type('222222222222'); ok(r.s_acct.sugg.join() === 'qa-mysql', 'search by account');
  r.s_ver = await type('3.08.2'); ok(r.s_ver.sugg.includes('orders-aurora'), 'search by version');
  r.s_tag = await type('payroll'); ok(r.s_tag.sugg.join() === 'hr-sqlserver', 'search by tag value');
  r.s_esc = await type('</script>'); ok(r.s_esc.sugg.join() === 'qa-mysql', 'search for a value containing </script>');
  await g.keyboard.press('Enter'); await sleep(150);
  r.esc = await g.evaluate(() => ({txt: [...document.querySelectorAll('#card .tag')].map(e => e.textContent).join('|'), b: document.querySelectorAll('#card .tag b').length}));
  ok(/orders<\/script><b>x/.test(r.esc.txt) && r.esc.b === 0, 'AWS values rendered as text, not HTML');
  t = await text(); ok(/Publicly accessible\s+Yes/.test(t) && /Deletion protection\s+No/.test(t), 'public / deletion-protection flags');
  r.s_none = await type('zz-no-such'); ok(r.s_none.sugg.length === 0 && /No match/.test(await g.evaluate(() => document.getElementById('sugg').innerText)), 'no-match message');

  // ---- hash survives reload; back to list; unknown id
  await go(ids['ledger-maz']); await g.reload(); await sleep(200);
  r.reload = await st(); ok(r.reload.title === 'ledger-maz', 'hash restores selection after reload');
  t = await text(); ok(/Multi-AZ DB cluster/.test(t) && /Auto minor version upgrade\s+Yes\s+\(cluster setting\)/.test(t), 'Multi-AZ DB cluster: cluster-level auto minor');
  await g.click('#back'); await sleep(150); r.back = await st(); ok(r.back.cards === 0 && r.back.rows.length === r.init.rows.length && r.back.hash === '', 'back to list clears hash');
  await go('arn:aws:rds:xx:000:db:nope'); ok(/not in this report/.test(await g.evaluate(() => document.getElementById('view').innerText)), 'unknown id message');
  await g.evaluate(() => { location.hash = ''; }); await sleep(100);

  // ---- filters
  await g.click('#clear'); await sleep(100);
  await g.select('#f-region', 'ap-south-1'); r.f_reg = (await st()).rows;
  ok(r.f_reg.length === 5 && r.f_reg.includes('pay-global') && r.f_reg.includes('qa-mysql') && !r.f_reg.includes('crm-pg'), 'region filter (global included via member region): ' + r.f_reg);
  await g.select('#f-account', '111111111111'); r.f_acc = (await st()).rows; ok(r.f_acc.length === 4 && !r.f_acc.includes('qa-mysql'), 'account + region filters combine');
  await g.select('#f-region', ''); await g.select('#f-account', '');
  await g.select('#f-type', 'global'); r.f_type = (await st()).rows; ok(r.f_type.join() === 'pay-global', 'type filter');
  await g.select('#f-type', 'instance'); r.f_inst = (await st()).rows; ok(r.f_inst.length === 5, 'type filter: standalone instances');
  await g.select('#f-type', ''); await g.select('#f-engine', 'aurora-mysql'); r.f_eng = (await st()).rows;
  ok(r.f_eng.length === 4 && r.f_eng[0] === 'orders-aurora', 'engine filter');
  r.f_q = await type('orders-3'); ok(r.f_q.rows.join() === 'orders-3,orders-aurora', 'search narrows the filtered list (exact name first, then its cluster): ' + r.f_q.rows);
  await g.click('#clear'); await sleep(100); ok((await st()).rows.length === r.init.rows.length, 'clear resets search + filters');

  // ================= v1.1: Pending maintenance tab =================
  const S110 = process.env.SHOTS_V110, CSVD = process.env.CSV_DIR;
  const ps = () => g.evaluate(() => ({
    hash: decodeURIComponent(location.hash),
    tabInv: document.getElementById('tab-inventory').getAttribute('aria-selected'),
    tabPm: document.getElementById('tab-pending').getAttribute('aria-selected'),
    invBar: document.getElementById('inv-toolbar').getClientRects().length > 0, pmBar: document.getElementById('pm-toolbar').getClientRects().length > 0,
    rows: [...document.querySelectorAll('#pm-table tbody tr')].map(t => t.querySelector('td:nth-child(3)').textContent),
    urg: [...document.querySelectorAll('#pm-table tbody tr')].map(t => t.dataset.urgency),
    hl: document.querySelectorAll('#pm-table tbody tr.hl').length,
    stats: [...document.querySelectorAll('#pm-counts .stat b')].map(b => b.textContent).join(),
    on: [...document.querySelectorAll('#pm-counts .stat.on')].map(b => b.id).join(),
    shown: (document.getElementById('pm-shown') || {}).textContent || ''}));
  const lastDl = () => g.evaluate(async () => {
    const d = window.__dl[window.__dl.length - 1]; if (!d) return null;
    const b = window.__blobOf[d.href]; return {n: window.__dl.length, name: d.name, type: b.type, bytes: Array.from(new Uint8Array(await b.arrayBuffer()))};
  });
  const sel = async (id, v) => { await g.select(id, v); await sleep(120); return ps(); };
  const sortBy = async k => { await g.click('#pm-table th[data-key="' + k + '"] button'); await sleep(120); return ps(); };
  const ALL5 = 'hr-sqlserver,orders-2,crm-pg,orders-aurora,qa-mysql';

  await g.evaluate(() => { location.hash = ''; }); await sleep(100);
  r.t0 = await ps(); ok(r.t0.tabInv === 'true' && r.t0.tabPm === 'false' && r.t0.invBar && !r.t0.pmBar, 'tabs: Inventory active by default');
  ok(await g.evaluate(() => document.getElementById('tab-pending-n').textContent) === '5', 'Pending tab shows the action count');
  r.listBadge = await g.evaluate(() => [...document.querySelectorAll('#list tbody tr')].filter(t => t.querySelector('.pbadge')).map(t => t.querySelector('td:nth-child(2)').textContent + ':' + t.querySelector('.pbadge').textContent).sort().join());
  ok(r.listBadge === 'crm-pg:1,hr-sqlserver:1,orders-2:1,orders-aurora:2,qa-mysql:1', 'inventory list: pending count column: ' + r.listBadge);
  await g.click('#tab-pending'); await sleep(150);
  r.t1 = await ps();
  ok(r.t1.hash === '#tab=pending' && r.t1.tabPm === 'true' && r.t1.pmBar && !r.t1.invBar, 'Pending tab: hash + toolbar swap: ' + r.t1.hash);
  ok(r.t1.rows.join() === ALL5, 'one row per action, most urgent first: ' + r.t1.rows);
  ok(r.t1.urg.join() === 'past_due,lt7,lt30,later,no_date', 'every urgency bucket present: ' + r.t1.urg);
  ok(r.t1.stats === '5,1,1,2', 'count strip: total / past due / 7 d / 30 d: ' + r.t1.stats);
  t = await g.evaluate(() => document.getElementById('pm-table').innerText);
  ok(/ca-certificate-rotation/.test(t) && /Rotate CA to "rds-ca-rsa2048-g1", restart required/.test(t) && /next-maintenance/.test(t), 'action, description, opt-in shown');
  ok(/2026-10-14 06:30 UTC\s+·\s+2026-10-14 12:00 IST\s+\(3 d ago\)/.test(t) && /2027-01-15 06:30 UTC\s+·\s+2027-01-15 12:00 IST/.test(t), 'apply dates in UTC + IST with relative days');
  ok(/sat:21:00-sat:21:30 UTC\s+sun:02:30-sun:03:00 IST\s+next: 2026-10-17 21:00 UTC\s+·\s+2026-10-18 02:30 IST/.test(t), 'next maintenance window in UTC + IST');
  r.heads = await g.evaluate(() => [...document.querySelectorAll('#pm-table th')].map(x => x.textContent).join('|'));
  ok(r.heads === 'Account|Region|Resource|Type|Action|Description|Auto-applied after|Forced apply|Opt-in status|Current apply|Next maintenance window|Urgency', 'pending columns: ' + r.heads);
  r.types = await g.evaluate(() => [...document.querySelectorAll('#pm-table tbody tr td:nth-child(4)')].map(x => x.textContent).join());
  ok(r.types === 'INSTANCE,MEMBER,INSTANCE,CLUSTER,INSTANCE', 'resource type column: ' + r.types);
  if (S110) await g.screenshot({path: path.join(S110, '01_pending_tab.png'), fullPage: true});
  await g.reload(); await sleep(200); ok((await ps()).rows.join() === ALL5, 'reload keeps the Pending tab');

  // filters + search
  r.pf1 = await sel('#pf-account', '222222222222'); ok(r.pf1.rows.join() === 'qa-mysql', 'pending account filter');
  r.pf2 = await sel('#pf-region', 'ap-south-1'); ok(r.pf2.rows.join() === 'qa-mysql', 'pending region filter');
  await sel('#pf-account', ''); await sel('#pf-region', '');
  r.pf3 = await sel('#pf-action', 'db-upgrade'); ok(r.pf3.rows.join() === 'orders-aurora,qa-mysql', 'action type filter: ' + r.pf3.rows);
  await sel('#pf-action', '');
  r.pf4 = await sel('#pf-urgency', 'past_due'); ok(r.pf4.rows.join() === 'hr-sqlserver' && r.pf4.on === 'st-past', 'urgency filter: past due');
  r.pf5 = await sel('#pf-urgency', 'no_date'); ok(r.pf5.rows.join() === 'qa-mysql', 'urgency filter: no date');
  await sel('#pf-urgency', '');
  await g.click('#st-30d'); await sleep(120); r.pf6 = await ps();
  ok(r.pf6.rows.join() === 'orders-2,crm-pg' && r.pf6.on === 'st-30d' && /Showing 2 of 5/.test(r.pf6.shown), 'count strip click filters (within 30 days): ' + r.pf6.rows);
  if (S110) await g.screenshot({path: path.join(S110, '02_pending_filtered.png'), fullPage: true});
  await g.click('#st-30d'); await sleep(120); ok((await ps()).rows.length === 5, 'clicking the active count again clears it');
  const ptype = async v => { await g.click('#pq', {clickCount: 3}); await g.keyboard.press('Backspace'); await g.keyboard.type(v); await sleep(150); return ps(); };
  ok((await ptype('certificate')).rows.join() === 'hr-sqlserver', 'pending text search (description)');
  ok((await ptype('nonprod')).rows.join() === 'qa-mysql', 'pending text search (profile)');
  ok((await ptype('system-update us-east-1')).rows.join() === 'orders-2,crm-pg', 'pending text search (multi-token)');
  r.pnone = await ptype('zz-nothing'); ok(r.pnone.rows.length === 0 && await g.$('#pm-none') !== null, 'pending: no-match empty state');
  await g.click('#pclear'); await sleep(120); ok((await ps()).rows.join() === ALL5, 'pending Clear resets');

  // sort
  r.so1 = await sortBy('resource'); ok(r.so1.rows.join() === 'crm-pg,hr-sqlserver,orders-2,orders-aurora,qa-mysql', 'sort by resource asc: ' + r.so1.rows);
  r.so2 = await sortBy('resource'); ok(r.so2.rows.join() === 'qa-mysql,orders-aurora,orders-2,hr-sqlserver,crm-pg', 'sort by resource desc');
  ok(await g.evaluate(() => document.querySelector('#pm-table th[data-key="resource"]').getAttribute('aria-sort')) === 'descending', 'aria-sort on sorted column');
  r.so3 = await sortBy('forced'); ok(r.so3.rows.join() === 'hr-sqlserver,crm-pg,orders-aurora,orders-2,qa-mysql', 'sort by forced apply asc, empty last: ' + r.so3.rows);
  r.so4 = await sortBy('forced'); ok(r.so4.rows.join() === 'orders-aurora,crm-pg,hr-sqlserver,orders-2,qa-mysql', 'sort by forced apply desc, empty still last: ' + r.so4.rows);
  r.so5 = await sortBy('urgency'); ok(r.so5.rows.join() === ALL5, 'sort by urgency');
  r.so6 = await sortBy('account'); ok(r.so6.rows[4] === 'qa-mysql', 'sort by account');
  const allKeys = await g.evaluate(() => [...document.querySelectorAll('#pm-table th')].map(x => x.dataset.key));
  let sortedAll = true; for (const k of allKeys) { const a = await sortBy(k); if (a.rows.length !== 5) sortedAll = false; }
  ok(allKeys.length === 12 && sortedAll, 'every column sorts');

  // CSV export from the Pending tab (filtered + sorted)
  await g.click('#pclear'); await sleep(120);
  await g.click('#pm-csv'); await sleep(150);
  r.dl1 = await lastDl();
  ok(r.dl1 && r.dl1.name === 'rds_pending_maintenance_20261017_063000.csv' && /text\/csv/.test(r.dl1.type), 'pending CSV: file name + type: ' + (r.dl1 && r.dl1.name));
  const b1 = Buffer.from(r.dl1.bytes);
  ok(b1[0] === 0xef && b1[1] === 0xbb && b1[2] === 0xbf, 'pending CSV: UTF-8 BOM');
  const t1 = b1.toString('utf8').slice(1);
  ok(t1.endsWith('\r\n') && t1.split('\r\n').length === 7 && !/[^\r]\n/.test(t1), 'pending CSV: CRLF, header + 5 rows');
  ok(/,"Rotate CA to ""rds-ca-rsa2048-g1"", restart required",/.test(t1) && /,-3,past due,/.test(t1), 'pending CSV: RFC 4180 quoting; numbers not guarded');
  const rows1 = parseCsv(t1);
  ok(rows1[0][0] === 'Account' && rows1[0].length === 19 && rows1.every(x => x.length === 19), 'pending CSV: 19 columns on every row');
  ok(rows1.slice(1).map(x => x[3]).join() === ALL5 && rows1[1][18] === ids['hr-sqlserver'], 'pending CSV: rows in table order');
  if (CSVD) {
    const f = fs.readdirSync(CSVD).find(x => /_pending_\d{8}_\d{6}\.csv$/.test(x));
    ok(f && Buffer.compare(fs.readFileSync(path.join(CSVD, f)), b1) === 0, 'pending CSV from the page == --csv file, byte for byte');
  }
  await g.click('#st-30d'); await sleep(100); await sortBy('resource'); await sortBy('resource');
  await g.click('#pm-csv'); await sleep(150);
  r.dl2 = await lastDl(); const rows2 = parseCsv(Buffer.from(r.dl2.bytes).toString('utf8').slice(1));
  ok(r.dl2.n === 2 && rows2.length === 3 && rows2[1][3] === 'orders-2' && rows2[2][3] === 'crm-pg', 'pending CSV exports the filtered + sorted rows: ' + rows2.slice(1).map(x => x[3]));
  await g.click('#pclear'); await sleep(120);

  // badge -> Pending tab, back, resource link
  await g.evaluate(id => { location.hash = '#id=' + encodeURIComponent(id); }, ids['orders-aurora']); await sleep(150);
  ok((await st()).title === 'orders-aurora' && (await ps()).tabInv === 'true', 'old #id= link still opens the Inventory card');
  r.badge = await g.evaluate(() => { const b = document.getElementById('pending-badge'); return b ? b.textContent : null; });
  ok(r.badge === '2 pending', 'cluster card badge counts cluster + member actions: ' + r.badge);
  if (S110) await g.screenshot({path: path.join(S110, '03_card_with_badge.png'), fullPage: false});
  await g.click('#pending-badge'); await sleep(150); r.b1 = await ps();
  ok(r.b1.hash === '#tab=pending&id=' + ids['orders-aurora'] + '&res=' + ids['orders-aurora'] && r.b1.tabPm === 'true', 'badge jumps to the Pending tab: ' + r.b1.hash);
  ok(r.b1.rows.join() === 'orders-2,orders-aurora' && r.b1.hl === 2 && await g.$('#res-note') !== null, "badge shows only that resource's rows (incl. members): " + r.b1.rows);
  await g.reload(); await sleep(200); ok((await ps()).rows.join() === 'orders-2,orders-aurora', 'resource filter survives reload');
  await g.goBack(); await sleep(150); ok((await st()).title === 'orders-aurora', 'browser Back returns to the card');
  await g.goForward(); await sleep(150);
  await g.click('#res-clear'); await sleep(150); r.b2 = await ps();
  ok(r.b2.rows.length === 5 && r.b2.hash === '#tab=pending&id=' + ids['orders-aurora'], 'Show all drops the resource filter, keeps the selection');
  await g.click('#tab-inventory'); await sleep(150);
  ok((await st()).title === 'orders-aurora' && (await ps()).hash === '#id=' + ids['orders-aurora'], 'Inventory tab returns to the selected card');
  await go(ids['hr-sqlserver']); ok(await g.evaluate(() => document.getElementById('pending-badge').textContent) === '1 pending', 'instance card badge');
  await go(ids['ledger-maz']); ok(await g.$('#pending-badge') === null, 'no badge without pending actions');
  await g.click('#tab-pending'); await sleep(150);
  await g.click('#pm-table tbody tr[data-res="' + ids['crm-pg'] + '"] a'); await sleep(150);
  ok((await st()).title === 'crm-pg' && (await ps()).tabInv === 'true', 'resource link in the Pending table opens its card');
  await g.evaluate(() => { location.hash = '#tab=pending&res=' + encodeURIComponent('arn:aws:rds:xx:0:db:nope'); }); await sleep(150);
  ok((await ps()).rows.length === 0 && await g.$('#res-note') !== null, 'unknown res= shows nothing, with Show all');
  await g.evaluate(() => { location.hash = ''; }); await sleep(100);

  // CSV export from the Inventory tab
  await g.click('#inv-csv'); await sleep(150);
  r.dl3 = await lastDl(); const b3 = Buffer.from(r.dl3.bytes), t3 = b3.toString('utf8').slice(1), rows3 = parseCsv(t3);
  ok(r.dl3.name === 'rds_inventory_20261017_063000.csv' && b3[0] === 0xef && b3[1] === 0xbb && b3[2] === 0xbf, 'inventory CSV: name + BOM: ' + r.dl3.name);
  ok(rows3.length === 1 + Object.keys(ids).length && rows3.every(x => x.length === rows3[0].length), 'inventory CSV: one row per resource, rectangular');
  ok(rows3[0].slice(0, 6).join() === 'Account,Profile,Region,Type,Identifier,Engine' && rows3[0].slice(-4).join() === 'tag:Application,tag:Environment,tag:Owner,tag:cost-center', 'inventory CSV: columns + tags as columns: ' + rows3[0].slice(-4));
  const qa = rows3.find(x => x[4] === 'qa-mysql'), H3 = rows3[0];
  ok(qa[H3.indexOf('tag:cost-center')] === "'=HYPERLINK(\"http://x\")" && /,"'=HYPERLINK\(""http:\/\/x""\)"/.test(t3), 'inventory CSV: formula-injection guard + quoting');
  ok(qa[H3.indexOf('tag:Application')] === 'orders</script><b>x' && qa[H3.indexOf('Port')] === '3306' && qa[H3.indexOf('Pending actions')] === '1', 'inventory CSV: raw values kept');
  const oa = rows3.find(x => x[4] === 'orders-aurora');
  ok(oa[H3.indexOf('Backup retention (days)')] === '14' && oa[H3.indexOf('Maintenance window (IST)')] === 'sun:02:30-sun:03:00 IST' && oa[H3.indexOf('Pending incl. members')] === '2' && /^arn:aws:kms:/.test(oa[H3.indexOf('KMS key')]), 'inventory CSV: cluster row');
  if (CSVD) {
    const f = fs.readdirSync(CSVD).find(x => /_inventory_\d{8}_\d{6}\.csv$/.test(x));
    ok(f && Buffer.compare(fs.readFileSync(path.join(CSVD, f)), b3) === 0, 'inventory CSV from the page == --csv file, byte for byte');
  }
  await g.select('#f-account', '222222222222'); await sleep(100);
  await g.click('#inv-csv'); await sleep(150);
  const rows4 = parseCsv(Buffer.from((await lastDl()).bytes).toString('utf8').slice(1));
  ok(rows4.length === 2 && rows4[1][4] === 'qa-mysql' && rows4[0].slice(-4).join() === 'tag:Application,tag:Environment,tag:Owner,tag:cost-center', 'inventory CSV exports only the filtered resources');
  await g.select('#f-type', 'cluster'); await sleep(100); await g.click('#inv-csv'); await sleep(150);
  const rows5 = parseCsv(Buffer.from((await lastDl()).bytes).toString('utf8').slice(1));
  ok(rows5.length === 1 && rows5[0][0] === 'Account', 'inventory CSV with nothing shown: header only');
  await g.click('#clear'); await sleep(100);

  // a real Chrome download (CSP allows the blob: link), on a page without the capture stub
  {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'rexp_dl_')), g2 = await b.newPage();
    g2.on('pageerror', e => errs.push('dl page: ' + e.message)); g2.on('console', m => m.type() === 'error' && errs.push('dl page: ' + m.text()));
    const cdp = await g2.target().createCDPSession();
    await cdp.send('Browser.setDownloadBehavior', {behavior: 'allow', downloadPath: dir});
    await g2.goto(url + '#tab=pending'); await sleep(200);
    await g2.click('#pm-csv');
    let got = null; for (let i = 0; i < 50 && !got; i++) { await sleep(100); got = fs.readdirSync(dir).find(x => /\.csv$/.test(x)); }
    ok(got === 'rds_pending_maintenance_20261017_063000.csv' && Buffer.compare(fs.readFileSync(path.join(dir, got)), b1) === 0, 'real browser download writes the same CSV: ' + got);
    await g2.close(); fs.rmSync(dir, {recursive: true, force: true});
  }

  // empty state
  if (process.env.EMPTY_HTML) {
    const g3 = await b.newPage(); g3.on('pageerror', e => errs.push('empty page: ' + e.message));
    await g3.goto('file://' + path.resolve(process.env.EMPTY_HTML) + '#tab=pending'); await sleep(200);
    r.empty = await g3.evaluate(() => ({e: !!document.getElementById('pm-empty'), n: document.getElementById('tab-pending-n').textContent, s: [...document.querySelectorAll('#pm-counts .stat b')].map(b => b.textContent).join()}));
    ok(r.empty.e && r.empty.n === '0' && r.empty.s === '0,0,0,0', 'Pending tab empty state');
    await g3.close();
  }

  // narrow widths: the cluster card's instance table (Pending column) stays inside the card
  for (const w of [680, 900, 1280]) {
    await g.setViewport({width: w, height: 900}); await go(ids['orders-aurora']);
    const m = await g.evaluate(() => {
      const tb = document.querySelector('#card table.members'), sc = tb.parentElement, last = tb.querySelector('tbody tr td:last-child').getBoundingClientRect();
      return {over: sc.scrollWidth - sc.clientWidth, right: last.right, vw: document.documentElement.clientWidth, page: document.documentElement.scrollWidth - document.documentElement.clientWidth};
    });
    ok(m.over <= 1 && m.right <= m.vw && m.page <= 0, 'cluster instance table fits at ' + w + 'px (overflow ' + m.over + ', pending cell right ' + Math.round(m.right) + '/' + m.vw + ')');
  }
  await g.setViewport({width: 1440, height: 1000});

  // ---- errors panel
  await g.click('#err-chip'); await sleep(100);
  r.err = await g.evaluate(() => ({open: document.getElementById('errors').open, n: document.querySelectorAll('#errors tbody tr').length, txt: document.getElementById('errors').innerText}));
  ok(r.err.open && r.err.n === 7 && /InvalidClientTokenId/.test(r.err.txt) && /me-central-1/.test(r.err.txt), 'errors panel');
  ok(!/eu-west-1/.test(await g.evaluate(() => document.body.innerText)), 'empty region never shown');

  // ---- cluster screenshot (light), then dark mode
  await go(ids['orders-aurora']);
  if (shots) await g.screenshot({path: path.join(shots, '02_cluster_card.png'), fullPage: true});
  for (let i = 0; i < 3 && await g.evaluate(() => document.documentElement.dataset.theme) !== 'dark'; i++) { await g.click('#theme-btn'); await sleep(50); }
  r.dark = await g.evaluate(() => ({theme: document.documentElement.dataset.theme, ls: localStorage.getItem('mg-theme'), bg: getComputedStyle(document.body).backgroundColor}));
  ok(r.dark.theme === 'dark' && r.dark.ls === 'dark' && r.dark.bg === 'rgb(13, 17, 23)', 'dark mode via mg-theme');
  await g.reload(); await sleep(200);
  ok(await g.evaluate(() => document.documentElement.dataset.theme) === 'dark' && (await st()).title === 'orders-aurora', 'dark mode + selection persist across reload');
  await go(ids['pay-aurora-use1']);
  if (shots) await g.screenshot({path: path.join(shots, '04_dark_mode.png'), fullPage: false});
  // mobile, dark: Pending tab rows become label / value lists, nothing scrolls sideways
  await g.setViewport({width: 390, height: 844, isMobile: true, hasTouch: true, deviceScaleFactor: 2});
  await g.evaluate(() => { location.hash = '#tab=pending'; }); await sleep(200);
  r.mob = await g.evaluate(() => ({theme: document.documentElement.dataset.theme, over: document.documentElement.scrollWidth - document.documentElement.clientWidth,
    thead: getComputedStyle(document.querySelector('#pm-table thead')).display, td: getComputedStyle(document.querySelector('#pm-table td')).display,
    lab: getComputedStyle(document.querySelector('#pm-table td'), '::before').content, rows: document.querySelectorAll('#pm-table tbody tr').length}));
  ok(r.mob.theme === 'dark' && r.mob.over <= 0 && r.mob.thead === 'none' && r.mob.td === 'grid' && r.mob.lab === '"Account"' && r.mob.rows === 5, 'mobile dark: stacked pending rows, no sideways scroll: ' + JSON.stringify(r.mob));
  if (S110) await g.screenshot({path: path.join(S110, '04_mobile_dark_pending.png'), fullPage: true});
  await go(ids['orders-aurora']);
  r.mob2 = await g.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
  ok(r.mob2 <= 0, 'mobile dark: cluster card has no sideways scroll');
  if (S110) await g.screenshot({path: path.join(S110, '05_mobile_dark_cluster_card.png'), fullPage: true});
  await g.setViewport({width: 1440, height: 1000});
  await g.evaluate(() => localStorage.removeItem('mg-theme'));

  ok(errs.length === 0, 'no JS errors: ' + errs.join('; '));
  ok(net.length === 0, 'self-contained (no network): ' + net.join(' '));
  console.log(JSON.stringify(process.env.DEBUG ? {fails, r} : {fails, passed: nchk - fails.length, total: nchk}));
  await b.close(); process.exit(fails.length ? 1 : 0);
})().catch(e => { fails.push(String(e && e.stack || e)); console.log(JSON.stringify({fails, r})); process.exit(1); });
