#!/usr/bin/env python3
"""Local fake AWS endpoint for validate_cli.sh: the REAL AWS CLI v2 is pointed at it with --endpoint-url.
Speaks the STS / EC2 / RDS query protocol (XML, Marker paging) with deliberately small pages so the CLI's
automatic pagination is exercised. Never forwards anything. CloudWatch requests are answered with an error
and logged so the test can prove none were made.
Usage: fake_aws_endpoint.py <portfile> <requestlog.jsonl> <expected.json>
Fleet: N standalone postgres instances (every 5th has a same-region read replica) + 1 Aurora cluster (writer + 2 readers)
in a global cluster, custom endpoint, pending maintenance, parameter groups with many parameters (paged).
"""
import http.server, json, sys, urllib.parse

portfile, logfile, expfile = sys.argv[1:4]
ACCT, REGION, N = "123456789012", "us-east-1", 60
NS = "http://rds.amazonaws.com/doc/2014-10-31/"


def x(tag, v):
    return "<%s>%s</%s>" % (tag, v, tag)


def arn(k, i):
    return "arn:aws:rds:%s:%s:%s:%s" % (REGION, ACCT, k, i)


def common(i, eng, ver, cls):
    return (x("DBInstanceIdentifier", i) + x("DBInstanceArn", arn("db", i)) + x("Engine", eng) + x("EngineVersion", ver)
            + x("DBInstanceClass", cls) + x("DBInstanceStatus", "available") + x("AvailabilityZone", REGION + "a")
            + x("InstanceCreateTime", "2025-01-15T10:00:00.000Z") + x("StorageEncrypted", "true") + x("DeletionProtection", "true")
            + x("PubliclyAccessible", "false") + x("CACertificateIdentifier", "rds-ca-rsa2048-g1")
            + "<DBSubnetGroup>%s%s</DBSubnetGroup>" % (x("DBSubnetGroupName", "db-private"), x("VpcId", "vpc-0fake"))
            + "<Endpoint>%s%s</Endpoint>" % (x("Address", i + ".fake.local"), x("Port", 5432)))


INST, REPL = [], 0
for k in range(N):
    i = "fake-pg-%03d" % k
    rr = "<ReadReplicaDBInstanceIdentifiers>%s</ReadReplicaDBInstanceIdentifiers>" % x("ReadReplicaDBInstanceIdentifier", i + "-rr") if k % 5 == 0 else ""
    INST.append("<DBInstance>" + common(i, "postgres", "16.8", "db.m6g.large") + x("AllocatedStorage", 100) + x("StorageType", "gp3")
                + x("BackupRetentionPeriod", 7) + x("MultiAZ", "true")
                + "<DBParameterGroups><DBParameterGroup>%s%s</DBParameterGroup></DBParameterGroups>" % (x("DBParameterGroupName", "pg16-secure"), x("ParameterApplyStatus", "in-sync"))
                + rr + "</DBInstance>")
    if k % 5 == 0:
        REPL += 1
        INST.append("<DBInstance>" + common(i + "-rr", "postgres", "16.8", "db.m6g.large") + x("AllocatedStorage", 100) + x("StorageType", "gp3")
                    + x("BackupRetentionPeriod", 0) + x("ReadReplicaSourceDBInstanceIdentifier", i)
                    + "<DBParameterGroups><DBParameterGroup>%s%s</DBParameterGroup></DBParameterGroups>" % (x("DBParameterGroupName", "pg16-secure"), x("ParameterApplyStatus", "in-sync"))
                    + "</DBInstance>")
MEM = [("fake-aurora-1", "true", 0), ("fake-aurora-2", "false", 1), ("fake-aurora-3", "false", 2)]
for m, w, t in MEM:
    INST.append("<DBInstance>" + common(m, "aurora-postgresql", "16.6", "db.r6g.xlarge") + x("DBClusterIdentifier", "fake-aurora")
                + x("PromotionTier", t) + "</DBInstance>")
CLUS = ["<DBCluster>" + x("DBClusterIdentifier", "fake-aurora") + x("DBClusterArn", arn("cluster", "fake-aurora")) + x("Engine", "aurora-postgresql")
        + x("EngineVersion", "16.6") + x("Status", "available") + x("StorageEncrypted", "true") + x("DeletionProtection", "true")
        + x("BackupRetentionPeriod", 7) + x("Endpoint", "fake-aurora.cluster-fake.local") + x("ReaderEndpoint", "fake-aurora.cluster-ro-fake.local")
        + x("Port", 5432) + x("DBClusterParameterGroup", "apg16-secure") + x("ClusterCreateTime", "2025-02-01T00:00:00.000Z")
        + "<AvailabilityZones>%s%s</AvailabilityZones>" % (x("AvailabilityZone", REGION + "a"), x("AvailabilityZone", REGION + "b"))
        + "<DBClusterMembers>" + "".join("<DBClusterMember>%s%s%s</DBClusterMember>" % (x("DBInstanceIdentifier", m), x("IsClusterWriter", w), x("PromotionTier", t)) for m, w, t in MEM)
        + "</DBClusterMembers></DBCluster>"]
GLOB = ["<GlobalCluster>" + x("GlobalClusterIdentifier", "fake-global") + x("GlobalClusterArn", "arn:aws:rds::%s:global-cluster:fake-global" % ACCT)
        + x("Engine", "aurora-postgresql") + x("EngineVersion", "16.6") + x("Status", "available")
        + "<GlobalClusterMembers><GlobalClusterMember>%s%s</GlobalClusterMember></GlobalClusterMembers></GlobalCluster>" % (x("DBClusterArn", arn("cluster", "fake-aurora")), x("IsWriter", "true"))]
