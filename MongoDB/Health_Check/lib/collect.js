// collect.js - READ-ONLY MongoDB health collector for mongo_health_report.sh (run by mongosh --nodb).
// Only diagnostic commands are used: hello, buildInfo, hostInfo, serverStatus, getCmdLineOpts, replSetGetStatus,
// replSetGetConfig, currentOp, listDatabases, dbStats, listCollections, $collStats, and find() on local.oplog.rs
// (first/last entry only). Nothing is written. Connection settings and the password come from environment
// variables set by the wrapper, so they never appear on a command line.
// Prints one line: @@MHR_JSON@@{...}
/* global Mongo, print, process */
(function () {
  'use strict';
  const E = process.env;
  const TIMEOUT_MS = (parseInt(E.MHR_TIMEOUT, 10) || 10) * 1000;
  const MAXTIME = (parseInt(E.MHR_MAXTIME, 10) || 30) * 1000;
  const LONG_OP = parseInt(E.MHR_LONG_OP, 10) || 60;
  const TOP_N = parseInt(E.MHR_TOP, 10) || 10;
  const MAX_COLLS = parseInt(E.MHR_MAX_COLLS, 10) || 500;
  const INC_SYS = E.MHR_INCLUDE_SYSTEM === '1';
  const MEMBERS = E.MHR_MEMBERS !== '0';
  const out = { ok: false, collected_at: Math.floor(Date.now() / 1000), errors: {} };

  const num = (x) => {
    if (x === null || x === undefined) return null;
    if (typeof x === 'number') return x;
    if (typeof x === 'bigint') return Number(x);
    if (x instanceof Date) return x.getTime() / 1000;
    if (typeof x.toNumber === 'function') return x.toNumber();
    if (typeof x.valueOf === 'function' && typeof x.valueOf() === 'number') return x.valueOf();
    const n = Number(x); return isNaN(n) ? null : n;
  };
  const secs = (d) => (d instanceof Date ? Math.floor(d.getTime() / 1000) : null);
  const tsSecs = (t) => (t ? (t.t !== undefined ? num(t.t) : (typeof t.getHighBits === 'function' ? t.getHighBits() : null)) : null);
  const pct = (a, b) => (a !== null && b ? Math.round((a / b) * 10000) / 100 : null);
  const msg = (e) => String((e && (e.codeName ? e.codeName + ': ' : '') + (e.message || e)) || 'error').slice(0, 400);
  const trunc = (s, n) => { s = String(s); return s.length > n ? s.slice(0, n) + '…' : s; };
  const safe = (section, fn) => { try { return fn(); } catch (e) { out.errors[section] = msg(e); return null; } };

  // ---- connection string (built here so credentials stay in memory) ----
  function splitUri(raw) {
    let scheme = 'mongodb://', rest = raw;
    const m = /^(mongodb(?:\+srv)?:\/\/)(.*)$/.exec(raw);
    if (m) { scheme = m[1]; rest = m[2]; }
    let query = '';
    const q = rest.indexOf('?');
    if (q >= 0) { query = rest.slice(q + 1); rest = rest.slice(0, q); }
    let creds = '';
    const at = rest.lastIndexOf('@');
    if (at >= 0) { creds = rest.slice(0, at); rest = rest.slice(at + 1); }
    let hosts = rest, path = '';
    const sl = rest.indexOf('/');
    if (sl >= 0) { hosts = rest.slice(0, sl); path = rest.slice(sl + 1); }
    const params = [];
    query.split('&').filter(Boolean).forEach((kv) => { const i = kv.indexOf('='); params.push([i < 0 ? kv : kv.slice(0, i), i < 0 ? '' : kv.slice(i + 1)]); });
    return { scheme, creds, hosts, path, params };
  }
  function setParam(p, k, v, override) {
    const i = p.params.findIndex((x) => x[0].toLowerCase() === k.toLowerCase());
    if (i >= 0) { if (override) p.params[i][1] = v; } else p.params.push([k, v]);
  }
  function delParam(p, k) { p.params = p.params.filter((x) => x[0].toLowerCase() !== k.toLowerCase()); }
  function build(p, hostsOverride, direct) {
    const q = JSON.parse(JSON.stringify(p));
    let scheme = q.scheme;
    if (hostsOverride) {
      if (scheme === 'mongodb+srv://') { scheme = 'mongodb://'; setParam(q, 'tls', 'true', false); }
      q.hosts = hostsOverride; delParam(q, 'replicaSet');
    }
    if (direct) setParam(q, 'directConnection', 'true', true);
    let creds = q.creds;
    if (!creds && E.MHR_USER) {
      creds = encodeURIComponent(E.MHR_USER) + (E.MHR_PASS ? ':' + encodeURIComponent(E.MHR_PASS) : '');
    }
    const qs = q.params.map((x) => x[0] + (x[1] !== '' ? '=' + x[1] : '')).join('&');
    return scheme + (creds ? creds + '@' : '') + q.hosts + '/' + q.path + (qs ? '?' + qs : '');
  }
  const P = splitUri(E.MHR_URI || '');
  const enc = encodeURIComponent;
  if (E.MHR_RS) setParam(P, 'replicaSet', enc(E.MHR_RS), false);
  if (E.MHR_USER) setParam(P, 'authSource', enc(E.MHR_AUTHDB || 'admin'), false);
  if (E.MHR_AUTHMECH) setParam(P, 'authMechanism', enc(E.MHR_AUTHMECH), false);
  if (E.MHR_TLS === 'on') setParam(P, 'tls', 'true', true);
  if (E.MHR_TLS === 'off') setParam(P, 'tls', 'false', true);
  if (E.MHR_TLSCA) setParam(P, 'tlsCAFile', enc(E.MHR_TLSCA), true);
  if (E.MHR_TLSCERT) setParam(P, 'tlsCertificateKeyFile', enc(E.MHR_TLSCERT), true);
  if (E.MHR_TLS_INSECURE === '1') setParam(P, 'tlsAllowInvalidCertificates', 'true', true);
  setParam(P, 'readPreference', 'primaryPreferred', false);   // still works when there is no primary
  setParam(P, 'serverSelectionTimeoutMS', String(TIMEOUT_MS), false);
  setParam(P, 'connectTimeoutMS', String(TIMEOUT_MS), false);
  setParam(P, 'socketTimeoutMS', String(MAXTIME + TIMEOUT_MS), false);
  setParam(P, 'appName', 'mongo_health_report', false);
  out.uri_has_credentials = !!P.creds;

  let conn, admin;
  try {
    conn = new Mongo(build(P));
    admin = conn.getDB('admin');
    admin.runCommand({ ping: 1 });
  } catch (e) {
    // Replica-set discovery can fail when no primary/visible secondary is up (e.g. only a hidden
    // member is alive). Fall back to each seed host on its own so the survivor still gets reported.
    const seeds = P.scheme === 'mongodb://' ? P.hosts.split(',').filter(Boolean) : [];
    const rsMode = seeds.length > 1 || P.params.some((x) => x[0].toLowerCase() === 'replicaset');
    let ok = false;
    if (rsMode) {
      for (const h of seeds) {
        try {
          conn = new Mongo(build(P, h, true));
          admin = conn.getDB('admin');
          admin.runCommand({ ping: 1 });
          out.connect_fallback = { host: h, reason: msg(e) };
          ok = true; break;
        } catch (e2) { /* try next seed */ }
      }
    }
    if (!ok) {
      out.error = 'connect: ' + msg(e);
      print('@@MHR_JSON@@' + JSON.stringify(out));
      return;
    }
  }
  const cmd = (dbname, c) => {
    const r = conn.getDB(dbname).runCommand(c);
    if (r && r.ok !== 1 && r.ok !== true) { const e = new Error(r.errmsg || 'command failed'); e.codeName = r.codeName; throw e; }
    return r;
  };
  out.ok = true;

  // ---- server ----
  const hello = safe('hello', () => cmd('admin', { hello: 1 })) || {};
  const bi = safe('buildInfo', () => cmd('admin', { buildInfo: 1 })) || {};
  const hi = safe('hostInfo', () => cmd('admin', { hostInfo: 1 })) || {};
  const ss = safe('serverStatus', () => cmd('admin', { serverStatus: 1, maxTimeMS: MAXTIME })) || {};
  const co = safe('getCmdLineOpts', () => cmd('admin', { getCmdLineOpts: 1 })) || {};
  const parsed = co.parsed || {};
  out.server = {
    host: ss.host || hello.me || null,
    me: hello.me || null,
    version: bi.version || ss.version || null,
    git: bi.gitVersion || null,
    modules: bi.modules || [],
    process: ss.process || null,
    pid: num(ss.pid),
    uptime_s: num(ss.uptime),
    local_time: secs(ss.localTime),
    storage_engine: (ss.storageEngine && ss.storageEngine.name) || null,
    is_writable_primary: !!(hello.isWritablePrimary || hello.ismaster),
    secondary: !!hello.secondary,
    arbiter: !!hello.arbiterOnly,
    set_name: hello.setName || null,
    msg: hello.msg || null,   // 'isdbgrid' = mongos
    os: hi.os ? [String(hi.os.name || '').replace(/^PRETTY_NAME=/, '').replace(/"/g, ''), hi.os.version].filter(Boolean).join(' · ') : null,
    cpus: hi.system ? num(hi.system.numCores) : null,
    mem_mb: hi.system ? num(hi.system.memSizeMB) : null,
    hostname: hi.system ? hi.system.hostname : null,
    fcv: null
  };
  safe('fcv', () => { const r = cmd('admin', { getParameter: 1, featureCompatibilityVersion: 1 }); out.server.fcv = r.featureCompatibilityVersion ? r.featureCompatibilityVersion.version : null; });
  out.cmdline = {
    dbpath: (parsed.storage && parsed.storage.dbPath) || null,
    logpath: (parsed.systemLog && parsed.systemLog.path) || null,
    config: parsed.config || null,
    port: parsed.net ? num(parsed.net.port) : null,
    bind_ip: parsed.net ? (parsed.net.bindIp || (parsed.net.bindIpAll ? '0.0.0.0 (bindIpAll)' : null)) : null,
    auth: !!((parsed.security && (parsed.security.authorization === 'enabled' || parsed.security.keyFile)) || (co.argv || []).includes('--auth')),
    repl_set: parsed.replication ? (parsed.replication.replSetName || parsed.replication.replSet || null) : null,
    oplog_min_retention_h: (parsed.storage && parsed.storage.oplogMinRetentionHours) || null
  };
  if (ss.connections) {
    const c = ss.connections;
    out.conns = { current: num(c.current), available: num(c.available), total_created: num(c.totalCreated), active: num(c.active),
      pct: pct(num(c.current), num(c.current) + num(c.available)) };
  }
  if (ss.mem) out.mem = { resident_mb: num(ss.mem.resident), virtual_mb: num(ss.mem.virtual) };
  if (ss.wiredTiger && ss.wiredTiger.cache) {
    const c = ss.wiredTiger.cache;
    const used = num(c['bytes currently in the cache']), max = num(c['maximum bytes configured']), dirty = num(c['tracked dirty bytes in the cache']);
    out.cache = { used_bytes: used, max_bytes: max, dirty_bytes: dirty, used_pct: pct(used, max), dirty_pct: pct(dirty, max),
      read_into: num(c['pages read into cache']), evicted_app: num(c['pages evicted by application threads']) };
  }
  const oc = (o) => (o ? { insert: num(o.insert), query: num(o.query), update: num(o.update), delete: num(o.delete), getmore: num(o.getmore), command: num(o.command) } : null);
  out.opcounters = oc(ss.opcounters);
  out.opcounters_repl = oc(ss.opcountersRepl);
  if (ss.globalLock) {
    const q = ss.globalLock.currentQueue || {}, a = ss.globalLock.activeClients || {};
    out.queues = { readers: num(q.readers), writers: num(q.writers), total: num(q.total), active_readers: num(a.readers), active_writers: num(a.writers) };
    const ex = (ss.queues && ss.queues.execution) || (ss.wiredTiger && ss.wiredTiger.concurrentTransactions);
    if (ex && ex.read && ex.write) Object.assign(out.queues, { tickets_read_out: num(ex.read.out), tickets_read_avail: num(ex.read.available), tickets_write_out: num(ex.write.out), tickets_write_avail: num(ex.write.available) });
  }
  if (ss.asserts) out.asserts = { regular: num(ss.asserts.regular), warning: num(ss.asserts.warning), msg: num(ss.asserts.msg), user: num(ss.asserts.user), rollovers: num(ss.asserts.rollovers) };
  out.page_faults = ss.extra_info ? num(ss.extra_info.page_faults) : null;
  if (ss.network) out.network = { bytes_in: num(ss.network.bytesIn), bytes_out: num(ss.network.bytesOut), requests: num(ss.network.numRequests) };

  // ---- replica set ----
  const isRs = !!(hello.setName || out.cmdline.repl_set);
  if (out.server.msg === 'isdbgrid') out.errors.topology = 'This is a mongos router: point the script at the config server and shard replica sets instead.';
  if (isRs) {
    const st = safe('replSetGetStatus', () => cmd('admin', { replSetGetStatus: 1 }));
    const cf = safe('replSetGetConfig', () => cmd('admin', { replSetGetConfig: 1 }));
    const cfm = {};
    if (cf && cf.config) cf.config.members.forEach((m) => { cfm[m.host] = m; });
    if (st) {
      const prim = st.members.find((m) => m.state === 1);
      const optimes = st.members.filter((m) => m.optimeDate instanceof Date && m.state !== 7).map((m) => m.optimeDate.getTime());
      const ref = prim && prim.optimeDate ? prim.optimeDate.getTime() : (optimes.length ? Math.max.apply(null, optimes) : null);
      out.repl = {
        set: st.set, term: num(st.term), my_state: st.myState, heartbeat_ms: num(st.heartbeatIntervalMillis),
        primary: prim ? prim.name : null, lag_reference: prim ? 'primary' : 'newest member optime (no primary)',
        config_version: cf && cf.config ? num(cf.config.version) : null,
        election_timeout_ms: cf && cf.config && cf.config.settings ? num(cf.config.settings.electionTimeoutMillis) : null,
        write_concern_majority_journal: cf && cf.config ? cf.config.writeConcernMajorityJournalDefault : null,
        majority_vote_count: num(st.majorityVoteCount), voting_members: num(st.votingMembersCount), writable_voting: num(st.writableVotingMembersCount),
        members: st.members.map((m) => {
          const c = cfm[m.name] || {};
          const od = m.optimeDate instanceof Date && m.optimeDate.getTime() > 0 && num(m.health) === 1 ? m.optimeDate.getTime() : null;
          return {
            id: m._id, name: m.name, state: m.state, state_str: m.stateStr, health: num(m.health), uptime_s: num(m.uptime),
            optime: od !== null ? Math.floor(od / 1000) : null,
            lag_s: od !== null && ref !== null && m.state !== 7 ? Math.max(0, Math.round((ref - od) / 1000)) : null,
            last_heartbeat: secs(m.lastHeartbeat), last_heartbeat_recv: secs(m.lastHeartbeatRecv), ping_ms: num(m.pingMs),
            sync_source: m.syncSourceHost || null, self: !!m.self, info: m.lastHeartbeatMessage || m.infoMessage || null,
            priority: num(c.priority), votes: num(c.votes), hidden: !!c.hidden, arbiter: !!c.arbiterOnly || m.state === 7,
            delay_s: num(c.secondaryDelaySecs !== undefined ? c.secondaryDelaySecs : c.slaveDelay) || 0,
            build_indexes: c.buildIndexes !== false, tags: c.tags || {}
          };
        })
      };
    }
    // oplog window: first and last entry (needs read on 'local')
    out.oplog = safe('oplog', () => {
      const l = conn.getDB('local');
      const o = {};
      try {
        const cs = l.getCollection('oplog.rs').aggregate([{ $collStats: { storageStats: { scale: 1 } } }]).toArray()[0].storageStats;
        o.size_bytes = num(cs.size); o.max_bytes = num(cs.maxSize); o.storage_bytes = num(cs.storageSize); o.used_pct = pct(o.size_bytes, o.max_bytes);
      } catch (e) { o.stats_error = msg(e); }
      const first = l.getCollection('oplog.rs').find({}, { ts: 1, wall: 1 }).sort({ $natural: 1 }).limit(1).maxTimeMS(MAXTIME).toArray()[0];
      const last = l.getCollection('oplog.rs').find({}, { ts: 1, wall: 1 }).sort({ $natural: -1 }).limit(1).maxTimeMS(MAXTIME).toArray()[0];
      o.first = first ? tsSecs(first.ts) : null; o.last = last ? tsSecs(last.ts) : null;
      o.window_h = o.first !== null && o.last !== null ? Math.round(((o.last - o.first) / 3600) * 100) / 100 : null;
      return o;
    });
  }

  // ---- long-running operations ----
  out.long_ops = safe('currentOp', () => {
    const r = cmd('admin', { currentOp: 1, active: true, secs_running: { $gte: LONG_OP } });
    return (r.inprog || [])
      .filter((o) => !(o.ns === 'local.oplog.rs' && o.op === 'getmore'))   // secondaries tailing the oplog
      .filter((o) => !(o.command && (o.command.hello || o.command.isMaster || o.command.ismaster) && o.command.maxAwaitTimeMS))
      .map((o) => ({ opid: String(o.opid), secs: num(o.secs_running), op: o.op || null, ns: o.ns || null, desc: o.desc || null,
        client: o.client || o.client_s || null, app: o.appName || null,
        user: (o.effectiveUsers || []).map((u) => u.user + '@' + u.db).join(',') || null,
        plan: o.planSummary || null, waiting_lock: !!o.waitingForLock,
        command: o.command ? trunc(JSON.stringify(EJSON.serialize(Object.fromEntries(Object.entries(o.command).filter((kv) => !['lsid', '$clusterTime', '$db', '$readPreference', 'signature'].includes(kv[0]))), { relaxed: true })), 300) : null }))
      .sort((a, b) => b.secs - a.secs);
  }) || [];

  // ---- databases, filesystem, top collections ----
  const dbl = safe('listDatabases', () => cmd('admin', { listDatabases: 1, nameOnly: true }).databases.map((d) => d.name)) || [];
  out.dbs = []; const colls = []; let collCount = 0;
  dbl.forEach((name) => {
    const s = safe('dbStats:' + name, () => cmd(name, { dbStats: 1, scale: 1, maxTimeMS: MAXTIME }));
    if (!s) return;
    out.dbs.push({ name, collections: num(s.collections), views: num(s.views), objects: num(s.objects), data_bytes: num(s.dataSize),
      storage_bytes: num(s.storageSize), index_bytes: num(s.indexSize), indexes: num(s.indexes), fs_used: num(s.fsUsedSize), fs_total: num(s.fsTotalSize) });
    if (!out.fs && s.fsTotalSize) out.fs = { used_bytes: num(s.fsUsedSize), total_bytes: num(s.fsTotalSize), pct: pct(num(s.fsUsedSize), num(s.fsTotalSize)) };
    if (!INC_SYS && (name === 'admin' || name === 'local' || name === 'config')) return;
    safe('collections:' + name, () => {
      const lc = cmd(name, { listCollections: 1, nameOnly: true, authorizedCollections: true }).cursor.firstBatch;
      lc.filter((c) => (c.type || 'collection') === 'collection' && !c.name.startsWith('system.')).forEach((c) => {
        if (collCount >= MAX_COLLS) { out.colls_truncated = true; return; }
        collCount++;
        try {
          const st = conn.getDB(name).getCollection(c.name).aggregate([{ $collStats: { storageStats: { scale: 1 } } }], { maxTimeMS: MAXTIME }).toArray()[0].storageStats;
          colls.push({ ns: name + '.' + c.name, count: num(st.count), data_bytes: num(st.size), storage_bytes: num(st.storageSize),
            index_bytes: num(st.totalIndexSize), indexes: num(st.nindexes), avg_obj: num(st.avgObjSize), capped: !!st.capped });
        } catch (e) { out.errors['collStats:' + name + '.' + c.name] = msg(e); }
      });
    });
  });
  out.top_colls = colls.sort((a, b) => (b.storage_bytes + b.index_bytes) - (a.storage_bytes + a.index_bytes)).slice(0, TOP_N);
  out.colls_scanned = collCount;

  // ---- every replica set member, direct connection (load, cache, disk on each host) ----
  if (MEMBERS && out.repl) {
    out.members_direct = out.repl.members.map((m) => {
      const r = { name: m.name };
      if (m.arbiter) { r.skipped = 'arbiter (holds no data)'; return r; }
      if (m.health !== 1) { r.skipped = 'member not healthy'; return r; }
      let c;
      try {
        c = new Mongo(build(P, m.name, true));
        const a = c.getDB('admin');
        const s = a.runCommand({ serverStatus: 1, maxTimeMS: MAXTIME });
        const st = a.runCommand({ dbStats: 1, scale: 1 });
        const opts = a.runCommand({ getCmdLineOpts: 1 });
        const cache = (s.wiredTiger && s.wiredTiger.cache) || {};
        const cu = num(cache['bytes currently in the cache']), cm = num(cache['maximum bytes configured']), cd = num(cache['tracked dirty bytes in the cache']);
        const q = (s.globalLock && s.globalLock.currentQueue) || {};
        Object.assign(r, { ok: true, host: s.host, version: s.version, uptime_s: num(s.uptime),
          conn_current: s.connections ? num(s.connections.current) : null,
          conn_pct: s.connections ? pct(num(s.connections.current), num(s.connections.current) + num(s.connections.available)) : null,
          resident_mb: s.mem ? num(s.mem.resident) : null, cache_used_pct: pct(cu, cm), cache_dirty_pct: pct(cd, cm),
          queue_r: num(q.readers), queue_w: num(q.writers), page_faults: s.extra_info ? num(s.extra_info.page_faults) : null,
          fs_used: num(st.fsUsedSize), fs_total: num(st.fsTotalSize), fs_pct: pct(num(st.fsUsedSize), num(st.fsTotalSize)),
          dbpath: opts.parsed && opts.parsed.storage ? opts.parsed.storage.dbPath || null : null,
          logpath: opts.parsed && opts.parsed.systemLog ? opts.parsed.systemLog.path || null : null });
      } catch (e) { r.ok = false; r.error = msg(e); }
      try { if (c) c.close(); } catch (e) { /* ignore */ }
      return r;
    });
  }
  try { conn.close(); } catch (e) { /* ignore */ }
  print('@@MHR_JSON@@' + JSON.stringify(out));
})();
