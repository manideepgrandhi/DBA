// Headless check of the HTML report (search, '/' hotkey, filters, expand/collapse). Needs puppeteer-core + Chrome.
// Usage: NODE_PATH=... node tests/html_check.js <report.html> [screenshot.png]  -> JSON, exit 1 on failure
const p = require('puppeteer-core');
(async () => {
  const b = await p.launch({executablePath: process.env.CHROME || '/usr/bin/google-chrome', args: ['--no-sandbox']});
  const g = await b.newPage(); const errs = [], net = [];
  g.on('pageerror', e => errs.push(e.message)); g.on('console', m => m.type() === 'error' && errs.push(m.text()));
  await g.setRequestInterception(true); g.on('request', r => { if (!r.url().startsWith('file:')) net.push(r.url()); r.continue(); });
  await g.setViewport({width: 1400, height: 1000}); await g.goto('file://' + process.argv[2]);
  const st = () => g.evaluate(() => ({count: document.getElementById('count').textContent,
    vis: [...document.querySelectorAll('details.card:not(.hidden)')].map(c => c.querySelector('summary b').textContent),
    open: document.querySelectorAll('details.card:not(.hidden)[open]').length, marks: document.querySelectorAll('mark').length,
    flags: document.querySelectorAll('tr.fl:not(.hidden)').length}));
  const search = async v => { await g.evaluate(v => { const q = document.getElementById('q'); q.value = v; q.dispatchEvent(new Event('input')); }, v); await new Promise(x => setTimeout(x, 300)); return st(); };
  const r = {}, fails = []; const ok = (c, m) => { if (!c) fails.push(m); };
  r.init = await st(); ok(r.init.open === 0 && r.init.vis.length > 5, 'initial: all cards collapsed');
  await g.keyboard.press('/'); ok(await g.evaluate(() => document.activeElement.id) === 'q', "'/' focuses search");
  await g.keyboard.type('ft_remote'); await new Promise(x => setTimeout(x, 400)); r.obj = await st();
  ok(r.obj.vis.includes('local-main / appdb') && !r.obj.vis.includes('local-second / billing') && r.obj.marks > 0 && r.obj.open === r.obj.vis.length, 'object search: card expanded + highlighted');
  ok(await g.evaluate(() => [...document.querySelectorAll('details.sch[open] > summary')].some(s => s.textContent.includes('schema sales'))), 'matching schema section opened');
  r.inv = await search('invoices'); ok(r.inv.vis.join() === 'local-second / billing', 'search second server');
  r.role = await search('svc_etl'); ok(r.role.vis.some(v => v.includes('access: svc_etl')) && r.role.vis.some(v => v.includes('roles')), 'search role');
  r.err = await search('connection refused'); ok(r.err.vis.join() === 'dead-server' && r.err.flags >= 1, 'unreachable server card + flag found');
  await g.click('#clear'); r.clear = await st(); ok(r.clear.marks === 0 && r.clear.vis.length === r.init.vis.length, 'clear resets');
  await g.select('#fs', 'local-second'); r.fs = await st(); ok(r.fs.vis.every(v => v.startsWith('local-second')), 'server filter');
  await g.select('#fs', ''); await g.select('#fk', 'access'); r.fk = await st(); ok(r.fk.vis.length > 0 && r.fk.vis.every(v => v.includes('access:')), 'section filter');
  await g.select('#fk', ''); await g.select('#fsev', 'HIGH'); r.sev = await st(); ok(r.sev.flags > 0 && r.sev.flags < r.init.flags, 'severity filter on flags'); await g.select('#fsev', '');
  await g.click('#ex'); ok((await st()).open === r.init.vis.length, 'expand all'); await g.click('#co'); ok((await st()).open === 0, 'collapse all');
  r.none = await search('zz-no-such'); ok(r.none.vis.length === 0 && await g.evaluate(() => !document.getElementById('none').hidden), 'no-match message');
  await g.click('#clear'); await search('orders');
  if (process.argv[3]) await g.screenshot({path: process.argv[3]});
  ok(errs.length === 0, 'no JS errors: ' + errs.join('; ')); ok(net.length === 0, 'self-contained (no network): ' + net.join(' '));
  console.log(JSON.stringify({fails, r})); await b.close(); process.exit(fails.length ? 1 : 0);
})().catch(e => { console.log(JSON.stringify({fails: [String(e)]})); process.exit(1); });
