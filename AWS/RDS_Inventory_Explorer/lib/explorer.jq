# explorer.jq - turns the raw describe-* output collected by rds_inventory_explorer.sh into the page's data model.
# Input : {meta, regions: [{account, profile, region, clusters, instances, globals, endpoints, pma, certs}], errors}
# Output: {meta (+counts), resources: [...], errors}. Every resource keeps its untouched AWS description in .raw
# (for "Copy JSON"); .d holds the normalised fields the detail card shows. No secret value is ever present: the
# describe-* APIs only return the Secrets Manager ARN / status / KMS key of a managed master password.

def nz: select(. != null and . != "");
def pad2: tostring | if length < 2 then "0" + . else . end;
def DAYS: ["sun", "mon", "tue", "wed", "thu", "fri", "sat"];
def tags: [(.TagList // [])[] | {k: .Key, v: (.Value // "")}];
def lastseg: tostring | split(":") | last;
def arnregion: tostring | split(":") | .[3] // "";
def arnacct: tostring | split(":") | .[4] // "";
def arnprefix: split(":") | .[0:5] | join(":") + ":";   # arn:aws:rds:<region>:<account>:
def keepeng($docdb): (.Engine // "") as $e | $docdb or ($e | test("^(docdb|neptune)") | not);

.meta as $meta
| $meta.tz_offset as $off | $meta.tz_abbr as $abbr | $meta.now as $now

# ISO-8601 (as printed by AWS CLI v2) -> epoch seconds, honouring Z / +hh:mm offsets; null when absent / unparsable
| def epoch: if type != "string" or . == "" then null else
      ([capture("^(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2})[T ](?<t>[0-9]{2}:[0-9]{2}:[0-9]{2})(\\.[0-9]+)?(?<z>Z|[+-][0-9]{2}:?[0-9]{2})?$")][0]) as $c
      | if $c == null then null else
          ((($c.d + "T" + $c.t + "Z") | fromdateiso8601)
           - (($c.z // "Z") | if . == "Z" then 0
                              else (.[0:1]) as $s | ((.[1:3] | tonumber) * 3600 + (.[-2:] | tonumber) * 60) | if $s == "-" then -. else . end end))
        end end;
  def when: epoch as $e | if $e == null then null else
      {utc: ($e | strftime("%Y-%m-%d %H:%M UTC")), local: ((($e + $off) | strftime("%Y-%m-%d %H:%M")) + " " + $abbr),
       days: ((($e - $now) / 86400) | floor)} end;
  # "sun:22:00" -> shifted by the display zone offset, wrapping the week; "20:30" -> shifted, wrapping the day
  def shift_dhm: split(":") as $p | (DAYS | index($p[0] | ascii_downcase)) as $di
      | if $di == null then . else
          ((($di * 1440 + ($p[1] | tonumber) * 60 + ($p[2] | tonumber) + (($off / 60) | floor)) % 10080 + 10080) % 10080) as $t
          | "\(DAYS[($t / 1440) | floor]):\((($t % 1440) / 60 | floor) | pad2):\(($t % 60) | pad2)" end;
  def shift_hm: split(":") as $p
      | (((($p[0] | tonumber) * 60 + ($p[1] | tonumber) + (($off / 60) | floor)) % 1440 + 1440) % 1440) as $t
      | "\(($t / 60 | floor) | pad2):\(($t % 60) | pad2)";
  def window: if type != "string" or . == "" then null else
      . as $w | {utc: ($w + " UTC"),
                 local: ((try ($w | split("-") | map(if (split(":") | length) == 3 then shift_dhm else shift_hm end) | join("-")) catch $w) + " " + $abbr)} end;
  def pending_list($m): [($m[.] // [])[] | {action: .Action, description: (.Description), opt_in: (.OptInStatus),
                                            auto_applied_after: (.AutoAppliedAfterDate | when), forced_apply: (.ForcedApplyDate | when),
                                            current_apply: (.CurrentApplyDate | when)}];
  def master: {username: (.MasterUsername), managed: (.MasterUserSecret != null),
               secret_arn: (.MasterUserSecret.SecretArn), secret_status: (.MasterUserSecret.SecretStatus),
               secret_kms: (.MasterUserSecret.KmsKeyId)};
  def cert($certs): (.CertificateDetails.CAIdentifier // .CACertificateIdentifier) as $id
      | if $id == null then null else {id: $id, valid_till: ((.CertificateDetails.ValidTill // $certs[$id]) | when)} end;
  def sgs: [(.VpcSecurityGroups // [])[] | .VpcSecurityGroupId];

  ($meta.include_docdb) as $docdb
  | [.regions[] | . as $r
     | {account, profile, region,
        clusters: [.clusters[] | select(keepeng($docdb))], instances: [.instances[] | select(keepeng($docdb))],
        globals: [.globals[] | select(keepeng($docdb))], endpoints: (.endpoints // []),
        certs: ([(.certs // [])[] | {key: .CertificateIdentifier, value: .ValidTill}] | from_entries)}] as $R
  | ([.regions[].pma[]? | {key: .ResourceIdentifier, value: (.PendingMaintenanceActionDetails // [])}] | from_entries) as $PMA
  | ([$R[] | . as $r | .instances[] | {key: "\($r.account)|\($r.region)|\(.DBInstanceIdentifier)", value: (. + {_acct: $r.account, _region: $r.region})}] | from_entries) as $IK
  | ([$R[] | .instances[] | {key: .DBInstanceArn, value: true}] | from_entries) as $IARN
  | ([$R[] | . as $r | .clusters[] | {key: .DBClusterArn, value: {name: .DBClusterIdentifier, region: $r.region, account: $r.account}}] | from_entries) as $CARN
  | ([$R[] | . as $r | .clusters[] | .DBClusterArn as $ca | (.DBClusterMembers // [])[]
      | {key: "\($r.account)|\($r.region)|\(.DBInstanceIdentifier)", value: {cluster: $ca, role: (if .IsClusterWriter then "writer" else "reader" end)}}] | from_entries) as $ROLE
  # global clusters: describe-global-clusters answers in every region -> keep one per ARN
  | ([$R[] | . as $r | .globals[] | . + {_acct: $r.account, _profile: $r.profile}] | group_by(.GlobalClusterArn) | map(.[0])) as $G
  | ([$G[] | .GlobalClusterArn as $g | (.GlobalClusterMembers // [])[] | {key: .DBClusterArn, value: $g}] | from_entries) as $GOF
  | ([$G[] | {key: "\(._acct)|\(.GlobalClusterIdentifier)", value: .GlobalClusterArn}] | from_entries) as $GID

  | def link_db($prefix): if type != "string" or . == "" then null
        elif startswith("arn:") then {name: lastseg, region: arnregion, id: (if $IARN[.] then . else null end)}
        else ($prefix + "db:" + .) as $a | {name: ., region: ($a | arnregion), id: (if $IARN[$a] then $a else null end)} end;
    def link_cluster: if . == null then null else {name: lastseg, region: arnregion, id: (if $CARN[.] then . else null end)} end;
    def search_text($extra): ([.name, .account, .profile, .region, .engine, .version, .status, .type_label, .id]
                              + [.tags[] | .k, .v] + $extra) | map(select(. != null) | tostring) | join(" ") | ascii_downcase;

    # ------------------------------------------------------------- global clusters
    [$G[] | . as $g
     | ([(.GlobalClusterMembers // [])[]
         | .DBClusterArn as $ca
         | {name: ($ca | lastseg), region: ($ca | arnregion), account: ($ca | arnacct), id: (if $CARN[$ca] then $ca else null end),
            role: (if .IsWriter then "primary" else "secondary" end), writer: (.IsWriter // false),
            write_forwarding: (.GlobalWriteForwardingStatus), sync: (.SynchronizationStatus),
            readers: [(.Readers // [])[] | lastseg]}] | sort_by(.role != "primary", .region)) as $mem
     | {id: .GlobalClusterArn, type: "global", type_label: "Global cluster", name: .GlobalClusterIdentifier,
        account: ._acct, profile: ._profile, region: ([$mem[] | select(.writer) | .region][0] // ($mem[0].region // "")),
        regions: ($mem | map(.region) | unique), engine: (.Engine // ""), version: (.EngineVersion // ""), status: (.Status // ""),
        endpoint: (.Endpoint), tags: tags, raw: (del(._acct, ._profile)),
        d: {primary_region: ([$mem[] | select(.writer) | .region][0]), secondary_regions: ([$mem[] | select(.writer | not) | .region] | unique),
            members: $mem, write_forwarding: ([$mem[] | select(.write_forwarding == "enabled") | .name]),
            deletion_protection: (.DeletionProtection), storage_encrypted: (.StorageEncrypted),
            database_name: (.DatabaseName), endpoint: (.Endpoint), failover: (.FailoverState),
            engine_lifecycle: (.EngineLifecycleSupport), resource_id: (.GlobalClusterResourceId)}}
     | . + {search: search_text([.d.members[].name, .endpoint])}] as $GLOBALS

    # ------------------------------------------------------------- clusters
  | [$R[] | . as $r | .clusters[] | . as $c
     | ($c.DBClusterArn | arnprefix) as $pfx
     | ([$r.endpoints[] | select(.DBClusterIdentifier == $c.DBClusterIdentifier and .EndpointType == "CUSTOM")
         | {name: .DBClusterEndpointIdentifier, endpoint: .Endpoint, type: (.CustomEndpointType), status: (.Status),
            static: (.StaticMembers // []), excluded: (.ExcludedMembers // [])}]) as $ce
     | (if ($ce | length) > 0 then $ce else [($c.CustomEndpoints // [])[] | {name: (split(".")[0]), endpoint: ., type: null, status: null, static: [], excluded: []}] end) as $custom
     | ([($c.DBClusterMembers // [])[] | . as $m | $IK["\($r.account)|\($r.region)|\($m.DBInstanceIdentifier)"] as $i
         | {name: $m.DBInstanceIdentifier, id: ($i.DBInstanceArn), role: (if $m.IsClusterWriter then "writer" else "reader" end),
            promotion_tier: ($m.PromotionTier // $i.PromotionTier), class: ($i.DBInstanceClass), az: ($i.AvailabilityZone),
            status: ($i.DBInstanceStatus), endpoint: ($i.Endpoint.Address), port: ($i.Endpoint.Port),
            auto_minor: ($i.AutoMinorVersionUpgrade), pi: ($i.PerformanceInsightsEnabled), pi_kms: ($i.PerformanceInsightsKMSKeyId),
            ca: (if $i == null then null else ($i | cert($r.certs)) end), param_group: ($i.DBParameterGroups[0].DBParameterGroupName),
            pending: (($i.DBInstanceArn // "") | pending_list($PMA))}]
        | sort_by(.role != "writer", .promotion_tier // 99, .name)) as $mem
     | (($GOF[$c.DBClusterArn] // (if $c.GlobalClusterIdentifier then $GID["\($r.account)|\($c.GlobalClusterIdentifier)"] else null end))) as $gl
     | ($c.Engine // "") as $eng
     | {id: $c.DBClusterArn, type: "cluster",
        type_label: (if ($eng | startswith("aurora")) then "Aurora cluster" elif $eng == "docdb" then "DocumentDB cluster"
                     elif $eng == "neptune" then "Neptune cluster" else "Multi-AZ DB cluster" end),
        name: $c.DBClusterIdentifier, account: $r.account, profile: $r.profile, region: $r.region, regions: [$r.region],
        engine: $eng, version: ($c.EngineVersion // ""), status: ($c.Status // ""), class: ($c.DBClusterInstanceClass),
        endpoint: ($c.Endpoint), tags: ($c | tags), raw: $c,
        d: {engine_mode: ($c.EngineMode), port: ($c.Port), writer_endpoint: ($c.Endpoint), reader_endpoint: ($c.ReaderEndpoint),
            custom_endpoints: $custom, members: $mem, writer: ([$mem[] | select(.role == "writer") | .name][0]),
            master: ($c | master), database_name: ($c.DatabaseName),
            storage_encrypted: ($c.StorageEncrypted // false), kms_key: ($c.KmsKeyId),
            pi_enabled: ($c.PerformanceInsightsEnabled),
            pi_kms: ([$c.PerformanceInsightsKMSKeyId // empty] + [$mem[] | .pi_kms // empty] | unique),
            backup: {retention_days: ($c.BackupRetentionPeriod), window: ($c.PreferredBackupWindow | window),
                     earliest_restorable: ($c.EarliestRestorableTime | when), latest_restorable: ($c.LatestRestorableTime | when),
                     copy_tags_to_snapshot: ($c.CopyTagsToSnapshot), backtrack_window: ($c.BacktrackWindow)},
            auto_minor_cluster: ($c.AutoMinorVersionUpgrade),
            auto_minor_members: {on: ([$mem[] | select(.auto_minor == true)] | length), off: ([$mem[] | select(.auto_minor == false)] | length)},
            maintenance_window: ($c.PreferredMaintenanceWindow | window),
            pending: ($c.DBClusterArn | pending_list($PMA)),
            member_pending: [$mem[] | select((.pending | length) > 0) | {name, id, pending}],
            param_group: ($c.DBClusterParameterGroup), subnet_group: ($c.DBSubnetGroup), security_groups: ($c | sgs),
            iam_auth: ($c.IAMDatabaseAuthenticationEnabled), deletion_protection: ($c.DeletionProtection),
            ca: (if $c.CertificateDetails then ($c | cert($r.certs)) else null end),
            member_cas: ([$mem[] | .ca // empty] | unique_by(.id)),
            global: (if $gl then {id: $gl, name: ($gl | lastseg)} else null end),
            global_write_forwarding: ($c.GlobalWriteForwardingStatus), local_write_forwarding: ($c.LocalWriteForwardingStatus),
            storage_type: ($c.StorageType), allocated_gb: ($c.AllocatedStorage), iops: ($c.Iops),
            storage_throughput: ($c.StorageThroughput),
            serverless_v2: ($c.ServerlessV2ScalingConfiguration), multi_az: ($c.MultiAZ), azs: ($c.AvailabilityZones // []),
            created: ($c.ClusterCreateTime | when), replication_source: ($c.ReplicationSourceIdentifier),
            read_replicas: ($c.ReadReplicaIdentifiers // []), logs_exports: ($c.EnabledCloudwatchLogsExports // []),
            engine_lifecycle: ($c.EngineLifecycleSupport), network_type: ($c.NetworkType),
            activity_stream: ($c.ActivityStreamStatus), http_endpoint: ($c.HttpEndpointEnabled),
            resource_id: ($c.DbClusterResourceId)}}
     | . + {search: search_text([.d.writer_endpoint, .d.reader_endpoint, .class] + [.d.custom_endpoints[] | .endpoint, .name] + [.d.members[] | .name, .endpoint])}] as $CLUSTERS

    # ------------------------------------------------------------- instances (standalone and cluster members)
  | [$R[] | . as $r | .instances[] | . as $i
     | ($i.DBInstanceArn | arnprefix) as $pfx
     | $ROLE["\($r.account)|\($r.region)|\($i.DBInstanceIdentifier)"] as $ro
     | ($i.DBClusterIdentifier) as $cid
     | ($ro.cluster // (if $cid then $pfx + "cluster:" + $cid else null end)) as $carn
     | {id: $i.DBInstanceArn, type: (if $cid then "member" else "instance" end),
        type_label: (if $cid then "Cluster member" else "RDS instance" end),
        name: $i.DBInstanceIdentifier, account: $r.account, profile: $r.profile, region: $r.region, regions: [$r.region],
        engine: ($i.Engine // ""), version: ($i.EngineVersion // ""), status: ($i.DBInstanceStatus // ""), class: ($i.DBInstanceClass),
        endpoint: ($i.Endpoint.Address), tags: ($i | tags), raw: $i,
        d: {endpoint: ($i.Endpoint.Address), port: ($i.Endpoint.Port), az: ($i.AvailabilityZone),
            secondary_az: ($i.SecondaryAvailabilityZone), multi_az: ($i.MultiAZ),
            cluster: (if $cid then {name: $cid, id: (if $CARN[$carn] then $carn else null end), role: ($ro.role)} else null end),
            global: (if $carn and $GOF[$carn] then {id: $GOF[$carn], name: ($GOF[$carn] | lastseg)} else null end),
            storage: {type: ($i.StorageType), allocated_gb: ($i.AllocatedStorage), max_allocated_gb: ($i.MaxAllocatedStorage),
                      iops: ($i.Iops), throughput: ($i.StorageThroughput)},
            subnet_group: ($i.DBSubnetGroup.DBSubnetGroupName), vpc: ($i.DBSubnetGroup.VpcId), security_groups: ($i | sgs),
            public: ($i.PubliclyAccessible),
            source: ($i.ReadReplicaSourceDBInstanceIdentifier | link_db($pfx)),
            replicas: [($i.ReadReplicaDBInstanceIdentifiers // [])[] | link_db($pfx)],
            pi: {enabled: ($i.PerformanceInsightsEnabled // false), retention_days: ($i.PerformanceInsightsRetentionPeriod),
                 kms: ($i.PerformanceInsightsKMSKeyId)},
            backup: {retention_days: ($i.BackupRetentionPeriod), window: ($i.PreferredBackupWindow | window),
                     latest_restorable: ($i.LatestRestorableTime | when), copy_tags_to_snapshot: ($i.CopyTagsToSnapshot)},
            storage_encrypted: ($i.StorageEncrypted // false), kms_key: ($i.KmsKeyId),
            master: ($i | master), database_name: ($i.DBName),
            auto_minor: ($i.AutoMinorVersionUpgrade), maintenance_window: ($i.PreferredMaintenanceWindow | window),
            pending: ($i.DBInstanceArn | pending_list($PMA)), ca: ($i | cert($r.certs)),
            param_groups: [($i.DBParameterGroups // [])[] | {name: .DBParameterGroupName, status: .ParameterApplyStatus}],
            option_groups: [($i.OptionGroupMemberships // [])[] | .OptionGroupName],
            monitoring_interval: ($i.MonitoringInterval), iam_auth: ($i.IAMDatabaseAuthenticationEnabled),
            deletion_protection: ($i.DeletionProtection), created: ($i.InstanceCreateTime | when),
            license: ($i.LicenseModel), network_type: ($i.NetworkType), logs_exports: ($i.EnabledCloudwatchLogsExports // []),
            engine_lifecycle: ($i.EngineLifecycleSupport), promotion_tier: ($i.PromotionTier),
            resource_id: ($i.DbiResourceId)}}
     | . + {search: search_text([.endpoint, .class, .d.cluster.name])}] as $INSTANCES

  | ($GLOBALS + $CLUSTERS + $INSTANCES) as $ALL
  | {meta: ($meta + {counts: {
        accounts: ($meta.accounts | map(.account) | unique | length),
        regions_with_databases: ([$ALL[] | select(.type != "global") | "\(.account)|\(.region)"] | unique | length),
        global_clusters: ($GLOBALS | length), clusters: ($CLUSTERS | length), instances: ($INSTANCES | length),
        standalone_instances: ([$INSTANCES[] | select(.type == "instance")] | length),
        cluster_members: ([$INSTANCES[] | select(.type == "member")] | length),
        pending_maintenance: ([$ALL[] | select((.d.pending // []) | length > 0)] | length),
        errors: (.errors | length)}}),
     resources: ($ALL | sort_by(({global: 0, cluster: 1, instance: 2, member: 3}[.type]), .name, .account, .region)),
     errors: .errors}
