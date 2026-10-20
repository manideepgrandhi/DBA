// Headless check of the HTML report's search / filters / expand-collapse (used by run_tests.sh when puppeteer-core
// and Chrome are available). Usage: node html_check.js <report.html> [screenshot.png]   -> prints JSON, exit 1 on failure
const p = require('puppeteer-core');
(async () => {
  const b = await p.launch({executablePath: process.env.CHROME || '/usr/bin/google-chrome', args: ['--no-sandbox']});
  const g = await b.newPage(); const errs = [];
  g.on('pageerror', e => errs.push(e.message)); g.on('console', m => m.type() === 'error' && errs.push(m.text()));
  await g.setRequestInterception(true); const net = [];
  g.on('request', r => { if (!r.url().startsWith('file:')) net.push(r.url()); r.continue(); });
  await g.setViewport({width: 1400, height: 1000}); await g.goto('file://' + process.argv[2]);
  const st = () => g.evaluate(() => ({count: document.getElementById('count').textContent,
    vis: [...document.querySelectorAll('details.card:not(.hidden)')].map(c => c.querySelector('summary b').textContent),
    open: [...document.querySelectorAll('details.card:not(.hidden)[open]')].length, marks: document.querySelectorAll('mark').length}));
  const search = async v => { await g.evaluate(v => { const q = document.getElementById('q'); q.value = v; q.dispatchEvent(new Event('input')); }, v); await new Promise(x => setTimeout(x, 300)); return st(); };
  const r = {}, fails = []; const ok = (c, m) => { if (!c) fails.push(m); };
  r.init = await st(); ok(r.init.open === 0 && r.init.vis.length > 0, 'initial: all collapsed');
  await g.keyboard.press('/'); ok(await g.evaluate(() => document.activeElement.id) === 'q', "'/' focuses search");
  await g.keyboard.type('billing-pg-dr'); await new Promise(x => setTimeout(x, 300)); r.name = await st();
  ok(r.name.vis.join() === 'billing-pg' && r.name.open === 1 && r.name.marks > 0 && /1 of \d+ group\(s\) · \d+ match/.test(r.name.count), 'search by replica name finds the source group, expanded + highlighted');
  r.tag = await search('payments'); ok(r.tag.vis.join() === 'pay-global', 'search by tag value');
  r.ep = await search('cluster-ro-'); ok(r.ep.vis.length >= 3, 'search by endpoint');
  r.ver = await search('8.0.mysql_aurora'); ok(r.ver.vis.join() === 'crm-sv2', 'search by version');
  r.acct = await search('222222222222'); ok(r.acct.vis.length === 2, 'search by account');
  await g.click('#clear'); r.clear = await st(); ok(r.clear.marks === 0 && r.clear.vis.length === r.init.vis.length, 'clear resets');
  await g.select('#fe', 'postgres'); r.fe = await st(); ok(r.fe.vis.includes('billing-pg') && !r.fe.vis.includes('crm-sv2'), 'engine filter'); await g.select('#fe', '');
  await g.select('#fr', 'ap-south-1'); r.fr = await st(); ok(r.fr.vis.includes('pay-global') && r.fr.vis.includes('billing-pg'), 'region filter includes global + cross-region replica groups'); await g.select('#fr', '');
  await g.select('#ft', 'standalone'); r.ft = await st(); ok(!r.ft.vis.includes('pay-global'), 'type filter'); await g.select('#ft', '');
  await g.click('#ex'); ok((await st()).open === r.init.vis.length, 'expand all'); await g.click('#co'); ok((await st()).open === 0, 'collapse all');
  r.none = await search('zz-no-such'); ok(r.none.vis.length === 0 && await g.evaluate(() => !document.getElementById('none').hidden), 'no-match message');
  await g.click('#clear'); await search('16.9');
  if (process.argv[3]) await g.screenshot({path: process.argv[3]});
  ok(errs.length === 0, 'no JS errors: ' + errs.join('; ')); ok(net.length === 0, 'self-contained (no network): ' + net.join(' '));
  console.log(JSON.stringify({fails, r})); await b.close(); process.exit(fails.length ? 1 : 0);
})().catch(e => { console.log(JSON.stringify({fails: [String(e)]})); process.exit(1); });
