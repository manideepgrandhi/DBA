# lib/checks.jq - check logic for aurora_pg_check.sh (pure functions over AWS CLI JSON).
#
# Called by aurora_pg_check.sh, never by hand:
#   jq -n --arg mode queries|evaluate --arg region R --argjson now EPOCH --argjson lookback SEC
#      --argjson period SEC --argjson th THRESHOLDS --argjson groups '["cluster",...]'
#      --slurpfile clusters F --slurpfile instances F --slurpfile pma F --slurpfile certs F
#      --slurpfile engver F --slurpfile major F --slurpfile params F --slurpfile itypes F
#      --slurpfile snaps F --slurpfile events F --slurpfile metrics F --slurpfile errors F
#      -f lib/checks.jq
# A data file holds null when its AWS call failed or was not needed; $errors[0] maps
# call keys ("instances", "pma", "snapshots:<cluster>", ...) to the AWS error text.

# ---------------------------------------------------------------- helpers
# AWS CLI v2 timestamps: 2026-10-10T01:02:03.456000+00:00 / ...Z / no offset (UTC)
def ts:
  if . == null or . == "" then null else
    (sub("\\.[0-9]+"; "") | sub("Z$"; "+00:00")) as $s
    | ([$s | capture("^(?<d>[0-9-]{10}T[0-9:]{8})(?<sg>[+-])(?<h>[0-9]{2}):?(?<m>[0-9]{2})$")] | .[0]) as $c
    | if $c == null then (($s[0:19] + "Z") | fromdateiso8601)
      else (($c.d + "Z") | fromdateiso8601)
           - (if $c.sg == "-" then -1 else 1 end) * (($c.h | tonumber) * 3600 + ($c.m | tonumber) * 60)
      end
  end;
