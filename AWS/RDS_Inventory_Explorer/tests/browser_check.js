// Headless browser check of the explorer page (used by run_tests.sh when puppeteer-core + Chrome are available).
// Usage: node browser_check.js <explorer.html> [screenshot-dir]   -> prints JSON {fails, r}; exit 1 on any failure.
// Covers: type-ahead search (name / endpoint / tag / account / version), keyboard selection, dropdown filters, single
// detail card, cross-links instance <-> cluster <-> global, URL hash (reload / back), Copy JSON, dark mode
// (mg-theme localStorage), errors panel, HTML-escaping of AWS values, no JS errors and no network requests.
const p = require('puppeteer-core');
const path = require('path');
const r = {}, fails = []; let nchk = 0; const ok = (c, m) => { nchk++; if (!c) fails.push(m); };
const sleep = ms => new Promise(x => setTimeout(x, ms));
(async () => {
  const file = path.resolve(process.argv[2]), shots = process.argv[3];
  const b = await p.launch({executablePath: process.env.CHROME || '/usr/bin/google-chrome', args: ['--no-sandbox', '--allow-file-access-from-files']});
  const g = await b.newPage(); const errs = [], net = [];
  g.on('pageerror', e => errs.push(e.message)); g.on('console', m => m.type() === 'error' && errs.push(m.text()));
  await g.setRequestInterception(true);
  g.on('request', r => { if (!r.url().startsWith('file:')) net.push(r.url()); r.continue(); });
  await g.evaluateOnNewDocument(() => {   // capture "Copy JSON" without touching the real clipboard
    const cap = t => { window.__copied = t; return Promise.resolve(); };
    try { Object.defineProperty(navigator, 'clipboard', {value: {writeText: cap}, configurable: true}); } catch (e) {}
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
  await g.evaluate(() => localStorage.removeItem('mg-theme'));

  ok(errs.length === 0, 'no JS errors: ' + errs.join('; '));
  ok(net.length === 0, 'self-contained (no network): ' + net.join(' '));
  console.log(JSON.stringify(process.env.DEBUG ? {fails, r} : {fails, passed: nchk - fails.length, total: nchk}));
  await b.close(); process.exit(fails.length ? 1 : 0);
})().catch(e => { fails.push(String(e && e.stack || e)); console.log(JSON.stringify({fails, r})); process.exit(1); });
