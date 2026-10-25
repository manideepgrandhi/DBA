#!/usr/bin/env bash
# Starts a THROWAWAY local MongoDB test bed for tests/run_tests.sh (never point this at a real server):
#   replica set rs0 on BASE+1..BASE+3 (member 3: priority 0, hidden, 120 s delayed, so delay-aware lag is exercised)
#   standalone with --auth on BASE+10: a throwaway root user "testadmin" and the monitoring user "mon"
#   (clusterMonitor + read on local, as documented in the README), plus sample data for dbStats / top collections.
# Usage: tests/setup_local.sh [start|stop]
#   env: MHR_TEST_DIR (default /tmp/mhr_testbed), MHR_TEST_BASE (default 28000),
#        MHR_TEST_PW (default 'Mon p@ss:/word' - deliberately full of URI-special characters)
set -euo pipefail
DIR="${MHR_TEST_DIR:-/tmp/mhr_testbed}"; BASE="${MHR_TEST_BASE:-28000}"; PW="${MHR_TEST_PW:-Mon p@ss:/word}"
P1=$((BASE + 1)); P2=$((BASE + 2)); P3=$((BASE + 3)); PS=$((BASE + 10))
up() { mongosh --quiet --port "$1" --eval 'db.adminCommand({ping:1}).ok' >/dev/null 2>&1; }
ADMIN=(-u testadmin -p testadmin-only --authenticationDatabase admin)

if [[ "${1:-start}" == stop ]]; then
    for p in "$P1" "$P2" "$P3"; do mongosh --quiet --port "$p" --eval 'db.adminCommand({shutdown:1,force:true})' >/dev/null 2>&1 || true; done
    mongosh --quiet --port "$PS" "${ADMIN[@]}" --eval 'db.adminCommand({shutdown:1})' >/dev/null 2>&1 || true
    echo "stopped (data left in $DIR)"; exit 0
fi

for c in mongod mongosh jq; do command -v "$c" >/dev/null || { echo "mongod, mongosh and jq must be on PATH" >&2; exit 2; }; done
mkdir -p "$DIR"/{rs1,rs2,rs3,sa,logs}
for n in 1 2 3; do
    p=$((BASE + n)); up "$p" && continue
    mongod --replSet rs0 --port "$p" --dbpath "$DIR/rs$n" --bind_ip 127.0.0.1 --fork --logpath "$DIR/logs/rs$n.log" \
           --wiredTigerCacheSizeGB 0.25 --oplogSize 50 >/dev/null
done
up "$PS" || mongod --port "$PS" --dbpath "$DIR/sa" --bind_ip 127.0.0.1 --fork --logpath "$DIR/logs/sa.log" --auth --wiredTigerCacheSizeGB 0.25 >/dev/null

mongosh --quiet --port "$P1" --eval "
  let st; try { st = rs.status(); } catch (e) { st = null; }
  if (!st) {
    rs.initiate({_id: 'rs0', members: [
      {_id: 0, host: '127.0.0.1:$P1', priority: 2},
      {_id: 1, host: '127.0.0.1:$P2'},
      {_id: 2, host: '127.0.0.1:$P3', priority: 0, hidden: true, secondaryDelaySecs: 120}]});
  }
  for (let i = 0; i < 60 && !db.hello().isWritablePrimary; i++) sleep(1000);
  const app = db.getSiblingDB('app');
  if (app.events.estimatedDocumentCount() === 0) {
    const w = {writeConcern: {w: 1}};
    for (let b = 0; b < 10; b++) app.events.insertMany(Array.from({length: 10000}, (_, i) => ({n: b * 10000 + i, pad: 'x'.repeat(300), t: new Date()})), w);
    app.events.createIndex({t: 1}); app.users.insertMany(Array.from({length: 2000}, (_, i) => ({u: i})), w);
    db.getSiblingDB('logs').l.insertMany(Array.from({length: 10000}, (_, i) => ({i, msg: 'log line ' + i})), w);
  }
  print('rs0 ready on $P1-$P3');"

# localhost exception: create a throwaway root user once, then the monitoring user through it
mongosh --quiet --port "$PS" --eval "db.getSiblingDB('admin').createUser({user: 'testadmin', pwd: 'testadmin-only', roles: ['root']})" >/dev/null 2>&1 || true
mongosh --quiet --port "$PS" "${ADMIN[@]}" --eval "
  const a = db.getSiblingDB('admin');
  if (!a.getUser('mon')) a.createUser({user: 'mon', pwd: $(printf '%s' "$PW" | jq -Rs .), roles: ['clusterMonitor', {role: 'read', db: 'local'}]});
  const s = db.getSiblingDB('sales');
  if (s.orders.estimatedDocumentCount() === 0) s.orders.insertMany(Array.from({length: 5000}, (_, i) => ({i, amt: i % 100})));
  print('standalone (auth) ready on $PS');"
