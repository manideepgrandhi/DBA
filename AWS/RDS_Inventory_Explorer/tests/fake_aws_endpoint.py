#!/usr/bin/env python3
"""Local fake AWS endpoint for validate_cli.sh: the REAL AWS CLI v2 is pointed at it with --endpoint-url.
Speaks the STS / EC2 / RDS query protocol (XML, Marker paging) with deliberately small pages so the CLI's
automatic pagination is exercised. Never forwards anything. The region is read from the SigV4 credential scope.
CloudWatch / Secrets Manager / KMS requests are answered with an error and logged so the test can prove none were made.
Usage: fake_aws_endpoint.py <portfile> <requestlog.jsonl> <expected.json>
Fleet (us-east-1 only; eu-west-1 is empty, so discovery must skip it): N standalone postgres instances (every 5th has
a same-region read replica) + 1 Aurora cluster (writer + 2 readers, managed master secret, custom endpoint) in a global cluster.
"""
import http.server, json, re, sys, urllib.parse

portfile, logfile, expfile = sys.argv[1:4]
ACCT, HOME, N = "123456789012", "us-east-1", 45
NS = "http://rds.amazonaws.com/doc/2014-10-31/"
KMS = "arn:aws:kms:us-east-1:%s:key/1111aaaa-2222-bbbb-3333-cccc4444dddd" % ACCT


def x(tag, v):
    return "<%s>%s</%s>" % (tag, v, tag)


def arn(k, i):
    return "arn:aws:rds:%s:%s:%s:%s" % (HOME, ACCT, k, i)


def common(i, eng, ver, cls):
    return (x("DBInstanceIdentifier", i) + x("DBInstanceArn", arn("db", i)) + x("Engine", eng) + x("EngineVersion", ver)
            + x("DBInstanceClass", cls) + x("DBInstanceStatus", "available") + x("AvailabilityZone", HOME + "a")
            + x("InstanceCreateTime", "2025-01-15T10:00:00.000Z") + x("StorageEncrypted", "true") + x("KmsKeyId", KMS)
            + x("DeletionProtection", "false") + x("PubliclyAccessible", "false") + x("CACertificateIdentifier", "rds-ca-rsa2048-g1")
            + x("AutoMinorVersionUpgrade", "true") + x("PreferredMaintenanceWindow", "sun:20:00-sun:20:30")
            + "<DBSubnetGroup>%s%s</DBSubnetGroup>" % (x("DBSubnetGroupName", "db-private"), x("VpcId", "vpc-0fake"))
            + "<Endpoint>%s%s</Endpoint>" % (x("Address", i + ".fake.local"), x("Port", 5432))
            + "<TagList><Tag>%s%s</Tag></TagList>" % (x("Key", "env"), x("Value", "e2e")))


INST, REPL = [], 0
for k in range(N):
    i = "fake-pg-%03d" % k
    rr = "<ReadReplicaDBInstanceIdentifiers>%s</ReadReplicaDBInstanceIdentifiers>" % x("ReadReplicaDBInstanceIdentifier", i + "-rr") if k % 5 == 0 else ""
    INST.append("<DBInstance>" + common(i, "postgres", "16.8", "db.m6g.large") + x("AllocatedStorage", 100) + x("StorageType", "gp3")
                + x("BackupRetentionPeriod", 7) + x("PreferredBackupWindow", "18:00-18:30") + x("MultiAZ", "true") + rr + "</DBInstance>")
    if k % 5 == 0:
        REPL += 1
        INST.append("<DBInstance>" + common(i + "-rr", "postgres", "16.8", "db.m6g.large") + x("AllocatedStorage", 100) + x("StorageType", "gp3")
                    + x("BackupRetentionPeriod", 0) + x("ReadReplicaSourceDBInstanceIdentifier", i) + "</DBInstance>")
MEM = [("fake-aurora-1", "true", 0), ("fake-aurora-2", "false", 1), ("fake-aurora-3", "false", 2)]
for m, w, t in MEM:
    INST.append("<DBInstance>" + common(m, "aurora-postgresql", "16.6", "db.r6g.xlarge") + x("DBClusterIdentifier", "fake-aurora")
                + x("PromotionTier", t) + "</DBInstance>")
CLUS = ["<DBCluster>" + x("DBClusterIdentifier", "fake-aurora") + x("DBClusterArn", arn("cluster", "fake-aurora")) + x("Engine", "aurora-postgresql")
        + x("EngineVersion", "16.6") + x("Status", "available") + x("StorageEncrypted", "true") + x("KmsKeyId", KMS) + x("DeletionProtection", "true")
        + x("BackupRetentionPeriod", 14) + x("PreferredBackupWindow", "19:00-19:30") + x("PreferredMaintenanceWindow", "sat:21:00-sat:21:30")
        + x("Endpoint", "fake-aurora.cluster-fake.local") + x("ReaderEndpoint", "fake-aurora.cluster-ro-fake.local")
        + x("Port", 5432) + x("MasterUsername", "postgres") + x("DBClusterParameterGroup", "apg16-secure") + x("ClusterCreateTime", "2025-02-01T00:00:00.000Z")
        + "<MasterUserSecret>%s%s%s</MasterUserSecret>" % (x("SecretArn", "arn:aws:secretsmanager:us-east-1:%s:secret:rds!cluster-fake-AbCdEf" % ACCT), x("SecretStatus", "active"), x("KmsKeyId", KMS))
        + "<AvailabilityZones>%s%s</AvailabilityZones>" % (x("AvailabilityZone", HOME + "a"), x("AvailabilityZone", HOME + "b"))
        + "<DBClusterMembers>" + "".join("<DBClusterMember>%s%s%s</DBClusterMember>" % (x("DBInstanceIdentifier", m), x("IsClusterWriter", w), x("PromotionTier", t)) for m, w, t in MEM)
        + "</DBClusterMembers></DBCluster>"]
