#!/usr/bin/env bash
# Replays every distinct AWS CLI command line that aurora_pg_check.sh issued (as logged by the
# mock) through the REAL AWS CLI v2 with fake credentials and a local endpoint. The real CLI
# parses options, shorthand (--filters) and file:// JSON and runs botocore parameter validation
# before it opens a connection, so "could not connect" == command accepted; a syntax/parameter
# problem fails earlier with rc 252/255 and a different message. Nothing reaches AWS.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REAL_AWS="${REAL_AWS:-/usr/local/bin/aws}"
[[ -x "$REAL_AWS" ]] || { echo "real aws CLI not found at $REAL_AWS"; exit 2; }
OUT="$(mktemp -d /tmp/apc_cli.XXXXXX)"; SRV=""
cleanup() { [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null; rm -rf -- "$OUT"; }
trap cleanup EXIT
export MOCK_LOG="$OUT/calls.jsonl" MOCK_CAPTURE="$OUT/capture"

# 1. generate calls with the mock across scenarios (keep workdirs to have the file:// inputs)
for s in "fleet --all-regions" "issues -r us-east-1" "metrics -r us-east-1" "serverless -r eu-west-1" "apifail -r us-east-1" \
         "fleet -r us-east-1 -c orders-prod,ghost -P prod -L 6h --period 60"; do
    read -r scen args <<<"$s"
    # shellcheck disable=SC2086
    MOCK_SCENARIO="$scen" PATH="$HERE/mock:$PATH" "$HERE/../aurora_pg_check.sh" $args -f json >/dev/null 2>&1
done
jq -c 'select(.[0] != "--version" and .[0] != "configure")' "$MOCK_LOG" | sort -u >"$OUT/uniq.jsonl"
echo "distinct command lines: $(wc -l <"$OUT/uniq.jsonl")"

export AWS_ACCESS_KEY_ID=AKIAFAKEFAKEFAKEFAKE AWS_SECRET_ACCESS_KEY=fake AWS_MAX_ATTEMPTS=1 AWS_CONFIG_FILE=/dev/null \
       AWS_SHARED_CREDENTIALS_FILE=/dev/null AWS_EC2_METADATA_DISABLED=true
pass=0; fail=0
while IFS= read -r line; do
    mapfile -t argv < <(jq -r '.[]' <<<"$line")
    args=(); skip=0
    for a in "${argv[@]}"; do
        if (( skip )); then skip=0; continue; fi
        case "$a" in
            --profile) skip=1; continue ;;                       # no profiles on this box
            --cli-connect-timeout|--cli-read-timeout) args+=("$a" 2); skip=1; continue ;;
            file://*) a="file://$MOCK_CAPTURE/$(basename "${a#file://}")" ;;
        esac
        args+=("$a")
    done
    out="$("$REAL_AWS" "${args[@]}" --endpoint-url http://127.0.0.1:9 2>&1)"; rc=$?
    svcop="$(jq -r '. as $a | ([range(length)] | map(select($a[.] | IN("rds","sts","ec2","cloudwatch"))) | .[0]) as $i | "\($a[$i]) \($a[$i+1])"' <<<"$line")"
    if [[ "$out" == *"Could not connect to the endpoint URL"* ]]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1)); echo "FAIL ($rc) $svcop: ${out:0:300}"
    fi
done <"$OUT/uniq.jsonl"
echo "accepted by real CLI: $pass, rejected: $fail"

# 2. --query on describe-db-parameters: run against a local fake RDS endpoint (query protocol, XML)
python3 - "$OUT/port" <<'PY' &
import http.server, sys
XML = b"""<DescribeDBParametersResponse xmlns="http://rds.amazonaws.com/doc/2014-10-31/"><DescribeDBParametersResult><Parameters>
<Parameter><ParameterName>max_connections</ParameterName><ParameterValue>LEAST({DBInstanceClassMemory/9531392},5000)</ParameterValue><Source>engine-default</Source></Parameter>
<Parameter><ParameterName>work_mem</ParameterName><ParameterValue>4096</ParameterValue><Source>engine-default</Source></Parameter>
</Parameters></DescribeDBParametersResult><ResponseMetadata><RequestId>11111111-2222</RequestId></ResponseMetadata></DescribeDBParametersResponse>"""
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        self.send_response(200); self.send_header("Content-Type", "text/xml"); self.end_headers(); self.wfile.write(XML)
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", 0), H); open(sys.argv[1], "w").write(str(s.server_port)); s.serve_forever()
PY
SRV=$!
for _ in $(seq 50); do [[ -s "$OUT/port" ]] && break; sleep 0.1; done
q="$("$REAL_AWS" --output json --no-cli-pager --region us-east-1 rds describe-db-parameters --db-parameter-group-name default.aurora-postgresql16 \
      --query "Parameters[?ParameterName=='max_connections']" --endpoint-url "http://127.0.0.1:$(cat "$OUT/port")" 2>&1)"
if jq -e 'length == 1 and .[0].ParameterName == "max_connections"' <<<"$q" >/dev/null 2>&1; then
    echo "describe-db-parameters --query: OK (real CLI returned the filtered array)"
else
    echo "describe-db-parameters --query: FAIL: $q"; fail=$((fail + 1))
fi
(( fail == 0 ))
