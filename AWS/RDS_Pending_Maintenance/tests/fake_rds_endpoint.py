#!/usr/bin/env python3
"""Local fake of the RDS/DocumentDB/STS query-protocol API (XML) that PAGINATES with Marker.

Used by validate_cli.sh to prove that the REAL AWS CLI v2, invoked with exactly the script's options,
follows every page (auto-pagination) and that the script receives the merged result.
Usage: fake_rds_endpoint.py <port-file> <request-log>   (listens on 127.0.0.1, random port)
Fleet: N_RES instances with 1 pending action each + N_CL clusters with 1 action each.
Pages: pending actions PAGE_PMA per page, describe-db-instances/clusters PAGE_DESC per page.
"""
import http.server, json, sys, urllib.parse
from xml.sax.saxutils import escape

N_RES, N_CL, PAGE_PMA, PAGE_DESC = 230, 30, 100, 20
ACCT, REGION = "123456789012", "us-east-1"
ARN = "arn:aws:rds:%s:%s:%%s:%%s" % (REGION, ACCT)
INST = [("pg-%03d" % i, ARN % ("db", "pg-%03d" % i)) for i in range(N_RES)]
CLUS = [("apg-%02d" % i, ARN % ("cluster", "apg-%02d" % i)) for i in range(N_CL)]
ACTS = ["system-update", "db-upgrade", "os-upgrade", "hardware-maintenance", "ca-certificate-rotation"]
portfile, logfile = sys.argv[1], sys.argv[2]


def page(items, marker, size):
    start = int(marker or 0)
    nxt = start + size
    return items[start:nxt], (str(nxt) if nxt < len(items) else None)


def pma_xml(arn, k):
    return ("<ResourcePendingMaintenanceActions><ResourceIdentifier>%s</ResourceIdentifier><PendingMaintenanceActionDetails>"
            "<PendingMaintenanceAction><Action>%s</Action><AutoAppliedAfterDate>2026-11-%02dT00:00:00Z</AutoAppliedAfterDate>"
            "<Description>%s</Description></PendingMaintenanceAction></PendingMaintenanceActionDetails></ResourcePendingMaintenanceActions>"
            % (escape(arn), ACTS[k % 5], 1 + k % 28, escape("Patch bundle %d & fixes <x>" % k)))


def inst_xml(ident, arn):
    return ("<DBInstance><DBInstanceIdentifier>%s</DBInstanceIdentifier><DBInstanceArn>%s</DBInstanceArn><Engine>postgres</Engine>"
            "<EngineVersion>16.4</EngineVersion><DBInstanceClass>db.m7g.large</DBInstanceClass>"
            "<PreferredMaintenanceWindow>sun:20:00-sun:20:30</PreferredMaintenanceWindow>"
            "<TagList><Tag><Key>Environment</Key><Value>prod</Value></Tag><Tag><Key>Owner</Key><Value>dba</Value></Tag></TagList></DBInstance>"
            % (ident, escape(arn)))


def clus_xml(ident, arn):
    return ("<DBCluster><DBClusterIdentifier>%s</DBClusterIdentifier><DBClusterArn>%s</DBClusterArn><Engine>aurora-postgresql</Engine>"
            "<EngineVersion>16.8</EngineVersion><PreferredMaintenanceWindow>mon:20:00-mon:20:30</PreferredMaintenanceWindow>"
            "<TagList><Tag><Key>Environment</Key><Value>prod</Value></Tag></TagList></DBCluster>" % (ident, escape(arn)))


class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        q = urllib.parse.parse_qs(self.rfile.read(int(self.headers.get("Content-Length", 0))).decode())
        action, marker = q.get("Action", [""])[0], q.get("Marker", [None])[0]
        values = {v[0] for k, v in q.items() if ".Values.Value." in k}
        with open(logfile, "a") as fh:
            fh.write(json.dumps({"action": action, "marker": marker, "n_values": len(values)}) + "\n")
        if action == "GetCallerIdentity":
            body = ("<GetCallerIdentityResponse xmlns=\"https://sts.amazonaws.com/doc/2011-06-15/\"><GetCallerIdentityResult>"
                    "<Arn>arn:aws:sts::%s:assumed-role/ReadOnly/test</Arn><UserId>AROAFAKE:test</UserId><Account>%s</Account>"
                    "</GetCallerIdentityResult></GetCallerIdentityResponse>" % (ACCT, ACCT))
        elif action == "DescribePendingMaintenanceActions":
            allp = [pma_xml(a, k) for k, (_, a) in enumerate(INST + CLUS)]
            items, nxt = page(allp, marker, PAGE_PMA)
            body = ("<DescribePendingMaintenanceActionsResponse><DescribePendingMaintenanceActionsResult><PendingMaintenanceActions>%s"
                    "</PendingMaintenanceActions>%s</DescribePendingMaintenanceActionsResult></DescribePendingMaintenanceActionsResponse>"
                    % ("".join(items), "<Marker>%s</Marker>" % nxt if nxt else ""))
        elif action in ("DescribeDBInstances", "DescribeDBClusters"):
            src, fn, tag = (INST, inst_xml, "DBInstances") if action == "DescribeDBInstances" else (CLUS, clus_xml, "DBClusters")
            sel = [fn(i, a) for i, a in src if a in values or i in values]
            items, nxt = page(sel, marker, PAGE_DESC)
            body = ("<%sResponse><%sResult><%s>%s</%s>%s</%sResult></%sResponse>"
                    % (action, action, tag, "".join(items), tag, "<Marker>%s</Marker>" % nxt if nxt else "", action, action))
        elif action == "DescribeDBEngineVersions":
            eng, ver = q.get("Engine", [""])[0], q.get("EngineVersion", [""])[0]
            tg = {("postgres", "16.4"): [("16.6", "false"), ("16.8", "false"), ("17.4", "true")]}.get((eng, ver), [])
            body = ("<DescribeDBEngineVersionsResponse><DescribeDBEngineVersionsResult><DBEngineVersions><DBEngineVersion>"
                    "<Engine>%s</Engine><EngineVersion>%s</EngineVersion><ValidUpgradeTarget>%s</ValidUpgradeTarget></DBEngineVersion>"
                    "</DBEngineVersions></DescribeDBEngineVersionsResult></DescribeDBEngineVersionsResponse>"
                    % (eng, ver, "".join("<UpgradeTarget><Engine>%s</Engine><EngineVersion>%s</EngineVersion><IsMajorVersionUpgrade>%s"
                                         "</IsMajorVersionUpgrade></UpgradeTarget>" % (eng, t, m) for t, m in tg)))
        else:
            self.send_response(400); self.end_headers(); return
        data = body.encode()
        self.send_response(200); self.send_header("Content-Type", "text/xml"); self.send_header("Content-Length", str(len(data)))
        self.end_headers(); self.wfile.write(data)

    def log_message(self, *a):
        pass


s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(portfile, "w").write(str(s.server_port))
s.serve_forever()
