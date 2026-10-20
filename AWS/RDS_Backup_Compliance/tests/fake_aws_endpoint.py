#!/usr/bin/env python3
"""Local fake AWS endpoint for validate_cli.sh: the REAL AWS CLI v2 is pointed at it with --endpoint-url.
Speaks the STS / RDS query protocol (XML, Marker paging) and the AWS Backup REST-JSON protocol (NextToken paging),
with deliberately small pages so the CLI's automatic pagination is exercised. Never forwards anything.
Usage: fake_aws_endpoint.py <portfile> <requestlog.jsonl> <expected.json>
Fleet: N instances (every 10th without AWS Backup, every 7th with 3-day retention) + 1 Aurora cluster (2 members).
"""
import http.server, json, sys, urllib.parse
from datetime import datetime, timedelta, timezone

portfile, logfile, expfile = sys.argv[1:4]
NOW = datetime.now(timezone.utc)
ACCT, REGION, N = "123456789012", "us-east-1", 120
PAGE = 20


def iso(d):
    return d.strftime("%Y-%m-%dT%H:%M:%S.000Z")


def arn(k, i):
    return "arn:aws:rds:%s:%s:%s:%s" % (REGION, ACCT, k, i)


def x(tag, v):
    return "<%s>%s</%s>" % (tag, v, tag)


INST, CLUS, SNAP, CSNAP, RP = [], [], [], [], []
expected = {"total": N + 1, "compliant": 0, "manual": 0}


def daily(ident, kind, n=9):
    for a in range(n):
        w = (NOW - timedelta(days=a)).replace(hour=20, minute=37, second=0, microsecond=0)
        if w > NOW:
            continue
        sid = "rds:%s-%s" % (ident, w.strftime("%Y-%m-%d-%H-%M"))
        common = x("SnapshotCreateTime", iso(w)) + x("Engine", "postgres" if kind == "i" else "aurora-postgresql") + x("AllocatedStorage", 50) + x("Status", "available") + x("SnapshotType", "automated")
        if kind == "i":
            SNAP.append(("automated", "<DBSnapshot>" + x("DBSnapshotIdentifier", sid) + x("DBInstanceIdentifier", ident) + common + "</DBSnapshot>"))
        else:
            CSNAP.append(("automated", "<DBClusterSnapshot>" + x("DBClusterSnapshotIdentifier", sid) + x("DBClusterIdentifier", ident) + common + "</DBClusterSnapshot>"))


def points(res, rtype):
    for a in (1, 8, 15, 22, 29):
        c = NOW - timedelta(days=a, hours=2)
        RP.append({"vault": "weekly", "p": {"RecoveryPointArn": "rp-%s-w%d" % (res, a), "BackupVaultName": "weekly", "ResourceArn": res, "ResourceType": rtype,
                   "Status": "COMPLETED", "CreationDate": c.timestamp(), "Lifecycle": {"DeleteAfterDays": 30},
                   "CalculatedLifecycle": {"DeleteAt": (c + timedelta(days=30)).timestamp()}, "CreatedBy": {"BackupRuleName": "Weekly"}}})
    for k in range(12):
        y, m = NOW.year, NOW.month - k
        while m <= 0:
            m += 12; y -= 1
        c = datetime(y, m, 1, 1, 0, tzinfo=timezone.utc)
        if c > NOW:
            continue
        RP.append({"vault": "monthly", "p": {"RecoveryPointArn": "rp-%s-m%d" % (res, k), "BackupVaultName": "monthly", "ResourceArn": res, "ResourceType": rtype,
                   "Status": "COMPLETED", "CreationDate": c.timestamp(),
                   "CalculatedLifecycle": {"DeleteAt": (c + timedelta(days=365)).timestamp()}, "CreatedBy": {"BackupRuleName": "Monthly"}}})


for k in range(N):
    i = "fake-pg-%03d" % k
    ret = 3 if k % 7 == 0 else 7
    INST.append("<DBInstance>" + x("DBInstanceIdentifier", i) + x("Engine", "postgres") + x("EngineVersion", "16.8") + x("DBInstanceStatus", "available")
                + x("BackupRetentionPeriod", ret) + x("PreferredBackupWindow", "20:30-21:00") + x("DBInstanceArn", arn("db", i)) + "</DBInstance>")
    daily(i, "i")
    if k % 10:
        points(arn("db", i), "RDS")
    if k % 10 and k % 7:
        expected["compliant"] += 1
for m in ("fake-aurora-1", "fake-aurora-2"):
    INST.append("<DBInstance>" + x("DBInstanceIdentifier", m) + x("DBClusterIdentifier", "fake-aurora") + x("Engine", "aurora-postgresql") + x("EngineVersion", "16.9")
                + x("BackupRetentionPeriod", 7) + x("DBInstanceArn", arn("db", m)) + "</DBInstance>")
CLUS.append("<DBCluster>" + x("DBClusterIdentifier", "fake-aurora") + x("Engine", "aurora-postgresql") + x("EngineVersion", "16.9") + x("Status", "available")
            + x("BackupRetentionPeriod", 7) + x("PreferredBackupWindow", "20:30-21:00") + x("DBClusterArn", arn("cluster", "fake-aurora"))
            + "<DBClusterMembers>" + "".join("<DBClusterMember>%s%s</DBClusterMember>" % (x("DBInstanceIdentifier", m), x("IsClusterWriter", "true")) for m in ("fake-aurora-1", "fake-aurora-2")) + "</DBClusterMembers></DBCluster>")
