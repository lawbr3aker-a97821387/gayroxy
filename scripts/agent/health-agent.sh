#!/usr/bin/env bash
# External subscription health agent.  Never edits or signals the main xray.
#
# Design:
#   - Rotation: three independent aux xray processes on ports 10030/10032/10034
#     (above the main xray's inbound range 10001-10016) that proxy through pool nodes at 1/2/5-minute intervals. The main Gayroxy
#     xray (clients connect here) is never touched by rotation.
#   - Health:   parallel probing (10 concurrent xray instances via xargs -P10).
#     Each probe spins up a temporary xray, curls ip-api.com through it, and
#     reports latency + country.
#   - Leaderboard: per-external-sub top-10 JSON (aux/pool-leaderboard.json).
#     On each health cycle, new candidates with better latency than the 10th
#     slot are inserted in order; the 11th is evicted.  The flat pool.tsv is
#     rebuilt from the leaderboard on every finalize.
#   - ip-api.com is the single source of truth for exit-country (used for both
#     rotation metadata and per-config country tags in the subscription).
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
# ─── Timing ───────────────────────────────────────────────────────────────────
HEALTH_INTERVAL="${HEALTH_INTERVAL:-1200}"        # 20 min — health-only cycle
SUBS_REFRESH_INTERVAL="${SUBS_REFRESH_INTERVAL:-7200}"  # 2 h — full source refresh
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-10}"            # per-probe curl timeout (seconds)
BEST_PER_SUB="${BEST_PER_SUB:-10}"
MAX_CONSEC_FAIL="${MAX_CONSEC_FAIL:-3}"
PARALLEL_PROBES="${PARALLEL_PROBES:-10}"
# Rotation intervals — three tiers, each its own aux xray
ROTATE1MIN_INTERVAL="${ROTATE1MIN_INTERVAL:-60}"
ROTATE2MIN_INTERVAL="${ROTATE2MIN_INTERVAL:-120}"
ROTATE5MIN_INTERVAL="${ROTATE5MIN_INTERVAL:-300}"
# WARP rotation tiers — cycle the 3 WARP planes (distinct free egress IPs).
ROTATEWARP2MIN_INTERVAL="${ROTATEWARP2MIN_INTERVAL:-120}"
ROTATEWARP4MIN_INTERVAL="${ROTATEWARP4MIN_INTERVAL:-240}"
ROTATEWARP6MIN_INTERVAL="${ROTATEWARP6MIN_INTERVAL:-360}"
# The 3 WARP plane SOCKS5 ports (each a separate WARP registration = own IP).
WARP_PLANE_PORTS="${WARP_PLANE_PORTS:-40010 40012 40014}"
# ─── Paths ────────────────────────────────────────────────────────────────────
XRAY_BIN="${XRAY_BIN:-$ROOT/xray}"
DOMAIN="${DOMAIN:-tunnel-coming-on-first-run.trycloudflare.com}"
WORKER_URL="${WORKER_URL:-}"
API_TOKEN="${API_TOKEN:-}"
DEFAULT_EXTERNAL_SUB="${DEFAULT_EXTERNAL_SUB:-https://raw.githubusercontent.com/Kolandone/v2raycollector/main/config_lite.txt}"
SUB_DIR="${SUB_DIR:-$ROOT/sub}"
AUX_DIR="$ROOT/aux"
AUX_LOG="$ROOT/logs/aux"
POOL_FILE="$AUX_DIR/pool.tsv"
POOL_STATE="$AUX_DIR/pool-state.json"
LEADERBOARD="$AUX_DIR/pool-leaderboard.json"
# Per-interval rotation state/config files
ROTATE1MIN_CONFIG="$AUX_DIR/rotate1min.json"
ROTATE1MIN_META="$AUX_DIR/rotate1min-meta.tsv"
ROTATE1MIN_STATE="$AUX_DIR/rotate1min-state.json"
ROTATE2MIN_CONFIG="$AUX_DIR/rotate2min.json"
ROTATE2MIN_META="$AUX_DIR/rotate2min-meta.tsv"
ROTATE2MIN_STATE="$AUX_DIR/rotate2min-state.json"
ROTATE5MIN_CONFIG="$AUX_DIR/rotate5min.json"
ROTATE5MIN_META="$AUX_DIR/rotate5min-meta.tsv"
ROTATE5MIN_STATE="$AUX_DIR/rotate5min-state.json"
# WARP rotation tier config/meta/state files
ROTATE_WARP2MIN_CONFIG="$AUX_DIR/rotatewarp2min.json"
ROTATE_WARP2MIN_META="$AUX_DIR/rotatewarp2min-meta.tsv"
ROTATE_WARP2MIN_STATE="$AUX_DIR/rotatewarp2min-state.json"
ROTATE_WARP4MIN_CONFIG="$AUX_DIR/rotatewarp4min.json"
ROTATE_WARP4MIN_META="$AUX_DIR/rotatewarp4min-meta.tsv"
ROTATE_WARP4MIN_STATE="$AUX_DIR/rotatewarp4min-state.json"
ROTATE_WARP6MIN_CONFIG="$AUX_DIR/rotatewarp6min.json"
ROTATE_WARP6MIN_META="$AUX_DIR/rotatewarp6min-meta.tsv"
ROTATE_WARP6MIN_STATE="$AUX_DIR/rotatewarp6min-state.json"
# PIDs for the three aux xray instances + rotation loops. Aux xray PIDs are held
# in pid files (written by the rotation loops that own them) so the parent
# cleanup can reach them even though the loops run in subshells.
# shellcheck disable=SC2034  # rotation/loop PIDs tracked for cleanup
ROTATE1MIN_PID="$AUX_DIR/rotate1min.pid"
# shellcheck disable=SC2034
ROTATE2MIN_PID="$AUX_DIR/rotate2min.pid"
# shellcheck disable=SC2034
ROTATE5MIN_PID="$AUX_DIR/rotate5min.pid"
# shellcheck disable=SC2034
ROTATE_WARP2MIN_PID="$AUX_DIR/rotatewarp2min.pid"
# shellcheck disable=SC2034
ROTATE_WARP4MIN_PID="$AUX_DIR/rotatewarp4min.pid"
# shellcheck disable=SC2034
ROTATE_WARP6MIN_PID="$AUX_DIR/rotatewarp6min.pid"
# shellcheck disable=SC2034
LOOP1MIN_PID=""
# shellcheck disable=SC2034
LOOP2MIN_PID=""
# shellcheck disable=SC2034
LOOP5MIN_PID=""
# shellcheck disable=SC2034
LOOP_WARP2MIN_PID=""
# shellcheck disable=SC2034
LOOP_WARP4MIN_PID=""
# shellcheck disable=SC2034
LOOP_WARP6MIN_PID=""
ONCE=0
[[ "${1:-}" == "--once" ]] && ONCE=1
mkdir -p "$AUX_DIR" "$AUX_LOG" "$SUB_DIR"

log()  { echo -e "\033[0;32m[health-agent]\033[0m $*"; }
warn() { echo -e "\033[1;33m[health-agent] WARNING\033[0m $*"; }

cleanup(){
  # Aux xray PIDs live in pid files (owned by the rotation loops), plus the
  # parent-owned loop PIDs.
  local pf pid
  for pf in "$ROTATE1MIN_PID" "$ROTATE2MIN_PID" "$ROTATE5MIN_PID" \
            "$ROTATE_WARP2MIN_PID" "$ROTATE_WARP4MIN_PID" "$ROTATE_WARP6MIN_PID"; do
    pid=$(cat "$pf" 2>/dev/null || true)
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
    rm -f "$pf"
  done
  for pid_var in LOOP1MIN_PID LOOP2MIN_PID LOOP5MIN_PID \
                 LOOP_WARP2MIN_PID LOOP_WARP4MIN_PID LOOP_WARP6MIN_PID; do
    [[ -n "${!pid_var:-}" ]] && kill "${!pid_var}" 2>/dev/null || true
  done
}
trap cleanup INT TERM EXIT