def local: if . == null then "-" else strflocaltime("%Y-%m-%d %H:%M %Z") end;
def dur: (. // 0 | floor) as $s
  | if $s < 0 then "-" + ((0 - $s) | dur)
    elif $s >= 86400 then "\($s / 86400 | floor)d \(($s % 86400) / 3600 | floor)h"
    elif $s >= 3600 then "\($s / 3600 | floor)h \(($s % 3600) / 60 | floor)m"
    elif $s >= 60 then "\($s / 60 | floor)m"
    else "\($s)s" end;
def r1: (. * 10 | round) / 10;
def r2: (. * 100 | round) / 100;
def big: if . >= 1e9 then "\(. / 1e9 | r2)B" elif . >= 1e6 then "\(. / 1e6 | r1)M"
         elif . >= 1e4 then "\(. / 1e3 | r1)k" else "\(r2)" end;
def mib: if . >= 1024 then "\(. / 1024 | r1) GiB" else "\(r1) MiB" end;
def fmtu($u): if $u == "MiB" then mib elif $u == "" then big elif $u == "%" then "\(r1)%"
              else "\(r2) \($u)" end;
def sev: {"OK":0, "INFO":0, "SKIP":0, "WARN":1, "ERROR":2, "CRIT":3}[.] // 0;
def worst: if length == 0 then "OK" else (max_by(sev)) as $w
           | if ($w | sev) == 0 then (if all(. == "SKIP") then "SKIP" elif all(. == "INFO") then "INFO" else "OK" end) else $w end end;
def hi($v; $w; $c): if $v == null then "SKIP" elif $v > $c then "CRIT" elif $v > $w then "WARN" else "OK" end;
def lo($v; $w; $c): if $v == null then "SKIP" elif $v < $c then "CRIT" elif $v < $w then "WARN" else "OK" end;
def vkey: split(".") | map(tonumber? // 0);
def on($g): ($groups | index($g)) != null;
def err($k): ($errors[0] // {})[$k];
def res($g; $c; $chk; $st; $val; $why):
  {region: $region, cluster: $c, group: $g, check: $chk, status: $st,
   value: (if $val == null then "" else ($val | tostring) end), reason: $why, details: []};
def withd($d): .details = [$d[] | tostring];
def yes: if . == true then "yes" elif . == false then "no" else "-" end;

# ---------------------------------------------------------------- metric catalogue
# stat = CloudWatch statistic per period; agg = how the datapoints are folded over the lookback
def mdefs: [
  {m:"CPUUtilization",            stat:"Average", agg:"max", dir:"hi", f:1, u:"%",   w:"cpu_warn",              c:"cpu_crit",              scope:"all"},
  {m:"FreeableMemory",            stat:"Minimum", agg:"min", dir:"lo", f:(1/1048576), u:"MiB", w:"mem_free_warn_mb", c:"mem_free_crit_mb", scope:"all"},
  {m:"DatabaseConnections",       stat:"Maximum", agg:"max", dir:"conn", f:1, u:"",                                                         scope:"all"},
  {m:"AuroraReplicaLag",          stat:"Maximum", agg:"max", dir:"hi", f:1, u:"ms",  w:"replica_lag_warn_ms",   c:"replica_lag_crit_ms",   scope:"reader"},
  {m:"AuroraReplicaLagMaximum",   stat:"Maximum", agg:"max", dir:"hi", f:1, u:"ms",  w:"replica_lag_warn_ms",   c:"replica_lag_crit_ms",   scope:"cluster"},
  {m:"FreeLocalStorage",          stat:"Minimum", agg:"min", dir:"lo", f:(1/1048576), u:"MiB", w:"local_storage_warn_mb", c:"local_storage_crit_mb", scope:"all"},
  {m:"DiskQueueDepth",            stat:"Average", agg:"max", dir:"hi", f:1, u:"",    w:"disk_queue_warn",       c:"disk_queue_crit",       scope:"all"},
  {m:"ReadLatency",               stat:"Average", agg:"max", dir:"hi", f:1000, u:"ms", w:"read_latency_warn_ms", c:"read_latency_crit_ms", scope:"all"},
  {m:"WriteLatency",              stat:"Average", agg:"max", dir:"hi", f:1000, u:"ms", w:"write_latency_warn_ms", c:"write_latency_crit_ms", scope:"all"},
  {m:"Deadlocks",                 stat:"Average", agg:"max", dir:"deadlock", f:1, u:"/s", w:"deadlocks_warn",   c:"deadlocks_crit",        scope:"all"},
  {m:"BufferCacheHitRatio",       stat:"Average", agg:"min", dir:"lo", f:1, u:"%",   w:"cache_hit_warn",        c:"cache_hit_crit",        scope:"all"},
  {m:"MaximumUsedTransactionIDs", stat:"Maximum", agg:"max", dir:"hi", f:1, u:"",    w:"xid_warn",              c:"xid_crit",              scope:"writer"},
  {m:"TransactionLogsDiskUsage",  stat:"Maximum", agg:"max", dir:"hi", f:(1/1048576), u:"MiB", w:"txlog_warn_mb", c:"txlog_crit_mb",       scope:"writer"},
  {m:"ReplicationSlotDiskUsage",  stat:"Maximum", agg:"max", dir:"hi", f:(1/1048576), u:"MiB", w:"slot_disk_warn_mb", c:"slot_disk_crit_mb", scope:"writer"},
  {m:"OldestReplicationSlotLag",  stat:"Maximum", agg:"max", dir:"hi", f:(1/1048576), u:"MiB", w:"slot_lag_warn_mb", c:"slot_lag_crit_mb",   scope:"writer"},
  {m:"ServerlessDatabaseCapacity",stat:"Maximum", agg:"max", dir:"info", f:1, u:"ACU",                                                      scope:"serverless"},
  {m:"ACUUtilization",            stat:"Maximum", agg:"max", dir:"hi", f:1, u:"%",   w:"acu_util_warn",         c:"acu_util_crit",         scope:"serverless"}
];

def pg_clusters: ($clusters[0] // []) | map(select(.Engine == "aurora-postgresql"));
def insts_of($c): ($instances[0] // []) | map(select(.DBClusterIdentifier == $c.DBClusterIdentifier));
def is_writer($c; $id): any(($c.DBClusterMembers // [])[]; .DBInstanceIdentifier == $id and .IsClusterWriter == true);
def targets($c):
  [ insts_of($c)[] | {id: .DBInstanceIdentifier, writer: is_writer($c; .DBInstanceIdentifier),
                      serverless: (.DBInstanceClass == "db.serverless")} ];

# ---------------------------------------------------------------- mode: queries
def queries:
  [ pg_clusters[] as $c | targets($c) as $t | mdefs[] as $d
    | ( if $d.scope == "cluster" then
          (if any($t[]; .writer | not) then [{n:"DBClusterIdentifier", v:$c.DBClusterIdentifier}] else [] end)
        else [ $t[] | select($d.scope == "all" or ($d.scope == "writer" and .writer)
                             or ($d.scope == "reader" and (.writer | not)) or ($d.scope == "serverless" and .serverless))
               | {n:"DBInstanceIdentifier", v:.id} ] end )[] as $x
    | {MetricStat: {Metric: {Namespace: "AWS/RDS", MetricName: $d.m, Dimensions: [{Name: $x.n, Value: $x.v}]},
                    Period: $period, Stat: $d.stat},
       Label: "\($c.DBClusterIdentifier)|\($x.v)|\($d.m)", ReturnData: true} ]
  | to_entries | map(.value + {Id: "q\(.key)"});

# ---------------------------------------------------------------- group: cluster
def cl_status: if . == "available" then "OK"
  elif test("^(failed|inaccessible-encryption|incompatible-|cloning-failed|migration-failed)") then "CRIT" else "WARN" end;
def in_status: if . == "available" then "OK"
  elif test("^(failed|inaccessible-encryption|incompatible-|storage-full|restore-error)") then "CRIT" else "WARN" end;

def g_cluster($c; $ins):
  ($c.DBClusterIdentifier) as $id | ($c.DBClusterMembers // []) as $mem
  | ($mem | map(select(.IsClusterWriter)) | length) as $nw | ($mem | map(select(.IsClusterWriter | not)) | length) as $nr
  | res("cluster"; $id; "cluster_status"; ($c.Status | cl_status); $c.Status;
        if $c.Status == "available" then "cluster is available" else "cluster status is '\($c.Status)'" end),
    ( if err("instances") then res("cluster"; $id; "instance_status"; "ERROR"; ""; "describe-db-instances failed: \(err("instances"))")
      else ($ins | map(.DBInstanceStatus | in_status) | worst) as $st
        | res("cluster"; $id; "instance_status"; $st;
              "\($ins | map(select(.DBInstanceStatus == "available")) | length)/\($ins | length) available";
              if $st == "OK" then "all instances available"
              else "not available: " + ($ins | map(select(.DBInstanceStatus != "available") | "\(.DBInstanceIdentifier)=\(.DBInstanceStatus)") | join(", ")) end)
        | withd($ins | map("\(.DBInstanceIdentifier): \(.DBInstanceStatus) (\(.DBInstanceClass), \(.AvailabilityZone // "-"))"))
      end ),
    ( if $nw == 1 then res("cluster"; $id; "writer"; "OK"; ($mem | map(select(.IsClusterWriter))[0].DBInstanceIdentifier); "writer present")
      elif $nw == 0 and ($c.GlobalClusterIdentifier // "") != "" then
        res("cluster"; $id; "writer"; "WARN"; "none"; "no writer (expected only for a global database secondary)")
      elif $nw == 0 then res("cluster"; $id; "writer"; "CRIT"; "none"; "no writer instance: the cluster cannot accept writes")
      else res("cluster"; $id; "writer"; "CRIT"; $nw; "more than one writer reported") end ),
    res("cluster"; $id; "reader_count"; (if $nr < $th.min_readers then "WARN" else "OK" end); $nr;
        if $nr == 0 then "no readers: a failover has to create a new instance (minutes of downtime)"
        elif $nr < $th.min_readers then "fewer than \($th.min_readers) reader(s)" else "\($nr) reader(s) available for failover/reads" end),
    ( if ($ins | length) == 0 then empty else
        ($ins | map(.AvailabilityZone) | unique) as $az | ([$th.min_azs, ($ins | length)] | min) as $need
        | res("cluster"; $id; "az_spread"; (if ($az | length) < $need then "WARN" else "OK" end); ($az | join(","));
              if ($ins | length) == 1 then "single instance in one AZ (no HA)"
              elif ($az | length) < $need then "instances span \($az | length) AZ(s); want at least \($need)"
              else "instances span \($az | length) AZs" end) end ),
    ( if ($ins | length) == 0 then empty else
        ($ins | map(.DBInstanceClass) | unique) as $cls
        | ($ins | map(select(is_writer($c; .DBInstanceIdentifier))) | .[0].DBInstanceClass) as $wc
        | res("cluster"; $id; "instance_class"; (if ($cls | length) > 1 then "WARN" else "OK" end); ($cls | join(","));
              if ($cls | length) > 1 then "mixed classes (writer \($wc // "-")): a failover may land on a different size"
              else "all instances are \($cls[0])" end)
        | withd($ins | map("\(.DBInstanceIdentifier): \(.DBInstanceClass) tier \(.PromotionTier // "-")")) end ),
    ( ($c.ServerlessV2ScalingConfiguration // null) as $sv
      | ($ins | map(select(.DBInstanceClass == "db.serverless")) | length) as $ns
      | if $sv == null and $ns == 0 then empty
        elif $sv == null then res("cluster"; $id; "serverless_v2"; "WARN"; "-"; "db.serverless instances but no ServerlessV2ScalingConfiguration")
        else res("cluster"; $id; "serverless_v2";
                 (if $sv.MaxCapacity <= $sv.MinCapacity then "WARN" else "OK" end);
                 "\($sv.MinCapacity)-\($sv.MaxCapacity) ACU, \($ns) serverless instance(s)";
                 if $sv.MaxCapacity <= $sv.MinCapacity then "min ACU = max ACU: no room to scale"
                 elif $sv.MinCapacity == 0 then "scales \($sv.MinCapacity)-\($sv.MaxCapacity) ACU; auto-pause enabled (resume adds latency)"
                 else "scales \($sv.MinCapacity)-\($sv.MaxCapacity) ACU" end) end );

# ---------------------------------------------------------------- group: versions
def g_versions($c; $ins):
  ($c.DBClusterIdentifier) as $id | ($c.EngineVersion) as $v
  | ([$c.DBClusterArn] + ($ins | map(.DBInstanceArn))) as $arns
  | (($engver[0] // {})[$v]) as $ev
  | ( if $ev == null and err("engver:\($v)") then res("versions"; $id; "engine_version"; "ERROR"; $v; "describe-db-engine-versions failed: \(err("engver:\($v)"))")
      elif $ev == null then res("versions"; $id; "engine_version"; "INFO"; $v; "version details unavailable")
      elif ($ev.Status // "available") == "deprecated" then res("versions"; $id; "engine_version"; "CRIT"; $v; "engine version \($v) is deprecated: upgrade")
      else res("versions"; $id; "engine_version"; "OK"; $v; "aurora-postgresql \($v) (\($ev.Status // "available"))") end ),
    ( ($ev.MajorEngineVersion // ($v | split(".")[0])) as $maj | (($major[0] // {})[$maj]) as $mj
      | ($mj.SupportedEngineLifecycles // [] | map(select(.LifecycleSupportName == "open-source-rds-standard-support")) | .[0]) as $std
      | ($mj.SupportedEngineLifecycles // [] | map(select(.LifecycleSupportName == "open-source-rds-extended-support")) | .[0]) as $ext
      | if $std == null then res("versions"; $id; "support_lifecycle"; "SKIP"; $maj; "major version lifecycle not available (describe-db-major-engine-versions)")
        else (($std.LifecycleSupportEndDate | ts) - $now) as $left
          | if $left < 0 then res("versions"; $id; "support_lifecycle"; "CRIT"; "std support ended \($std.LifecycleSupportEndDate | ts | local)";
                "major \($maj) is past Aurora standard support: RDS Extended Support charges apply (until \($ext.LifecycleSupportEndDate | ts | local)); cluster setting \($c.EngineLifecycleSupport // "-")")
            elif $left < $th.support_warn_days * 86400 then res("versions"; $id; "support_lifecycle"; "WARN"; "std support ends in \($left | dur)";
                "major \($maj) leaves standard support on \($std.LifecycleSupportEndDate | ts | local): plan the major upgrade")
            else res("versions"; $id; "support_lifecycle"; "OK"; "std support ends in \($left | dur)"; "major \($maj) in standard support") end end ),
    ( if $ev == null then empty else
        ($ev.ValidUpgradeTarget // []) as $t
        | ($t | map(select(.IsMajorVersionUpgrade | not) | .EngineVersion) | sort_by(vkey)) as $mi
        | ($t | map(select(.IsMajorVersionUpgrade) | .EngineVersion) | sort_by(vkey)) as $ma
        | res("versions"; $id; "upgrade_targets";
              (if $th.minor_behind_warn > 0 and ($mi | length) >= $th.minor_behind_warn then "WARN" else "INFO" end);
              "minor: \(if ($mi | length) > 0 then "\($mi[-1]) (+\($mi | length))" else "none" end); major: \(if ($ma | length) > 0 then $ma[-1] else "none" end)";
              if ($mi | length) > 0 then "\($mi | length) newer minor version(s) available" else "on the newest minor version" end)
        | withd(($mi | map("minor " + .)) + ($ma | map("major " + .))) end ),
    ( if ($pma[0]) == null then res("versions"; $id; "pending_maintenance"; "ERROR"; ""; "describe-pending-maintenance-actions failed: \(err("pma") // "no data")")
      else [ $pma[0][] | select(.ResourceIdentifier as $r | $arns | index($r)) | .ResourceIdentifier as $r
             | .PendingMaintenanceActionDetails[]
             | ([.AutoAppliedAfterDate, .ForcedApplyDate] | map(ts) | map(select(. != null)) | min) as $due
             | {r: ($r | split(":") | .[-1]), a: .Action, d: (.Description // ""), due: $due, opt: (.OptInStatus // ""),
                cur: (.CurrentApplyDate | ts)} ] as $acts
        | if ($acts | length) == 0 then res("versions"; $id; "pending_maintenance"; "OK"; 0; "no pending maintenance actions")
          else ($acts | map(select(.due != null and .due - $now < $th.maint_crit_days * 86400))) as $soon
            | res("versions"; $id; "pending_maintenance"; (if ($soon | length) > 0 then "CRIT" else "WARN" end); ($acts | length);
                  if ($soon | length) > 0 then "\($soon | length) action(s) auto-applied within \($th.maint_crit_days)d: " + ($soon | map("\(.a) on \(.r)") | join(", "))
                  else "\($acts | length) pending action(s): " + ($acts | map(.a) | unique | join(", ")) end)
            | withd($acts | map("\(.r): \(.a) - \(.d)\(if .due then " (auto-applied after \(.due | local))" else "" end)\(if .cur then " next window \(.cur | local)" else "" end)\(if .opt != "" then " [\(.opt)]" else "" end)"))
          end end ),
    ( if ($ins | length) == 0 then empty else
        ($ins | map(select(.AutoMinorVersionUpgrade != true) | .DBInstanceIdentifier)) as $off
        | res("versions"; $id; "auto_minor_upgrade";
              (if ($off | length) == 0 then "OK" elif $th.require_auto_minor_upgrade == 1 then "WARN" else "INFO" end);
              "\(($ins | length) - ($off | length))/\($ins | length) enabled";
              if ($off | length) == 0 then "auto minor version upgrade on for all instances"
              else "disabled on: \($off | join(", ")) (security/bug-fix minors are not applied automatically)" end) end ),
    ( if ($ins | length) == 0 then empty else
        [ $ins[] | .CACertificateIdentifier as $ca
          | ((($certs[0] // []) | map(select(.CertificateIdentifier == $ca)) | .[0].ValidTill) | ts) as $catill
          | (.CertificateDetails.ValidTill | ts) as $srv
          | {i: .DBInstanceIdentifier, ca: ($ca // "-"), catill: $catill, srv: $srv,
             left: ([$catill, $srv] | map(select(. != null)) | if length == 0 then null else (min - $now) / 86400 end)} ] as $cs
        | ($cs | map(.left) | map(select(. != null))) as $l
        | if ($l | length) == 0 then
            res("versions"; $id; "ca_certificate"; (if err("certs") then "ERROR" else "SKIP" end); ($cs | map(.ca) | unique | join(","));
                if err("certs") then "describe-certificates failed: \(err("certs"))" else "certificate expiry unknown" end)
          else ($l | min) as $min
            | res("versions"; $id; "ca_certificate"; lo($min; $th.cert_warn_days; $th.cert_crit_days);
                  "\($cs | map(.ca) | unique | join(",")), " + (if $min < 0 then "expired \(0 - $min | floor)d ago" else "\($min | floor)d left" end);
                  if $min < 0 then "certificate EXPIRED: clients verifying TLS will fail; rotate the CA"
                  elif $min < $th.cert_warn_days then "certificate expires in \($min | floor) days: rotate the CA (needs restart)"
                  else "earliest CA/server certificate expiry in \($min | floor) days" end)
            | withd($cs | map("\(.i): CA \(.ca) valid till \(.catill | local); server cert till \(.srv | local)")) end end );

# ---------------------------------------------------------------- group: config
def apply_st: if . == "in-sync" then "OK" else "WARN" end;
def g_config($c; $ins):
  ($c.DBClusterIdentifier) as $id | ($c.DBClusterMembers // []) as $mem
  | ( ($mem | map(select(.DBClusterParameterGroupStatus != "in-sync"))) as $bad
      | res("config"; $id; "cluster_param_apply"; (if ($bad | length) > 0 then "WARN" else "OK" end); ($c.DBClusterParameterGroup // "-");
            if ($bad | length) > 0 then "not in-sync: " + ($bad | map("\(.DBInstanceIdentifier)=\(.DBClusterParameterGroupStatus)") | join(", ")) + " (reboot to apply)"
            else "cluster parameter group in-sync on all members" end) ),
    ( if ($ins | length) == 0 then empty else
        ($ins | map(. as $i | .DBParameterGroups[]? | select(.ParameterApplyStatus != "in-sync") | "\($i.DBInstanceIdentifier)=\(.ParameterApplyStatus)")) as $bad
        | res("config"; $id; "instance_param_apply"; (if ($bad | length) > 0 then "WARN" else "OK" end);
              ($ins | map(.DBParameterGroups[]?.DBParameterGroupName) | unique | join(","));
              if ($bad | length) > 0 then "not in-sync: \($bad | join(", ")) (reboot to apply)" else "DB parameter groups in-sync" end) end ),
    res("config"; $id; "deletion_protection"; (if $c.DeletionProtection then "OK" else "WARN" end); ($c.DeletionProtection | yes);
        if $c.DeletionProtection then "deletion protection on" else "deletion protection OFF: the cluster can be deleted by a single API call" end),
    res("config"; $id; "storage_encrypted"; (if $c.StorageEncrypted then "OK" else "WARN" end); ($c.StorageEncrypted | yes);
        if $c.StorageEncrypted then "storage encrypted at rest" else "storage NOT encrypted (fix requires snapshot + encrypted restore)" end),
    res("config"; $id; "iam_db_auth";
        (if $c.IAMDatabaseAuthenticationEnabled then "OK" elif $th.require_iam_auth == 1 then "WARN" else "INFO" end);
        ($c.IAMDatabaseAuthenticationEnabled | yes);
        if $c.IAMDatabaseAuthenticationEnabled then "IAM database authentication enabled" else "IAM database authentication disabled" end),
    ( if ($ins | length) == 0 then empty else
        ($ins | map(select(.PubliclyAccessible == true) | .DBInstanceIdentifier)) as $pub
        | res("config"; $id; "public_access";
              (if ($pub | length) == 0 then "OK" elif $th.public_access_crit == 1 then "CRIT" else "WARN" end);
              (if ($pub | length) == 0 then "none" else ($pub | join(",")) end);
              if ($pub | length) == 0 then "no publicly accessible instances"
              else "publicly accessible: \($pub | join(", ")) (DNS resolves to a public IP; check security groups)" end) end ),
    ( ($c.EnabledCloudwatchLogsExports // []) as $lx
      | res("config"; $id; "log_exports"; (if ($lx | index("postgresql")) then "OK" else "WARN" end);
            (if ($lx | length) > 0 then ($lx | join(",")) else "none" end);
            if ($lx | index("postgresql")) then "postgresql log exported to CloudWatch Logs" else "postgresql log NOT exported to CloudWatch Logs" end) ),
    ( if ($ins | length) == 0 then empty else
        ($ins | map(select(.PerformanceInsightsEnabled != true) | .DBInstanceIdentifier)) as $off
        | ($ins | map(select(.PerformanceInsightsEnabled == true and (.PerformanceInsightsRetentionPeriod // 0) < $th.pi_min_retention_days) | "\(.DBInstanceIdentifier)=\(.PerformanceInsightsRetentionPeriod)d")) as $short
        | res("config"; $id; "performance_insights"; (if ($off | length) + ($short | length) > 0 then "WARN" else "OK" end);
              "\(($ins | length) - ($off | length))/\($ins | length) enabled";
              if ($off | length) > 0 then "Performance Insights off on: \($off | join(", "))"
              elif ($short | length) > 0 then "retention below \($th.pi_min_retention_days)d: \($short | join(", "))"
              else "enabled on all instances" end)
        | withd($ins | map("\(.DBInstanceIdentifier): PI \(.PerformanceInsightsEnabled | yes), retention \(.PerformanceInsightsRetentionPeriod // "-")d, mode \(.DatabaseInsightsMode // "-")")) end ),
    ( if ($ins | length) == 0 then empty else
        ($ins | map(select((.MonitoringInterval // 0) == 0 or .MonitoringInterval > $th.em_max_interval) | "\(.DBInstanceIdentifier)=\(.MonitoringInterval // 0)s")) as $bad
        | res("config"; $id; "enhanced_monitoring"; (if ($bad | length) > 0 then "WARN" else "OK" end);
              ($ins | map(.MonitoringInterval // 0) | unique | map("\(.)s") | join(","));
              if ($bad | length) > 0 then "off or coarser than \($th.em_max_interval)s: \($bad | join(", ")) (0s = disabled)"
              else "enhanced monitoring on all instances" end) end ),
    res("config"; $id; "copy_tags_to_snapshot"; (if $c.CopyTagsToSnapshot then "OK" else "WARN" end); ($c.CopyTagsToSnapshot | yes);
        if $c.CopyTagsToSnapshot then "tags are copied to snapshots" else "tags are NOT copied to snapshots (cost allocation / retention tooling)" end);

# ---------------------------------------------------------------- group: backups
def hm2min: split(":") | (.[0] | tonumber) * 60 + (.[1] | tonumber);
def day_idx: {"mon":0, "tue":1, "wed":2, "thu":3, "fri":4, "sat":5, "sun":6}[ascii_downcase];
# true if the daily backup window overlaps the weekly maintenance window
def windows_overlap($bw; $mw):
  ($bw | split("-")) as $b | ($b[0] | hm2min) as $bs | ($b[1] | hm2min) as $be0
  | (if $be0 <= $bs then $be0 + 1440 else $be0 end) as $be
  | ($mw | split("-") | map(split(":") | {d: (.[0] | day_idx), m: ((.[1] | tonumber) * 60 + (.[2] | tonumber))})) as $m
  | ($m[0].d * 1440 + $m[0].m) as $ms | ($m[1].d * 1440 + $m[1].m) as $me0
  | (if $me0 <= $ms then $me0 + 10080 else $me0 end) as $me
  | any(range(0; 8) as $d | (-10080, 0, 10080) as $sh
        | ($d * 1440 + $bs) as $s | ($d * 1440 + $be) as $e | ($s < $me + $sh and $ms + $sh < $e); .);

def g_backups($c):
  ($c.DBClusterIdentifier) as $id
  | res("backups"; $id; "backup_retention"; lo($c.BackupRetentionPeriod; $th.backup_retention_warn; $th.backup_retention_crit);
        "\($c.BackupRetentionPeriod)d";
        if $c.BackupRetentionPeriod < $th.backup_retention_warn then "point-in-time recovery limited to \($c.BackupRetentionPeriod) day(s); want >= \($th.backup_retention_warn)"
        else "point-in-time recovery window \($c.BackupRetentionPeriod) days" end),
    ( ($c.LatestRestorableTime | ts) as $lrt
      | if $lrt == null then res("backups"; $id; "restore_lag"; "WARN"; "-"; "no LatestRestorableTime: point-in-time restore not available")
        else (($now - $lrt) / 60) as $lag
          | res("backups"; $id; "restore_lag"; hi($lag; $th.restore_lag_warn_min; $th.restore_lag_crit_min); ($lag * 60 | dur);
                "latest restorable time \($lrt | local) (\($lag * 60 | dur) behind)") end ),
    ( (($snaps[0] // {})[$id]) as $s
      | if $s == null then res("backups"; $id; "snapshots"; "ERROR"; ""; "describe-db-cluster-snapshots failed: \(err("snapshots:\($id)") // "no data")")
        else ($s | map(select(.SnapshotType == "automated" and .Status == "available")) | sort_by(.SnapshotCreateTime | ts)) as $auto
          | ($s | map(select(.SnapshotType == "manual")) | sort_by(.SnapshotCreateTime | ts)) as $man
          | ($s | map(select(.SnapshotType == "awsbackup")) | length) as $nb
          | (($now - ($c.ClusterCreateTime | ts // $now)) / 3600) as $cage
          | ( if ($auto | length) == 0 then
                res("backups"; $id; "automated_snapshot"; (if $cage > 48 then "CRIT" else "INFO" end); "none";
                    if $cage > 48 then "no available automated cluster snapshot" else "cluster is new: no automated snapshot yet" end)
              else (($now - ($auto[-1].SnapshotCreateTime | ts)) / 3600) as $age
                | res("backups"; $id; "automated_snapshot"; hi($age; $th.auto_snapshot_warn_hours; $th.auto_snapshot_crit_hours);
                      "\($age * 3600 | dur) old";
                      "newest automated snapshot \($auto[-1].DBClusterSnapshotIdentifier) at \($auto[-1].SnapshotCreateTime | ts | local); \($auto | length) retained") end ),
            ( ($man | length) as $n
              | (if $n > 0 then ($now - ($man[-1].SnapshotCreateTime | ts)) / 86400 else null end) as $mage
              | res("backups"; $id; "manual_snapshots";
                    (if $n > $th.manual_snapshot_count_warn then "WARN"
                     elif $th.manual_snapshot_max_age_days > 0 and ($mage == null or $mage > $th.manual_snapshot_max_age_days) then "WARN"
                     elif $n == 0 then "INFO" else "OK" end);
                    "\($n) manual\(if $nb > 0 then ", \($nb) awsbackup" else "" end)";
                    if $n > $th.manual_snapshot_count_warn then "\($n) manual snapshots (regional quota is 100 by default): prune old ones"
                    elif $n == 0 then "no manual snapshots" + (if $th.manual_snapshot_max_age_days > 0 then " (want one newer than \($th.manual_snapshot_max_age_days)d)" else "" end)
                    else "newest manual snapshot \($man[-1].DBClusterSnapshotIdentifier) is \($mage * 86400 | dur) old"
                         + (if $th.manual_snapshot_max_age_days > 0 and $mage > $th.manual_snapshot_max_age_days then " (older than \($th.manual_snapshot_max_age_days)d)" else "" end) end) )
        end ),
    ( ($c.PreferredBackupWindow // "") as $bw | ($c.PreferredMaintenanceWindow // "") as $mw
      | if $bw == "" then res("backups"; $id; "backup_window"; "INFO"; "-"; "no preferred backup window")
        elif $mw != "" and (try windows_overlap($bw; $mw) catch false) then
          res("backups"; $id; "backup_window"; "WARN"; "\($bw) UTC"; "backup window overlaps maintenance window \($mw) UTC")
        else res("backups"; $id; "backup_window"; "OK"; "\($bw) UTC"; "daily backup window \($bw) UTC; maintenance \($mw) UTC") end );

# ---------------------------------------------------------------- group: metrics
def maxconn($c; $i):
  ($i.DBParameterGroups[0].DBParameterGroupName // "") as $pg
  | (($params[0] // {})[$pg] // [] | map(select(.ParameterName == "max_connections")) | .[0].ParameterValue) as $v
  | (if $i.DBInstanceClass == "db.serverless" then ($c.ServerlessV2ScalingConfiguration.MaxCapacity // null) | (if . then . * 2 * 1073741824 else null end)
     else (($itypes[0] // []) | map(select(.InstanceType == ($i.DBInstanceClass | sub("^db\\."; "")))) | .[0].MemoryInfo.SizeInMiB)
          | (if . then . * 1048576 else null end) end) as $mem
  | if $th.max_connections > 0 then {v: $th.max_connections, src: "max_connections threshold"}
    elif $v == null then null
    elif ($v | test("^[0-9]+$")) then {v: ($v | tonumber), src: "parameter group \($pg)"}
    else ([$v | capture("DBInstanceClassMemory/(?<d>[0-9]+)\\}[ ]*,[ ]*(?<cap>[0-9]+)")] | .[0]) as $f
      | if $f == null or $mem == null then null
        else {v: ([($mem / ($f.d | tonumber) | floor), ($f.cap | tonumber)] | min), src: "estimated from \($v)"} end
    end;

def mstat($r; $d): ($r.Values // []) as $v
  | if ($v | length) == 0 then null
    else {agg: ((if $d.agg == "min" then ($v | min) else ($v | max) end) * $d.f), avg: (($v | add) / ($v | length) * $d.f),
          sum: ($v | add), n: ($v | length)} end;

def g_metrics($c; $ins):
  ($c.DBClusterIdentifier) as $id
  | if err("metrics") then res("metrics"; $id; "metrics"; "ERROR"; ""; "get-metric-data failed: \(err("metrics"))")
    elif ($metrics[0]) == null then res("metrics"; $id; "metrics"; "SKIP"; ""; "no metric data collected")
    else
      ($metrics[0] | map(select(.Label | startswith($id + "|")))) as $rs
      | mdefs[] as $d
      | ($rs | map(select(.Label | endswith("|" + $d.m)))) as $mr
      | if ($mr | length) == 0 then empty else
          [ $mr[] | (.Label | split("|")[1]) as $tg | mstat(.; $d) as $s
            | ($ins | map(select(.DBInstanceIdentifier == $tg)) | .[0]) as $inst
            | if $s == null then {t: $tg, st: "SKIP", v: "no data", sortv: null}
              elif $d.dir == "hi" then {t: $tg, st: hi($s.agg; $th[$d.w]; $th[$d.c]), v: "\($s.agg | fmtu($d.u)) (avg \($s.avg | fmtu($d.u)))", sortv: $s.agg}
              elif $d.dir == "lo" then {t: $tg, st: lo($s.agg; $th[$d.w]; $th[$d.c]), v: "\($s.agg | fmtu($d.u)) (avg \($s.avg | fmtu($d.u)))", sortv: (0 - $s.agg)}
              elif $d.dir == "deadlock" then
                {t: $tg, st: hi($s.agg; $th[$d.w]; $th[$d.c]), v: "~\($s.sum * $period | round) in window (peak \($s.agg | r2)/s)", short: "~\($s.sum * $period | round) deadlocks", sortv: $s.agg}
              elif $d.dir == "conn" then
                (if $inst == null then null else maxconn($c; $inst) end) as $mc
                | if $mc != null then ($s.agg / $mc.v * 100) as $p
                    | {t: $tg, st: hi($p; $th.conn_pct_warn; $th.conn_pct_crit), v: "\($s.agg | round)/\($mc.v) (\($p | r1)%)", sortv: $p, note: $mc.src}
                  elif $th.conn_warn > 0 then
                    {t: $tg, st: hi($s.agg; $th.conn_warn; (if $th.conn_crit > 0 then $th.conn_crit else infinite end)), v: "\($s.agg | round)", sortv: $s.agg, note: "absolute threshold"}
                  else {t: $tg, st: "INFO", v: "\($s.agg | round) (max_connections unknown)", sortv: $s.agg} end
              else {t: $tg, st: "INFO", v: "peak \($s.agg | r2) \($d.u), avg \($s.avg | r2)", short: "peak \($s.agg | r2) \($d.u)", sortv: $s.agg} end ] as $per
          | ($per | map(.st) | worst) as $st
          | ($per | map(select(.st == $st)) | max_by(.sortv // -1e18)) as $top
          | res("metrics"; $id; $d.m; $st; "\($top.short // ($top.v | split(" (avg")[0])) on \($top.t)";
                if $st == "SKIP" then "no datapoints in the lookback window"
                elif $st == "OK" or $st == "INFO" then "\($d.stat) per \($period)s over lookback, worst: \($top.t)"
                else "\($top.t) beyond \($st | ascii_downcase) threshold"
                     + (if $d.dir == "hi" or $d.dir == "deadlock" then " (\($d.w)=\($th[$d.w]), \($d.c)=\($th[$d.c]))"
                        elif $d.dir == "lo" then " (\($d.w)=\($th[$d.w]), \($d.c)=\($th[$d.c]))"
                        elif $d.dir == "conn" then " (\($top.note // ""))" else "" end) end)
          | withd($per | map("\(.t): \(.v) [\(.st)]\(if .note then " - " + .note else "" end)")) end
    end;

# ---------------------------------------------------------------- group: events
def ev_sev: (.EventCategories // []) as $cat | (.Message // "") as $m
  | if ($cat | index("failure")) or ($cat | index("low storage")) then "CRIT"
    elif ($cat | index("failover")) or ($m | test("fail(ed)? ?over"; "i")) then "WARN"
    elif ($cat | index("availability")) or ($cat | index("recovery")) or ($m | test("reboot|restart|shut ?down"; "i")) then "WARN"
    else "INFO" end;
def g_events($c; $ins):
  ($c.DBClusterIdentifier) as $id | ([$id] + ($ins | map(.DBInstanceIdentifier))) as $src
  | if ($events[0]) == null then res("events"; $id; "recent_events"; "ERROR"; ""; "describe-events failed: \(err("events") // "no data")")
    else ($events[0] | map(select(.SourceIdentifier as $s | $src | index($s))) | sort_by(.Date | ts) | reverse
          | map(. + {sev: ev_sev, fo: ((.EventCategories // [] | index("failover")) != null or ((.Message // "") | test("fail(ed)? ?over"; "i")))})) as $ev
      | ($ev | map(select(.fo)) | length) as $nf
      | ($ev | map(select(.EventCategories // [] | index("failure"))) | length) as $nfail
      | (if $nf > $th.failover_crit_count then "CRIT" else ($ev | map(.sev) | worst) end) as $st
      | res("events"; $id; "recent_events"; (if ($ev | length) == 0 then "OK" elif $st == "OK" then "INFO" else $st end);
            "\($ev | length) event(s), \($nf) failover event(s)";
            if ($ev | length) == 0 then "no events in the last \($lookback_events | dur)"
            else "last \($lookback_events | dur): " + ($ev | map(.EventCategories // [] | .[]) | group_by(.) | map("\(.[0])=\(length)") | join(", "))
                 + (if $nfail > 0 then "; \($nfail) failure event(s)" else "" end) end)
      | withd($ev[0:$th.events_show] | map("\(.Date | ts | local) \(.SourceIdentifier) [\((.EventCategories // []) | join(","))] \(.Message)"))
    end;

# ---------------------------------------------------------------- mode: evaluate
def evaluate:
  ($clusters[0] // []) as $all
  | { results: [
        ( if err("clusters") then res("cluster"; "(region)"; "describe_db_clusters"; "ERROR"; "";
                                     "describe-db-clusters failed: \(err("clusters"))") else empty end ),
        ( $all[] | select(.Engine != "aurora-postgresql")
          | res("cluster"; .DBClusterIdentifier; "engine"; "WARN"; .Engine; "engine is \(.Engine), not aurora-postgresql: skipped") ),
        ( pg_clusters[] as $c | insts_of($c) as $ins
          | (if on("cluster")  then g_cluster($c; $ins)  else empty end),
            (if on("versions") then g_versions($c; $ins) else empty end),
            (if on("config")   then g_config($c; $ins)   else empty end),
            (if on("backups")  then g_backups($c)        else empty end),
            (if on("metrics")  then g_metrics($c; $ins)  else empty end),
            (if on("events")   then g_events($c; $ins)   else empty end) ) ],
      clusters: [ pg_clusters[] as $c | insts_of($c) as $ins
                  | {region: $region, cluster: $c.DBClusterIdentifier, engine_version: $c.EngineVersion, status: $c.Status,
                     instances: ([$ins | length, ($c.DBClusterMembers // [] | length)] | max),
                     writers: ($c.DBClusterMembers // [] | map(select(.IsClusterWriter)) | length),
                     readers: ($c.DBClusterMembers // [] | map(select(.IsClusterWriter | not)) | length),
                     serverless: ($c.ServerlessV2ScalingConfiguration != null)} ] };

if $mode == "queries" then queries else evaluate end