daily("fake-aurora", "c"); points(arn("cluster", "fake-aurora"), "Aurora"); expected["compliant"] += 1
for k in range(45):   # 45 old manual snapshots (paged), one orphan
    src = "gone-db" if k == 0 else "fake-pg-%03d" % k
    SNAP.append(("manual", "<DBSnapshot>" + x("DBSnapshotIdentifier", "manual-%03d" % k) + x("DBInstanceIdentifier", src) + x("SnapshotCreateTime", iso(NOW - timedelta(days=100 + k)))
                 + x("Engine", "postgres") + x("AllocatedStorage", 10) + x("Status", "available") + x("SnapshotType", "manual") + "</DBSnapshot>"))
expected["manual"] = 45
json.dump(expected, open(expfile, "w"))


def page(items, marker, size):
    s = int(marker or 0)
    nxt = s + size if s + size < len(items) else None
    return items[s:s + size], nxt


def wrap(action, tag, items, nxt):
    return ('<%sResponse xmlns="http://rds.amazonaws.com/doc/2014-10-31/"><%sResult><%s>%s</%s>%s</%sResult></%sResponse>'
            % (action, action, tag, "".join(items), tag, "<Marker>%s</Marker>" % nxt if nxt else "", action, action))


class H(http.server.BaseHTTPRequestHandler):
    def log(self, d):
        with open(logfile, "a") as fh:
            fh.write(json.dumps(d) + "\n")

    def send(self, code, body, ctype):
        data = body.encode()
        self.send_response(code); self.send_header("Content-Type", ctype); self.send_header("Content-Length", str(len(data)))
        self.end_headers(); self.wfile.write(data)

    def do_GET(self):   # AWS Backup REST-JSON
        u = urllib.parse.urlparse(self.path); q = urllib.parse.parse_qs(u.query)
        tok = q.get("nextToken", [None])[0]; parts = [urllib.parse.unquote(p) for p in u.path.strip("/").split("/")]
        if parts == ["backup-vaults"]:
            self.log({"action": "ListBackupVaults", "marker": tok})
            vs = [{"BackupVaultName": v, "BackupVaultArn": "arn:aws:backup:%s:%s:backup-vault:%s" % (REGION, ACCT, v)} for v in ("Default", "weekly", "monthly")]
            items, nxt = page(vs, tok, 2)
            return self.send(200, json.dumps({"BackupVaultList": items, **({"NextToken": str(nxt)} if nxt else {})}), "application/json")
        if len(parts) == 3 and parts[0] == "backup-vaults" and parts[2] == "recovery-points":
            after = q.get("createdAfter", [None])[0]
            self.log({"action": "ListRecoveryPointsByBackupVault", "marker": tok, "vault": parts[1], "createdAfter": after})
            lim = datetime.fromisoformat(after.replace("Z", "+00:00")).timestamp() if after else 0
            ps = [r["p"] for r in RP if r["vault"] == parts[1] and r["p"]["CreationDate"] >= lim]
            items, nxt = page(ps, tok, 100)
            return self.send(200, json.dumps({"RecoveryPoints": items, **({"NextToken": str(nxt)} if nxt else {})}), "application/json")
        self.send(404, json.dumps({"message": "not found"}), "application/json")

    def do_POST(self):  # STS / RDS query protocol
        q = urllib.parse.parse_qs(self.rfile.read(int(self.headers.get("Content-Length", 0))).decode())
        action, marker = q.get("Action", [""])[0], q.get("Marker", [None])[0]
        st = q.get("SnapshotType", [None])[0]
        self.log({"action": action, "marker": marker, "snapshot_type": st})
        if action == "GetCallerIdentity":
            body = ('<GetCallerIdentityResponse xmlns="https://sts.amazonaws.com/doc/2011-06-15/"><GetCallerIdentityResult>'
                    '<Arn>arn:aws:sts::%s:assumed-role/ReadOnly/test</Arn><UserId>AROAFAKE:test</UserId><Account>%s</Account>'
                    '</GetCallerIdentityResult></GetCallerIdentityResponse>' % (ACCT, ACCT))
        elif action == "DescribeDBInstances":
            body = wrap(action, "DBInstances", *page(INST, marker, PAGE))
        elif action == "DescribeDBClusters":
            body = wrap(action, "DBClusters", *page(CLUS, marker, PAGE))
        elif action == "DescribeDBSnapshots":
            body = wrap(action, "DBSnapshots", *page([s for t, s in SNAP if st in (None, t)], marker, 100))
        elif action == "DescribeDBClusterSnapshots":
            body = wrap(action, "DBClusterSnapshots", *page([s for t, s in CSNAP if st in (None, t)], marker, 3))
        else:
            return self.send(400, "<ErrorResponse><Error><Code>InvalidAction</Code><Message>%s</Message></Error></ErrorResponse>" % action, "text/xml")
        self.send(200, body, "text/xml")

    def log_message(self, *a):
        pass


s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(portfile, "w").write(str(s.server_port))
s.serve_forever()