# ─── Subscription parsing ──────────────────────────────────────────────────────
fetch_sub(){
  local body
  body=$(curl -fsSL --max-time 20 --retry 1 "$1" 2>/dev/null || true)
  [[ -n "$body" ]] || return 1
  if ! [[ "$body" == *'vless://'* || "$body" == *'vmess://'* || "$body" == *'trojan://'* || "$body" == *'ss://'* ]]; then
    body=$(printf '%s' "$body" | tr -d '\r\n ' | base64 -d 2>/dev/null || true)
  fi
  printf '%s\n' "$body" | grep -E '^(vless|vmess|trojan|ss)://' || true
}

normalise(){ python3 - "$1" <<'PY'
import sys,json,base64,urllib.parse,re
s=sys.argv[1].strip(); m=re.match(r'^(vless|vmess|trojan|ss)://(.+)$',s)
if not m: raise SystemExit(1)
p,rest=m.groups(); frag=''
if '#' in rest: rest,frag=rest.rsplit('#',1)
if p=='vmess':
 try: d=json.loads(base64.b64decode(rest+'='*((-len(rest))%4)))
 except Exception:
  try:
   auth_rest,q=(rest.split('?',1) if '?' in rest else (rest,''))
   user,authority=auth_rest.rsplit('@',1)
   host,port=authority.rsplit(':',1)
  except Exception: raise SystemExit(1)
  params=urllib.parse.parse_qs(q)
  d={'_proto':'vmess','_remark':urllib.parse.unquote(frag),'host':host,'port':int(port),'id':user,'aid':0,
     'type':params.get('type',['tcp'])[0],'security':params.get('security',[''])[0],'tls':(params.get('security',[''])[0] if params.get('security',[''])[0] in ('tls','reality') else ''),
     'path':params.get('path',[''])[0],'sni':params.get('sni',[''])[0],'fp':params.get('fp',[''])[0],
     'serviceName':params.get('serviceName',[''])[0],'method':params.get('method',['aes-256-gcm'])[0],
     'flow':params.get('flow',[''])[0],'pbk':params.get('pbk',[''])[0],'sid':params.get('sid',[''])[0]}
  print(json.dumps(d)); raise SystemExit
 d['_proto']='vmess'; d['_remark']=urllib.parse.unquote(frag); print(json.dumps(d)); raise SystemExit
q='';
if '?' in rest: rest,q=rest.split('?',1)
try:
 user,authority=rest.rsplit('@',1)
except ValueError: raise SystemExit(1)
if ':' not in authority: raise SystemExit(1)
host,port=authority.rsplit(':',1)
params=urllib.parse.parse_qs(q)
d={'_proto':p,'_remark':urllib.parse.unquote(frag),'host':host,'port':int(port),'user':urllib.parse.unquote(user),'type':params.get('type',['tcp'])[0],'security':params.get('security',[''])[0],'path':params.get('path',[''])[0],'sni':params.get('sni',[''])[0],'fp':params.get('fp',[''])[0],'serviceName':params.get('serviceName',[''])[0],'method':params.get('method',['aes-256-gcm'])[0],'flow':params.get('flow',[''])[0],'pbk':params.get('pbk',[''])[0],'sid':params.get('sid',[''])[0]}
print(json.dumps(d))
PY
}

outbound_json(){ python3 - "$1" <<'PY'
import sys,json,base64
x=json.loads(sys.argv[1]); p=x['_proto']; host=x.get('host') or x.get('add'); port=int(x.get('port') or 443)
stream={'network':x.get('type') or x.get('net') or 'tcp'}
if stream['network']=='ws': stream['wsSettings']={'path':x.get('path') or '/','headers':{'Host':x.get('host') or x.get('add')}}
elif stream['network']=='grpc': stream['grpcSettings']={'serviceName':x.get('serviceName') or x.get('path') or ''}
elif stream['network']=='httpupgrade': stream['httpupgradeSettings']={'path':x.get('path') or '/','host':host}
sec=x.get('security') or ('tls' if x.get('tls') else '')
if sec in ('tls','reality'):
    stream['security']='tls'
    fp=x.get('fp') or ('chrome' if sec=='reality' else '')
    if sec=='reality':
        stream['tlsSettings']={'serverName':x.get('sni') or host,'fingerprint':fp or 'chrome','realitySettings':{'publicKey':x.get('pbk') or '','shortId':x.get('sid') or '','serverName':x.get('sni') or host}}
    else:
        stream['tlsSettings']={'serverName':x.get('sni') or host,'fingerprint':fp or ''}
if p=='vless':
    usr={'id':x.get('user',''),'encryption':'none'}
    if x.get('flow'): usr['flow']=x.get('flow')
    elif sec=='reality': usr['flow']='xtls-rprx-vision'
    return_obj={'protocol':'vless','settings':{'vnext':[{'address':host,'port':port,'users':[usr]}]},'streamSettings':stream}
elif p=='vmess':
    u=x.get('id',''); return_obj={'protocol':'vmess','settings':{'vnext':[{'address':host,'port':port,'users':[{'id':u,'alterId':int(x.get('aid',0) or 0),'security':'auto'}]}]},'streamSettings':stream}
elif p=='trojan':
    return_obj={'protocol':'trojan','settings':{'servers':[{'address':host,'port':port,'password':x.get('user','')}]},'streamSettings':stream}
else:
    return_obj={'protocol':'shadowsocks','settings':{'servers':[{'address':host,'port':port,'method':x.get('method','aes-256-gcm'),'password':x.get('user','')}]},'streamSettings':stream}
print(json.dumps(return_obj,separators=(',',':')))
PY
}

sub_name(){ python3 - "$1" <<'PY'
import sys,urllib.parse,re
u=urllib.parse.urlparse(sys.argv[1]); h=u.hostname or 'source'; print(re.sub(r'[^A-Za-z0-9._-]+','-',h)[:32])
PY
}

# ─── Node testing ──────────────────────────────────────────────────────────────
# Fast TCP pre-filter — skip dead hosts before the expensive xray probe.
tcp_ping(){
  local node="$1" host port
  host=$(printf '%s' "$node" | python3 -c 'import sys,json; x=json.load(sys.stdin); print(x.get("host") or x.get("add") or "")' 2>/dev/null) || return 1
  port=$(printf '%s' "$node" | python3 -c 'import sys,json; x=json.load(sys.stdin); print(int(x.get("port") or 443))' 2>/dev/null) || return 1
  [[ -n "$host" ]] || return 1
  if command -v nc >/dev/null 2>&1; then
    timeout 4 nc -z -w2 "$host" "$port" 2>/dev/null
  else
    timeout 3 bash -c "exec 3<>/dev/tcp/$host/$port" 2>/dev/null
  fi
}

