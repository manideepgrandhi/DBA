# inventory.jq - model, grouping and rendering for rds_inventory_report.sh (read-only, no CloudWatch).
# jq --arg mode M --argjson now EPOCH --argjson cfg {...} -f inventory.jq
#   build     : raw  {meta, regions:[region records], errors}  -> report {meta, groups, rows, errors}
#   finalize  : report -> report + summary
#   text|csv|csv_summary|html|json : rendering

def ts:
  if . == null or . == "" then null
  else ([capture("^(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2})[T ](?<t>[0-9]{2}:[0-9]{2}:[0-9]{2})(?<f>\\.[0-9]+)?(?<z>Z|[+-][0-9]{2}:?[0-9]{2})?$")?] | .[0]) as $c
    | if $c == null then null
      else (($c.d + "T" + $c.t + "Z") | fromdateiso8601)
           - (if ($c.z // "Z") == "Z" then 0
              else ($c.z | gsub("[^0-9]"; "")) as $n
                   | (($n[0:2] | tonumber) * 3600 + ($n[2:4] | tonumber) * 60) * (if ($c.z | startswith("-")) then -1 else 1 end) end)
      end
  end;
def day(e): if e == null then null else (e | floor | strftime("%Y-%m-%d")) end;
def esc: tostring | gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;") | gsub("\""; "&quot;") | gsub("'"; "&#39;");
def tagsobj: (. // []) | map({key: .Key, value: (.Value // "")}) | from_entries;
def glob2re: "^" + (gsub("(?<c>[.+^$(){}|\\[\\]\\\\])"; "\\\(.c)") | gsub("\\*"; ".*") | gsub("\\?"; ".")) + "$";
def globmatch($globs): . as $s | ($globs | length) == 0 or any($globs[]; . as $g | ($s // "" | ascii_downcase) | test($g | ascii_downcase | glob2re));
def arnpart($i): (. // "") | split(":") | .[$i] // "";
def lastpart: (. // "") | split(":") | .[-1];
def uniq_nonempty: map(select(. != null and . != "")) | unique;

def major($engine; $v):
  ($v // "") as $v
  | if ($engine | test("^aurora-mysql")) then ($v | split(".") | .[0:2] | join("."))
    elif ($engine | test("postgres")) then ($v | split(".") | if (.[0] | tonumber? // 0) >= 10 then .[0] else (.[0:2] | join(".")) end)
    elif ($engine | test("^oracle|^db2")) then ($v | split(".") | .[0])
    else ($v | split(".") | .[0:2] | join(".")) end;

# static class table (approximate, from published instance sizes; no API call)
def classinfo($c):
  if $c == null or $c == "" then {vcpu: null, mem: null}
  elif $c == "db.serverless" then {vcpu: null, mem: null}
  else ($c | split(".")) as $p | ($p[1] // "") as $fam | ($p[2] // "") as $size
    | ({"micro": 2, "small": 2, "medium": 2, "large": 2, "xlarge": 4, "2xlarge": 8, "4xlarge": 16, "8xlarge": 32, "12xlarge": 48,
        "16xlarge": 64, "24xlarge": 96, "32xlarge": 128, "48xlarge": 192}[$size]) as $v
    | if $v == null then {vcpu: null, mem: null}
      elif ($fam | test("^t")) then {vcpu: (if $size == "xlarge" then 4 elif $size == "2xlarge" then 8 else 2 end),
                                    mem: ({"micro": 1, "small": 2, "medium": 4, "large": 8, "xlarge": 16, "2xlarge": 32}[$size])}
      elif ($fam | test("^(x2|x1e)")) then {vcpu: $v, mem: ($v * 16)}
      elif ($fam | test("^(r|z1d|x)")) then {vcpu: $v, mem: ($v * 8)}
      elif ($fam | test("^m")) then {vcpu: $v, mem: ($v * 4)}
      elif ($fam | test("^c")) then {vcpu: $v, mem: ($v * 2)}
      else {vcpu: $v, mem: null} end
  end;

def lifecycle($R; $engine; $maj):
  ($R.lifecycle[$engine][$maj] // null) as $l
  | if $l == null then {std_end: null, ext_end: null, support_status: "unknown"}
    else ($l.std_end | ts) as $se | ($l.ext_end | ts) as $ee
      | {std_end: day($se), ext_end: day($ee),
         support_status: (if $se == null then "unknown"
                          elif $now > $se then (if $ee != null and $now > $ee then "past extended support" else "extended support (past standard end)" end)
                          elif $se - $now < $cfg.support_warn_days * 86400 then "standard support ends \(day($se))"
                          else "standard" end),
         past_std: ($se != null and $now > $se),
         std_soon: ($se != null and $now <= $se and $se - $now < $cfg.support_warn_days * 86400)}
    end;

def pma($R; $arn):
  [($R.pma // [])[] | select(.ResourceIdentifier == $arn) | .PendingMaintenanceActionDetails[]?
    | {action: .Action, description: (.Description // ""), auto_applied_after: day(.AutoAppliedAfterDate | ts), forced_apply: day(.ForcedApplyDate | ts),
       current_apply: day(.CurrentApplyDate | ts), opt_in: (.OptInStatus // null)}];
def pma_text: map(.action + (if .current_apply then " @" + .current_apply elif .auto_applied_after then " auto " + .auto_applied_after elif .forced_apply then " forced " + .forced_apply else "" end)) | join("; ");

def ssl($R; $kind; $group):
  if $cfg.fast then {value: "skipped (--fast)", enforced: null}
  elif $group == null or $group == "" then {value: "", enforced: null}
  else ($R.params[$kind + ":" + $group] // null) as $p
    | if $p == null then {value: "unknown", enforced: null}
      elif $p.error then {value: "lookup failed", enforced: null}
      elif ($p.params | length) == 0 then {value: "n/a", enforced: null}
      else ($p.params | map("\(.name)=\(.value // "engine-default")") | join(", ")) as $t
        | {value: $t, enforced: (if any($p.params[]; (.value // "") | test("^(1|ON|on|true)$")) then true
                                 elif any($p.params[]; (.value // "") | test("^(0|OFF|off|false)$")) then false else null end)}
      end
  end;

def ca($R; $x):
  ($x.CertificateDetails.CAIdentifier // $x.CACertificateIdentifier // null) as $id
  | ($x.CertificateDetails.ValidTill // ($R.certs // [] | map(select(.CertificateIdentifier == $id)) | .[0].ValidTill) // null) as $vt
  | {ca: $id, valid_till: day($vt | ts), ca_days: (if ($vt | ts) == null then null else ((($vt | ts) - $now) / 86400 | floor) end)};

def is_prod($tags): (($tags[$cfg.prod_tag_key] // "") | test($cfg.prod_regex));

# common fields of a cluster or instance row
def base($R; $x; $kind):
  ($x.TagList | tagsobj) as $tags
  | major($x.Engine; $x.EngineVersion) as $maj
  | ($x.InstanceCreateTime // $x.ClusterCreateTime | ts) as $cr
  | lifecycle($R; $x.Engine; $maj) as $lc
  | {kind: $kind, account: $R.account, profile: $R.profile, region: $R.region, engine: $x.Engine, version: ($x.EngineVersion // ""), major: $maj,
     created: day($cr), age_days: (if $cr == null then null else (($now - $cr) / 86400 | floor) end),
     engine_lifecycle_support: ($x.EngineLifecycleSupport // ""), standard_support_end: $lc.std_end, extended_support_end: $lc.ext_end,
     support_status: $lc.support_status, _past_std: ($lc.past_std // false), _std_soon: ($lc.std_soon // false),
     encrypted: ($x.StorageEncrypted // false), kms_key: ($x.KmsKeyId // ""), iam_auth: ($x.IAMDatabaseAuthenticationEnabled // false),
     deletion_protection: ($x.DeletionProtection // false), performance_insights: ($x.PerformanceInsightsEnabled // false),
     pi_retention_days: ($x.PerformanceInsightsRetentionPeriod // null), monitoring_interval: ($x.MonitoringInterval // 0),
     log_exports: ($x.EnabledCloudwatchLogsExports // []), database_insights: ($x.DatabaseInsightsMode // ""),
     retention_days: ($x.BackupRetentionPeriod // null), backup_window: ($x.PreferredBackupWindow // ""), maintenance_window: ($x.PreferredMaintenanceWindow // ""),
     security_groups: [($x.VpcSecurityGroups // [])[] | .VpcSecurityGroupId], public: ($x.PubliclyAccessible // false),
     tags: $tags, _prod: is_prod($tags)};

def ninst($R; $i):
  classinfo($i.DBInstanceClass) as $ci | ca($R; $i) as $ca
  | base($R; $i; "instance") + {name: $i.DBInstanceIdentifier, arn: $i.DBInstanceArn, cluster: ($i.DBClusterIdentifier // ""),
     class: ($i.DBInstanceClass // ""), vcpu: $ci.vcpu, memory_gib: $ci.mem,
     storage_type: ($i.StorageType // ""), allocated_gb: ($i.AllocatedStorage // null), iops: ($i.Iops // null), throughput: ($i.StorageThroughput // null),
     max_allocated_gb: ($i.MaxAllocatedStorage // null), multi_az: ($i.MultiAZ // false), az: ($i.AvailabilityZone // ""), secondary_az: ($i.SecondaryAvailabilityZone // ""),
     promotion_tier: ($i.PromotionTier // null), endpoint: ($i.Endpoint.Address // ""), port: ($i.Endpoint.Port // $i.DbInstancePort // null),
     vpc: ($i.DBSubnetGroup.VpcId // ""), subnet_group: ($i.DBSubnetGroup.DBSubnetGroupName // ""),
     ca_cert: $ca.ca, ca_valid_till: $ca.valid_till, _ca_days: $ca.ca_days,
     auto_minor_upgrade: ($i.AutoMinorVersionUpgrade // false), pending_maintenance: pma($R; $i.DBInstanceArn),
     parameter_group: (($i.DBParameterGroups // [])[0].DBParameterGroupName // ""), parameter_group_status: (($i.DBParameterGroups // [])[0].ParameterApplyStatus // ""),
     option_group: ([($i.OptionGroupMemberships // [])[] | .OptionGroupName] | join(",")),
     status: ($i.DBInstanceStatus // ""), automatic_restart: day($i.AutomaticRestartTime | ts),
     replica_source: ($i.ReadReplicaSourceDBInstanceIdentifier // $i.ReadReplicaSourceDBClusterIdentifier // ""),
     replicas: (($i.ReadReplicaDBInstanceIdentifiers // []) + ($i.ReadReplicaDBClusterIdentifiers // [])),
     ssl: (if ($i.DBClusterIdentifier // "") == "" then ssl($R; "db"; (($i.DBParameterGroups // [])[0].DBParameterGroupName)) else {value: "(cluster parameter group)", enforced: null} end)}
  | if .cluster != "" then . + {allocated_gb: null, iops: null, throughput: null, max_allocated_gb: null, retention_days: null, backup_window: "", storage_type: ""} else . end;

def ncluster($R; $c):
  ca($R; $c) as $ca
  | (($c.Engine | test("^aurora")) and (($c.EngineMode // "provisioned") != "serverless")) as $aur
  | ($c.ServerlessV2ScalingConfiguration // null) as $sv2
  | base($R; $c; "cluster") + {name: $c.DBClusterIdentifier, arn: $c.DBClusterArn,
     cluster_type: (if ($c.Engine | test("^(docdb)")) then "DocumentDB cluster" elif ($c.Engine | test("^neptune")) then "Neptune cluster"
                    elif ($c.Engine | test("^aurora")) then "Aurora cluster" else "Multi-AZ DB cluster" end),
     mode: (if ($c.EngineMode // "") == "serverless" then "serverless v1" elif $sv2 != null then "provisioned + serverless v2" else ($c.EngineMode // "provisioned") end),
     acu_min: ($sv2.MinCapacity // $c.ScalingConfigurationInfo.MinCapacity // null), acu_max: ($sv2.MaxCapacity // $c.ScalingConfigurationInfo.MaxCapacity // null),
     class: ($c.DBClusterInstanceClass // ""), storage_type: ($c.StorageType // (if $aur then "aurora" else "" end)),
     allocated_gb: (if $aur then null else ($c.AllocatedStorage // null) end), iops: ($c.Iops // null), throughput: ($c.StorageThroughput // null),
     multi_az: ($c.MultiAZ // false), azs: ($c.AvailabilityZones // []),
     endpoint: ($c.Endpoint // ""), reader_endpoint: ($c.ReaderEndpoint // ""), port: ($c.Port // null),
     custom_endpoints: [($R.endpoints // [])[] | select(.DBClusterIdentifier == $c.DBClusterIdentifier and (.EndpointType // "") == "CUSTOM")
                        | {endpoint: .Endpoint, type: (.CustomEndpointType // ""), static: (.StaticMembers // []), excluded: (.ExcludedMembers // []), status: (.Status // "")}],
     subnet_group: ($c.DBSubnetGroup // ""), ca_cert: $ca.ca, ca_valid_till: $ca.valid_till, _ca_days: $ca.ca_days,
     auto_minor_upgrade: ($c.AutoMinorVersionUpgrade // null), pending_maintenance: pma($R; $c.DBClusterArn),
     parameter_group: ($c.DBClusterParameterGroup // ""), status: ($c.Status // ""), automatic_restart: day($c.AutomaticRestartTime | ts),
     global_cluster: ($c.GlobalClusterIdentifier // ""), replication_source: ($c.ReplicationSourceIdentifier // ""),
     ssl: ssl($R; "cluster"; $c.DBClusterParameterGroup),
     _members: ($c.DBClusterMembers // [])};

def flags:
  . as $r
  | [ (if $r.public then "PUBLIC" else empty end),
      (if $r.kind != "global" and ($r.encrypted | not) and ($r.kind == "cluster" or $r.cluster == "") then "UNENCRYPTED" else empty end),
      (if ($r.kind == "cluster" or ($r.kind == "instance" and $r.cluster == "")) and ($r.deletion_protection | not) then "NO_DELETION_PROTECTION" else empty end),
      (if $r._prod and (($r.kind == "instance" and $r.cluster == "" and $r.replica_source == "" and ($r.multi_az | not))
                        or ($r.kind == "cluster" and $r._single_az == true)) then "SINGLE_AZ_PROD" else empty end),
      (if $r._ca_days != null and $r._ca_days < $cfg.ca_days then "CA_EXPIRING" else empty end),
      (if ($r.kind == "cluster" or $r.cluster == "") and $r._past_std then "EXTENDED_SUPPORT" elif ($r.kind == "cluster" or $r.cluster == "") and $r._std_soon then "SUPPORT_ENDING" else empty end),
      (if $r.kind == "instance" and ($r.performance_insights | not) and ($r.engine | test("^(docdb|neptune)") | not) then "PI_OFF" else empty end),
      (if ($r.kind == "cluster" or ($r.kind == "instance" and $r.cluster == "" and $r.replica_source == "")) and ($r.retention_days // 99) < 7 then "RETENTION_LT_7" else empty end),
      (if (($r.status // "") | test("^stopped")) then "STOPPED_AUTO_RESTART" else empty end)
    ] | unique;

def finish_row($g; $gt; $level; $role): . + {group: $g, group_type: $gt, level: $level, role: $role} | . + {flags: flags};

def wanted_row: (.engine | globmatch($cfg.engines)) and ($cfg.include_docdb or ((.engine // "") | test("^(docdb|neptune)") | not));

# ------------------------------------------------------------------ build
def build:
  . as $raw
  | [$raw.regions[] as $R | ($R.instances // [])[] | ninst($R; .)] as $INST
  | [$raw.regions[] as $R | ($R.clusters // [])[] | ncluster($R; .)] as $CL
  | ($INST | map({key: .arn, value: .}) | from_entries) as $IBYARN
  | def members($c):
      [$c._members[] as $m | ($INST[] | select(.account == $c.account and .region == $c.region and .name == $m.DBInstanceIdentifier))
       + {_writer: ($m.IsClusterWriter // false), promotion_tier: ($m.PromotionTier // .promotion_tier), parameter_group_status: ($m.DBClusterParameterGroupStatus // .parameter_group_status)}]
      | sort_by((if ._writer then 0 else 1 end), (.promotion_tier // 99), .name);
    def cluster_rows($c; $g; $gt; $lvl; $role):
      members($c) as $mem
      | ($mem | map(.az) | uniq_nonempty) as $azs
      | ($c + {vpc: ($mem[0].vpc // ""), reader_count: ([$mem[] | select(._writer | not)] | length), member_count: ($mem | length),
               member_azs: $azs, _single_az: (($c.cluster_type == "Aurora cluster" or ($c.cluster_type | test("DocumentDB|Neptune"))) and ($azs | length) < 2 and ($mem | length) > 0)}
         | finish_row($g; $gt; $lvl; $role)),
        ($mem[] | finish_row($g; $gt; $lvl + 1; (if ._writer then "writer" else "reader" end)));
  # globals (dedup by account + id)
  ([$raw.regions[] as $R | ($R.globals // [])[] | . + {_account: $R.account, _profile: $R.profile}]
     | group_by([._account, .GlobalClusterIdentifier]) | map(.[0])) as $GL
  | ([$GL[] | .GlobalClusterMembers[]?.DBClusterArn]) as $garns
  | ($CL | map(select(wanted_row))) as $CLW
  | [ $GL[] | . as $gx
      | select(($gx.Engine // "") | globmatch($cfg.engines))
      | "global/\($gx._account)/\($gx.GlobalClusterIdentifier)" as $g
      | ([$gx.GlobalClusterMembers[]? | . as $m
           | ($CL | map(select(.arn == $m.DBClusterArn)) | .[0]) as $c
           | {m: $m, c: $c, region: ($m.DBClusterArn | arnpart(3))}]
         | sort_by((if .m.IsWriter then 0 else 1 end), .region)) as $mm
      | select(($cfg.identifiers | length) == 0 or ([$gx.GlobalClusterIdentifier, ($mm[] | .c.name // empty), ($mm[] | .c | select(. != null) | members(.)[] | .name)] | any(globmatch($cfg.identifiers))))
      | ($gx.TagList | tagsobj) as $gt
      | {key: $g, type: "global", title: $gx.GlobalClusterIdentifier, account: $gx._account,
         rows: ([{kind: "global", account: $gx._account, profile: $gx._profile, region: ([$mm[] | .region] | join(",")), name: $gx.GlobalClusterIdentifier,
                  arn: ($gx.GlobalClusterArn // ""), engine: ($gx.Engine // ""), version: ($gx.EngineVersion // ""), major: major($gx.Engine // ""; $gx.EngineVersion),
                  endpoint: ($gx.Endpoint // ""), encrypted: ($gx.StorageEncrypted // false), deletion_protection: ($gx.DeletionProtection // false),
                  status: ($gx.Status // ""), engine_lifecycle_support: ($gx.EngineLifecycleSupport // ""),
                  primary_region: ([$mm[] | select(.m.IsWriter) | .region] | join(",")),
                  secondary_regions: [$mm[] | select(.m.IsWriter | not) | .region],
                  member_clusters: [$mm[] | .m.DBClusterArn | lastpart], failover_state: ($gx.FailoverState // null),
                  tags: $gt, public: false, _prod: is_prod($gt)} | . + {group: $g, group_type: "global", level: 0, role: "global", flags: []}]
               + [$mm[] | if .c == null then {kind: "cluster", account: $gx._account, region: .region, name: (.m.DBClusterArn | lastpart), arn: .m.DBClusterArn,
                                              engine: $gx.Engine, version: "", major: "", status: "not scanned (region/account not in scope)", tags: {}, group: $g, group_type: "global", level: 1,
                                              role: (if .m.IsWriter then "primary" else "secondary" end), flags: [], not_scanned: true}
                          else cluster_rows(.c; $g; "global"; 1; (if .m.IsWriter then "primary" else "secondary" end)) end])} ] as $GG
  | [ $CLW[] | select((.arn as $a | $garns | index($a)) == null)
      | . as $c | select(($cfg.identifiers | length) == 0 or ([$c.name, (members($c)[] | .name)] | any(globmatch($cfg.identifiers))))
      | "cluster/\($c.account)/\($c.region)/\($c.name)" as $g
      | {key: $g, type: "cluster", title: $c.name, account: $c.account, rows: [cluster_rows($c; $g; "cluster"; 0; "cluster")]} ] as $CG
  # standalone instances + replicas (linked by id in-region, by ARN cross-region)
  | ($INST | map(select(.cluster == "" and wanted_row))) as $SA
  | def srcof($r): if $r.replica_source == "" then null
                   elif ($r.replica_source | startswith("arn:")) then ($IBYARN[$r.replica_source] // null)
                   else ($SA | map(select(.account == $r.account and .region == $r.region and .name == $r.replica_source)) | .[0]) end;
    def root($r; $d): (srcof($r)) as $s | if $s == null or $d > 4 then $r else root($s; $d + 1) end;
  ([$SA[] | . as $r | root($r; 0) as $o | {r: $r, root: $o.arn}] | group_by(.root)) as $SG0
  | [ $SG0[] | . as $grp
      | ($grp | map(select(.r.arn == .root)) | .[0].r) as $src
      | ($src // ($grp[0].r)) as $head
      | "standalone/\($head.account)/\($head.region)/\($head.name)" as $g
      | select(($cfg.identifiers | length) == 0 or ([$grp[].r.name] | any(globmatch($cfg.identifiers))))
      | {key: $g, type: "standalone", title: $head.name, account: $head.account,
         rows: ([$head | finish_row($g; "standalone"; 0; (if .replica_source != "" then "replica (source not scanned)" else "primary" end))]
                + [$grp[].r | select(.arn != $head.arn) | . as $x
                   | finish_row($g; "standalone"; 1; (if $x.region != $head.region then "cross-region replica" else "read replica" end))
                   | . + {_order: [(if .region == $head.region then 0 else 1 end), .region, .name]}] | sort_by(._order // []) | map(del(._order)))} ] as $SGG
  | ([$GG[], $CG[], $SGG[]]
     | sort_by((if .type == "global" then 0 elif .type == "cluster" then 1 else 2 end), .account, (.rows[0].region // ""), .title)) as $groups
  | {meta: $raw.meta, errors: $raw.errors,
     groups: [$groups[] | . + {region: (.rows[0].region), engine: (.rows[0].engine), flag_count: ([.rows[].flags[]] | length)}
              | .rows |= [to_entries[] | .value + {seq: (.key + 1)} | with_entries(select(.key | startswith("_") | not))]]};

# ------------------------------------------------------------------ summary
def countby(f): group_by(f) | map({key: (.[0] | f | tostring), count: length}) | sort_by(-.count, .key);
def finalize:
  . as $r | [.groups[].rows[]] as $rows
  | [$rows[] | select(.kind == "instance")] as $I
  | [$rows[] | select(.kind != "global" and (.not_scanned | not))] as $RES
  | $r + {summary: {
      groups: (.groups | length),
      by_type: ([$rows[] | select(.not_scanned | not) | if .kind == "global" then "Global cluster" elif .kind == "cluster" then .cluster_type
                 elif .cluster != "" then "Cluster member instance" elif .replica_source != "" then "Read replica" else "Standalone instance" end] | countby(.)),
      by_account: ($RES | countby(.account)), by_region: ($RES | countby(.region)), by_engine: ($RES | countby(.engine)),
      by_major: ($RES | countby("\(.engine) \(.major)")), by_class: ($I | countby(.class)),
      instances: ($I | length), clusters: ([$RES[] | select(.kind == "cluster")] | length),
      global_clusters: ([$rows[] | select(.kind == "global")] | length),
      allocated_gb: ([$RES[] | select(.kind == "instance" and .cluster == "" or (.kind == "cluster" and .allocated_gb != null)) | .allocated_gb // 0] | add // 0),
      vcpu_total: ([$I[].vcpu // 0] | add // 0), memory_gib_total: ([$I[].memory_gib // 0] | add // 0),
      flags: ([$rows[] | . as $x | .flags[] | {f: ., n: "\($x.account)/\($x.region)/\($x.name)"}] | group_by(.f)
              | map({flag: .[0].f, count: length, examples: ([.[].n] | .[0:$cfg.top_n])}) | sort_by(-.count, .flag)),
      errors: (.errors | length)}};

# ------------------------------------------------------------------ rendering helpers
def yn: if . == true then "yes" elif . == false then "no" else (. // "") | tostring end;
def v: if . == null then "" elif type == "array" then (map(if type == "object" then (.endpoint // .action // tostring) else tostring end) | join(", ")) elif type == "boolean" then yn else tostring end;
def flagdesc: {PUBLIC: "publicly accessible", UNENCRYPTED: "storage not encrypted", NO_DELETION_PROTECTION: "deletion protection off",
               SINGLE_AZ_PROD: "single-AZ while tagged prod", CA_EXPIRING: "CA certificate expires within \($cfg.ca_days) days",
               EXTENDED_SUPPORT: "major past end of standard support (RDS Extended Support charges)", SUPPORT_ENDING: "standard support ends within \($cfg.support_warn_days) days",
               PI_OFF: "Performance Insights off", RETENTION_LT_7: "backup retention < 7 days", STOPPED_AUTO_RESTART: "stopped - RDS restarts it automatically after 7 days"};
def fields:
  [["Engine", "\(.engine) \(.version)"], ["Major", .major], ["Mode", .mode], ["ACU min/max", (if .acu_min != null then "\(.acu_min) / \(.acu_max)" else null end)],
   ["Class", .class], ["vCPU / memory (static table)", (if .vcpu != null then "\(.vcpu) vCPU / \(.memory_gib // "?") GiB" else null end)],
   ["Storage", ([.storage_type, (if .allocated_gb != null then "\(.allocated_gb) GB" else empty end), (if .iops != null then "\(.iops) IOPS" else empty end),
                 (if .throughput != null then "\(.throughput) MiB/s" else empty end), (if .max_allocated_gb != null then "max \(.max_allocated_gb) GB" else empty end)] | map(select(. != null and . != "")) | join(" · "))],
   ["Multi-AZ", .multi_az], ["AZ", ([.az, .secondary_az] | map(select(. != null and . != "")) | join(" / "))], ["AZs", .azs], ["Member AZs", .member_azs],
   ["Readers", .reader_count], ["Promotion tier", .promotion_tier],
   ["Endpoint", .endpoint], ["Reader endpoint", .reader_endpoint], ["Custom endpoints", (.custom_endpoints // [] | map("\(.endpoint) (\(.type); static: \(.static | join(",")))\(if (.excluded | length) > 0 then " excl: " + (.excluded | join(",")) else "" end)") | join("; "))],
   ["Port", .port], ["VPC", .vpc], ["Subnet group", .subnet_group], ["Security groups", .security_groups], ["Public", .public],
   ["Encrypted", .encrypted], ["KMS key", .kms_key], ["IAM auth", .iam_auth], ["Deletion protection", .deletion_protection],
   ["CA cert", (if .ca_cert then "\(.ca_cert) (valid till \(.ca_valid_till // "?"))" else null end)], ["SSL enforcement (param group)", .ssl.value],
   ["Backup retention", (if .retention_days != null then "\(.retention_days) days" else null end)], ["Backup window", .backup_window], ["Maintenance window", .maintenance_window],
   ["Auto minor upgrade", .auto_minor_upgrade], ["Pending maintenance", (.pending_maintenance // [] | pma_text)],
   ["Parameter group", (if (.parameter_group // "") != "" then .parameter_group + (if (.parameter_group_status // "") != "" then " (\(.parameter_group_status))" else "" end) else null end)],
   ["Option group", .option_group], ["Performance Insights", (if .kind == "global" then null elif .performance_insights then "on (\(.pi_retention_days // "?") days)" else "off" end)],
   ["Enhanced monitoring", (if (.monitoring_interval // 0) > 0 then "\(.monitoring_interval)s" elif .kind == "global" then null else "off" end)],
   ["Log exports", .log_exports], ["Database Insights", .database_insights],
   ["Status", .status], ["Auto restart", .automatic_restart], ["Created", (if .created then "\(.created) (\(.age_days) days)" else null end)],
   ["Lifecycle", ([.engine_lifecycle_support, .support_status, (if .standard_support_end then "std end \(.standard_support_end)" else empty end),
                   (if .extended_support_end then "ext end \(.extended_support_end)" else empty end)] | map(select(. != null and . != "" and . != "unknown")) | join(" · "))],
   ["Global cluster", .global_cluster], ["Primary region", .primary_region], ["Secondary regions", .secondary_regions], ["Member clusters", .member_clusters],
   ["Replication source", (.replica_source // .replication_source)], ["Replicas", .replicas],
   ["ARN", .arn], ["Tags", (.tags // {} | to_entries | map("\(.key)=\(.value)") | join(", "))]]
  | map(select((.[1] | v) != "") | [.[0], (.[1] | v)]);

def role_label: if .role == "global" then "GLOBAL CLUSTER" elif .kind == "cluster" then "\(.cluster_type // "cluster") [\(.role)]" else "instance [\(.role)]" end;

def text:
  .meta as $m | .summary as $s
  | "RDS INVENTORY REPORT  (\($m.script) v\($m.version), read-only, no CloudWatch)",
    "Generated: \($m.generated_local) | \($m.generated_utc)",
    "Accounts : \([$m.accounts[] | "\(.account) (\(.profile))"] | join(", "))",
    "Regions  : \($m.regions | join(", "))" + (if $m.filters_text != "" then "   Filters: \($m.filters_text)" else "" end),
    "",
    "== SUMMARY",
    "Totals   : \($s.groups) group(s) | \($s.global_clusters) global cluster(s) | \($s.clusters) cluster(s) | \($s.instances) instance(s) | allocated \($s.allocated_gb) GB (instances + Multi-AZ clusters; Aurora storage is dynamic and not included) | \($s.vcpu_total) vCPU / \($s.memory_gib_total) GiB (static class table, provisioned only)",
    "By type  : \($s.by_type | map("\(.key) \(.count)") | join(" | "))",
    "Account  (resources): \($s.by_account | map("\(.key) \(.count)") | join(" | "))",
    "Region   (resources): \($s.by_region | map("\(.key) \(.count)") | join(" | "))",
    "Engine   : \($s.by_engine | map("\(.key) \(.count)") | join(" | "))",
    "Major    : \($s.by_major | map("\(.key) \(.count)") | join(" | "))",
    "Class    : \($s.by_class | map("\(.key) \(.count)") | join(" | "))",
    "Risk flags:",
    (if ($s.flags | length) == 0 then "  none" else ($s.flags[] | "  \(.flag | . + " " * (22 - length)) \(.count | tostring | . + " " * (4 - length)) \(flagdesc[.flag])  e.g. \(.examples[0:4] | join(", "))") end),
    (if $s.errors > 0 then "ERRORS   : \($s.errors) AWS call(s) failed - see the end of the report" else empty end),
    "",
    "== GROUPS (global cluster -> regional clusters -> member instances; standalone primary -> replicas)",
    (.groups[] |
      "",
      "#### [\(.type | ascii_upcase)] \(.title)  (\(.account) \(.region))  \(.rows | length) resource(s)\(if .flag_count > 0 then "  !! \([.rows[].flags[]] | unique | join(","))" else "" end)",
      (.rows[] | ("    " * .level) as $ind
        | "\($ind)\(if .level == 0 then "■" else "└─" end) \(role_label): \(.name)  [\(.engine) \(.version)\(if .class != null and .class != "" then ", " + .class else "" end)\(if .region != null then ", " + .region else "" end)]  \(.status // "")\(if (.flags | length) > 0 then "  !! " + (.flags | join(",")) else "" end)",
          (fields | map(select(.[0] != "Engine" and .[0] != "Class" and .[0] != "Status")) | _nwise(4) | "\($ind)     " + (map("\(.[0]): \(.[1])") | join(" | "))))),
    (if (.errors | length) > 0 then "", "== ERRORS", (.errors[] | "  \(.profile)/\(.region) \(.call): \(.message)") else empty end);

def csvq: map(if . == null then "" elif type == "array" then (map(if type == "object" then (.endpoint // .action // tojson) else tostring end) | join("; ")) elif type == "number" then . elif type == "object" then tojson else tostring end) | @csv;
def csvcols: ["group","group_type","seq","level","role","kind","account","region","name","arn","engine","version","major","cluster_type","mode","acu_min","acu_max",
  "class","vcpu","memory_gib","storage_type","allocated_gb","iops","throughput","max_allocated_gb","multi_az","az","secondary_az","azs","member_azs","reader_count","promotion_tier",
  "endpoint","reader_endpoint","custom_endpoints","port","vpc","subnet_group","security_groups","public","encrypted","kms_key","iam_auth","deletion_protection",
  "ca_cert","ca_valid_till","ssl_enforcement","retention_days","backup_window","maintenance_window","auto_minor_upgrade","pending_maintenance",
  "parameter_group","parameter_group_status","option_group","performance_insights","pi_retention_days","monitoring_interval","log_exports","database_insights",
  "status","automatic_restart","created","age_days","engine_lifecycle_support","standard_support_end","extended_support_end","support_status",
  "global_cluster","primary_region","secondary_regions","member_clusters","replica_source","replicas","flags"];
def csv:
  (csvcols + ($cfg.tagcols | map("tag:" + .)) | csvq),
  (.groups[].rows[] | . as $r
    | [csvcols[] | if . == "ssl_enforcement" then $r.ssl.value elif . == "pending_maintenance" then ($r.pending_maintenance // [] | pma_text)
                   elif . == "replica_source" then ($r.replica_source // $r.replication_source) else $r[.] end]
      + ($cfg.tagcols | map($r.tags[.])) | csvq);
def csv_summary:
  .summary as $s | .meta as $m
  | (["section","key","count","examples"] | csvq),
    (["generated","\($m.generated_local) | \($m.generated_utc)","",""] | csvq),
    (["total","groups",$s.groups,""],["total","global_clusters",$s.global_clusters,""],["total","clusters",$s.clusters,""],["total","instances",$s.instances,""],
     ["total","allocated_gb_excl_aurora",$s.allocated_gb,""],["total","vcpu_static_table",$s.vcpu_total,""],["total","memory_gib_static_table",$s.memory_gib_total,""] | csvq),
    ($s.by_type[] | ["type",.key,.count,""] | csvq), ($s.by_account[] | ["account",.key,.count,""] | csvq), ($s.by_region[] | ["region",.key,.count,""] | csvq),
    ($s.by_engine[] | ["engine",.key,.count,""] | csvq), ($s.by_major[] | ["major",.key,.count,""] | csvq), ($s.by_class[] | ["class",.key,.count,""] | csvq),
    ($s.flags[] | ["flag",.flag,.count,(.examples | join(" "))] | csvq);

def chips(a): a | map("<span class=chip>\(.key | esc) <b>\(.count)</b></span>") | join("");
def kv: fields | map("<div class=k>\(.[0] | esc)</div><div class=v>\(.[1] | esc)</div>") | join("");
def html:
  .meta as $m | .summary as $s
  | ([.groups[].rows[].engine] | unique) as $engines | ([.groups[].account] | unique) as $accts | ([.groups[].rows[].region | select(. != null) | split(",")[]] | unique) as $regs
  | "<!doctype html><html lang=en><head><meta charset=utf-8><meta name=viewport content=\"width=device-width,initial-scale=1\"><title>RDS inventory</title><style>"
  + ":root{--b:#dde1e7;--mut:#5b6475}body{font:14px/1.45 system-ui,sans-serif;margin:20px;color:#1d2433;background:#f6f7f9}h1{font-size:20px;margin:0 0 4px}h2{font-size:16px;margin:18px 0 8px}"
  + ".meta{color:var(--mut)}.chip{display:inline-block;background:#fff;border:1px solid var(--b);border-radius:12px;padding:1px 8px;margin:2px;font-size:12px}"
  + ".sum{display:grid;grid-template-columns:120px 1fr;gap:4px 10px;background:#fff;border:1px solid var(--b);border-radius:8px;padding:10px}.sum>div:nth-child(odd){color:var(--mut)}"
  + "table.fl{border-collapse:collapse;background:#fff}table.fl td,table.fl th{border:1px solid var(--b);padding:4px 7px;text-align:left;vertical-align:top}"
  + ".bar{position:sticky;top:0;z-index:5;background:#f6f7f9;padding:10px 0;display:flex;flex-wrap:wrap;gap:8px;align-items:center;border-bottom:1px solid var(--b)}"
  + ".bar input[type=search]{flex:1 1 320px;padding:7px 10px;border:1px solid #9aa3b2;border-radius:6px;font-size:14px}.bar select,.bar button{padding:6px 8px;border:1px solid #9aa3b2;border-radius:6px;background:#fff}"
  + "#count{color:var(--mut);min-width:140px}details.card{background:#fff;border:1px solid var(--b);border-radius:8px;margin:8px 0}details.card>summary{cursor:pointer;padding:9px 12px;list-style:none;display:flex;gap:8px;flex-wrap:wrap;align-items:center}"
  + "details.card>summary::before{content:'\\25B8';color:var(--mut)}details.card[open]>summary::before{content:'\\25BE'}.ty{font-size:11px;font-weight:700;padding:1px 6px;border-radius:4px;color:#fff}.ty.global{background:#6a3fb5}.ty.cluster{background:#1a6fd1}.ty.standalone{background:#3a7d44}"
  + ".res{border-top:1px solid #eef0f3;padding:8px 12px}.res h3{font-size:14px;margin:0 0 6px}.l1{margin-left:22px;border-left:3px solid #c9d6ea}.l2{margin-left:44px;border-left:3px solid #e1e8f2}"
  + ".grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(150px,max-content) minmax(180px,1fr));gap:2px 10px;font-size:12.5px}.k{color:var(--mut)}.v{word-break:break-all}"
  + ".flag{background:#fde7e7;color:#a11;border-radius:4px;padding:0 5px;font-size:11px;font-weight:600;margin-left:3px}.role{font-size:11px;background:#eef1f5;border-radius:4px;padding:0 5px;color:#333}"
  + "mark{background:#ffe066;padding:0}.hidden{display:none}.muted{color:var(--mut)}"
  + "</style></head><body>"
  + "<h1>RDS inventory</h1><div class=meta>Generated \($m.generated_local | esc) &middot; \($m.generated_utc | esc) &middot; accounts \([$m.accounts[] | "\(.account) (\(.profile))"] | join(", ") | esc) &middot; regions \($m.regions | join(", ") | esc) &middot; read-only, no CloudWatch</div>"
  + "<h2>Summary</h2><div class=sum><div>Totals</div><div>\($s.groups) groups &middot; \($s.global_clusters) global clusters &middot; \($s.clusters) clusters &middot; \($s.instances) instances &middot; \($s.allocated_gb) GB allocated <span class=muted>(instances + Multi-AZ clusters; Aurora storage is dynamic, not included)</span> &middot; \($s.vcpu_total) vCPU / \($s.memory_gib_total) GiB <span class=muted>(static class table)</span></div>"
  + "<div>Type</div><div>\(chips($s.by_type))</div><div>Account</div><div>\(chips($s.by_account))</div><div>Region</div><div>\(chips($s.by_region))</div><div>Engine</div><div>\(chips($s.by_engine))</div>"
  + "<div>Major</div><div>\(chips($s.by_major))</div><div>Class</div><div>\(chips($s.by_class))</div></div>"
  + "<h2>Risk flags</h2><table class=fl><tr><th>Flag<th>Count<th>Meaning<th>Examples</tr>"
  + (if ($s.flags | length) == 0 then "<tr><td colspan=4>none</tr>" else ([$s.flags[] | "<tr><td><span class=flag>\(.flag)</span><td>\(.count)<td>\(flagdesc[.flag] | esc)<td>\(.examples | join(", ") | esc)</tr>"] | join("")) end)
  + "</table>"
  + "<div class=bar><input type=search id=q placeholder=\"Search name, endpoint, engine, version, tag value, account, region...  (press /)\" aria-label=Search>"
  + "<button id=clear type=button>Clear</button>"
  + "<select id=fe><option value=\"\">All engines</option>\([$engines[] | "<option>\(. | esc)</option>"] | join(""))</select>"
  + "<select id=fa><option value=\"\">All accounts</option>\([$accts[] | "<option>\(. | esc)</option>"] | join(""))</select>"
  + "<select id=fr><option value=\"\">All regions</option>\([$regs[] | "<option>\(. | esc)</option>"] | join(""))</select>"
  + "<select id=ft><option value=\"\">All types</option><option value=global>Global</option><option value=cluster>Cluster</option><option value=standalone>Standalone</option></select>"
  + "<button id=ex type=button>Expand all</button><button id=co type=button>Collapse all</button><span id=count></span></div><div id=cards>"
  + ([.groups[] | . as $g
      | "<details class=card data-type=\"\(.type)\" data-account=\"\(.account | esc)\" data-engines=\"|\([.rows[].engine] | unique | join("|") | esc)|\" data-regions=\"|\([.rows[].region | select(. != null) | split(",")[]] | unique | join("|") | esc)|\""
      + " data-s=\"\([.rows[] | .name, .endpoint, .reader_endpoint, (.custom_endpoints // [] | .[].endpoint), .engine, .version, .account, .region, .class, (.tags // {} | .[])] | map(select(. != null and . != "") | tostring | ascii_downcase) | join(" ") | esc)\">"
      + "<summary><span class=\"ty \(.type)\">\(.type | ascii_upcase)</span><b>\(.title | esc)</b><span class=muted>\(.account | esc) &middot; \(.region // "" | esc) &middot; \(.engine // "" | esc) &middot; \(.rows | length) resource(s)</span>"
      + ([.rows[].flags[]] | unique | map("<span class=flag>\(.)</span>") | join("")) + "</summary>"
      + ([.rows[] | "<div class=\"res l\(.level)\"><h3><span class=role>\(role_label | esc)</span> \(.name | esc) <span class=muted>\(.region // "" | esc)</span>\(.flags | map("<span class=flag title=\"\(flagdesc[.] | esc)\">\(.)</span>") | join(""))</h3><div class=grid>\(kv)</div></div>"] | join(""))
      + "</details>"] | join(""))
  + "</div><p class=muted id=none hidden>No match.</p>"
  + (if (.errors | length) > 0 then "<h2>Errors</h2><table class=fl><tr><th>Profile / region<th>Call<th>Message</tr>" + ([.errors[] | "<tr><td>\(.profile | esc) / \(.region | esc)<td>\(.call | esc)<td>\(.message | esc)</tr>"] | join("")) + "</table>" else "" end)
  + "<p class=muted>\($m.script | esc) v\($m.version | esc) &middot; \($m.aws_calls) AWS call(s) &middot; read-only &middot; vCPU/memory from a static class table (approximate)</p>"
  + "<script>(function(){var q=document.getElementById('q'),cards=[].slice.call(document.querySelectorAll('details.card')),cnt=document.getElementById('count'),none=document.getElementById('none');"
  + "var fe=document.getElementById('fe'),fa=document.getElementById('fa'),fr=document.getElementById('fr'),ft=document.getElementById('ft');"
  + "function unmark(c){[].slice.call(c.querySelectorAll('mark')).forEach(function(m){var p=m.parentNode;p.replaceChild(document.createTextNode(m.textContent),m);p.normalize();});}"
  + "function mark(c,t){var w=document.createTreeWalker(c,NodeFilter.SHOW_TEXT,null),ns=[],n;while((n=w.nextNode()))ns.push(n);ns.forEach(function(n){var s=n.nodeValue,l=s.toLowerCase(),i=l.indexOf(t);if(i<0)return;var f=document.createDocumentFragment(),p=0;"
  + "while(i>=0){f.appendChild(document.createTextNode(s.slice(p,i)));var m=document.createElement('mark');m.textContent=s.slice(i,i+t.length);f.appendChild(m);p=i+t.length;i=l.indexOf(t,p);}f.appendChild(document.createTextNode(s.slice(p)));n.parentNode.replaceChild(f,n);});}"
  + "function apply(){var t=q.value.trim().toLowerCase(),shown=0,hits=0;cards.forEach(function(c){unmark(c);var ok=(!fe.value||c.dataset.engines.indexOf('|'+fe.value+'|')>=0)&&(!fa.value||c.dataset.account===fa.value)&&(!fr.value||c.dataset.regions.indexOf('|'+fr.value+'|')>=0)&&(!ft.value||c.dataset.type===ft.value);"
  + "if(ok&&t){ok=c.dataset.s.indexOf(t)>=0||c.textContent.toLowerCase().indexOf(t)>=0;if(ok){mark(c,t);c.open=true;hits+=c.querySelectorAll('mark').length;}}c.classList.toggle('hidden',!ok);if(ok)shown++;});"
  + "cnt.textContent=shown+' of '+cards.length+' group(s)'+(t?' \\u00b7 '+hits+' match(es)':'');none.hidden=shown>0;}"
  + "var tm;q.addEventListener('input',function(){clearTimeout(tm);tm=setTimeout(apply,120);});[fe,fa,fr,ft].forEach(function(s){s.addEventListener('change',apply);});"
  + "document.getElementById('clear').addEventListener('click',function(){q.value='';fe.value=fa.value=fr.value=ft.value='';cards.forEach(function(c){c.open=false;});apply();q.focus();});"
  + "document.getElementById('ex').addEventListener('click',function(){cards.forEach(function(c){if(!c.classList.contains('hidden'))c.open=true;});});document.getElementById('co').addEventListener('click',function(){cards.forEach(function(c){c.open=false;});});"
  + "document.addEventListener('keydown',function(e){if(e.key==='/'&&document.activeElement!==q&&!/^(INPUT|SELECT|TEXTAREA)$/.test(document.activeElement.tagName)){e.preventDefault();q.focus();q.select();}else if(e.key==='Escape'&&document.activeElement===q){q.value='';apply();}});apply();})();</script></body></html>";

if $mode == "build" then build
elif $mode == "finalize" then finalize
elif $mode == "text" then text
elif $mode == "csv" then csv
elif $mode == "csv_summary" then csv_summary
elif $mode == "html" then html
elif $mode == "json" then .
elif $mode == "major" then major($ARGS.named.e; $ARGS.named.v)
elif $mode == "classinfo" then classinfo($ARGS.named.c)
else error("unknown mode \($mode)") end
