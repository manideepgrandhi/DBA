// Headless browser check of the patch compliance HTML (run_tests.sh runs it when puppeteer-core + Chrome are available).
// Usage: node browser_check.js <report.html> [screenshot-dir]  -> prints JSON {checks, fails, r}; exit 1 on any failure.
// Covers (v1.3.0): account / region / engine / status dropdowns + DB-name search; cards, Per account and Per region
// (rows + All-regions footer) recomputed from the filtered rows; empty regions never shown; engine sections hidden when
// empty; Reset; Export CSV (BOM, CRLF, RFC 4180 quoting, formula-injection guard, filtered rows only, account in every
// row; also one real Chrome download); no region names above the first table; no JS errors, no network requests.
const p = require('puppeteer-core');
const path = require('path'), fs = require('fs'), os = require('os');
const fails = [], r = {}; let nchk = 0; const ok = (c, m) => { nchk++; if (!c) fails.push(m); };
const sleep = ms => new Promise(x => setTimeout(x, ms));
function parseCsv(t) {
  const rows = []; let row = [], f = '', q = false;
  for (let i = 0; i < t.length; i++) { const c = t[i];
    if (q) { if (c === '"') { if (t[i + 1] === '"') { f += '"'; i++; } else q = false; } else f += c; }
    else if (c === '"' && f === '') q = true; else if (c === ',') { row.push(f); f = ''; }
    else if (c === '\r' && t[i + 1] === '\n') { row.push(f); rows.push(row); row = []; f = ''; i++; } else f += c; }
  if (f !== '' || row.length) { row.push(f); rows.push(row); } return rows; }