EPS = ["<DBClusterEndpointList>" + x("DBClusterEndpointIdentifier", "fake-reporting") + x("DBClusterIdentifier", "fake-aurora")
       + x("Endpoint", "fake-reporting.cluster-custom-fake.local") + x("EndpointType", "CUSTOM") + x("CustomEndpointType", "READER") + x("Status", "available")
       + "<StaticMembers>%s</StaticMembers></DBClusterEndpointList>" % x("member", "fake-aurora-3")]
PMA = ["<ResourcePendingMaintenanceActions>" + x("ResourceIdentifier", arn("db", "fake-pg-%03d" % k))
       + "<PendingMaintenanceActionDetails><PendingMaintenanceAction>%s%s%s</PendingMaintenanceAction></PendingMaintenanceActionDetails></ResourcePendingMaintenanceActions>"
       % (x("Action", "system-update"), x("AutoAppliedAfterDate", "2026-12-01T00:00:00.000Z"), x("Description", "patch"))
       for k in range(0, N, 4)]
CERTS = ["<Certificate>" + x("CertificateIdentifier", "rds-ca-rsa2048-g1") + x("ValidTill", "2061-05-25T23:34:57.000Z") + "</Certificate>"]
MEV = {e: ["<DBMajorEngineVersion>%s%s<SupportedEngineLifecycles>%s%s</SupportedEngineLifecycles></DBMajorEngineVersion>"
           % (x("Engine", e), x("MajorEngineVersion", "16"),
              "<SupportedEngineLifecycle>%s%s%s</SupportedEngineLifecycle>" % (x("LifecycleSupportName", "open-source-rds-standard-support"), x("LifecycleSupportStartDate", "2024-01-01T00:00:00Z"), x("LifecycleSupportEndDate", "2029-02-28T00:00:00Z")),
              "<SupportedEngineLifecycle>%s%s%s</SupportedEngineLifecycle>" % (x("LifecycleSupportName", "open-source-rds-extended-support"), x("LifecycleSupportStartDate", "2029-03-01T00:00:00Z"), x("LifecycleSupportEndDate", "2032-02-28T00:00:00Z")))]
       for e in ("postgres", "aurora-postgresql")}


def params(ssl):
    ps = ["<Parameter>%s%s%s</Parameter>" % (x("ParameterName", "param_%03d" % k), x("ParameterValue", k), x("Source", "engine-default")) for k in range(250)]
    ps.insert(137, "<Parameter>%s%s%s</Parameter>" % (x("ParameterName", "rds.force_ssl"), x("ParameterValue", ssl), x("Source", "user")))
    return ps


n_inst = N + REPL + len(MEM)
json.dump({"groups": 1 + N, "instances": n_inst, "clusters": 1, "global_clusters": 1, "rows": 1 + 1 + len(MEM) + n_inst - len(MEM),
           "errors": 0}, open(expfile, "w"))

PAGES = {"DescribeDBInstances": ("DBInstances", lambda q: INST, 20), "DescribeDBClusters": ("DBClusters", lambda q: CLUS, 20),
         "DescribeGlobalClusters": ("GlobalClusters", lambda q: GLOB, 20), "DescribeDBClusterEndpoints": ("DBClusterEndpoints", lambda q: EPS, 20),
         "DescribePendingMaintenanceActions": ("PendingMaintenanceActions", lambda q: PMA, 5), "DescribeCertificates": ("Certificates", lambda q: CERTS, 20),
         "DescribeDBMajorEngineVersions": ("DBMajorEngineVersions", lambda q: MEV.get(q.get("Engine", [""])[0], []), 20),
         "DescribeDBParameters": ("Parameters", lambda q: params("1"), 100), "DescribeDBClusterParameters": ("Parameters", lambda q: params("1"), 100)}


class H(http.server.BaseHTTPRequestHandler):
    def send(self, code, body):
        data = body.encode()
        self.send_response(code); self.send_header("Content-Type", "text/xml"); self.send_header("Content-Length", str(len(data)))
        self.end_headers(); self.wfile.write(data)

    def do_POST(self):
        q = urllib.parse.parse_qs(self.rfile.read(int(self.headers.get("Content-Length", 0))).decode())
        action, marker = q.get("Action", [""])[0], q.get("Marker", [None])[0]
        with open(logfile, "a") as fh:
            fh.write(json.dumps({"action": action, "marker": marker, "auth": self.headers.get("Authorization", "")[:60]}) + "\n")
        if action == "GetCallerIdentity":
            return self.send(200, '<GetCallerIdentityResponse xmlns="https://sts.amazonaws.com/doc/2011-06-15/"><GetCallerIdentityResult>'
                             '<Arn>arn:aws:sts::%s:assumed-role/ReadOnly/test</Arn><UserId>AROAFAKE:test</UserId><Account>%s</Account>'
                             '</GetCallerIdentityResult></GetCallerIdentityResponse>' % (ACCT, ACCT))
        if action in PAGES:
            tag, fn, size = PAGES[action]
            items = fn(q); s = int(marker or 0); nxt = s + size if s + size < len(items) else None
            return self.send(200, '<%sResponse xmlns="%s"><%sResult><%s>%s</%s>%s</%sResult></%sResponse>'
                             % (action, NS, action, tag, "".join(items[s:s + size]), tag, x("Marker", nxt) if nxt else "", action, action))
        self.send(400, "<ErrorResponse><Error><Type>Sender</Type><Code>InvalidAction</Code><Message>%s</Message></Error></ErrorResponse>" % action)

    def log_message(self, *a):
        pass


s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(portfile, "w").write(str(s.server_port))
s.serve_forever()
