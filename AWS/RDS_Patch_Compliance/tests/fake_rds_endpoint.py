#!/usr/bin/env python3
"""Local fake of the RDS/STS query-protocol API (XML) that PAGINATES every list with Marker.

Used by validate_cli.sh to prove that the REAL AWS CLI v2, invoked with exactly the script's options, follows
every page (auto-pagination) and that the script gets the merged result. Listens on 127.0.0.1 (random port).
Usage: fake_rds_endpoint.py <port-file> <request-log>
Fleet: N_CL aurora-postgresql 16.8 clusters (1 member each) + N_INST standalone postgres 16.4 instances.
"""
import http.server, json, sys, urllib.parse
from xml.sax.saxutils import escape

N_CL, N_INST, PAGE = 30, 200, 20
ACCT, REGION = "123456789012", "us-east-1"
ARN = "arn:aws:rds:%s:%s:%%s:%%s" % (REGION, ACCT)
EV = {"postgres": ["16.3", "16.4", "16.6", "16.8", "16.9", "16.10", "16.11"], "aurora-postgresql": ["16.6", "16.8", "16.9"]}
portfile, logfile = sys.argv[1], sys.argv[2]


def page(items, marker, size):
    start = int(marker or 0)
    nxt = start + size
    return items[start:nxt], (str(nxt) if nxt < len(items) else None)


def inst_xml(ident, engine, ver, cluster=None):
    return ("<DBInstance><DBInstanceIdentifier>%s</DBInstanceIdentifier><DBInstanceArn>%s</DBInstanceArn><Engine>%s</Engine>"
            "<EngineVersion>%s</EngineVersion><AutoMinorVersionUpgrade>true</AutoMinorVersionUpgrade>%s"
            "<PreferredMaintenanceWindow>sun:20:00-sun:20:30</PreferredMaintenanceWindow>"
            "<TagList><Tag><Key>Environment</Key><Value>prod &amp; test</Value></Tag></TagList></DBInstance>"
            % (ident, escape(ARN % ("db", ident)), engine, ver, "<DBClusterIdentifier>%s</DBClusterIdentifier>" % cluster if cluster else ""))


def clus_xml(ident):
    return ("<DBCluster><DBClusterIdentifier>%s</DBClusterIdentifier><DBClusterArn>%s</DBClusterArn><Engine>aurora-postgresql</Engine>"
            "<EngineVersion>16.8</EngineVersion><PreferredMaintenanceWindow>mon:20:00-mon:20:30</PreferredMaintenanceWindow>"
            "<DBClusterMembers><DBClusterMember><DBInstanceIdentifier>%s-1</DBInstanceIdentifier><IsClusterWriter>true</IsClusterWriter></DBClusterMember></DBClusterMembers>"
            "</DBCluster>" % (ident, escape(ARN % ("cluster", ident)), ident))


INST = [inst_xml("apg-%02d-1" % i, "aurora-postgresql", "16.8", "apg-%02d" % i) for i in range(N_CL)] + \
       [inst_xml("pg-%03d" % i, "postgres", "16.4") for i in range(N_INST)]
CLUS = [clus_xml("apg-%02d" % i) for i in range(N_CL)]
PMA = ["<ResourcePendingMaintenanceActions><ResourceIdentifier>%s</ResourceIdentifier><PendingMaintenanceActionDetails><PendingMaintenanceAction>"
       "<Action>system-update</Action><Description>x</Description></PendingMaintenanceAction></PendingMaintenanceActionDetails></ResourcePendingMaintenanceActions>"
       % escape(ARN % ("db", "pg-%03d" % i)) for i in range(50)]


def wrap(action, tag, items, nxt):
    return ("<%sResponse><%sResult><%s>%s</%s>%s</%sResult></%sResponse>"
            % (action, action, tag, "".join(items), tag, "<Marker>%s</Marker>" % nxt if nxt else "", action, action))


class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        q = urllib.parse.parse_qs(self.rfile.read(int(self.headers.get("Content-Length", 0))).decode())
        action, marker, eng = q.get("Action", [""])[0], q.get("Marker", [None])[0], q.get("Engine", [""])[0]
        with open(logfile, "a") as fh:
            fh.write(json.dumps({"action": action, "marker": marker, "engine": eng}) + "\n")
        if action == "GetCallerIdentity":
            body = ("<GetCallerIdentityResponse xmlns=\"https://sts.amazonaws.com/doc/2011-06-15/\"><GetCallerIdentityResult>"
                    "<Arn>arn:aws:sts::%s:assumed-role/ReadOnly/test</Arn><UserId>AROAFAKE:test</UserId><Account>%s</Account>"
                    "</GetCallerIdentityResult></GetCallerIdentityResponse>" % (ACCT, ACCT))
        elif action == "DescribeDBInstances":
            body = wrap(action, "DBInstances", *page(INST, marker, PAGE))
        elif action == "DescribeDBClusters":
            body = wrap(action, "DBClusters", *page(CLUS, marker, PAGE))
        elif action == "DescribePendingMaintenanceActions":
            body = wrap(action, "PendingMaintenanceActions", *page(PMA, marker, PAGE))
        elif action == "DescribeDBEngineVersions":
            ver = q.get("EngineVersion", [None])[0]
            allv = EV.get(eng, [])
            vs = []
            for v in allv:
                if ver is not None and v != ver:
                    continue
                tg = "".join("<UpgradeTarget><Engine>%s</Engine><EngineVersion>%s</EngineVersion><IsMajorVersionUpgrade>false</IsMajorVersionUpgrade>"
                             "<AutoUpgrade>%s</AutoUpgrade></UpgradeTarget>" % (eng, t, "true" if t == allv[-1] else "false") for t in allv[allv.index(v) + 1:])
                tg += "<UpgradeTarget><Engine>%s</Engine><EngineVersion>17.4</EngineVersion><IsMajorVersionUpgrade>true</IsMajorVersionUpgrade></UpgradeTarget>" % eng
                vs.append("<DBEngineVersion><Engine>%s</Engine><EngineVersion>%s</EngineVersion><MajorEngineVersion>16</MajorEngineVersion><Status>available</Status>"
                          "<ValidUpgradeTarget>%s</ValidUpgradeTarget></DBEngineVersion>" % (eng, v, tg))
            body = wrap(action, "DBEngineVersions", *page(vs, marker, 2))
        elif action == "DescribeDBMajorEngineVersions":
            ms = ["<DBMajorEngineVersion><Engine>%s</Engine><MajorEngineVersion>%s</MajorEngineVersion><SupportedEngineLifecycles>"
                  "<SupportedEngineLifecycle><LifecycleSupportName>open-source-rds-standard-support</LifecycleSupportName>"
                  "<LifecycleSupportStartDate>2024-01-01T00:00:00Z</LifecycleSupportStartDate><LifecycleSupportEndDate>2029-02-28T00:00:00Z</LifecycleSupportEndDate>"
                  "</SupportedEngineLifecycle></SupportedEngineLifecycles></DBMajorEngineVersion>" % (eng, m) for m in ("14", "15", "16")]
            body = wrap(action, "DBMajorEngineVersions", *page(ms, marker, 1))
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