(async () => {
  const file = path.resolve(process.argv[2]), shots = process.argv[3];
  if (shots) fs.mkdirSync(shots, {recursive: true});
  const b = await p.launch({executablePath: process.env.CHROME || '/usr/bin/google-chrome', args: ['--no-sandbox']});
  const g = await b.newPage(); const errs = [], net = [];
  g.on('pageerror', e => errs.push(e.message)); g.on('console', m => m.type() === 'error' && errs.push(m.text()));
  await g.setRequestInterception(true);
  g.on('request', q => { if (!/^(file|blob|data):/.test(q.url())) net.push(q.url()); q.continue(); });
  await g.setViewport({width: 1400, height: 1000});
  await g.goto('file://' + file, {waitUntil: 'load'});
  const st = () => g.evaluate(() => {
    const vis = n => n && n.offsetParent !== null;
    const card = k => { const c = document.querySelector('.card[data-k="' + k + '"] .v'); return c ? c.textContent : null; };
    const rows = [...document.querySelectorAll('#regions tbody tr')].filter(vis).map(t => [t.dataset.k, +t.cells[3].dataset.s, +t.cells[5].dataset.s]);
    const acc = [...document.querySelectorAll('#accounts tbody tr')].filter(vis).map(t => [t.dataset.a, +t.cells[3].dataset.s]);
    const ft = document.querySelector('#regions tfoot tr');
    return {servers: card('servers-clusters'), compliant: card('compliant'), nc: card('non-compliant'), regions: card('regions'),
      main: [...document.querySelectorAll('table.main tbody tr[data-i]')].filter(vis).length,
      sections: [...document.querySelectorAll('table.main')].filter(t => vis(t)).length,
      regionRows: rows, accRows: acc, foot: ft ? [+ft.cells[3].dataset.s, +ft.cells[4].dataset.s, +ft.cells[5].dataset.s] : null,
      count: document.getElementById('f-count').textContent,
      opts: Object.fromEntries(['f-acct', 'f-region', 'f-engine', 'f-status'].map(i => [i, [...document.getElementById(i).options].map(o => o.value + '|' + o.textContent)]))}; });
  const sel = async (id, v) => { await g.select('#' + id, v); await sleep(50); };
  const D = await g.evaluate(() => JSON.parse(document.getElementById('pc-data').textContent));
  const N = D.rows.length, accts = D.accounts.map(a => a.account);
  const top = await g.evaluate(() => { const t = document.querySelector('table'); let out = '';
    document.querySelectorAll('header, .cards, .flt-note, #f-count').forEach(n => { if (n.compareDocumentPosition(t) & Node.DOCUMENT_POSITION_FOLLOWING) out += n.innerText + ' '; }); return out; });
  ok(!/[a-z]{2}-[a-z]+-[0-9]/.test(top), 'region name in the header / cards (above the first table): ' + top.slice(0, 200));
  let s = await st(); r.initial = s;
  ok(+s.servers === N, 'initial servers card = rows');
  ok(s.main === N, 'all rows visible initially');
  ok(s.opts['f-acct'].length === accts.length + 1, 'account dropdown has every account');
  ok(s.opts['f-acct'].slice(1).every(o => /^\d{12}\|\d{12} \(.+\)$/.test(o)), 'account option = number (profile)');
  const regs = [...new Set(D.rows.map(x => x.region))];
  ok(s.opts['f-region'].length === regs.length + 1, 'region dropdown = regions with databases only');
  ok(s.regionRows.every(x => x[1] > 0 || true), 'region rows');
  ok(s.foot && s.foot[0] === N, 'footer total = all rows');
  if (shots) await g.screenshot({path: path.join(shots, '01_merged_all.png'), fullPage: false});
  // account filter
  for (const a of accts) {
    await sel('f-acct', a); s = await st();
    const want = D.rows.filter(x => x.account_id === a);
    ok(+s.servers === want.length, `acct ${a}: servers card ${s.servers} != ${want.length}`);
    ok(s.main === want.length, `acct ${a}: visible rows`);
    ok(+s.nc === want.filter(x => x.compliance_status === 'NON-COMPLIANT').length, `acct ${a}: NC card`);
    ok(s.regionRows.every(x => x[0].startsWith(a + '|')) && s.regionRows.every(x => x[1] > 0), `acct ${a}: only its non-empty region rows`);
    ok(s.foot[0] === want.length, `acct ${a}: footer total`);
    ok(s.accRows.length === 1 && s.accRows[0][0] === a, `acct ${a}: per-account table one row`);
    ok(s.count.startsWith('showing ' + want.length + ' of ' + N), `acct ${a}: count strip`);
  }
  r.acct2 = s;
  if (shots) { await sel('f-acct', accts[1] || accts[0]); await g.screenshot({path: path.join(shots, '02_filter_account.png')}); }
  // region + status combos
  await sel('f-acct', '');
  for (const rg of regs) { await sel('f-region', rg); s = await st();
    const want = D.rows.filter(x => x.region === rg);
    ok(s.foot[0] === want.length && s.regionRows.reduce((a, x) => a + x[1], 0) === want.length, `region ${rg}: per-region totals`);
    ok(s.regionRows.every(x => x[0].endsWith('|' + rg)), `region ${rg}: only that region`); }
  await sel('f-region', '');
  await sel('f-status', 'NON-COMPLIANT'); s = await st();
  const ncs = D.rows.filter(x => x.compliance_status === 'NON-COMPLIANT');
  ok(+s.servers === ncs.length && +s.nc === ncs.length && +s.compliant === 0, 'status NC: cards');
  ok(s.foot[2] === ncs.length && s.foot[1] === 0, 'status NC: footer');
  if (shots) await g.screenshot({path: path.join(shots, '03_filter_status_nc.png')});
  const eng = D.rows[0].engine;
  await sel('f-engine', eng); s = await st();
  const en = ncs.filter(x => x.engine === eng);
  ok(s.main === en.length, 'engine+status combo rows');
  ok(s.sections === (en.length ? 1 : 0), 'only the matching engine section is shown');
  await sel('f-status', ''); await sel('f-engine', '');
  // name search
  const nm = D.rows[D.rows.length - 1].identifier;
  await g.type('#q', nm.toUpperCase()); await sleep(80); s = await st();
  const qn = D.rows.filter(x => (x.identifier + ' ' + x.members).toLowerCase().includes(nm.toLowerCase()));
  ok(s.main === qn.length && qn.length >= 1, 'name search (case-insensitive)');
  ok(+s.servers === qn.length, 'name search: cards');
  if (shots) await g.screenshot({path: path.join(shots, '04_search_name.png')});
  // CSV export (filtered)
  await g.evaluate(() => { document.getElementById('q').value = ''; document.getElementById('q').dispatchEvent(new Event('input')); });
  const a1 = accts[accts.length - 1];
  await sel('f-acct', a1);
  const csv = await g.evaluate(() => window.__pcCsv());
  ok(csv.charCodeAt(0) === 0xfeff, 'CSV has BOM');
  ok(/\r\n$/.test(csv) && !/[^\r]\n/.test(csv), 'CSV uses CRLF');
  const rows = parseCsv(csv.slice(1)); r.csvRows = rows.length;
  const hdr = rows[0], want = D.rows.filter(x => x.account_id === a1);
  ok(rows.length === want.length + 1, 'CSV has only the filtered rows');
  ok(hdr[0] === 'account_id' && rows.slice(1).every(x => x[0] === a1), 'CSV: account number in every row');
  ok(rows.every(x => x.length === hdr.length), 'CSV: same column count in every row');
  const flat = rows.flat();
  ok(!flat.some(c => /^[=+@]/.test(c) || (/^-/.test(c) && !/^-?[0-9]+(\.[0-9]+)?$/.test(c))), 'CSV formula-injection guard');
  r.guarded = flat.filter(c => /^'[=+\-@]/.test(c));
  // real download
  const dl = fs.mkdtempSync(path.join(os.tmpdir(), 'pcdl'));
  const cdp = await g.target().createCDPSession();
  await cdp.send('Page.setDownloadBehavior', {behavior: 'allow', downloadPath: dl});
  await g.click('#f-csv'); let got = [];
  for (let i = 0; i < 50 && !(got = fs.readdirSync(dl).filter(f => f.endsWith('.csv'))).length; i++) await sleep(100);
  ok(got.length === 1 && got[0] === 'rds_patch_compliance_' + a1 + '_' + D.csv_stamp + '_filtered.csv', 'real CSV download with account in the name: ' + got);
  if (got.length) ok(fs.readFileSync(path.join(dl, got[0]), 'utf8') === csv, 'downloaded bytes = export');
  r.download = got[0];
  // reset
  await g.click('#f-reset'); await sleep(50); s = await st();
  ok(+s.servers === N && s.main === N && s.foot[0] === N, 'reset restores all');
  if (shots) { await g.evaluate(() => document.getElementById('accounts').scrollIntoView()); await g.screenshot({path: path.join(shots, '05_per_account_region.png')});
    const src = await g.$('#sources'); if (src) { await src.scrollIntoView(); await g.screenshot({path: path.join(shots, '06_merged_inputs.png')}); } }
  ok(errs.length === 0, 'JS errors: ' + errs.join(' | '));
  ok(net.length === 0, 'network requests: ' + net.join(' '));
  await b.close();
  console.log(JSON.stringify({checks: nchk, fails, r: {download: r.download, csvRows: r.csvRows, guarded: r.guarded}}));
  process.exit(fails.length ? 1 : 0);
})().catch(e => { console.log(JSON.stringify({checks: nchk, fails: ['crash: ' + e.message]})); process.exit(1); });