# Full tunnel test: spin up a temporary xray, curl ip-api.com through it.
# Outputs latency_ms|country_code|normalised_json   OR   nothing on failure.
test_node(){
  local node="$1" port="$2"
  local cfg="$AUX_DIR/test-$port.json" out="$AUX_LOG/test-$port.log"
  local ob; ob=$(outbound_json "$node") || return 1
  python3 - "$cfg" "$ob" "$port" <<'PY'
import sys,json
p,ob,port=sys.argv[1:]; o=json.loads(ob); o['tag']='node'
c={'log':{'loglevel':'error'},'inbounds':[{'tag':'in','listen':'127.0.0.1','port':int(port),'protocol':'socks','settings':{'udp':False}}],'outbounds':[o,{'tag':'direct','protocol':'freedom'}],'routing':{'rules':[{'type':'field','inboundTag':['in'],'outboundTag':'node'}]}}
json.dump(c,open(p,'w'))
PY
  "$XRAY_BIN" run -c "$cfg" >"$out" 2>&1 & local pid=$!
  sleep .7
  local t result country
  t=$(date +%s%N)
  # Probe through the node → ip-api.com gives us exit-country + confirms the
  # node actually routes traffic.
  result=$(curl -fsS --max-time "$HEALTH_TIMEOUT" --proxy "socks5h://127.0.0.1:$port" 'http://ip-api.com/json?fields=countryCode' 2>/dev/null || true)
  [[ -n "$result" ]] || result=$(curl -fsS --max-time "$HEALTH_TIMEOUT" --proxy "socks5h://127.0.0.1:$port" 'https://api.ipify.org?format=json' 2>/dev/null || true)
  local elapsed=$((($(date +%s%N)-t)/1000000))
  kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
  [[ -n "$result" ]] || return 1
  country=$(printf '%s' "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("countryCode","??"))' 2>/dev/null || echo '??')
  printf '%s|%s|%s\n' "$elapsed" "$country" "$node"
}

# ─── Source loading ────────────────────────────────────────────────────────────
load_urls(){
  if [[ -z "${EXTERNAL_SUB_URLS:-}" ]]; then
    printf '%s\n' "$DEFAULT_EXTERNAL_SUB"
  else
    printf '%s\n' "$EXTERNAL_SUB_URLS" | tr ',' '\n'
  fi
}

# ─── Consecutive-failure state ────────────────────────────────────────────────
update_state(){ python3 - "$POOL_STATE" "$1" "$2" <<'PY'
import sys,json,os
p,node,ok=sys.argv[1],sys.argv[2],sys.argv[3]
st={}
if os.path.exists(p):
 try: st=json.load(open(p))
 except Exception: pass
k=node[:80]
st.setdefault(k,{'fails':0})
st[k]['fails']=0 if ok=='0' else st[k].get('fails',0)+1
json.dump(st,open(p,'w'))
PY
}
bump_fail(){ python3 - "$POOL_STATE" "$1" "$MAX_CONSEC_FAIL" <<'PY' | grep -q '^1$'
import sys,json,os
p,node,lim=sys.argv[1],sys.argv[2],int(sys.argv[3])
st={}
if os.path.exists(p):
 try: st=json.load(open(p))
 except Exception: pass
k=node[:80]; f=st.get(k,{}).get('fails',0)+1
print('1' if f>=lim else '0')
st[k]={'fails':f}
json.dump(st,open(p,'w'))
PY
}

# ─── Leaderboard (per-sub top 10, JSON) ───────────────────────────────────────
# Read the leaderboard dict from disk.  Returns an empty dict if missing.
read_leaderboard(){
  python3 - "$LEADERBOARD" <<'PY'
import sys,json,os
p=sys.argv[1]
if os.path.exists(p):
 try: print(json.dumps(json.load(open(p)))); raise SystemExit
 except: pass
print('{}')
PY
}

# Insert a candidate into the per-sub leaderboard.
# $1=subscription_name  $2=latency_ms  $3=country  $4=normalised_json
leaderboard_insert(){
  python3 - "$LEADERBOARD" "$1" "$2" "$3" "$4" <<'PY'
import sys,json,os,bisect
lb_path,sub,lat,country,node=sys.argv[1:]; lat=int(lat)
lb={}
if os.path.exists(lb_path):
 try: lb=json.load(open(lb_path))
 except: pass
entries=lb.get(sub,[])

# Resolve the new node's host for dedupe
skip=False
try:
 n=json.loads(node); host=(n.get('host') or n.get('add') or '').lower(); proto=n.get('_proto','?')
except Exception:
 skip=True
if not skip and host:
    # Drop any existing entry with the same host+proto (a faster clone replaces it).
    # If an existing entry with the same host+proto is EQUAL-or-better, skip insert.
    removed=[]
    for e in entries:
        try:
            en=json.loads(e['node']); eh=(en.get('host') or en.get('add') or '').lower()
        except Exception: continue
        if eh==host and en.get('_proto')==proto:
            if e['latency']<=lat:
                skip=True
                break
            removed.append(e)
    if not skip:
        lb[sub]=[e for e in entries if e not in removed]
        entries=lb.get(sub,[])

if skip:
    json.dump(lb, open(lb_path,'w'), ensure_ascii=False, indent=2)
    raise SystemExit(0)

# Insert in sorted position (lowest latency first)
keys=[e['latency'] for e in entries]
pos=bisect.bisect_left(keys, lat)
entries.insert(pos, {'latency':lat, 'country':country, 'node':node})
# Cap at BEST_PER_SUB equivalent (hard 10; the per-sub cap is enforced by
# BEST_PER_SUB at pool-build time)
if len(entries)>10: entries=entries[:10]
lb[sub]=entries
os.makedirs(os.path.dirname(lb_path) or '.', exist_ok=True)
json.dump(lb, open(lb_path,'w'), ensure_ascii=False, indent=2)
PY
}

# ─── Parallel health probe ─────────────────────────────────────────────────────
# Test up to PARALLEL_PROBES nodes concurrently.  Each probe writes
# latency|country|node_json to a temp file; we collect them after all finish.
# $1 = subscription name, $2+ = node json strings
parallel_test(){
  local sub="$1"; shift
  local -a nodes=("$@")
  local total=${#nodes[@]}
  [[ $total -eq 0 ]] && return 0

  local tmp_dir="$AUX_DIR/.health-$$"
  mkdir -p "$tmp_dir"
  local port_base=$((21000 + RANDOM % 1000))

  # Launch all probes concurrently via probe-node.sh (standalone — no parent
  # functions needed). xargs -P caps at PARALLEL_PROBES. Each probe writes
  # latency|country|node_json to stdout; we collect after all finish.
  # shellcheck disable=SC2097,SC2098  # env prefix intentionally reaches xargs children
  printf '%s\n' "${nodes[@]}" | \
    PARALLEL_PROBES=$PARALLEL_PROBES XRAY_BIN="$XRAY_BIN" AUX_DIR="$AUX_DIR" \
    AUX_LOG="$AUX_LOG" HEALTH_TIMEOUT="$HEALTH_TIMEOUT" PORT_BASE=$port_base \
    xargs -I{} -P "$PARALLEL_PROBES" \
    bash "$ROOT/scripts/agent/probe-node.sh" {} \
    > "$tmp_dir/probe-out" 2>/dev/null || true

  # Update leaderboard with results
  while IFS='|' read -r rl rc rn; do
    [[ -n "$rn" ]] || continue
    leaderboard_insert "$sub" "$rl" "$rc" "$rn" 2>/dev/null || true
  done < "$tmp_dir/probe-out"

  # Report — verbose: list every probe result for this sub, tagging each with the
  # parent sub + host so a failing config is visible right next to the healthy
  # ones. We diff the passed node set ($tmp_dir/probe-out) against the input
  # nodes to label the dead ones.
  local pass
  pass=$(wc -l < "$tmp_dir/probe-out" 2>/dev/null || echo 0)
  local dead=$((total - pass))
  PASS_SET="$tmp_dir/probe-out" NODES_STR="$(
    for n in "${nodes[@]}"; do printf '%s\n' "$n"; done)" python3 - "$sub" <<'PY' || true
import sys,os
sub=sys.argv[1]
passed=set()
for line in open(os.environ['PASS_SET'],errors='ignore'):
 lst=line.rstrip('\n').rsplit('|',2)
 if len(lst)==3: passed.add(lst[2])
def host(n):
 try:
  import json; x=json.loads(n); return (x.get('host') or x.get('add') or '?').lower()
 except Exception: return '?'
dead=[]
for n in os.environ['NODES_STR'].splitlines():
 if n and n not in passed: dead.append(host(n))
for n in sorted(passed): print('  [%s] OK  %s' % (sub, host(n)))
for h in dead: print('  [%s] FAIL %s' % (sub, h))
PY
  rm -rf "$tmp_dir"
  if [[ $dead -gt 0 ]]; then
    log "$sub: $pass/$total alive, $dead dead (leaderboard top 10 maintained)"
  else
    log "$sub: $pass/$total alive, all passing"
  fi
}

# ─── Health-only cycle (re-test existing pool, 10-at-a-time parallel) ──────────
health_only(){
  [[ -s "$POOL_FILE" ]] || { log "pool empty; waiting for a source refresh"; return 0; }

  # Collect all nodes per sub for batch parallel testing
  declare -A sub_nodes=()
  declare -A sub_pool=()   # sub → "lat|country|node" for existing pool rows
  while IFS=$'\t' read -r name latency country node; do
    [[ -n "$name" && -n "$node" ]] || continue
    sub_nodes["$name"]+="${node}"$'\n'
    sub_pool["$name"]+="${latency}|${country}|${node}"$'\n'
  done < "$POOL_FILE"

  local -a kept_rows=()
  local total=0 rej=0
  declare -A alive_hosts=()

  for sub in "${!sub_nodes[@]}"; do
    local -a nodes=()
    while IFS= read -r n; do
      [[ -n "$n" ]] && nodes+=("$n")
    done <<< "${sub_nodes[$sub]}"
    [[ ${#nodes[@]} -eq 0 ]] && continue
    total=$((total + ${#nodes[@]}))

    # One parallel pass (10 at a time). parallel_test probes all nodes through
    # ip-api.com and updates the leaderboard with fresh latency/country.
    parallel_test "$sub" "${nodes[@]}"

    # The fresh leaderboard top-10 for this sub = surviving, latency-sorted set.
    # A node that full-test passed is in it; one that failed is not.
    local lb_entries
    lb_entries=$(python3 - "$LEADERBOARD" "$sub" <<'PY'
import sys,json
lb,sub=sys.argv[1:]
try: d=json.load(open(lb))
except: d={}
for e in d.get(sub,[]):
 print("%s\t%s\t%s\t%s" % (sub,e['latency'],e['country'],e['node']))
PY
    )

    # Track hosts that came back alive so we can tell "pool node failed" from
    # "replaced". Use host as the dedupe key.
    while IFS=$'\t' read -r lsub llat lcountry lnode; do
      [[ -n "$lnode" ]] || continue
      local lbhost
      lbhost=$(printf '%s' "$lnode" | python3 -c 'import sys,json; x=json.load(sys.stdin); print((x.get("host") or x.get("add") or "").lower())' 2>/dev/null)
      [[ -n "$lbhost" ]] && alive_hosts["$lbhost"]=1
      kept_rows+=("$lsub|$llat|$lcountry|$lnode")
    done <<< "$lb_entries"

    # Prune the leaderboard for this sub: only keep entries whose host was
    # verified alive via ip-api this cycle.  Anything that failed the full test
    # (or was evicted) is dropped so it never re-enters the published list.
    local alive_str=""
    for h in "${!alive_hosts[@]}"; do alive_str+="${h}|"; done
    ALIVE_HOSTS="$alive_str" python3 - "$LEADERBOARD" "$sub" <<'PY'
import sys,json,os
lb_path,sub=sys.argv[1],sys.argv[2]
lb={}
if os.path.exists(lb_path):
    try: lb=json.load(open(lb_path))
    except: lb={}
entries=lb.get(sub,[])
alive=set()
for h in os.environ.get('ALIVE_HOSTS','').split('|'):
    if h: alive.add(h)
out=[]
for e in entries:
    n=json.loads(e['node']); h=(n.get('host') or n.get('add') or '').lower()
    if h in alive: out.append(e)
lb[sub]=out
json.dump(lb,open(lb_path,'w'),ensure_ascii=False,indent=2)
PY

    # Now decide fate of the OLD pool rows: if their host came back alive keep;
    # if it disappeared (probe failed), apply MAX_CONSEC_FAIL drop logic.
    while IFS=$'\t' read -r lname llat lcountry lnode; do
      [[ -n "$lnode" ]] || continue
      local oldhost
      oldhost=$(printf '%s' "$lnode" | python3 -c 'import sys,json; x=json.load(sys.stdin); print((x.get("host") or x.get("add") or "").lower())' 2>/dev/null)
      if [[ -n "$oldhost" && -n "${alive_hosts[$oldhost]:-}" ]]; then
        # Alive via the parallel pass — already counted above; ensure success state
        update_state "$lnode" 0
        continue
      fi
      # Not alive in this pass: TCP check for the runner-egress false-negative case
      if tcp_ping "$lnode"; then
        update_state "$lnode" 0
        # It may have been dropped from the top-10 by faster new nodes; keep its
        # old latency so it can re-enter if not already present.
        if [[ -z "${alive_hosts[$oldhost]:-}" ]]; then
          kept_rows+=("$lname|$llat|$lcountry|$lnode")
        fi
      elif bump_fail "$lnode"; then
        rej=$((rej + 1))
        log "dropped (${MAX_CONSEC_FAIL} consecutive fails): $lname ${lnode:0:40}"
      else
        # Not yet at drop threshold — carry forward
        if [[ -z "${alive_hosts[$oldhost]:-}" ]]; then
          kept_rows+=("$lname|$llat|$lcountry|$lnode")
        fi
      fi
    done <<< "${sub_pool[$sub]}"
  done

  # Rebuild pool.tsv from the kept set
  : > "$POOL_FILE"
  for row in "${kept_rows[@]}"; do
    IFS='|' read -r name lat c node <<< "$row"
    printf '%s\t%s\t%s\t%s\n' "$name" "$lat" "$c" "$node" >> "$POOL_FILE"
  done

  if [[ $rej -gt 0 ]]; then
    log "health pass: ${#kept_rows[@]} in pool ($total probed parallel, $rej dropped)"
  else
    log "health pass: ${#kept_rows[@]} in pool, all alive (parallel, ${PARALLEL_PROBES} concurrent)"
  fi
  finalize
}

# ─── Full source refresh (parallel 10-at-a-time) ──────────────────────────────
refresh_sources(){
  declare -A seen=()

  # Seed leaderboard with existing pool entries (so unreachable subs don't wipe the set)
  if [[ -s "$POOL_FILE" ]]; then
    while IFS=$'\t' read -r name latency country node; do
      [[ -n "$name" && -n "$node" ]] || continue
      leaderboard_insert "$name" "$latency" "$country" "$node" 2>/dev/null || true
    done < "$POOL_FILE"
  fi

  while IFS= read -r url; do
    [[ -z "$url" || -n "${seen[$url]:-}" ]] && continue
    seen[$url]=1; local name; name=$(sub_name "$url")
    local content; content=$(fetch_sub "$url" || true)
    [[ -n "$content" ]] || { warn "No nodes from $url (keeping existing pool)"; continue; }

    local -a nodes=()
    while IFS= read -r line; do
      local node; node=$(normalise "$line" 2>/dev/null || true); [[ -n "$node" ]] || continue
      nodes+=("$node")
      (( ${#nodes[@]} >= 120 )) && break
    done <<< "$content"

    # TCP pre-filter: skip dead hosts before the expensive xray probe
    local -a good_nodes=()
    for node in "${nodes[@]}"; do
      tcp_ping "$node" || continue
      good_nodes+=("$node")
    done
    log "$name: ${#good_nodes[@]}/${#nodes[@]} passed TCP pre-filter"

    # Run parallel health probes (10 at a time) for this sub
    parallel_test "$name" "${good_nodes[@]}"

  done < <(load_urls)

  # Rebuild pool.tsv from leaderboard
  rebuild_pool_from_leaderboard
  finalize
}

# ─── Pool rebuild from leaderboard ─────────────────────────────────────────────
# Reads pool-leaderboard.json, keeps BEST_PER_SUB per sub (deduped by host),
# and writes the flat pool.tsv.
rebuild_pool_from_leaderboard(){
  python3 - "$LEADERBOARD" "$POOL_FILE" "$BEST_PER_SUB" <<'PY'
import sys,json,collections
lb_path,out_path,limit=sys.argv[1],sys.argv[2],int(sys.argv[3])
lb={}
try: lb=json.load(open(lb_path))
except: pass
lines=[]
seen_hosts=set()
for sub,entries in lb.items():
 count=0
 for e in entries:
  if count>=limit: break
  node=e.get('node','')
  try:
   n=json.loads(node); host=(n.get('host') or n.get('add') or '').lower()
   if host and host in seen_hosts: continue
   if host: seen_hosts.add(host)
  except: pass
  lines.append('%s\t%s\t%s\t%s' % (sub, e['latency'], e['country'], node))
  count+=1
with open(out_path,'w') as f: f.write('\n'.join(lines)+'\n' if lines else '')
total=sum(len(v) for v in lb.values())
print('pool: %d configs across %d subs (leaderboard total: %d entries)' % (len(lines), len(lb), total))
PY
}

# ─── Merge subscription output ─────────────────────────────────────────────────
write_merged_sub(){
  [[ -s "${SUB_DIR}/subscription.b64" ]] || return 0
  local base; base=$(base64 -d "${SUB_DIR}/subscription.b64" 2>/dev/null || true)
  [[ -n "$base" ]] || return 0
  python3 - "$POOL_FILE" "$base" <<'PY' > "$SUB_DIR/external-healthy.txt"
import sys,json,urllib.parse,base64,re
p,b64=sys.argv[1:]
lines=[l for l in b64.split('\n') if l.strip()]
def is_external(line):
    if '#' in line:
        frag=line.rsplit('#',1)[1]
        if frag.startswith('External-'): return True
    m=re.match(r'^vmess://(.+)$',line)
    if m:
        try:
            d=json.loads(base64.b64decode(m.group(1)+'='*((-len(m.group(1)))%4)))
            if str(d.get('ps','')).startswith('External-'): return True
        except Exception: pass
    return False
flags=lambda c: ''.join(chr(127397+ord(x)) for x in c.upper()) if len(c)==2 else '🌐'
from collections import defaultdict
ext_groups = defaultdict(list)
for line in open(p,errors='ignore'):
    a=line.rstrip('\n').split('\t')
    if len(a)!=4: continue
    sub,lat,c,node=a
    lat=int(lat)
    x=json.loads(node)
    proto=x['_proto']
    host=x.get('host') or x.get('add')
    port=x.get('port',443)
    ext_groups[sub].append({'latency':lat,'country':c,'proto':proto,'host':host,'port':port,'node':node})
kept = []
for sub, configs in ext_groups.items():
    configs.sort(key=lambda c: c['latency'])
    for idx, cfg in enumerate(configs[:10], 1):
        cfg['index'] = idx
        kept.append((sub, cfg))
for line in lines:
    if not is_external(line): print(line)
for sub, cfg in kept:
    lat=cfg['latency']; c=cfg['country']; proto=cfg['proto']
    host=cfg['host']; port=cfg['port']; idx=cfg['index']
    remark=f'External-{flags(c)}-{proto.upper()}-{lat}ms-{idx:03d}'
    x=json.loads(cfg['node'])
    if proto=='vmess':
        x['ps']=remark
        raw=json.dumps({k:v for k,v in x.items() if not k.startswith('_')},ensure_ascii=False).encode()
        link='vmess://'+base64.b64encode(raw).decode()
    else:
        u=urllib.parse.quote(x.get('user',''),safe='')
        q={'type':x.get('type','tcp'),'security':x.get('security','')}
        if x.get('path'): q['path']=x['path']
        if x.get('sni'): q['sni']=x['sni']
        if x.get('serviceName'): q['serviceName']=x['serviceName']
        if x.get('flow'): q['flow']=x['flow']
        if x.get('pbk'): q['pbk']=x['pbk']
        if x.get('sid'): q['sid']=x['sid']
        if x.get('fp'): q['fp']=x['fp']
        if x.get('method'): q['method']=x['method']
        query=urllib.parse.urlencode(q)
        link=f'{proto}://{u}@{host}:{port}?{query}#{urllib.parse.quote(remark)}'
    print(link)
PY
  cat "$SUB_DIR/external-healthy.txt" | base64 -w0 > "$SUB_DIR/subscription.b64"
  push_sub
}

push_sub(){
  [[ -s "$SUB_DIR/subscription.b64" ]] || return 0
  [[ -n "${WORKER_URL:-}" ]] || return 0
  curl -fsS --max-time 10 -X POST \
    -H "Content-Type: text/plain; charset=utf-8" \
    -H "x-gayroxy-token: ${API_TOKEN:-}" \
    --data-binary @"$SUB_DIR/subscription.b64" \
    "$WORKER_URL/api/sub" >/dev/null 2>&1 \
    && log "Pushed merged subscription to KV" 2>/dev/null || true
}

# ─── Health JSON report ────────────────────────────────────────────────────────
write_health_json(){
  python3 - "$POOL_FILE" "$AUX_DIR/health.json" "$LEADERBOARD" \
    "$AUX_DIR/rotate1min-state.json" "$AUX_DIR/rotate2min-state.json" "$AUX_DIR/rotate5min-state.json" \
    "$AUX_DIR/rotatewarp2min-state.json" "$AUX_DIR/rotatewarp4min-state.json" "$AUX_DIR/rotatewarp6min-state.json" <<'PY'
import sys,json,datetime,collections,os
p,out,lb_path,r1,r2,r5,wr2,wr4,wr6=sys.argv[1:]
d=collections.defaultdict(list)
for line in open(p,errors='ignore'):
 parts=line.rstrip('\n').split('\t')
 if len(parts)==4: d[parts[0]].append({'latencyMs':int(parts[1]),'country':parts[2]})
lb={}
try: lb=json.load(open(lb_path))
except: pass
lb_summary={}
for sub,entries in lb.items():
 lb_summary[sub]={'topConfigs':[{'latencyMs':e['latency'],'country':e['country']} for e in entries[:10]]}
result={'checkedAt':datetime.datetime.utcnow().isoformat()+'Z','sources':d,'leaderboard':lb_summary}
rotations={}
for tier,state_path in (('1min',r1),('2min',r2),('5min',r5),('warp2min',wr2),('warp4min',wr4),('warp6min',wr6)):
 if not os.path.exists(state_path): continue
 try:
  s=json.load(open(state_path))
  if isinstance(s,dict) and s.get('tag'):
   rotations[tier]={'tag':s.get('tag'),'country':s.get('country'),'host':s.get('host')}
 except Exception: pass
if rotations:
 result['rotations']=rotations
 result['rotation']={'enabled':True,'algorithms':sorted(rotations.keys())}
else:
 result['rotation']={'enabled':False}
json.dump(result,open(out,'w'),ensure_ascii=False,indent=2)
PY
  if [[ -n "$WORKER_URL" ]]; then
    curl -fsS --max-time 10 -X POST -H "Content-Type: application/json" -H "x-gayroxy-token: $API_TOKEN" --data-binary @"$AUX_DIR/health.json" "$WORKER_URL/api/health" >/dev/null 2>&1 || true
  fi
}

# ─── Rotation config generation ────────────────────────────────────────────────
# Generate an xray rotation config for a given interval + listen port.
# $1 = interval_seconds, $2 = listen_port, $3 = output_config_path,
# $4 = meta_output_path, $5 = state_output_path,
# $6 = uuid, $7 = ws_path, $8 = main_country, $9 = main_host
gen_rotate_config(){
  # interval is a named parameter for readability; the actual delay lives in
  # the loop's sleep. The listen port is embedded in the config below.
  # shellcheck disable=SC2034
  local interval="$1" port="$2" cfg_out="$3" meta_out="$4" state_out="$5"
  local uuid="$6" ws_path="$7" main_country="$8" main_host="$9"

  # Get runner's exit country. Caller passes it as $8 (already computed once in
  # write_all_rotate_configs); fall back to a direct lookup only if empty so we
  # never hit ip-api three times per finalize.
  local run_country="$main_country"
  if [[ -z "$run_country" || "$run_country" == "??" ]]; then
    run_country=$(curl -fsS --max-time 5 'http://ip-api.com/json?fields=countryCode' 2>/dev/null \
      | python3 -c 'import json,sys; print(json.load(sys.stdin).get("countryCode","??"))' 2>/dev/null \
      || echo '??')
  fi

  python3 - "$POOL_FILE" "$cfg_out" "$meta_out" "$state_out" "$uuid" "$ws_path" "$run_country" "$main_host" "$port" <<'PY'
import sys,json,os
pool,out,meta_path,state_path,uuid,path,main_country,main_host,listen_port=sys.argv[1:]
WARP_PORT=int(os.environ.get('WARP_PORT','40000'))
obs=[]; meta=[]
meta.append('pool-main\t%s\t%s' % (main_country, main_host))
# Always offer WARP egress (SOCKS5 on WARP_PORT) so rotation has a working,
# datacenter-accepted exit even when every external node is down. This is the
# free always-on rotating egress. Skipped if WARP didn't come up on the runner.
if os.environ.get('WARP_ACTIVE')=='true':
    meta.append('pool-warp\tWARP\t127.0.0.1')
    obs.append({'tag':'pool-warp','protocol':'socks',
        'settings':{'servers':[{'address':'127.0.0.1','port':WARP_PORT}]}})
for n,line in enumerate(open(pool,errors='ignore')):
 a=line.rstrip('\n').split('\t')
 if len(a)!=4: continue
 try:
  x=json.loads(a[3]); p=x['_proto']; host=x.get('host') or x.get('add'); port=int(x.get('port') or 443)
  meta.append('pool-%d\t%s\t%s' % (n, a[2], host))
  stream={'network':x.get('type') or 'tcp'}
  net=stream['network']
  if net=='ws': stream['wsSettings']={'path':x.get('path') or '/','headers':{'Host':host}}
  elif net=='grpc': stream['grpcSettings']={'serviceName':x.get('serviceName') or ''}
  elif net=='httpupgrade': stream['httpupgradeSettings']={'path':x.get('path') or '/','host':host}
  if x.get('security')=='tls' or x.get('tls')=='tls': stream['security']='tls'; stream['tlsSettings']={'serverName':x.get('sni') or host,'fingerprint':x.get('fp') or 'chrome'}
  tag='pool-%d'%n
  if p=='vless': o={'tag':tag,'protocol':'vless','settings':{'vnext':[{'address':host,'port':port,'users':[{'id':x.get('user',''),'encryption':'none','flow':x.get('flow','')}]}]},'streamSettings':stream}
  elif p=='vmess': o={'tag':tag,'protocol':'vmess','settings':{'vnext':[{'address':host,'port':port,'users':[{'id':x.get('id',''),'alterId':int(x.get('aid',0) or 0),'security':'auto'}]}]},'streamSettings':stream}
  elif p=='trojan': o={'tag':tag,'protocol':'trojan','settings':{'servers':[{'address':host,'port':port,'password':x.get('user','')}]},'streamSettings':stream}
  elif p=='ss': o={'tag':tag,'protocol':'shadowsocks','settings':{'servers':[{'address':host,'port':port,'method':x.get('method','aes-256-gcm'),'password':x.get('user','')}]},'streamSettings':stream}
  else: continue
  obs.append(o)
 except Exception: pass
if not obs: obs=[{'tag':'pool-main','protocol':'freedom'}]
else:
    if not any(o['tag']=='pool-main' for o in obs): obs.append({'tag':'pool-main','protocol':'freedom'})
open(meta_path,'w').write('\n'.join(meta)+'\n')
first=next((o['tag'] for o in obs if o['tag'].startswith('pool-')),'pool-main')
c={'log':{'loglevel':'warning'},'inbounds':[{'tag':'rotate','listen':'127.0.0.1','port':int(listen_port),'protocol':'vless','settings':{'clients':[{'id':uuid}],'decryption':'none'},'streamSettings':{'network':'ws','security':'none','wsSettings':{'path':path}}}],'outbounds':obs,'routing':{'rules':[{'type':'field','inboundTag':['rotate'],'outboundTag':first}]}}
json.dump(c,open(out,'w'),indent=2)
# Seed rotation state
py_meta={}
for m in meta:
 parts=m.split('\t')
 if len(parts)==3: py_meta[parts[0]]=(parts[1],parts[2])
seed=py_meta.get(first)
if seed:
 json.dump({'tag':first,'country':seed[0],'host':seed[1]},open(state_path,'w'))
PY
}

# ─── WARP rotation config ───────────────────────────────────────────────────
# Builds one aux xray whose outbounds are the 3 WARP planes (distinct free
# egress IPs). The rotate inbound cycles through them via pick_next, so one
# client config changes its egress IP/location on a fixed cadence. Meta rows use
# synthetic host labels (warp-ip-0/1/2) so pick_next sees distinct "hosts" and
# rotates across all three planes instead of bouncing.
# $1 = config out, $2 = meta out, $3 = state out, $4 = uuid, $5 = ws path,
# $6 = listen port
gen_warp_rotate_config(){
  local cfg_out="$1" meta_out="$2" state_out="$3" uuid="$4" ws_path="$5" listen_port="$6"
  python3 - "$cfg_out" "$meta_out" "$state_out" "$uuid" "$ws_path" "$listen_port" <<'PY'
import sys,json,os
out,meta_path,state_path,uuid,path,listen_port=sys.argv[1:]
ports=[int(p) for p in os.environ.get('WARP_PLANE_PORTS','').split() if p.strip()][:3]
if not ports:
    # No WARP planes => write an empty config (nothing to proxy) and bail.
    open(out,'w').write('{}')
    sys.exit(0)
obs=[]; meta=[]
for i,p in enumerate(ports):
    tag='warp-%d'%i
    obs.append({'tag':tag,'protocol':'socks','settings':{'servers':[{'address':'127.0.0.1','port':p,'udp':True}]}})
    # Synthetic distinct host label so pick_next treats each plane as unique.
    meta.append('%s\tWARP\twarp-ip-%d' % (tag,i))
c={'log':{'loglevel':'warning'},
   'inbounds':[{'tag':'rotate','listen':'127.0.0.1','port':int(listen_port),'protocol':'vless','settings':{'clients':[{'id':uuid}],'decryption':'none'},'streamSettings':{'network':'ws','security':'none','wsSettings':{'path':path}}}],
   'outbounds':obs,'routing':{'rules':[{'type':'field','inboundTag':['rotate'],'outboundTag':'warp-0'}]}}
json.dump(c,open(out,'w'),indent=2)
open(meta_path,'w').write('\n'.join(meta)+'\n')
json.dump({'tag':'warp-0','country':'WARP','host':'warp-ip-0'},open(state_path,'w'))
PY
}
pick_next(){ python3 - "$1" "$2" <<'PY'
import json,sys,os,random
meta_path,state_path=sys.argv[1],sys.argv[2]
meta={}
for line in open(meta_path,errors='ignore'):
 a=line.rstrip('\n').split('\t')
 if len(a)==3: meta[a[0]]={'country':a[1],'host':a[2]}
if not meta: raise SystemExit(1)
state={}
if os.path.exists(state_path):
 try: state=json.load(open(state_path))
 except: state={}
prev=state.get('tag'); ph=state.get('host'); recent=state.get('recent',[])
tags=list(meta)
# Prefer a node whose HOST hasn't been used recently and differs from the
# current one, expanding the rotation beyond a 2-node bounce. Tie-break random.
recent_hosts=set(recent)
fresh=[t for t in tags if t!=prev and meta[t]['host']!=ph and meta[t]['host'] not in recent_hosts]
if not fresh: fresh=[t for t in tags if t!=prev and meta[t]['host']!=ph]
if not fresh: fresh=[t for t in tags if t!=prev]
if not fresh: fresh=[prev]
t=random.choice(fresh)
sel=meta[t]
# Track a small recency window (hosts) so we cycle across all distinct egresses.
recent=[h for h in recent if h!=sel['host']]
recent.insert(0,sel['host'])
recent=recent[:6]
json.dump({'tag':t,'country':sel['country'],'host':sel['host'],'recent':recent},open(state_path,'w'))
print(t)
PY
}

# ─── Start an aux xray instance ───────────────────────────────────────────────
# $1 = config path, $2 = log path, $3 = pid-file path. The previous instance (if
# any) is stopped and we wait for its bind port to free before launching the new
# one, so two xrays never fight over the same listen port. The live PID is
# recorded in the pid file for parent cleanup.
start_aux_xray(){
  local cfg="$1" logf="$2" pidfile="$3" old pid port
  if [[ ! -x "$XRAY_BIN" ]]; then
    rm -f "$pidfile"
    warn "xray binary missing; skipping launch ($cfg)"
    return 0
  fi
  old=$(cat "$pidfile" 2>/dev/null || true)
  if [[ -n "$old" ]] && kill -0 "$old" 2>/dev/null; then
    kill "$old" 2>/dev/null || true
  fi
  port=$(python3 - "$cfg" <<'PY'
import sys,json
try: print(json.load(open(sys.argv[1]))['inbounds'][0].get('port','')); sys.exit(0)
except Exception: sys.exit(1)
PY
  )
  # Give the dying process a moment to release the bind port so a freshly
  # launched xray never collides with the one it is replacing.
  if [[ -n "$port" ]]; then
    # shellcheck disable=SC2034  # loop waits until the port is free
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      if ! (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then break; fi
      exec 3>&- 3<&- 2>/dev/null || true
      sleep .1
    done
  fi
  "$XRAY_BIN" run -c "$cfg" >"$logf" 2>&1 &
  pid=$!
  printf '%s\n' "$pid" > "$pidfile"
  sleep .5
  kill -0 "$pid" 2>/dev/null || warn "aux xray ($cfg) failed to start"
}

# ─── Set a rotation target directly ────────────────────────────────────────────
# Rewrites the aux xray config so its rotate inbound routes straight to $1 (the
# selected node). We avoid a selector balancer here: a plain selector
# round-robins across its members, so it would NOT honor the scheduled lead, and
# including `pool-main` (direct freedom egress) would defeat rotation entirely.
# Direct routing makes the exit deterministic and exactly what the schedule says.
# NOTE: `fallbackTag` is deliberately NOT used — this xray build (26.x) rejects
# it at startup ("not all dependencies are resolved") and the process dies
# immediately.
set_rotate_target(){
  local cfg="$1" lead="$2"
  python3 - "$cfg" "$lead" <<'PY'
import sys,json
cfg_path,lead=sys.argv[1],sys.argv[2]
d=json.load(open(cfg_path))
obs=d.get('outbounds',[])
# Any named routing target (pool-* external nodes, warp-* WARP planes, direct).
tags=[o['tag'] for o in obs if isinstance(o.get('tag'),str)]
if not tags:
    json.dump(d,open(cfg_path,'w'),indent=2); raise SystemExit
# Honor the requested lead if it actually exists in this config's outbounds,
# otherwise fall back to the first one. A stale `lead` must never be
# referenced: xray 26.x crashes at startup ("not all dependencies are resolved")
# if a routing target doesn't resolve to an existing outbound.
target=lead if lead in tags else tags[0]
# Point the rotate inbound directly at the selected outbound. A plain selector
# balancer round-robins across all members and so would NOT honor the scheduled
# lead (rotation would be effectively random), and `pool-main` (direct freedom
# egress) in the chain defeats rotation entirely. Direct routing is
# deterministic: every connection egresses through exactly the selected node
# until the loop rotates again.
rules=d.setdefault('routing',{}).get('rules',[])
for r in rules:
    if r.get('inboundTag')==['rotate'] or r.get('inboundTag')=='rotate':
        r.pop('balancerTag',None); r['outboundTag']=target
        break
else:
    rules.append({'type':'field','inboundTag':['rotate'],'outboundTag':target})
json.dump(d,open(cfg_path,'w'),indent=2)
print(target)
PY
}

# ─── Rotation loops (three tiers) ─────────────────────────────────────────────
# Each loop is the SOLE owner of its aux xray: it starts it on the first pass
# (so egress is live immediately, independent of any finalize), then rotates the
# target and restarts it on the configured cadence. write_all_rotate_configs
# only regenerates configs — it never restarts, so the parent and a loop can
# never fight over the same port.
update_rotate_target(){
  local cfg="$1" meta="$2" state="$3" logf="$4" pidfile="$5" reason="$6"
  [[ -f "$cfg" && -f "$meta" ]] || return 0
  local prev_host next ncountry nhost port
  # Read the CURRENT egress before rotating so the log shows old → new.
  prev_host=$(python3 - "$state" 2>/dev/null <<'PY' || true
import sys,json
try:
 s=json.load(open(sys.argv[1])); print(s.get('host','?') or '?')
except Exception: print('?')
PY
)
  next=$(pick_next "$meta" "$state" 2>/dev/null || true)
  [[ -n "$next" ]] || return 0
  # The chosen egress from the meta TSV (tag \t country \t host).
  read -r ncountry nhost <<< "$(awk -F'\t' -v t="$next" '$1==t{print $2"\t"$3; exit}' "$meta")"
  port=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["inbounds"][0].get("port","?"))' "$cfg" 2>/dev/null || echo '?')
  set_rotate_target "$cfg" "$next"
  start_aux_xray "$cfg" "$logf" "$pidfile"
  log "Rotate[$reason]: host $prev_host → $next (${ncountry:-?}, ${nhost:-?}) on port $port"
}

rotate_loop_1min(){
  update_rotate_target "$ROTATE1MIN_CONFIG" "$ROTATE1MIN_META" "$ROTATE1MIN_STATE" \
    "$AUX_LOG/rotate1min.log" "$ROTATE1MIN_PID" "1min"
  while :; do
    sleep "$ROTATE1MIN_INTERVAL"
    update_rotate_target "$ROTATE1MIN_CONFIG" "$ROTATE1MIN_META" "$ROTATE1MIN_STATE" \
      "$AUX_LOG/rotate1min.log" "$ROTATE1MIN_PID" "1min"
  done
}

rotate_loop_2min(){
  update_rotate_target "$ROTATE2MIN_CONFIG" "$ROTATE2MIN_META" "$ROTATE2MIN_STATE" \
    "$AUX_LOG/rotate2min.log" "$ROTATE2MIN_PID" "2min"
  while :; do
    sleep "$ROTATE2MIN_INTERVAL"
    update_rotate_target "$ROTATE2MIN_CONFIG" "$ROTATE2MIN_META" "$ROTATE2MIN_STATE" \
      "$AUX_LOG/rotate2min.log" "$ROTATE2MIN_PID" "2min"
  done
}

rotate_loop_5min(){
  update_rotate_target "$ROTATE5MIN_CONFIG" "$ROTATE5MIN_META" "$ROTATE5MIN_STATE" \
    "$AUX_LOG/rotate5min.log" "$ROTATE5MIN_PID" "5min"
  while :; do
    sleep "$ROTATE5MIN_INTERVAL"
    update_rotate_target "$ROTATE5MIN_CONFIG" "$ROTATE5MIN_META" "$ROTATE5MIN_STATE" \
      "$AUX_LOG/rotate5min.log" "$ROTATE5MIN_PID" "5min"
  done
}

rotate_loop_warp_2min(){
  update_rotate_target "$ROTATE_WARP2MIN_CONFIG" "$ROTATE_WARP2MIN_META" "$ROTATE_WARP2MIN_STATE" \
    "$AUX_LOG/rotatewarp2min.log" "$ROTATE_WARP2MIN_PID" "warp2min"
  while :; do
    sleep "$ROTATEWARP2MIN_INTERVAL"
    update_rotate_target "$ROTATE_WARP2MIN_CONFIG" "$ROTATE_WARP2MIN_META" "$ROTATE_WARP2MIN_STATE" \
      "$AUX_LOG/rotatewarp2min.log" "$ROTATE_WARP2MIN_PID" "warp2min"
  done
}

rotate_loop_warp_4min(){
  update_rotate_target "$ROTATE_WARP4MIN_CONFIG" "$ROTATE_WARP4MIN_META" "$ROTATE_WARP4MIN_STATE" \
    "$AUX_LOG/rotatewarp4min.log" "$ROTATE_WARP4MIN_PID" "warp4min"
  while :; do
    sleep "$ROTATEWARP4MIN_INTERVAL"
    update_rotate_target "$ROTATE_WARP4MIN_CONFIG" "$ROTATE_WARP4MIN_META" "$ROTATE_WARP4MIN_STATE" \
      "$AUX_LOG/rotatewarp4min.log" "$ROTATE_WARP4MIN_PID" "warp4min"
  done
}

rotate_loop_warp_6min(){
  update_rotate_target "$ROTATE_WARP6MIN_CONFIG" "$ROTATE_WARP6MIN_META" "$ROTATE_WARP6MIN_STATE" \
    "$AUX_LOG/rotatewarp6min.log" "$ROTATE_WARP6MIN_PID" "warp6min"
  while :; do
    sleep "$ROTATEWARP6MIN_INTERVAL"
    update_rotate_target "$ROTATE_WARP6MIN_CONFIG" "$ROTATE_WARP6MIN_META" "$ROTATE_WARP6MIN_STATE" \
      "$AUX_LOG/rotatewarp6min.log" "$ROTATE_WARP6MIN_PID" "warp6min"
  done
}

# ─── Write all three rotation configs ──────────────────────────────────────────
write_all_rotate_configs(){
  local main_country
  main_country=$(curl -fsS --max-time 5 'http://ip-api.com/json?fields=countryCode' 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("countryCode","??"))' 2>/dev/null \
    || echo '??')

  gen_rotate_config "$ROTATE1MIN_INTERVAL" 10030 "$ROTATE1MIN_CONFIG" "$ROTATE1MIN_META" "$ROTATE1MIN_STATE" \
    "${UUID_ROTATE1MIN:-}" "${PATH_ROTATE1MIN:-}" "$main_country" "${DOMAIN}"
  gen_rotate_config "$ROTATE2MIN_INTERVAL" 10032 "$ROTATE2MIN_CONFIG" "$ROTATE2MIN_META" "$ROTATE2MIN_STATE" \
    "${UUID_ROTATE2MIN:-}" "${PATH_ROTATE2MIN:-}" "$main_country" "${DOMAIN}"
  gen_rotate_config "$ROTATE5MIN_INTERVAL" 10034 "$ROTATE5MIN_CONFIG" "$ROTATE5MIN_META" "$ROTATE5MIN_STATE" \
    "${UUID_ROTATE5MIN:-}" "${PATH_ROTATE5MIN:-}" "$main_country" "${DOMAIN}"
  # WARP rotation tiers — each cycles its own 3-plane WARP set on its cadence.
  # Only meaningful when the WARP planes (distinct free IPs) are actually up.
  if [[ "${WARP_PLANES_ACTIVE:-false}" == "true" ]]; then
    gen_warp_rotate_config "$ROTATE_WARP2MIN_CONFIG" "$ROTATE_WARP2MIN_META" "$ROTATE_WARP2MIN_STATE" \
      "${UUID_ROTATE_WARP2MIN:-}" "${PATH_ROTATE_WARP2MIN:-}" 10040
    gen_warp_rotate_config "$ROTATE_WARP4MIN_CONFIG" "$ROTATE_WARP4MIN_META" "$ROTATE_WARP4MIN_STATE" \
      "${UUID_ROTATE_WARP4MIN:-}" "${PATH_ROTATE_WARP4MIN:-}" 10042
    gen_warp_rotate_config "$ROTATE_WARP6MIN_CONFIG" "$ROTATE_WARP6MIN_META" "$ROTATE_WARP6MIN_STATE" \
      "${UUID_ROTATE_WARP6MIN:-}" "${PATH_ROTATE_WARP6MIN:-}" 10044
  fi
}

finalize(){
  rebuild_pool_from_leaderboard
  write_merged_sub
  write_health_json
  write_all_rotate_configs
}

# ─── Main ──────────────────────────────────────────────────────────────────────
main(){
  [[ -x "$XRAY_BIN" ]] || warn "xray binary not found; health checks will fail"
  # First run: full source refresh so pool + leaderboard + rotation configs
  # are all written before any rotation loop starts.
  refresh_sources
  if (( ONCE == 1 )); then log "One health cycle complete"; return 0; fi

# shellcheck disable=SC2034  # rotation-loop PIDs set here, used in cleanup()
  # Launch three rotation loops in background
  rotate_loop_1min &
# shellcheck disable=SC2034
  LOOP1MIN_PID=$!
  rotate_loop_2min &
# shellcheck disable=SC2034
  LOOP2MIN_PID=$!
  rotate_loop_5min &
# shellcheck disable=SC2034
  LOOP5MIN_PID=$!
  # WARP tiers only when the distinct-IP planes are up.
  if [[ "${WARP_PLANES_ACTIVE:-false}" == "true" ]]; then
    rotate_loop_warp_2min &
# shellcheck disable=SC2034
    LOOP_WARP2MIN_PID=$!
    rotate_loop_warp_4min &
# shellcheck disable=SC2034
    LOOP_WARP4MIN_PID=$!
    rotate_loop_warp_6min &
# shellcheck disable=SC2034
    LOOP_WARP6MIN_PID=$!
  fi

  log "Rotation loops started: 1min (10030), 2min (10032), 5min (10034); WARP 2min (10040), 4min (10042), 6min (10044)"
  log "Parallel health probes: up to $PARALLEL_PROBES concurrent, ${HEALTH_TIMEOUT}s timeout"

  # Two-tier scheduler:
  #  - every HEALTH_INTERVAL (20 min): parallel health-check the included pool
  #  - every SUBS_REFRESH_INTERVAL (2 h): refetch sources + merge new configs
  local elapsed=0
  while :; do
    sleep "$HEALTH_INTERVAL"; elapsed=$((elapsed + HEALTH_INTERVAL))
    if (( elapsed >= SUBS_REFRESH_INTERVAL )); then
      refresh_sources; elapsed=0
    else
      health_only
    fi
  done
}
main