GLOB = ["<GlobalCluster>" + x("GlobalClusterIdentifier", "fake-global") + x("GlobalClusterArn", "arn:aws:rds::%s:global-cluster:fake-global" % ACCT)
        + x("Engine", "aurora-postgresql") + x("EngineVersion", "16.6") + x("Status", "available") + x("StorageEncrypted", "true")
        + "<GlobalClusterMembers><GlobalClusterMember>%s%s</GlobalClusterMember></GlobalClusterMembers></GlobalCluster>" % (x("DBClusterArn", arn("cluster", "fake-aurora")), x("IsWriter", "true"))]
EPS = ["<DBClusterEndpointList>" + x("DBClusterEndpointIdentifier", "fake-reporting") + x("DBClusterIdentifier", "fake-aurora")
       + x("Endpoint", "fake-reporting.cluster-custom-fake.local") + x("EndpointType", "CUSTOM") + x("CustomEndpointType", "READER") + x("Status", "available")
       + "<StaticMembers>%s</StaticMembers></DBClusterEndpointList>" % x("member", "fake-aurora-3")]
PMA = ["<ResourcePendingMaintenanceActions>" + x("ResourceIdentifier", arn("db", "fake-pg-%03d" % k))
       + "<PendingMaintenanceActionDetails><PendingMaintenanceAction>%s%s%s</PendingMaintenanceAction></PendingMaintenanceActionDetails></ResourcePendingMaintenanceActions>"
       % (x("Action", "system-update"), x("AutoAppliedAfterDate", "2026-12-01T00:00:00.000Z"), x("Description", "patch"))
       for k in range(0, N, 4)]
CERTS = ["<Certificate>" + x("CertificateIdentifier", "rds-ca-rsa2048-g1") + x("ValidTill", "2061-05-25T23:34:57.000Z") + "</Certificate>"]

n_inst = N + REPL + len(MEM)
json.dump({"accounts": 1, "regions_with_databases": 1, "global_clusters": 1, "clusters": 1, "instances": n_inst,
           "standalone_instances": N + REPL, "cluster_members": len(MEM), "pending_maintenance": len(PMA), "errors": 0}, open(expfile, "w"))

PAGES = {"DescribeDBInstances": ("DBInstances", INST, 20), "DescribeDBClusters": ("DBClusters", CLUS, 20),
         "DescribeGlobalClusters": ("GlobalClusters", GLOB, 20), "DescribeDBClusterEndpoints": ("DBClusterEndpoints", EPS, 20),
         "DescribePendingMaintenanceActions": ("PendingMaintenanceActions", PMA, 5), "DescribeCertificates": ("Certificates", CERTS, 20)}
REGIONS = ["eu-west-1", "us-east-1"]


class H(http.server.BaseHTTPRequestHandler):
    def send(self, code, body):
        data = body.encode()
        self.send_response(code); self.send_header("Content-Type", "text/xml"); self.send_header("Content-Length", str(len(data)))
        self.end_headers(); self.wfile.write(data)

    def do_POST(self):
        q = urllib.parse.parse_qs(self.rfile.read(int(self.headers.get("Content-Length", 0))).decode())
        action, marker = q.get("Action", [""])[0], q.get("Marker", [None])[0]
        m = re.search(r"Credential=[^/]+/\d+/([^/]+)/([^/]+)/", self.headers.get("Authorization", ""))
        region, svc = (m.group(1), m.group(2)) if m else ("?", "?")
        with open(logfile, "a") as fh:
            fh.write(json.dumps({"action": action, "service": svc, "region": region, "marker": marker,
                                 "max_records": q.get("MaxRecords", [None])[0]}) + "\n")
        if action == "GetCallerIdentity":
            return self.send(200, '<GetCallerIdentityResponse xmlns="https://sts.amazonaws.com/doc/2011-06-15/"><GetCallerIdentityResult>'
                             '<Arn>arn:aws:sts::%s:assumed-role/ReadOnly/test</Arn><UserId>AROAFAKE:test</UserId><Account>%s</Account>'
                             '</GetCallerIdentityResult></GetCallerIdentityResponse>' % (ACCT, ACCT))
        if action == "DescribeRegions":
            items = "".join("<item>%s%s%s</item>" % (x("regionName", r), x("regionEndpoint", "ec2.%s.amazonaws.com" % r), x("optInStatus", "opt-in-not-required")) for r in REGIONS)
            return self.send(200, '<DescribeRegionsResponse xmlns="http://ec2.amazonaws.com/doc/2016-11-15/"><requestId>r1</requestId>'
                             '<regionInfo>%s</regionInfo></DescribeRegionsResponse>' % items)
        if action in PAGES and svc == "rds":
            tag, allitems, size = PAGES[action]
            items = allitems if region == HOME else []
            size = min(size, int(q.get("MaxRecords", [size])[0]))
            s = int(marker or 0); nxt = s + size if s + size < len(items) else None
            return self.send(200, '<%sResponse xmlns="%s"><%sResult><%s>%s</%s>%s</%sResult></%sResponse>'
                             % (action, NS, action, tag, "".join(items[s:s + size]), tag, x("Marker", nxt) if nxt else "", action, action))
        self.send(400, "<ErrorResponse><Error><Type>Sender</Type><Code>InvalidAction</Code><Message>%s</Message></Error></ErrorResponse>" % action)

    def log_message(self, *a):
        pass


s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(portfile, "w").write(str(s.server_port))
s.serve_forever()
